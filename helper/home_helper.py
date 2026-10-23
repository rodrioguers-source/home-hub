"""Long-lived helper for the SamsungTV menu bar app: Tuya lights and PSN.

Protocol (stdin/stdout, one JSON object per line):
  request:  {"id": 1, "method": "lights.status", "params": {"target": "all"}}
  response: {"id": 1, "ok": true, "result": ...} | {"id": 1, "ok": false, "error": "..."}

Methods: ping, lights.list, lights.status, lights.on, lights.off, lights.toggle,
lights.brightness {pct}, lights.temp {pct}, lights.colour {value},
lights.white {brightness, temp} (on + white mode in one command),
lights.apply {looks: [{index, on, mode: "white"|"colour", brightness, temp, colour}]} (a different look per bulb,
all in parallel; colour is hex at full value and brightness sets its level), psn.summary {force},
retry {what: "lights"|"psn"|"all"}. Targets are "all" or a 1-based index in luzes order.
SmartThings TV (see smartthings.py): st.state, st.retry, st.status {refresh}, st.caps, st.inputs,
st.set_input {id}, st.picture {mode, alt, ...}, st.sound {mode, alt}, st.apps, st.launch {app_id, app_name},
st.triggers {names} (Alexa virtual switches), st.reset_trigger {id}, st.washer (read-only washing machine state),
st.handover {to: "mac"|"hub"} (which host refreshes the SmartThings token), st.owner.
PS5 Remote Play (see ps5_control.py): ps5.wake {wait}, ps5.standby.

Secrets are read from 1Password once, kept in memory only, and scrubbed from any error text.
"""
import json
import logging
import os
import subprocess
import sys
import threading
import time
import warnings
from concurrent.futures import ThreadPoolExecutor

_proto = None


def _claim_stdout():
    """stdout is the protocol channel, so library prints (even from C) are redirected to stderr."""
    global _proto
    _proto = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    logging.disable(logging.WARNING)
    warnings.filterwarnings("ignore")


HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "luzes"))
import luzes  # noqa: E402
import secret_store  # noqa: E402

PSN_OP_ITEM = "PSN NPSSO"
PSN_TTL = 60

_out_lock = threading.Lock()
_secrets = set()


def _scrub(text):
    text = str(text)
    for s in _secrets:
        if s:
            text = text.replace(s, "***")
    return text[:240]


def _send(obj):
    line = json.dumps(obj, ensure_ascii=False, default=str)
    with _out_lock:
        _proto.write(line + "\n")
        _proto.flush()


# MARK: lights

class Lights:
    def __init__(self):
        self.lock = threading.Lock()
        self.state = "pending"
        self.error = None

    def ensure(self):
        """Loads keys once. After a failure it stays failed until retry(), so polling never re-prompts Touch ID."""
        with self.lock:
            if self.state == "pending":
                try:
                    devs = luzes.devices()
                    for d in devs:
                        _secrets.add(d.get("local_key", ""))
                    self.state = "ready"
                except Exception as e:
                    self.state = "failed"
                    self.error = "Couldn't read the light keys from 1Password ('Tuya Lamps')."
                    if not isinstance(e, luzes.LuzesError):
                        self.error = _scrub(e)
            if self.state != "ready":
                raise HelperError(self.error or "Lights unavailable", code="lights_unavailable")

    def retry(self):
        with self.lock:
            if self.state == "failed":
                self.state = "pending"
                self.error = None
                luzes._devices = None

    def list(self):
        self.ensure()
        return [{"index": i, "name": d["name"], "ip": d["ip"]} for i, d in enumerate(luzes.devices(), 1)]

    def call(self, method, params):
        self.ensure()
        target = str(params.get("target", "all"))
        if method == "status":
            rows = luzes.status(target)
        elif method in ("on", "off", "toggle"):
            rows = getattr(luzes, method)(target)
        elif method == "brightness":
            rows = luzes.set_brightness(int(params["pct"]), target)
        elif method == "temp":
            rows = luzes.set_temp(int(params["pct"]), target)
        elif method == "colour":
            rows = luzes.set_color(str(params["value"]), target)
        elif method == "white":
            bright, temp = int(params["brightness"]), int(params["temp"])
            rows = luzes._each(target, lambda b: b.set_white_percentage(bright, temp))
        elif method == "apply":
            looks = list(params.get("looks") or [])
            if not looks:
                return []
            with ThreadPoolExecutor(max_workers=len(looks)) as pool:
                rows = list(pool.map(_apply_look, looks))
        else:
            raise HelperError(f"Unknown method lights.{method}")
        index = {d["name"]: i for i, d in enumerate(luzes.devices(), 1)}
        clean = []
        for r in rows:
            row = {k: v for k, v in r.items() if k != "result"}
            row["index"] = index.get(r.get("name"), r.get("index"))
            if "error" in row:
                row["error"] = _scrub(row["error"])
            clean.append(row)
        return clean


