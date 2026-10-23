"""The phone web app and the Mac's hub API on port 8787: HTTP server, pairing and routes (WebServer.swift,
WebAccess.swift, WebAPI.swift)."""
import asyncio
import datetime
import hashlib
import hmac
import json
import os
import re
import secrets
import time
import urllib.parse

from . import glance, icons, lan
from . import lights as L
from . import ps5 as P
from .helper import Failure
from .scenes import AUTOMATIONS, SCENES, scene_by_id, summary
from .store import JSONFile
from .tv import ALL_APPS, CONSOLES, FAVOURITES, ON, PS5_INPUT, PS5_INPUT_NAME, STANDBY, RemoteSocket, app_by_key, input_label

MAX_HEADER = 16 * 1024
MAX_BODY = 64 * 1024
COOKIE = "stv_device"
CSP = ("default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
       "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
REASONS = {200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
           404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 415: "Unsupported Media Type",
           421: "Misdirected Request", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
           500: "Internal Server Error", 502: "Bad Gateway"}
KEYS = {"KEY_UP", "KEY_DOWN", "KEY_LEFT", "KEY_RIGHT", "KEY_ENTER", "KEY_RETURN", "KEY_HOME", "KEY_MENU", "KEY_EXIT",
        "KEY_VOLUP", "KEY_VOLDOWN", "KEY_MUTE", "KEY_SOURCE", "KEY_HDMI", "KEY_PLAY", "KEY_PAUSE", "KEY_STOP",
        "KEY_REWIND", "KEY_FF", "KEY_CHUP", "KEY_CHDOWN"}
RPC_METHODS = {"st.status", "st.inputs", "st.set_input", "st.picture", "st.sound", "st.apps", "st.launch", "st.power_on",
               "st.caps", "st.state", "st.retry"}
WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")


class Request:
    def __init__(self, method, path, query, headers, body, remote):
        self.method, self.path, self.query, self.headers, self.body, self.remote = method, path, query, headers, body, remote

    def cookie(self, name):
        for part in (self.headers.get("cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == name and v:
                return v
        return None

    def json(self):
        try:
            v = json.loads(self.body or b"null")
        except ValueError:
            return None
        return v if isinstance(v, dict) else None


class Response:
    def __init__(self, status, type, body, headers=None):
        self.status, self.type, self.body, self.headers = status, type, body, list(headers or [])

    @classmethod
    def json(cls, obj, status=200):
        return cls(status, "application/json; charset=utf-8", json.dumps(obj, sort_keys=True, ensure_ascii=False).encode())

    @classmethod
    def error(cls, status, message, code=None):
        body = {"ok": False, "error": message}
        if code:
            body["code"] = code
        return cls.json(body, status)

    @classmethod
    def text(cls, status, text, type="text/plain; charset=utf-8"):
        return cls(status, type, text.encode())

    def serialised(self):
        fixed = [("Content-Type", self.type), ("Content-Length", str(len(self.body))), ("Connection", "close"),
                 ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), ("X-Frame-Options", "DENY"),
                 ("Referrer-Policy", "no-referrer"), ("Content-Security-Policy", CSP)]
        head = f"HTTP/1.1 {self.status} {REASONS.get(self.status, 'Status')}\r\n"
        head += "".join(f"{k}: {v}\r\n" for k, v in fixed + self.headers)
        return (head + "\r\n").encode() + self.body


def parse(buffer, remote):
    """('incomplete', None), ('invalid', Response) or ('request', Request)."""
    end = buffer.find(b"\r\n\r\n")
    if end < 0:
        return ("invalid", Response.text(431, "Headers too large.")) if len(buffer) > MAX_HEADER else ("incomplete", None)
    if end > MAX_HEADER:
        return "invalid", Response.text(431, "Headers too large.")
    lines = buffer[:end].decode("utf-8", "replace").split("\r\n")
    start = lines[0].split(" ")
    if len(start) != 3 or not start[2].startswith("HTTP/1."):
        return "invalid", Response.text(400, "Bad request.")
    headers = {}
    for line in lines[1:]:
        k, sep, v = line.partition(":")
        if sep:
            headers[k.strip().lower()] = v.strip()
    try:
        length = int(headers.get("content-length") or "0")
    except ValueError:
        length = -1
    if length < 0:
        return "invalid", Response.text(400, "Bad Content-Length.")
    if length > MAX_BODY:
        return "invalid", Response.text(413, "Body too large.")
    body_start = end + 4
    if len(buffer) - body_start < length:
        return "incomplete", None
    path, _, qs = start[1].partition("?")
    query = {}
    for item in qs.split("&") if qs else []:
        k, _, v = item.partition("=")
        query[urllib.parse.unquote(k)] = urllib.parse.unquote(v)
    return "request", Request(start[0], path, query, headers, buffer[body_start:body_start + length], remote)


class Server:
    def __init__(self, handler, port, bind="auto", log=None):
        self.handler, self.port, self.bind = handler, port, bind
        self.log = log or (lambda m: None)
        self.servers = []
        self.addresses = []

    def wanted(self):
        if isinstance(self.bind, list):
            return list(self.bind)
        lanip = lan.primary_address()
        return ["127.0.0.1"] + ([lanip] if lanip else []) + ["100.64.72.81"]

    async def start(self):
        await self.stop()
        self.addresses = self.wanted()
        for host in self.addresses:
            try:
                self.servers.append(await asyncio.start_server(self._client, host, self.port, reuse_address=True))
                self.log(f"listening on http://{host}:{self.port}")
            except OSError as e:
                self.log(f"couldn't listen on {host}:{self.port}: {e}")

    async def stop(self):
        for s in self.servers:
            s.close()
            try:
                await s.wait_closed()
            except Exception:
                pass
        self.servers = []

    async def watch(self):
        """Rebinds when the laptop's LAN address changes (a new DHCP lease, another network)."""
        while True:
            await asyncio.sleep(60)
            if self.wanted() != self.addresses:
                await self.start()

    async def _client(self, reader, writer):
        peer = (writer.get_extra_info("peername") or ("", 0))[0]
        try:
            if not lan.is_local(peer):
                writer.write(Response.text(403, "Local network only.").serialised())
                await writer.drain()
                return
            await asyncio.wait_for(self._serve(reader, writer, peer), 15)
        except Exception:
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _serve(self, reader, writer, peer):
        buffer = b""
        while True:
            data = await reader.read(65536)
            if data:
                buffer += data
            kind, value = parse(buffer, peer)
            if kind == "incomplete":
                if not data:
                    return
                continue
            if kind == "invalid":
                response = value
            else:
                try:
                    response = await self.handler(value)
                except Exception as e:
                    self.log(f"handler error: {type(e).__name__}: {e}")
                    response = Response.error(500, "Something went wrong on the hub.")
            writer.write(response.serialised())
            await writer.drain()
            return


class PairingStore:
    CODE_LIFETIME = 5 * 60
    WRONG_ALLOWED = 5
    ATTEMPTS = 10
    WINDOW = 10 * 60

    def __init__(self, path, clock=time.time):
        self.file = JSONFile(path, {"version": 1, "devices": []})
        self.devices = list(self.file.data.get("devices") or [])
        self.now = clock
        self.code = None
        self.code_expires = None
        self._wrong = 0
        self._attempts = {}

    @staticmethod
    def hash(token):
        return hashlib.sha256(token.encode()).hexdigest()

    @property
    def active_code(self):
        if self.code and self.code_expires and self.now() < self.code_expires:
            return self.code
        return None

    def start(self):
        self.code = f"{secrets.randbelow(1_000_000):06d}"
        self.code_expires = self.now() + self.CODE_LIFETIME
        self._wrong = 0
        return self.code

    def cancel(self):
        self.code = self.code_expires = None
        self._wrong = 0

    def pair(self, attempt, label, address):
        t = self.now()
        recent = [a for a in self._attempts.get(address, []) if t - a < self.WINDOW]
        if len(recent) >= self.ATTEMPTS:
            return "limited", None
        recent.append(t)
        self._attempts[address] = recent
        expected = self.active_code
        if not expected:
            return "no_code", None
        if not hmac.compare_digest(attempt.encode(), expected.encode()):
            self._wrong += 1
            if self._wrong >= self.WRONG_ALLOWED:
                self.cancel()
            return "wrong", None
        self.cancel()
        token = secrets.token_urlsafe(32)
        name = "".join(ch for ch in label if ch not in "\r\n")[:60] or "Phone"
        stamp = _iso(t)
        self.devices.append({"hash": self.hash(token), "label": name, "pairedAt": stamp, "lastSeen": stamp})
        self._persist()
        return "paired", token

    def authorised(self, token):
        if not token or not 40 <= len(token) <= 64:
            return False
        h = self.hash(token)
        for d in self.devices:
            if hmac.compare_digest(d["hash"], h):
                seen = _parse_iso(d.get("lastSeen"))
                if seen is None or self.now() - seen > 3600:
                    d["lastSeen"] = _iso(self.now())
                    self._persist()
                return True
        return False

    def forget_all(self):
        self.devices = []
        self._persist()

    def shared(self):
        """What the Mac mirrors so a phone paired here also works on it: hashes, never tokens."""
        return [{"hash": d["hash"], "label": d.get("label", "Phone"), "pairedAt": d.get("pairedAt")} for d in self.devices]

    def import_devices(self, items):
        """Adds phones the Mac paired while the hub was down. Only well-formed hashes that aren't known yet."""
        known = {d["hash"] for d in self.devices}
        added = 0
        for item in items[:50]:
            h = item.get("hash") if isinstance(item, dict) else None
            if not isinstance(h, str) or not re.fullmatch(r"[0-9a-f]{64}", h) or h in known:
                continue
            label = "".join(ch for ch in str(item.get("label") or "Phone") if ch not in "\r\n")[:60] or "Phone"
            stamp = item.get("pairedAt") if _parse_iso(item.get("pairedAt")) is not None else _iso(self.now())
            self.devices.append({"hash": h, "label": label, "pairedAt": stamp, "lastSeen": None})
            known.add(h)
            added += 1
        if added:
            self._persist()
        return added

    def _persist(self):
        self.file.data = {"version": 1, "devices": self.devices}
        self.file.save()


def _iso(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_iso(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def device_label(ua):
    ua = ua or ""
    device = ("iPhone" if "iPhone" in ua else "iPad" if "iPad" in ua else "Android" if "Android" in ua
              else "Mac" if "Macintosh" in ua else "Browser")
    browser = " · Chrome" if ("CriOS" in ua or "Chrome" in ua) else " · Safari" if "Safari" in ua else ""
    if "SamsungTVRemote" in ua:
        return "Mac app"
    return device + browser


def load_page():
    with open(os.path.join(WEB_DIR, "index.html"), encoding="utf-8") as f:
        return f.read()


class API:
    def __init__(self, hub):
        self.hub = hub
        self.page = load_page()
        self._icons = {}
        self._art = {}
        self._lights_asked = 0
        self._ps5_asked = 0

    def _host_allowed(self, header):
        if not header:
            return False
        host = header.lower()
        if host.startswith("["):
            return False
        host = host.rsplit(":", 1)[0] if ":" in host else host
        allowed = {"localhost", "127.0.0.1"} | set(lan.own_addresses()) | lan.host_names() | set(self.hub.server.addresses)
        if self.hub.cfg.get("mdns_name"):
            allowed.add(f"{self.hub.cfg['mdns_name'].lower()}.local")
        return host in allowed

    @staticmethod
    def _post_refusal(r):
        if not (r.headers.get("content-type") or "").lower().startswith("application/json"):
            return Response.error(415, "Send JSON.")
        origin = r.headers.get("origin")
        if origin is not None and origin != f"http://{r.headers.get('host', '')}":
            return Response.error(403, "Cross-origin requests aren't allowed.")
        return None

    async def handle(self, r):
        if not self._host_allowed(r.headers.get("host")):
            return Response.text(421, "Unknown host.")
        key = (r.method, r.path)
        if key in (("GET", "/"), ("GET", "/index.html")):
            dark = self.hub.theme == "dark"
            page = (self.page.replace("{{THEME}}", "dark" if dark else "light")
                    .replace("{{BAR}}", "#111215" if dark else "#1428A0").replace("{{ROOM}}", self.hub.cfg["room"]))
            return Response.text(200, page, "text/html; charset=utf-8")
        if key == ("GET", "/manifest.webmanifest"):
            room = self.hub.cfg["room"]
            resp = Response.json({"name": room, "short_name": room, "start_url": "/", "scope": "/", "display": "standalone",
                                  "background_color": "#111215", "theme_color": "#1428A0",
                                  "icons": [{"src": "/icon-180.png", "sizes": "180x180", "type": "image/png"},
                                            {"src": "/icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any"}]})
            resp.type = "application/manifest+json"
            return resp
        if key in (("GET", "/icon-180.png"), ("GET", "/apple-touch-icon.png")):
            return self._icon(180)
        if key == ("GET", "/icon-512.png"):
            return self._icon(512)
        if key == ("POST", "/api/pair"):
            return self._post_refusal(r) or self._pair(r)
        if key == ("POST", "/api/pairing/local-start"):
            refused = self._post_refusal(r)
            if refused:
                return refused
            if r.remote not in ("127.0.0.1", "::1"):
                return Response.error(403, "Only from the hub laptop itself.")
            return self._start_pairing()
        if not r.path.startswith("/api/"):
            return Response.text(404, "Not found.")
        if not self.hub.pairing.authorised(r.cookie(COOKIE)):
            return Response.error(401, "This device isn't paired.", "unpaired")
        if r.method == "GET":
            if r.path == "/api/state":
                self._refresh(r.query.get("focus"))
                return Response.json(self.snapshot())
            if r.path == "/api/hub":
                return Response.json(self.hub_state())
            if r.path == "/api/devices":
                return Response.json({"devices": self.hub.pairing.shared()})
            if r.path.startswith("/api/art/"):
                return await self._artwork(r.path[len("/api/art/"):])
            return Response.text(404, "Not found.")
        if r.method != "POST":
            return Response.error(405, "Method not allowed.")
        refused = self._post_refusal(r)
        if refused:
            return refused
        body = r.json() or {}
        if r.path == "/api/rpc":
            return await self._rpc(body)
        if r.path.startswith("/api/presets/"):
            return await self._presets(r.path, body)
        if r.path == "/api/devices/import":
            if not isinstance(body.get("devices"), list):
                return Response.error(400, "Send the devices to add.")
            added = self.hub.pairing.import_devices(body["devices"])
            if added:
                self.hub.log(f"added {added} phone(s) paired on the Mac while the hub was down")
            return Response.json({"ok": True, "added": added})
        return self.act(r.path, body)

    async def _presets(self, path, b):
        lm, store = self.hub.lights, self.hub.lights.presets
        if path == "/api/presets/import":
            if not isinstance(b.get("slots"), list):
                return Response.error(400, "Send the slots to copy.")
            imported, kept, invalid = store.import_slots(b["slots"])
            self.hub.log(f"presets imported into slots {imported}, kept {kept}")
            return Response.json({"ok": True, "imported": imported, "kept": kept, "invalid": invalid})
        slot = b.get("slot")
        if not L.valid_slot(slot):
            return Response.error(400, "Pick a slot from 1 to 5.")
        if b.get("name") is not None and not isinstance(b.get("name"), str):
            return Response.error(400, "The name must be text.")
        if path == "/api/presets/save":
            if lm.preset_busy:
                return Response.error(409, "A preset is already being applied.", "busy")
            lm.preset_busy = f"slot-{slot}"
            try:
                looks, missing = await lm.capture_looks()
            except Failure as e:
                return Response.error(502, f"Couldn't read the lights: {e}", e.code)
            finally:
                lm.preset_busy = None
            p = store.save(slot, b.get("name"), looks)
            note = f"Saved without {L.join_names(missing)} (didn't respond)." if missing else None
            return Response.json({"ok": True, "id": p["id"], "name": p["name"], "note": note})
        if path == "/api/presets/put":
            looks = L.clean_looks(b.get("looks"))
            if looks is None:
                return Response.error(400, "Those looks aren't valid.")
            p = store.save(slot, b.get("name"), looks)
            return Response.json({"ok": True, "id": p["id"], "name": p["name"]})
        if path == "/api/presets/rename":
            if not store.rename(slot, b.get("name")):
                return Response.error(409, "That slot is empty.", "empty")
            return Response.json({"ok": True, "name": store.slots[slot]["name"]})
        if path == "/api/presets/clear":
            store.clear(slot)
            return Response.json({"ok": True})
        return Response.text(404, "Not found.")

    def _pair(self, r):
        code = "".join(ch for ch in str((r.json() or {}).get("code") or "") if ch.isdigit())
        outcome, token = self.hub.pairing.pair(code, device_label(r.headers.get("user-agent")), r.remote)
        if outcome == "paired":
            resp = Response.json({"ok": True})
            resp.headers.append(("Set-Cookie", f"{COOKIE}={token}; Path=/; Max-Age=34560000; HttpOnly; SameSite=Strict"))
            return resp
        if outcome == "wrong":
            return Response.error(401, "That code isn't right. Check the hub and try again.", "wrong")
        if outcome == "no_code":
            return Response.error(403, "No pairing code is active. On the hub laptop, run python -m hub.pair first.", "no_code")
        return Response.error(429, "Too many tries. Wait a few minutes.", "limited")

    def _start_pairing(self):
        code = self.hub.pairing.start()
        self.hub.log("pairing code issued (valid 5 min)")
        return Response.json({"ok": True, "code": code, "expires": self.hub.pairing.code_expires})

    async def _rpc(self, b):
        method, params = b.get("method"), b.get("params") or {}
        if method not in RPC_METHODS or not isinstance(params, dict):
            return Response.error(400, "Not an allowed method.")
        try:
            result = await self.hub.helper.call(method, params)
        except Failure as e:
            return Response.json({"ok": False, "error": str(e), "code": e.code})
        if method == "st.status":
            self.hub.st.absorb(result)
            self.hub.st.fetched_at = self.hub.st.ok_at = time.time()
            self.hub.st.phase = self.hub.st.READY
        return Response.json({"ok": True, "result": result})

    def act(self, path, b):
        hub = self.hub
        ok = Response.json({"ok": True})
        tv_off = Response.error(409, "The TV isn't on.", "tv_off")
        if path == "/api/tv/power":
            if not isinstance(b.get("on"), bool):
                return Response.error(400, "Say on or off.")
            hub.tv.power_on() if b["on"] else hub.tv.power_off()
        elif path == "/api/tv/key":
            if b.get("key") not in KEYS:
                return Response.error(400, "Unknown key.")
            if hub.tv.power != ON:
                return tv_off
            hub.tv.key(b["key"])
        elif path == "/api/tv/app":
            app = app_by_key(b.get("app")) if isinstance(b.get("app"), str) else None
            if not app:
                return Response.error(400, "Unknown app.")
            if hub.tv.power != ON:
                return tv_off
            hub.tv.launch(app)
        elif path == "/api/tv/input":
            known = [i["id"] for i in (hub.st.status or {}).get("inputs") or []] + [PS5_INPUT]
            if b.get("id") not in known:
                return Response.error(400, "Unknown input.")
            if hub.tv.power != ON:
                return tv_off
            hub.tv_input(b["id"])
        elif path in ("/api/lights/power", "/api/lights/brightness", "/api/lights/temp", "/api/lights/colour"):
            return self._lights(path, b)
        elif path == "/api/lights/preset":
            p = next((p for p in hub.lights.all_presets() if p["id"] == b.get("id")), None)
            if not p:
                return Response.error(400, "Unknown preset.")
            if hub.lights.preset_busy:
                return Response.error(409, "A preset is already being applied.", "busy")
            asyncio.ensure_future(hub.lights.run_preset(p))
        elif path == "/api/scenes/run":
            scene = scene_by_id(b.get("id"))
            if not scene:
                return Response.error(400, "Unknown scene.")
            if hub.runner.running:
                return Response.error(409, "Another scene is running.", "busy")
            hub.runner.run(scene)
        elif path == "/api/scenes/clear":
            hub.runner.dismiss()
        elif path == "/api/scenes/app":
            scene, app = scene_by_id(b.get("scene")), app_by_key(b.get("app")) if isinstance(b.get("app"), str) else None
            if not scene or not app or not scene.get("default_app"):
                return Response.error(400, "Unknown scene or app.")
            hub.runner.set_app(scene, app)
        elif path == "/api/automations/set":
            if b.get("kind") not in AUTOMATIONS or not isinstance(b.get("on"), bool):
                return Response.error(400, "Unknown automation.")
            hub.automations.set(b["kind"], b["on"])
        elif path == "/api/voice/set":
            if not isinstance(b.get("on"), bool):
                return Response.error(400, "Say on or off.")
            hub.voice.set(b["on"])
        elif path == "/api/pairing/start":
            return self._start_pairing()
        elif path == "/api/ps5/power":
            if not isinstance(b.get("on"), bool):
                return Response.error(400, "Say on or off.")
            if hub.ps5.power_busy:
                return Response.error(409, "Already changing power.", "busy")
            asyncio.ensure_future(hub.ps5.set_power(b["on"]))
        elif path == "/api/washer/claim":
            if not hub.washer.claim_current():
                return Response.error(409, "The washer isn't running.", "idle")
        elif path == "/api/washer/unclaim":
            hub.washer.unclaim()
        elif path == "/api/washer/notify-free":
            if not isinstance(b.get("on"), bool):
                return Response.error(400, "Say on or off.")
            hub.washer.set_notify_when_free(b["on"])
        else:
            return Response.text(404, "Not found.")
        return ok

    def _lights(self, path, b):
        lm = self.hub.lights
        index = b.get("index")
        if index is not None:
            if isinstance(index, bool) or not isinstance(index, int) or not any(x.id == index for x in lm.bulbs):
                return Response.error(400, "Unknown light.")

        def pct():
            v = b.get("pct")
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                return None
            return min(max(float(v), 0), 100)
        if path == "/api/lights/power":
            if not isinstance(b.get("on"), bool):
                return Response.error(400, "Say on or off.")
            lm.set_power(index, b["on"])
        elif path == "/api/lights/brightness":
            p = pct()
            if p is None:
                return Response.error(400, "Give a percentage.")
            lm.set_brightness(index, max(p, 1))
        elif path == "/api/lights/temp":
            p = pct()
            if p is None:
                return Response.error(400, "Give a percentage.")
            lm.set_temp(index, p)
        else:
            h = str(b.get("hex") or "").lower().replace("#", "")
            if len(h) != 6 or any(c not in "0123456789abcdef" for c in h):
                return Response.error(400, "Give a colour as six hex digits.")
            lm.set_colour(index, h)
        return Response.json({"ok": True})

    def _refresh(self, focus):
        now = time.time()
        lm = self.hub.lights
        if (focus == "lights" or not lm.loaded) and now - self._lights_asked > L.POLL_INTERVAL and not lm.refreshing:
            self._lights_asked = now
            asyncio.ensure_future(lm.refresh())
        if focus == "ps5" and now - self._ps5_asked > P.VISIBLE_POLL:
            self._ps5_asked = now

            async def go():
                await self.hub.ps5.probe()
                await self.hub.ps5.refresh_psn()
            asyncio.ensure_future(go())

    def snapshot(self):
        hub = self.hub
        return {"theme": hub.theme, "room": hub.cfg["room"], "tv": self._tv(), "lights": self._lights_state(),
                "scenes": self._scenes(), "ps5": self._ps5(), "washer": hub.washer.web_state(),
                "weather": hub.weather.web_state(), "match": hub.match.web_state()}

    def _app_ref(self, a):
        return {"key": a.key, "name": a.name, "short": a.short, "colour": f"{a.color:06x}", "running": a.id in self.hub.tv.running_apps}

    def _tv(self):
        tv, st = self.hub.tv, self.hub.st
        apps = [a for a in ALL_APPS if a.key in tv.installed] if tv.installed else ALL_APPS
        inputs = ((st.status or {}).get("inputs") or []) if st.usable else []

        def kind(i):
            return "ps5" if i["id"] == PS5_INPUT else "console" if i["id"] in CONSOLES else "hdmi" if i["id"].lower().startswith("hdmi") else "tv"
        status = st.status or {}
        volume = status.get("volume") if st.usable else None
        busy = st.busy[6:] if st.busy and st.busy.startswith("input:") else None
        active = tv.active_input
        return {"power": tv.power, "waking": tv.waking, "status": tv.status_text, "remote": tv.remote_status_text,
                "remoteReady": tv.socket.state == RemoteSocket.READY,
                "app": self._app_ref(tv.current_app) if tv.current_app else None, "caption": tv.now_caption,
                "launching": tv.launching.key if tv.launching else None, "apps": [self._app_ref(a) for a in apps],
                "favourites": [a.key for a in FAVOURITES],
                "inputs": [{"id": i["id"], "name": i["name"], "label": input_label(i), "kind": kind(i)} for i in inputs],
                "input": active["id"] if active else None, "inputBusy": busy, "smartThings": st.usable,
                "volume": int(round(volume)) if isinstance(volume, (int, float)) else None,
                "muted": st.usable and status.get("mute") == "muted", "notice": st.notice}

    def _lights_state(self):
        lm = self.hub.lights
        state = ("unavailable" if lm.unavailable else "loading" if (not lm.loaded and not lm.bulbs)
                 else "empty" if not lm.bulbs else "ok")
        names = {b.id: b.label for b in lm.bulbs}
        presets = []
        for p in lm.all_presets():
            looks = p["looks"]
            level = 1 if not looks else sum(l["brightness"] if l["on"] else 0 for l in looks) / len(looks) / 100
            presets.append({"id": p["id"], "name": p["name"], "summary": L.preset_summary(p, names),
                            "active": L.is_active(p, lm.bulbs), "builtIn": L.is_built_in(p),
                            "swatches": [L.look_hex(l) for l in looks], "level": level})
        bulbs = [{"index": b.id, "label": b.label, "subtitle": b.subtitle,
                  "glow": b.colour[1:] if b.colour else L.white_hex(b.temp), "on": b.on, "reachable": b.reachable,
                  "brightness": int(round(b.brightness)), "temp": int(round(b.temp)),
                  "colour": b.colour[1:] if b.colour else None} for b in lm.bulbs]
        return {"state": state, "message": lm.unavailable, "anyOn": lm.any_on, "subtitle": lm.master_subtitle,
                "brightness": int(round(lm.master_brightness)), "temp": int(round(lm.master_temp)),
                "enabled": bool(lm.reachable), "bulbs": bulbs, "presets": presets, "busy": lm.preset_busy,
                "result": lm.preset_result, "error": lm.last_error,
                "slots": [{"id": p["id"], "name": p["name"]} if p else None for p in lm.presets.slots],
                "swatches": [{"name": n, "hex": h} for n, h in L.SWATCHES]}

    def _scenes(self):
        runner = self.hub.runner
        icons_ = {"popcorn.fill": "film", "gamecontroller.fill": "gamepad", "moon.stars.fill": "moon", "sun.max.fill": "sun"}
        out = []
        for s in SCENES:
            app = runner.app_for(s)
            out.append({"id": s["id"], "name": s["name"], "subtitle": s["subtitle"], "icon": icons_.get(s["icon"], "sparkles"),
                        "from": f"{s['colours'][0]:06x}", "to": f"{s['colours'][1]:06x}", "app": app.name if app else None})
        current = None
        run = runner.current
        if run:
            kinds = [st["status"][0] for st in run["steps"]]
            current = {"id": run["scene"]["id"], "name": run["scene"]["name"], "summary": summary(run), "finished": run["finished"],
                       "failed": "failed" in kinds, "warned": "warning" in kinds,
                       "tracks": len({st["track"] for st in run["steps"]}),
                       "steps": [{"label": st["label"], "track": st["track"], "status": st["status"][0], "detail": st["status"][1]}
                                 for st in run["steps"]]}
        return {"running": runner.running, "list": out, "current": current}

    def _ps5(self):
        ps5, tv, st = self.hub.ps5, self.hub.tv, self.hub.st
        summary_ = ps5.psn
        if summary_ and not summary_.get("configured"):
            psn, err = "connect", None
        elif summary_ and summary_.get("state") != "ready" and summary_.get("most_played") is None:
            psn, err = "error", summary_.get("error") or "PSN isn't available right now."
        elif summary_:
            psn, err = "ready", summary_.get("error")
        elif ps5.psn_helper_error:
            psn, err = "error", ps5.psn_helper_error
        else:
            psn, err = "loading", None
        titles = (summary_ or {}).get("most_played") or []
        top = float(max((titles[0].get("seconds") or 1) if titles else 1, 1))
        presence = (summary_ or {}).get("presence") or {}
        room = self.hub.cfg["room"]
        if tv.power != ON:
            note = "The TV needs to be on"
        elif st.usable:
            note = f"Sets the {room} TV to {PS5_INPUT_NAME}"
        else:
            note = f"Sends HDMI to the {room} TV"
        return {"status": ps5.status, "polled": ps5.has_polled, "busy": ps5.power_busy, "error": ps5.power_error,
                "name": self.hub.cfg["ps5_name"], "host": self.hub.ps5.host, "psn": psn, "psnError": err,
                "onlineId": (summary_ or {}).get("online_id"), "playing": presence.get("title"),
                "online": presence.get("online_status") == "online", "caption": ps5.playing_caption,
                "art": presence.get("icon") is not None,
                "top": [{"name": t.get("name") or "Unknown title", "time": P.hours(t.get("seconds") or 0),
                         "fraction": (t.get("seconds") or 0) / top, "art": t.get("image") is not None} for t in titles[:5]],
                "tvOn": tv.power == ON, "switchNote": note}

    def hub_state(self):
        hub = self.hub
        run = hub.runner.current
        current = None
        if run:
            current = {"id": run["scene"]["id"], "finished": run["finished"], "started_at": run["started_at"],
                       "steps": [{"label": s["label"], "track": s["track"], "status": s["status"][0], "detail": s["status"][1]}
                                 for s in run["steps"]]}
        w = hub.washer
        return {"version": 1,
                "scenes": {"running": hub.runner.running, "current": current,
                           "apps": {s["id"]: hub.runner.app_for(s).key for s in SCENES if hub.runner.app_for(s)}},
                "automations": {"enabled": sorted(hub.automations.enabled), "events": hub.automations.events},
                "voice": {"enabled": hub.voice.enabled, "last": hub.voice.last, "problem": hub.voice.problem},
                "washer": {"phase": w.phase, "reason": w.reason, "status": w.status, "fetched_at": w.fetched_at,
                           "claim": w.claim, "notify_when_free": w.notify_when_free},
                "smartthings": {"phase": hub.st.phase, "reason": hub.st.reason},
                "presets": {"slots": hub.lights.presets.slots, "busy": hub.lights.preset_busy, "result": hub.lights.preset_result}}

    def _icon(self, size):
        if size not in self._icons:
            self._icons[size] = icons.icon(size)
        return Response(200, "image/png", self._icons[size])

    async def _artwork(self, which):
        """Only the PSN images in the current state, fetched by the hub, so the phone never talks to Sony."""
        s = self.hub.ps5.psn or {}
        raw = None
        if which == "now":
            raw = (s.get("presence") or {}).get("icon")
        elif which.startswith("top/") and which[4:].isdigit():
            titles = s.get("most_played") or []
            i = int(which[4:])
            raw = titles[i].get("image") if i < len(titles) else None
        if not raw or not raw.startswith("https://"):
            return Response.text(404, "No artwork.")
        if raw in self._art:
            t, data = self._art[raw]
            return Response(200, t, data)
        r = await glance.fetch(raw)
        if not r or not r[0].startswith("image/") or len(r[1]) >= 4_000_000:
            return Response.text(502, "Artwork unavailable.")
        if len(self._art) > 16:
            self._art.clear()
        self._art[raw] = r
        return Response(200, r[0], r[1])
