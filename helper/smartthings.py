"""SmartThings cloud control for the Samsung TV (picture mode, inputs, apps).

Auth is an OAuth-In SmartApp (see smartthings_auth.py). On the Mac the tokens live in the 1Password
item "SmartThings OAuth Mac" when it exists (its own authorisation, independent of the home hub's),
otherwise in "SmartThings OAuth". HOME_ST_ITEM forces a title. Refresh tokens are single-use, so every
refresh is written back.

    python smartthings.py devices|caps|status|inputs|apps|raw|washer
    python smartthings.py input <id> | launch <appId> [name] | picture mode=<m> [alt=<m>] [brightness=..] | sound <mode> [alt]
    python smartthings.py ocf-get <href> | ocf-set <href> '<json>'      (experimental)
"""
import base64
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import op_cli  # noqa: E402
import secret_store  # noqa: E402

API = "https://api.smartthings.com/v1"
AUTHORIZE_URL = "https://api.smartthings.com/oauth/authorize"
TOKEN_URLS = ["https://api.smartthings.com/oauth/token", "https://api.smartthings.com/v1/oauth/token"]
REDIRECT_URI = "https://httpbin.org/get"
SCOPES = ["r:devices:*", "w:devices:*", "x:devices:*"]
OP_ITEM = "SmartThings OAuth"
MAC_ITEM = "SmartThings OAuth Mac"
EARLY_REFRESH = 600

if os.name == "nt":
    import msvcrt
    LOCK_PATH = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "HomeHub", "smartthings.lock")
else:
    import fcntl
    LOCK_PATH = os.path.join(os.path.expanduser("~/Library/Caches"), "samsung-tv-smartthings.lock")

# The refresh token is single-use, and the file lock only covers one machine. The item's
# "refresh_owner" field says which host may refresh: "mac" (also when the field is missing) or "hub".
HOST_ID = os.environ.get("HOME_ST_HOST", "mac").strip().lower() or "mac"
OWNER_FIELD = "refresh_owner"

SECRET_FIELDS = ("client_id", "client_secret", "refresh_token", "access_token")

INPUT_CAPS = ("samsungvd.mediaInputSource", "mediaInputSource")
ALWAYS_LISTED_INPUTS = ({"id": "HDMI1", "name": "HDMI 1"},)
PICTURE_CAPS = ("samsungvd.pictureMode", "custom.picturemode")
SOUND_CAPS = ("samsungvd.soundMode", "custom.soundmode")
PICTURE_ADJUST_KEYS = ("brightness", "contrast", "sharpness", "colour", "color", "tint", "backlight")
INTERESTING_CAPS = ("switch", "refresh", "execute", "audioVolume", "audioMute", "tvChannel", "mediaPlayback",
                    "custom.launchapp", "samsungvd.thingStatus", "samsungvd.supportsPowerOnByOcf",
                    "samsungvd.supportsFeatures", "samsungvd.firmwareVersion") + INPUT_CAPS + PICTURE_CAPS + SOUND_CAPS


class SmartThingsError(Exception):
    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


_secrets = set()
_resolved = None


def item_title():
    """The item this host reads and writes. Before the first read on the Mac it's the shared one."""
    forced = (os.environ.get("HOME_ST_ITEM") or "").strip()
    if forced:
        return forced
    if secret_store.backend() != "op":
        return OP_ITEM
    return _resolved or OP_ITEM


def forget_item_choice():
    global _resolved
    _resolved = None


def scrub(text):
    text = str(text)
    for s in _secrets:
        if s and len(s) > 4:
            text = text.replace(s, "***")
    return text