def _apply_look(look):
    index = int(look["index"])
    try:
        return luzes._each(str(index), _look_fn(look))[0]
    except Exception as e:
        return {"name": f"Light {index}", "index": index, "ok": False, "error": str(e)}


def _look_fn(look):
    if not look.get("on", True):
        return lambda b: b.turn_off()
    bright = min(max(int(look.get("brightness", 100)), 1), 100)
    if look.get("mode") == "colour":
        import colorsys
        r, g, b_ = luzes.parse_color(str(look["colour"]))
        h, s, _ = colorsys.rgb_to_hsv(r / 255, g / 255, b_ / 255)
        return lambda b: b.set_hsv(h, s, bright / 100)
    temp = min(max(int(look.get("temp", 0)), 0), 100)
    return lambda b: b.set_white_percentage(bright, temp)


# MARK: PSN

class PSN:
    def __init__(self):
        self.lock = threading.Lock()
        self.client = None
        self.api = None
        self.state = "pending"
        self.error = None
        self.cache = None
        self.cached_at = 0.0

    def _load(self):
        try:
            npsso = (secret_store.get_field(PSN_OP_ITEM) or "").strip()
        except secret_store.SecretError as e:
            if e.code == "op_unavailable":
                self.state, self.error = "failed", "1Password CLI (op) isn't available."
            else:
                self.state, self.error = "failed", f"{e} {_scrub(e.detail)}".strip()
            return
        if not npsso:
            self.state, self.error = "missing", None
            return
        _secrets.add(npsso)
        try:
            from psnawp_api import PSNAWP
            self.api = PSNAWP(npsso)
            self.client = self.api.me()
            self.state = "ready"
        except Exception as e:
            self.state, self.error = "failed", _psn_error(e)

    def ensure(self):
        with self.lock:
            if self.state == "pending":
                self._load()

    def retry(self):
        with self.lock:
            if self.state in ("missing", "failed"):
                self.state, self.error, self.api, self.client = "pending", None, None, None
                self.cache, self.cached_at = None, 0.0

    def summary(self, force=False):
        if force:
            self.retry()
        self.ensure()
        with self.lock:
            if self.state != "ready":
                return {"configured": self.state != "missing", "state": self.state, "error": self.error}
            if self.cache and not force and time.time() - self.cached_at < PSN_TTL:
                return self.cache
            try:
                data = {"configured": True, "state": "ready", "error": None,
                        "online_id": self.client.online_id,
                        "presence": self._presence(),
                        "most_played": self._most_played()}
            except Exception as e:
                msg = _psn_error(e)
                if self.cache:
                    stale = dict(self.cache)
                    stale["error"] = msg
                    return stale
                return {"configured": True, "state": "error", "error": msg}
            data["fetched_at"] = time.time()
            self.cache, self.cached_at = data, time.time()
            return data

    def _presence(self):
        try:
            user = self.api.user(account_id=self.client.account_id)
            raw = user.get_presence().get("basicPresence", {})
        except Exception:
            return None
        platform = raw.get("primaryPlatformInfo", {}) or {}
        titles = raw.get("gameTitleInfoList") or []
        title = titles[0] if titles else {}
        return {
            "availability": raw.get("availability"),
            "online_status": platform.get("onlineStatus"),
            "platform": platform.get("platform"),
            "title": title.get("titleName"),
            "title_id": title.get("npTitleId"),
            "icon": title.get("conceptIconUrl") or title.get("npTitleIconUrl"),
        }

    def _most_played(self, top=5):
        stats = list(self.client.title_stats(limit=200))
        stats.sort(key=lambda t: t.play_duration.total_seconds() if t.play_duration else 0, reverse=True)
        out = []
        for t in stats[:top]:
            out.append({
                "title_id": t.title_id,
                "name": t.name,
                "image": t.image_url,
                "seconds": int(t.play_duration.total_seconds()) if t.play_duration else 0,
                "plays": t.play_count,
                "platform": t.category.name if t.category else None,
                "last_played": t.last_played_date_time.isoformat() if t.last_played_date_time else None,
            })
        return out