def op_get_item(title=None):
    """Returns the full item JSON (with revealed values) or None if it doesn't exist."""
    title = title or item_title()
    try:
        r = op_cli.run(["item", "get", title, "--format", "json", "--reveal"], title=title)
    except Exception as e:
        raise SmartThingsError(f"1Password CLI (op) isn't available: {type(e).__name__}", "op_unavailable")
    if r.returncode != 0:
        err = r.stderr.lower()
        if "isn't an item" in err or "not found" in err or "no item" in err:
            return None
        raise SmartThingsError(f"Couldn't read '{title}' from 1Password: {scrub(r.stderr.strip())[:200]}", "op_failed")
    item = json.loads(r.stdout)
    for f in item.get("fields", []):
        if f.get("label") in SECRET_FIELDS and f.get("value"):
            _secrets.add(f["value"])
    return item


def item_fields(item):
    return {f.get("label"): f.get("value", "") for f in (item or {}).get("fields", []) if f.get("label")}


def _field(label, value, concealed=True):
    return {"id": label, "label": label, "type": "CONCEALED" if concealed else "STRING", "value": value}


def op_save_fields(values, title=None):
    """Creates or updates the item. Values travel on stdin only, never argv."""
    title = title or item_title()
    for k, v in values.items():
        if k in SECRET_FIELDS and v:
            _secrets.add(v)
    item = op_get_item(title)
    if item is None:
        template = {"title": title, "category": "API_CREDENTIAL",
                    "fields": [_field(k, str(v), k in SECRET_FIELDS) for k, v in values.items()]}
        cmd = ["item", "create"]
    else:
        fields = item.setdefault("fields", [])
        by_label = {f.get("label"): f for f in fields}
        for k, v in values.items():
            if k in by_label:
                by_label[k]["value"] = str(v)
            else:
                fields.append(_field(k, str(v), k in SECRET_FIELDS))
        template = item
        cmd = ["item", "edit", item["id"]]
    r = op_cli.run(cmd, title=title, input=json.dumps(template))
    if r.returncode != 0:
        raise SmartThingsError(f"Couldn't write '{title}' to 1Password: {scrub(r.stderr.strip())[:200]}", "op_write_failed")


def op_set_owner(owner, title=None):
    """Writes only the owner field (an assignment, not a whole-item template), so a token the other
    host saved a moment ago can't be overwritten with an older copy."""
    title = title or item_title()
    owner = str(owner).strip().lower()
    if owner not in ("mac", "hub"):
        raise SmartThingsError("Owner must be mac or hub", "bad_owner")
    r = op_cli.run(["item", "edit", title, f"{OWNER_FIELD}[text]={owner}"], title=title)
    if r.returncode != 0:
        raise SmartThingsError(f"Couldn't write '{title}' to 1Password: {scrub(r.stderr.strip())[:200]}", "op_write_failed")
    return owner


def read_fields(title=None):
    """The item's fields from whichever store this host uses (1Password on the Mac, the keyring on the hub).
    On the Mac the first read picks the Mac's own item if there is one, and sticks with it."""
    global _resolved
    if secret_store.backend() == "op":
        if title is None and _resolved is None and not (os.environ.get("HOME_ST_ITEM") or "").strip():
            own = op_get_item(MAC_ITEM)
            _resolved = MAC_ITEM if own is not None else OP_ITEM
            if own is not None:
                return item_fields(own)
        return item_fields(op_get_item(title or item_title()))
    title = title or item_title()
    try:
        f = secret_store.get_fields(title) or {}
    except secret_store.SecretError as e:
        raise SmartThingsError(str(e), e.code)
    for k in SECRET_FIELDS:
        if f.get(k):
            _secrets.add(f[k])
    return f


def save_fields(values, title=None):
    if secret_store.backend() == "op":
        return op_save_fields(values, title)
    for k, v in values.items():
        if k in SECRET_FIELDS and v:
            _secrets.add(v)
    try:
        secret_store.save_fields(title or item_title(), values)
    except secret_store.SecretError as e:
        raise SmartThingsError(str(e), "op_write_failed" if e.code == "keyring_write_failed" else e.code)


def set_owner(owner, title=None):
    if secret_store.backend() == "op":
        return op_set_owner(owner, title)
    owner = str(owner).strip().lower()
    if owner not in ("mac", "hub"):
        raise SmartThingsError("Owner must be mac or hub", "bad_owner")
    save_fields({OWNER_FIELD: owner}, title)
    return owner


def may_refresh(fields, host=None):
    owner = (fields.get(OWNER_FIELD) or "").strip().lower()
    return (owner or "mac") == (host or HOST_ID)


def _http(method, url, headers=None, body=None, timeout=20):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            data = json.loads(raw) if raw else {}
        except ValueError:
            data = {"raw": raw[:300].decode("utf-8", "replace")}
        return e.code, data
    except Exception as e:
        raise SmartThingsError(f"Couldn't reach SmartThings ({type(e).__name__})", "network")


def token_request(client_id, client_secret, form):
    """POSTs to the token endpoint. Only a 404 moves on to the next URL, so a single-use code/refresh token is never sent twice."""
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    headers = {"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded",
               "Accept": "application/json"}
    body = urllib.parse.urlencode(dict(form, client_id=client_id)).encode()
    for url in TOKEN_URLS:
        status, data = _http("POST", url, headers, body)
        if status == 404:
            continue
        if status != 200 or "access_token" not in data:
            err = data.get("error_description") or data.get("error") or data.get("message") or f"HTTP {status}"
            code = "reauth_needed" if data.get("error") in ("invalid_grant", "invalid_token", "unauthorized") else "token_failed"
            raise SmartThingsError(f"SmartThings token request failed: {scrub(err)}", code)
        for k in ("access_token", "refresh_token"):
            if data.get(k):
                _secrets.add(data[k])
        return data
    raise SmartThingsError("SmartThings token endpoint not found", "token_failed")


def authorize_url(client_id):
    q = {"client_id": client_id, "response_type": "code", "redirect_uri": REDIRECT_URI, "scope": " ".join(SCOPES)}
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode(q)


def tokens_to_fields(data):
    return {"access_token": data["access_token"], "refresh_token": data["refresh_token"],
            "access_expires_at": str(int(time.time()) + int(data.get("expires_in", 86399)))}