def _psn_error(e):
    name = type(e).__name__
    if name == "PSNAWPAuthenticationError" or name == "PSNAWPUnauthorized":
        return "PSN sign-in failed: the NPSSO has probably expired. Get a new one and update 'PSN NPSSO'."
    if name == "PSNAWPTooManyRequests":
        return "PSN is rate limiting requests. Try again in a few minutes."
    if name == "PSNAWPForbidden":
        return "PSN refused the request (privacy settings?)."
    if "Connection" in name or "Timeout" in name:
        return "Couldn't reach PSN."
    return f"PSN error ({name})."


class HelperError(Exception):
    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


lights = Lights()
psn = PSN()


def st_call(name, params):
    import smartthings as st
    if name == "state":
        return {"state": st.client.state, "error": st.client.error}
    if name == "retry":
        st.client.retry()
        return {"state": st.client.state}
    calls = {
        "status": lambda: st.status(refresh=bool(params.get("refresh"))),
        "caps": st.capability_report,
        "inputs": st.inputs,
        "set_input": lambda: st.set_input(str(params["id"])),
        "picture": lambda: st.set_picture(**params),
        "sound": lambda: st.set_sound(str(params["mode"]), params.get("alt")),
        "apps": st.apps,
        "launch": lambda: st.launch_app(params.get("app_id"), params.get("app_name")),
        "power_on": lambda: st.client.command("switch", "on") and None,
        "triggers": lambda: st.client.triggers([str(n) for n in params.get("names", [])]),
        "reset_trigger": lambda: st.client.reset_trigger(str(params["id"])),
        "claim_trigger": lambda: st.client.claim_trigger(str(params["id"])),
        "chain": st.client.chain,
        "washer": st.client.washer,
        "handover": lambda: st.client.handover(str(params.get("to", ""))),
        "owner": lambda: {"host": st.HOST_ID, "may_refresh": st.may_refresh(st.client.fields) if st.client.fields else None},
    }
    if name not in calls:
        raise HelperError(f"Unknown method st.{name}")
    try:
        return calls[name]()
    except st.SmartThingsError as e:
        raise HelperError(st.scrub(e), code=e.code)


def ps5_call(name, params):
    if name not in ("wake", "standby"):
        raise HelperError(f"Unknown method ps5.{name}")
    args = [name] + ([] if name == "standby" or params.get("wait") else ["--no-wait"])
    # Remote Play times out inside this threaded helper but works as a standalone process.
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ps5_control.py")
    try:
        proc = subprocess.run([sys.executable, script] + args, capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        raise HelperError("The PS5 didn't answer in time.", code="session_timeout")
    try:
        out = json.loads(proc.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise HelperError("The PS5 control script gave no answer.", code="standby_failed" if name == "standby" else "network")
    if not out.get("ok"):
        raise HelperError(out.get("error") or "PS5 command failed.", code=out.get("code"))
    return out.get("result")


def handle(req):
    rid = req.get("id")
    method = req.get("method", "")
    params = req.get("params") or {}
    try:
        if method == "ping":
            result = {"lights": lights.state, "psn": psn.state}
        elif method == "lights.list":
            result = lights.list()
        elif method.startswith("lights."):
            result = lights.call(method.split(".", 1)[1], params)
        elif method == "psn.summary":
            result = psn.summary(force=bool(params.get("force")))
        elif method.startswith("st."):
            result = st_call(method.split(".", 1)[1], params)
        elif method.startswith("ps5."):
            result = ps5_call(method.split(".", 1)[1], params)
        elif method == "retry":
            what = params.get("what", "all")
            if what in ("lights", "all"):
                lights.retry()
            if what in ("psn", "all"):
                psn.retry()
            result = {"lights": lights.state, "psn": psn.state}
        else:
            raise HelperError(f"Unknown method {method}")
        _send({"id": rid, "ok": True, "result": result})
    except HelperError as e:
        _send({"id": rid, "ok": False, "error": _scrub(e), "code": e.code})
    except Exception as e:
        _send({"id": rid, "ok": False, "error": _scrub(e)})


def _preload():
    for fn in (lights.ensure, psn.ensure):
        try:
            fn()
        except Exception:
            pass


def main():
    if "--no-preload" not in sys.argv:
        threading.Thread(target=_preload, daemon=True).start()
    pool = ThreadPoolExecutor(max_workers=6)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            _send({"id": None, "ok": False, "error": "Invalid JSON"})
            continue
        pool.submit(handle, req)
    pool.shutdown(wait=True)


if __name__ == "__main__":
    _claim_stdout()
    main()