class _FileLock:
    """Cross-process lock so the menu-bar helper and a terminal run never refresh at the same time."""

    def __enter__(self):
        os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
        self.fh = open(LOCK_PATH, "a+")
        if os.name == "nt":
            while True:
                try:
                    self.fh.seek(0)
                    msvcrt.locking(self.fh.fileno(), msvcrt.LK_LOCK, 1)
                    break
                except OSError:
                    time.sleep(0.5)
        else:
            fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        if os.name == "nt":
            self.fh.seek(0)
            msvcrt.locking(self.fh.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


class SmartThings:
    def __init__(self):
        self.lock = threading.Lock()
        self.state = "pending"
        self.error = None
        self.fields = {}
        self._caps = None
        self._trigger_ids = set()
        self._washer_id = None
        self._washer_label = None

    # MARK: auth

    def ensure(self):
        """Loads once; after a failure stays failed until retry(), so polling never re-prompts Touch ID."""
        with self.lock:
            if self.state == "pending":
                try:
                    f = read_fields()
                    if not (f.get("client_id") and f.get("client_secret") and f.get("refresh_token")):
                        self.state, self.error = "missing", "SmartThings isn't set up. Run helper/smartthings_auth.py."
                    else:
                        self.fields, self.state, self.error = f, "ready", None
                except SmartThingsError as e:
                    self.state, self.error = "failed", str(e)
            if self.state != "ready":
                raise SmartThingsError(self.error or "SmartThings unavailable", f"st_{self.state}")

    def retry(self):
        with self.lock:
            if self.state in ("missing", "failed"):
                self.state, self.error, self.fields, self._caps = "pending", None, {}, None
                self._washer_id = None
                forget_item_choice()

    def _valid(self, f):
        try:
            return f.get("access_token") and int(f.get("access_expires_at") or 0) - EARLY_REFRESH > time.time()
        except ValueError:
            return False

    def access_token(self, force_refresh=False):
        self.ensure()
        with self.lock:
            if not force_refresh and self._valid(self.fields):
                return self.fields["access_token"]
            stale = self.fields.get("access_token")
            with _FileLock():
                # Another process may already have rotated the refresh token; re-read before using ours.
                fresh = read_fields() or self.fields
                if self._valid(fresh) and (not force_refresh or fresh.get("access_token") != stale):
                    self.fields = fresh
                    return fresh["access_token"]
                if not may_refresh(fresh):
                    self.fields = fresh
                    owner = (fresh.get(OWNER_FIELD) or "mac").strip().lower()
                    where = "the home hub" if owner == "hub" else "the Mac app"
                    raise SmartThingsError(f"SmartThings token refresh is owned by {where}, so this {HOST_ID} won't refresh it. "
                                           "Move it with python -m hub.send_secrets (or --back).", "st_not_owner")
                try:
                    data = token_request(fresh["client_id"], fresh["client_secret"],
                                         {"grant_type": "refresh_token", "refresh_token": fresh["refresh_token"]})
                except SmartThingsError as e:
                    if e.code == "reauth_needed":
                        self.state, self.error = "failed", "SmartThings authorisation expired. Run helper/smartthings_auth.py again."
                    raise
                new = tokens_to_fields(data)
                self.fields = dict(fresh, **new)
                save_fields(new)
            return self.fields["access_token"]

    # MARK: REST

    def api(self, method, path, body=None):
        for attempt in (0, 1):
            token = self.access_token(force_refresh=attempt == 1)
            headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
            data = None
            if body is not None:
                headers["Content-Type"] = "application/json"
                data = json.dumps(body).encode()
            status, resp = _http(method, API + path, headers, data)
            if status == 401 and attempt == 0:
                continue
            if status >= 400:
                err = resp.get("error", {}) if isinstance(resp.get("error"), dict) else {}
                msg = err.get("message") or resp.get("message") or f"HTTP {status}"
                details = "; ".join(d.get("message", "") for d in err.get("details", []) if isinstance(d, dict))
                raise SmartThingsError(scrub(f"SmartThings {method} {path} failed: {msg} {details}".strip()), f"http_{status}")
            return resp
        raise SmartThingsError("SmartThings rejected the token", "http_401")

    def devices(self):
        out, path = [], "/devices"
        while path:
            resp = self.api("GET", path)
            for d in resp.get("items", []):
                caps = [c["id"] for comp in d.get("components", []) if comp.get("id") == "main"
                        for c in comp.get("capabilities", [])]
                out.append({"deviceId": d.get("deviceId"), "label": d.get("label"), "name": d.get("name"),
                            "manufacturer": d.get("manufacturerName"), "type": d.get("type"),
                            "ocfDeviceType": (d.get("ocf") or {}).get("ocfDeviceType"), "capabilities": caps})
            nxt = (resp.get("_links") or {}).get("next") or {}
            path = nxt.get("href", "").replace(API, "") if nxt.get("href") else None
        return out

    def tv_device_id(self):
        self.ensure()
        if self.fields.get("device_id"):
            return self.fields["device_id"]
        tvs = [d for d in self.devices() if is_tv(d)]
        if not tvs:
            raise SmartThingsError("No TV found in this SmartThings account/location", "no_tv")
        device_id = tvs[0]["deviceId"]
        self.fields["device_id"] = device_id
        if may_refresh(self.fields):
            try:
                save_fields({"device_id": device_id})
            except SmartThingsError:
                pass
        return device_id

    def capabilities(self):
        if self._caps is None:
            d = self.api("GET", f"/devices/{self.tv_device_id()}")
            self._caps = sorted({c["id"] for comp in d.get("components", []) if comp.get("id") == "main"
                                 for c in comp.get("capabilities", [])})
        return self._caps

    def capability_report(self):
        caps = set(self.capabilities())
        return {"present": [c for c in INTERESTING_CAPS if c in caps],
                "missing": [c for c in INTERESTING_CAPS if c not in caps],
                "all": sorted(caps)}

    def _pick(self, options):
        caps = set(self.capabilities())
        return next((c for c in options if c in caps), None)

    def command(self, capability, command, arguments=None):
        cmd = {"component": "main", "capability": capability, "command": command}
        if arguments is not None:
            cmd["arguments"] = arguments
        return self.api("POST", f"/devices/{self.tv_device_id()}/commands", {"commands": [cmd]})

    def raw_status(self, refresh=False):
        if refresh and "refresh" in self.capabilities():
            try:
                self.command("refresh", "refresh")
                time.sleep(1.5)
            except SmartThingsError:
                pass
        return self.api("GET", f"/devices/{self.tv_device_id()}/status").get("components", {}).get("main", {})

    # MARK: high level

    def status(self, refresh=False):
        main = self.raw_status(refresh)
        try:
            health = self.api("GET", f"/devices/{self.tv_device_id()}/health").get("state")
        except SmartThingsError:
            health = None
        out = {"health": health, "power": _val(main, "switch", "switch")}
        icap = next((c for c in INPUT_CAPS if c in main), None)
        out["input_source"] = _val(main, icap, "inputSource") if icap else None
        pcap = next((c for c in PICTURE_CAPS if c in main), None)
        out["picture_mode"] = _val(main, pcap, "pictureMode") if pcap else None
        out["picture_modes"] = _modes(main, pcap, "supportedPictureModesMap", "supportedPictureModes") if pcap else []
        scap = next((c for c in SOUND_CAPS if c in main), None)
        out["sound_mode"] = _val(main, scap, "soundMode") if scap else None
        out["sound_modes"] = _modes(main, scap, "supportedSoundModesMap", "supportedSoundModes") if scap else []
        out["inputs"] = _input_list(main, icap) if icap else []
        out["volume"] = _val(main, "audioVolume", "volume")
        out["mute"] = _val(main, "audioMute", "mute")
        out["tv_channel"] = _val(main, "tvChannel", "tvChannel")
        out["tv_channel_name"] = _val(main, "tvChannel", "tvChannelName")
        out["picture_adjustments"] = find_attributes(main, PICTURE_ADJUST_KEYS)
        report = self.capability_report()
        out["capabilities"] = report["present"]
        out["missing_capabilities"] = report["missing"]
        return out

    def inputs(self):
        main = self.raw_status()
        icap = next((c for c in INPUT_CAPS if c in main), None)
        if not icap:
            raise SmartThingsError(f"TV exposes none of {', '.join(INPUT_CAPS)}", "unsupported")
        return {"capability": icap, "current": _val(main, icap, "inputSource"), "inputs": _input_list(main, icap)}

    def set_input(self, input_id):
        cap = self._pick(INPUT_CAPS)
        if not cap:
            raise SmartThingsError(f"TV exposes none of {', '.join(INPUT_CAPS)}", "unsupported")
        self.command(cap, "setInputSource", [input_id])
        return {"capability": cap, "input": input_id}

    def _set_mode(self, caps, command, mode, alt=None):
        """The capability takes a free string (mode id or display name). If the API rejects one form, try `alt`."""
        cap = self._pick(caps)
        if not cap:
            raise SmartThingsError(f"TV exposes none of {', '.join(caps)}", "unsupported")
        try:
            self.command(cap, command, [mode])
            return cap, mode
        except SmartThingsError as e:
            if not alt or alt == mode or e.code in ("http_401", "http_429") or not str(e.code or "").startswith("http_4"):
                raise
        self.command(cap, command, [alt])
        return cap, alt

    def set_picture(self, mode=None, alt=None, **adjust):
        done, unsupported = {}, {}
        sent = None
        if mode:
            cap, sent = self._set_mode(PICTURE_CAPS, "setPictureMode", mode, alt)
            done["mode"] = {"capability": cap, "value": sent}
        for k, v in adjust.items():
            unsupported[k] = v
        out = {"done": done, "sent": sent}
        if unsupported:
            out["unsupported"] = list(unsupported)
            out["note"] = ("SmartThings has no documented capability for brightness/contrast/sharpness/colour on TVs. "
                           "If 'execute' is present, try ocf_get()/ocf_set() with an href captured from the SmartThings app.")
            out["execute_available"] = "execute" in self.capabilities()
        return out

    def set_sound(self, mode, alt=None):
        cap, sent = self._set_mode(SOUND_CAPS, "setSoundMode", mode, alt)
        return {"capability": cap, "mode": sent, "sent": sent}

    def apps(self):
        """No published TV capability lists installed apps; return whatever this TV's status exposes."""
        main = self.raw_status(refresh=True)
        found = {}
        for cap, attrs in main.items():
            for attr, v in (attrs or {}).items():
                value = v.get("value") if isinstance(v, dict) else None
                if "app" in attr.lower() and isinstance(_load_list(value), list) and _load_list(value):
                    found[f"{cap}.{attr}"] = _load_list(value)
        return {"lists": found,
                "current": {"tv_channel": _val(main, "tvChannel", "tvChannel"),
                            "tv_channel_name": _val(main, "tvChannel", "tvChannelName")},
                "launch_capability": "custom.launchapp" if "custom.launchapp" in self.capabilities() else None,
                "note": None if found else ("This TV's SmartThings status has no installed-app list. Open the app on the TV, "
                                            "then check 'current' here, or probe IDs over the LAN REST API.")}

    def launch_app(self, app_id=None, app_name=None):
        if "custom.launchapp" not in self.capabilities():
            raise SmartThingsError("TV doesn't expose custom.launchapp", "unsupported")
        if not (app_id or app_name):
            raise SmartThingsError("launch_app needs app_id or app_name")
        args = [app_id] if app_id and not app_name else [app_id or "", app_name]
        self.command("custom.launchapp", "launchApp", args)
        return {"app_id": app_id, "app_name": app_name}

    # MARK: voice triggers (virtual switches Alexa turns on)

    def triggers(self, names):
        """One batched call: every virtual switch whose label is in `names`, with its state and when it last changed."""
        wanted = {n.lower(): n for n in names}
        found, path = [], "/devices?type=VIRTUAL&capability=switch&includeStatus=true"
        while path:
            resp = self.api("GET", path)
            for d in resp.get("items", []):
                label = (d.get("label") or d.get("name") or "").strip()
                if label.lower() not in wanted:
                    continue
                main = next((c for c in d.get("components", []) if c.get("id") == "main"), {})
                cap = next((c for c in main.get("capabilities", []) if c.get("id") == "switch"), {})
                sw = (cap.get("status") or {}).get("switch") or {}
                found.append({"device_id": d.get("deviceId"), "name": wanted[label.lower()],
                              "on": sw.get("value") == "on", "changed_at": sw.get("timestamp")})
            nxt = ((resp.get("_links") or {}).get("next") or {}).get("href")
            path = nxt.replace(API, "") if nxt else None
        self._trigger_ids = {t["device_id"] for t in found}
        seen = {t["name"] for t in found}
        return {"triggers": found, "missing": [n for n in names if n not in seen]}

    def handover(self, owner):
        """Says which host refreshes the token from now on; the next refresh re-reads the item."""
        with self.lock:
            with _FileLock():
                done = set_owner(owner)
            self.fields[OWNER_FIELD] = done
        return {"owner": done}

    def reset_trigger(self, device_id):
        # Only ids the last triggers() call returned, so a bad id can never switch off the TV.
        if device_id not in self._trigger_ids:
            raise SmartThingsError("Not a known voice-trigger switch", "unknown_trigger")
        self.api("POST", f"/devices/{device_id}/commands",
                 {"commands": [{"component": "main", "capability": "switch", "command": "off"}]})
        return {"device_id": device_id, "on": False}

    def claim_trigger(self, device_id):
        """Switches a voice trigger off only if it still reads on, and says whether this call was the one that
        did it. The Mac and the hub both use it, so when both are polling only the first one runs the scene."""
        if device_id not in self._trigger_ids:
            raise SmartThingsError("Not a known voice-trigger switch", "unknown_trigger")
        now = self.api("GET", f"/devices/{device_id}/components/main/capabilities/switch/status")
        if ((now or {}).get("switch") or {}).get("value") != "on":
            return {"device_id": device_id, "claimed": False}
        self.api("POST", f"/devices/{device_id}/commands",
                 {"commands": [{"component": "main", "capability": "switch", "command": "off"}]})
        return {"device_id": device_id, "claimed": True}

    def chain(self):
        """Which item this host uses and whether it may refresh it, so the Mac knows if it has its own tokens."""
        self.ensure()
        return {"item": item_title(), "may_refresh": may_refresh(self.fields)}

    # MARK: washing machine (read-only)

    def washer(self):
        """Compact state of the first oic.d.washer. Only ever GETs; never sends the washer a command."""
        self.ensure()
        if not self._washer_id:
            found = next((d for d in self.devices() if d.get("ocfDeviceType") == "oic.d.washer"), None)
            if not found:
                return {"found": False}
            self._washer_id, self._washer_label = found["deviceId"], found.get("label") or found.get("name")
        try:
            main = self.api("GET", f"/devices/{self._washer_id}/status").get("components", {}).get("main", {})
        except SmartThingsError as e:
            if e.code in ("http_403", "http_404"):
                self._washer_id = None
            raise
        return washer_summary(main, self._washer_label)

    # MARK: experimental OCF passthrough (undocumented for TVs)

    def ocf_get(self, href):
        self.command("execute", "execute", [href])
        time.sleep(1.5)
        return _val(self.raw_status(), "execute", "data")

    def ocf_set(self, href, props):
        self.command("execute", "execute", [href, props])
        time.sleep(1.5)
        return _val(self.raw_status(), "execute", "data")


def is_tv(d):
    caps = set(d.get("capabilities") or [])
    return (d.get("ocfDeviceType") == "oic.d.tv" or any(c.startswith("samsungvd.") for c in caps)
            or "tvChannel" in caps or "samsungTv" in caps)


MACHINE_STATES = {"run": "running", "pause": "paused", "stop": "ready"}


def washer_summary(main, label=None):
    ce, std = "samsungce.washerOperatingState", "washerOperatingState"
    used = [(ce, "operatingState"), (ce, "washerJobPhase"), (ce, "washerJobState"), (ce, "progress"),
            (ce, "remainingTime"), (std, "machineState"), (std, "completionTime")]
    state = _val(main, ce, "operatingState") or MACHINE_STATES.get(_val(main, std, "machineState"))
    since = _stamp(main, ce, "operatingState") if _val(main, ce, "operatingState") else _stamp(main, std, "machineState")
    phases = [{"name": p.get("phaseName"), "minutes": p.get("timeInMin")}
              for p in _load_list(_val(main, ce, "scheduledPhases")) if isinstance(p, dict) and p.get("phaseName")]
    stamps = [s for s in (_stamp(main, c, a) for c, a in used) if s]
    return {"found": True, "label": label, "state": state, "state_since": since,
            "phase": _val(main, ce, "washerJobPhase") or _val(main, ce, "washerJobState") or _val(main, std, "washerJobState"),
            "job_state": _val(main, ce, "washerJobState") or _val(main, std, "washerJobState"),
            "progress": _int(_val(main, ce, "progress")), "remaining_min": _int(_val(main, ce, "remainingTime")),
            "operation_min": _int(_val(main, ce, "operationTime")),
            "completion_time": _val(main, std, "completionTime"), "phases": phases,
            "temp": _val(main, "custom.washerWaterTemperature", "washerWaterTemperature"),
            "spin": _val(main, "custom.washerSpinLevel", "washerSpinLevel"),
            "rinses": _val(main, "custom.washerRinseCycles", "washerRinseCycles"),
            "kids_lock": _val(main, "samsungce.kidsLock", "lockState") == "locked",
            "updated_at": max(stamps) if stamps else None}


def _stamp(main, cap, attr):
    v = (main.get(cap) or {}).get(attr)
    return v.get("timestamp") if isinstance(v, dict) else None


def _int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _val(main, cap, attr):
    v = (main.get(cap) or {}).get(attr) if cap else None
    return v.get("value") if isinstance(v, dict) else None


def _load_list(value):
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            return []
    return value if isinstance(value, list) else []


def _modes(main, cap, map_attr, list_attr):
    m = _load_list(_val(main, cap, map_attr))
    if m:
        return [{"id": x.get("id"), "name": x.get("name") or x.get("id")} for x in m if isinstance(x, dict)]
    return [{"id": x, "name": x} for x in _load_list(_val(main, cap, list_attr))]


def _input_list(main, cap):
    sources = _load_list(_val(main, cap, "supportedInputSourcesMap"))
    if not sources:
        sources = [{"id": s, "name": s} for s in _load_list(_val(main, cap, "supportedInputSources"))]
    out = [{"id": s.get("id"), "name": s.get("name") or s.get("id")} if isinstance(s, dict)
           else {"id": s, "name": s} for s in sources]
    # The TV only lists inputs it detects, so the Switch's port vanishes while the Switch is off.
    for inp in ALWAYS_LISTED_INPUTS:
        if out and not any(o["id"] == inp["id"] for o in out):
            after = [i for i, o in enumerate(out) if str(o["id"]).startswith("HDMI") and str(o["id"]) > inp["id"]]
            out.insert(after[0] if after else len(out), dict(inp))
    return out


def find_attributes(main, keys):
    out = {}
    for cap, attrs in main.items():
        for attr, v in (attrs or {}).items():
            if any(k in attr.lower() for k in keys) and isinstance(v, dict):
                out[f"{cap}.{attr}"] = v.get("value")
    return out


client = SmartThings()
devices = client.devices
tv_device_id = client.tv_device_id
status = client.status
set_picture = client.set_picture
inputs = client.inputs
set_input = client.set_input
set_sound = client.set_sound
apps = client.apps
launch_app = client.launch_app
capability_report = client.capability_report


def _coerce(v):
    try:
        return int(v)
    except ValueError:
        return v


def main(argv):
    if not argv:
        sys.exit(__doc__)
    cmd, args = argv[0], argv[1:]
    try:
        if cmd == "devices":
            result = [{k: d[k] for k in ("deviceId", "label", "manufacturer", "ocfDeviceType")} for d in devices()]
        elif cmd == "caps":
            result = capability_report()
        elif cmd == "status":
            result = status(refresh="--refresh" in args)
        elif cmd == "raw":
            result = client.raw_status(refresh=True)
        elif cmd == "washer":
            result = client.washer()
        elif cmd == "inputs":
            result = inputs()
        elif cmd == "input":
            result = set_input(args[0])
        elif cmd == "sound":
            result = set_sound(args[0], args[1] if len(args) > 1 else None)
        elif cmd == "apps":
            result = apps()
        elif cmd == "launch":
            result = launch_app(args[0], args[1] if len(args) > 1 else None)
        elif cmd == "picture":
            kw = dict(a.split("=", 1) for a in args)
            result = set_picture(**{k: _coerce(v) for k, v in kw.items()})
        elif cmd == "ocf-get":
            result = client.ocf_get(args[0])
        elif cmd == "ocf-set":
            result = client.ocf_set(args[0], json.loads(args[1]))
        else:
            sys.exit(f"Unknown command: {cmd}\n{__doc__}")
    except SmartThingsError as e:
        sys.exit(f"Erro: {scrub(e)}")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main(sys.argv[1:])
