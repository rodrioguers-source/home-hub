"""The Samsung TV: REST on :8001 for power and apps, the remote WebSocket on :8002, Wake-on-LAN, and
the polling model ported from TVModel.swift."""
import asyncio
import base64
import json
import socket
import time
import urllib.parse

from . import wsclient


class TVApp:
    def __init__(self, id, key, name, short, color):
        self.id, self.key, self.name, self.short, self.color = id, key, name, short, color

    def __repr__(self):
        return f"TVApp({self.key})"


FAVOURITES = [
    TVApp("3201907018807", "netflix", "Netflix", "N", 0xE50914),
    TVApp("111299001912", "youtube", "YouTube", "▶", 0xFF0033),
    TVApp("3201910019365", "prime", "Prime Video", "prime", 0x00A8E1),
    TVApp("3201901017640", "disney", "Disney+", "D+", 0x0E3B6E),
    TVApp("3201606009684", "spotify", "Spotify", "♫", 0x1DB954),
    TVApp("3201807016597", "appletv", "Apple TV", "tv", 0x2A2A2D),
]
OTHERS = [
    TVApp("3201601007670", "iplayer", "BBC iPlayer", "BBC", 0xF54997),
    TVApp("121299000089", "itvx", "ITVX", "ITVX", 0x1C1E3C),
    TVApp("3201603008746", "now", "NOW", "NOW", 0x00C9A7),
    TVApp("3202010022079", "browser", "Browser", "www", 0x3B5BDB),
    TVApp("IkWsFHtOY9.Stremio", "stremio", "Stremio", "S", 0x7B5BF5),
]
ALL_APPS = FAVOURITES + OTHERS


def app_by_key(key):
    return next((a for a in ALL_APPS if a.key == key), None)


ON, STANDBY, UNREACHABLE = "on", "standby", "unreachable"


async def http(host, port, method, path, timeout=3.0):
    """(status, body bytes), or None when the host didn't answer."""
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    except Exception:
        return None
    try:
        req = f"{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        writer.write(req.encode())
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(-1), timeout + 1)
    except Exception:
        return None
    finally:
        writer.close()
    head, _, body = raw.partition(b"\r\n\r\n")
    try:
        status = int(head.split(b" ", 2)[1])
    except (IndexError, ValueError):
        return None
    if b"transfer-encoding: chunked" in head.lower():
        body = _unchunk(body)
    return status, body


def _unchunk(body):
    out = b""
    while body:
        size, _, rest = body.partition(b"\r\n")
        try:
            n = int(size.split(b";")[0], 16)
        except ValueError:
            break
        if n == 0:
            break
        out += rest[:n]
        body = rest[n + 2:]
    return out


class Network:
    """Everything that touches the TV on the LAN. The self-test swaps in a fake."""

    async def power(self, host):
        r = await http(host, 8001, "GET", "/api/v2/")
        if r is None:
            return UNREACHABLE, None, None
        try:
            device = json.loads(r[1]).get("device") or {}
        except ValueError:
            device = {}
        state = (device.get("PowerState") or "").lower()
        return (ON if state in ("", "on") else STANDBY), device.get("modelName"), device.get("wifiMac")

    async def status(self, host, app_id):
        """None when not installed. Some apps (Stremio) answer 200 with an empty body: installed, state unknown."""
        r = await http(host, 8001, "GET", f"/api/v2/applications/{app_id}")
        if r is None or r[0] != 200:
            return None
        try:
            data = json.loads(r[1]) if r[1].strip() else {}
        except ValueError:
            data = {}
        return {"name": data.get("name"), "running": data.get("running"), "visible": data.get("visible")}

    async def launch(self, host, app_id):
        await http(host, 8001, "POST", f"/api/v2/applications/{app_id}")

    async def discover(self, prefixes, mac):
        """Scans each /24 for a Samsung REST API whose Wi-Fi MAC is the TV's."""
        want = mac.lower()
        sem = asyncio.Semaphore(64)

        async def probe(ip):
            async with sem:
                r = await http(ip, 8001, "GET", "/api/v2/", timeout=1.5)
            if r is None:
                return None
            try:
                got = ((json.loads(r[1]).get("device") or {}).get("wifiMac") or "").lower()
            except ValueError:
                return None
            return ip if got == want else None

        for prefix in prefixes:
            tasks = [asyncio.ensure_future(probe(f"{prefix}.{i}")) for i in range(1, 255)]
            try:
                for fut in asyncio.as_completed(tasks):
                    ip = await fut
                    if ip:
                        return ip
            finally:
                for t in tasks:
                    t.cancel()
        return None

    def wake(self, mac, host=None):
        raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
        if len(raw) != 6:
            return 0
        packet = b"\xff" * 6 + raw * 16
        targets = ["255.255.255.255"]
        if host and host.count(".") == 3:
            targets.append(host.rsplit(".", 1)[0] + ".255")
        sent = 0
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            for t in targets:
                try:
                    sent += s.sendto(packet, (t, 9))
                except OSError:
                    pass
        return sent


class RemoteSocket:
    IDLE, FETCHING, CONNECTING, READY, UNAUTHORIZED, NO_TOKEN = "idle", "fetchingToken", "connecting", "ready", "unauthorized", "tokenUnavailable"

    def __init__(self, host, name, token_source, connector=None):
        self.host = host
        self.name = name
        self.token_source = token_source
        self.connector = connector or (lambda url: wsclient.connect(url, insecure_host=self.host()))
        self.state = self.IDLE
        self.allowed = False
        self.token = None
        self.ws = None
        self.pending = []
        self.retry_delay = 2
        self.retry_scheduled = False
        self._tasks = set()
        self._gen = 0

    @property
    def ready(self):
        return self.state == self.READY

    def _spawn(self, coro):
        t = asyncio.ensure_future(coro)
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)
        return t

    def connect_if_needed(self):
        if self.state == self.IDLE and self.allowed:
            self.state = self.CONNECTING if self.token else self.FETCHING
            self._spawn(self._connect())

    def retry(self):
        if self.state in (self.NO_TOKEN, self.UNAUTHORIZED):
            self.token = None
            self.state = self.IDLE
        self.connect_if_needed()

    def disconnect(self):
        self._gen += 1
        ws, self.ws = self.ws, None
        if ws:
            self._spawn(ws.close())
        self.pending.clear()
        if self.state in (self.READY, self.CONNECTING):
            self.state = self.IDLE

    async def _connect(self):
        gen = self._gen
        if self.token is None:
            self.state = self.FETCHING
            try:
                self.token = await asyncio.get_running_loop().run_in_executor(None, self.token_source)
            except Exception:
                self.token = None
            if not self.token:
                self.token = None
                self.state = self.NO_TOKEN
                return
        self.state = self.CONNECTING
        name = base64.b64encode(self.name.encode()).decode()
        q = urllib.parse.urlencode({"name": name, "token": self.token})
        url = f"wss://{self.host()}:8002/api/v2/channels/samsung.remote.control?{q}"
        try:
            ws = await self.connector(url)
        except Exception:
            if gen == self._gen:
                self._failed()
            return
        if gen != self._gen:
            await ws.close()
            return
        self.ws = ws
        self._spawn(self._reader(ws, gen))

    async def _reader(self, ws, gen):
        pinger = None
        try:
            while True:
                text = await ws.recv()
                if gen != self._gen:
                    return
                try:
                    msg = json.loads(text)
                except ValueError:
                    continue
                event = msg.get("event")
                if event == "ms.channel.connect":
                    fresh = (msg.get("data") or {}).get("token")
                    if fresh:
                        self.token = fresh
                    self.state = self.READY
                    self.retry_delay = 2
                    await self._flush()
                    if pinger is None:
                        pinger = self._spawn(self._pings(ws, gen))
                elif event == "ms.channel.unauthorized":
                    self.ws = None
                    await ws.close()
                    self.state = self.UNAUTHORIZED
                    return
        except Exception:
            if gen == self._gen and self.ws is ws:
                self._failed()
        finally:
            if pinger:
                pinger.cancel()

    async def _pings(self, ws, gen):
        while True:
            await asyncio.sleep(20)
            try:
                await ws.ping()
            except Exception:
                if gen == self._gen and self.ws is ws:
                    self._failed()
                return

    def _failed(self):
        ws, self.ws = self.ws, None
        self._gen += 1
        if ws:
            self._spawn(ws.close())
        if self.state in (self.UNAUTHORIZED, self.NO_TOKEN):
            return
        self.state = self.IDLE
        if self.retry_scheduled:
            return
        self.retry_scheduled = True
        delay = self.retry_delay
        self.retry_delay = min(self.retry_delay * 2, 30)

        async def later():
            await asyncio.sleep(delay)
            self.retry_scheduled = False
            self.connect_if_needed()
        self._spawn(later())

    async def _flush(self):
        if not self.ws:
            return
        cutoff = time.time() - 8
        queued = [t for at, t in self.pending if at > cutoff]
        self.pending.clear()
        for text in queued:
            try:
                await self.ws.send(text)
            except Exception:
                self._failed()
                return

    def send(self, payload):
        if not self.allowed or self.state in (self.UNAUTHORIZED, self.NO_TOKEN):
            return
        self.pending.append((time.time(), json.dumps(payload)))
        del self.pending[:-20]
        if self.state == self.READY:
            self._spawn(self._flush())
        else:
            self.connect_if_needed()

    def key(self, key):
        self.send({"method": "ms.remote.control",
                   "params": {"Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"}})

    def launch(self, app_id, native=False):
        """DEEP_LINK suits web apps; native Tizen apps can silently ignore it and need NATIVE_LAUNCH."""
        self.send({"method": "ms.channel.emit",
                   "params": {"event": "ed.apps.launch", "to": "host",
                              "data": {"action_type": "NATIVE_LAUNCH" if native else "DEEP_LINK", "appId": app_id, "metaTag": ""}}})


class TVModel:
    def __init__(self, cfg, settings, st, token_source, net=None, connector=None, clock=time.time):
        self.cfg = cfg
        self.settings = settings
        self.st = st
        self.net = net or Network()
        self.now = clock
        self.host = settings.get("tv_host") or cfg["tv_host"]
        self.mac = cfg["tv_mac"]
        self.power = UNREACHABLE
        self.has_polled = False
        self.model_name = "UE32F6000FKXXU"
        self.visible_app = None
        self.running_apps = set()
        self.installed = {}
        self.waking = False
        self.launching = None
        self.refreshing = False
        self._turning_off_until = None
        self._missed = 0
        self._off_requested_at = None
        self._wake_started_at = None
        self._last_discovery = None
        self._catalogue_checked = False
        self._launch_task = None
        self.socket = RemoteSocket(lambda: self.host, cfg["tv_remote_name"], token_source, connector)

    async def run(self):
        while True:
            try:
                await self.poll()
            except Exception:
                pass
            await asyncio.sleep(3 if (self.waking or self.power != ON) else 5)

    def _prefixes(self):
        out = [self.host.rsplit(".", 1)[0]]
        try:
            from .lan import own_addresses
            for ip in own_addresses():
                p = ip.rsplit(".", 1)[0]
                if p not in out:
                    out.append(p)
        except Exception:
            pass
        return out

    async def poll(self):
        reported, model, _ = await self.net.power(self.host)
        # The router hands the TV a new address now and then, so look for it by MAC, at most once a minute.
        if reported == UNREACHABLE and self.now() - (self._last_discovery or 0) > 60:
            self._last_discovery = self.now()
            ip = await self.net.discover(self._prefixes(), self.mac)
            if ip and ip != self.host:
                self.host = ip
                self.settings.set("tv_host", ip)
                self.socket.disconnect()
                reported, model, _ = await self.net.power(self.host)
        # A busy TV sometimes misses one REST poll; dropping the remote over that felt like random disconnects.
        if reported == UNREACHABLE and self.power == ON and self._turning_off_until is None and self._missed < 2:
            self._missed += 1
            return
        self._missed = 0
        if self._off_requested_at is not None:
            if self.now() - self._off_requested_at > 60:
                self._off_requested_at = None
            elif reported == ON:
                self._turning_off_until = self.now() + 30
                self.socket.allowed = True
                self.socket.connect_if_needed()
                if self.socket.ready:
                    self.socket.key("KEY_POWER")
                    self._off_requested_at = None
                    self.power = STANDBY
                    return
        state = reported
        if self._turning_off_until is not None:
            if state != ON or self.now() > self._turning_off_until:
                self._turning_off_until = None
            else:
                state = STANDBY
        self.power = state
        self.has_polled = True
        if model:
            self.model_name = model
        self.socket.allowed = state == ON or self._off_requested_at is not None
        if self.waking and state != ON and self._wake_started_at is not None:
            if self.now() - self._wake_started_at < 40:
                self.net.wake(self.mac, self.host)
            else:
                self.waking = False
                self._wake_started_at = None
        if state == ON:
            self.waking = False
            self._wake_started_at = None
            self.socket.connect_if_needed()
            if not self._catalogue_checked:
                await self._check_catalogue()
            await self._refresh_apps()
        else:
            if self._off_requested_at is None:
                self.socket.disconnect()
            self.visible_app = None
            self.running_apps = set()

    async def _statuses(self, apps):
        results = await asyncio.gather(*(self.net.status(self.host, a.id) for a in apps))
        return list(zip(apps, results))

    async def _check_catalogue(self):
        found = {a.key: (s.get("name") or a.name) for a, s in await self._statuses(ALL_APPS) if s is not None}
        self.installed = found
        self._catalogue_checked = bool(found)

    async def _refresh_apps(self):
        apps = [a for a in ALL_APPS if a.key in self.installed] if self.installed else FAVOURITES
        results = await self._statuses(apps)
        self.visible_app = next((a for a, s in results if s and s.get("visible") is True), None)
        self.running_apps = {a.id for a, s in results if s and s.get("running") is True}

    def key(self, key):
        self.socket.key(key)

    @property
    def current_app(self):
        if self.visible_app:
            return self.visible_app
        name = (self.st.status or {}).get("tv_channel_name")
        if self.power != ON or not name:
            return None
        return next((a for a in ALL_APPS if a.id == name), None)

    @property
    def active_input(self):
        st = self.st
        if not st.usable:
            return None
        inp = st.current_input
        if inp is None:
            return None
        if st.chosen_input and self.now() - st.chosen_input["at"] < 15:
            return inp
        if self.power != ON or not inp["id"].lower().startswith("hdmi"):
            return inp
        if self.current_app is not None:
            return None
        status = st.status or {}
        channel, name = status.get("tv_channel") or "", status.get("tv_channel_name") or ""
        if channel or (name and "." not in name):
            return next((i for i in status.get("inputs") or [] if not i["id"].lower().startswith("hdmi")), None)
        return inp if not name else None

    def launch(self, app):
        if self._launch_task:
            self._launch_task.cancel()
        self._launch_task = asyncio.ensure_future(self.open(app))

    async def open(self, app):
        """Sends the launch by the first path that works, and only falls through when one errors."""
        self.launching = app
        try:
            if await self._on_screen(app, cloud=False):
                return {"method": "already open", "confirmed": True}
            st = self.st

            async def via_st():
                return st.usable and (await st.launch(app.id)) is None

            async def via_remote():
                if not await self.remote_ready():
                    return False
                self.socket.launch(app.id)
                return True

            async def via_native():
                if not self.socket.ready:
                    return False
                self.socket.launch(app.id, native=True)
                return True

            async def via_rest():
                await self.net.launch(self.host, app.id)
                return True

            for name, window, send in (("SmartThings", 8, via_st), ("remote", 6, via_remote),
                                       ("remote (native)", 6, via_native), ("local network", 6, via_rest)):
                if not await send():
                    continue
                confirmed = await self._wait_on_screen(app, window)
                asyncio.ensure_future(self._poll_soon())
                return {"method": name, "confirmed": confirmed}
            return None
        finally:
            if self.launching is app:
                self.launching = None

    async def _poll_soon(self):
        await asyncio.sleep(1)
        try:
            await self.poll()
        except Exception:
            pass

    async def _wait_on_screen(self, app, window):
        start = self.now()
        last_cloud = start
        while self.now() - start < window:
            await asyncio.sleep(1)
            cloud = self.st.usable and self.now() - last_cloud >= 3
            if cloud:
                last_cloud = self.now()
            if await self._on_screen(app, cloud):
                return True
        return False

    async def _on_screen(self, app, cloud):
        s = await self.net.status(self.host, app.id)
        if s and s.get("visible") is True:
            return True
        if not cloud:
            return False
        before = (self.st.status or {}).get("tv_channel_name")
        await self.st.fetch()
        # tvChannelName keeps the last app after the TV leaves it, so only a change counts.
        return before != app.id and (self.st.status or {}).get("tv_channel_name") == app.id

    async def wait_for_cloud_ready(self, timeout=20):
        """SmartThings accepts a launch while the TV is still waking but the TV drops it."""
        if not self.st.usable:
            return
        start = self.now()
        while self.now() - start < timeout:
            await self.st.fetch(refresh=True)
            if (self.st.status or {}).get("power") == "on":
                break
            await asyncio.sleep(2)
        await asyncio.sleep(3)

    async def remote_ready(self, timeout=6):
        start = self.now()
        while self.now() - start < timeout:
            if self.socket.state == RemoteSocket.READY:
                return True
            if self.socket.state in (RemoteSocket.NO_TOKEN, RemoteSocket.UNAUTHORIZED):
                return False
            self.socket.connect_if_needed()
            await asyncio.sleep(0.3)
        return False

    def power_off(self):
        if self.socket.ready:
            self.socket.key("KEY_POWER")
        else:
            self._off_requested_at = self.now()
        self.waking = False
        self._turning_off_until = self.now() + 30
        self.power = STANDBY

    def power_on(self):
        self._off_requested_at = None
        self._turning_off_until = None
        self.waking = True
        self._wake_started_at = self.now()
        self.net.wake(self.mac, self.host)
        if self.st.usable:
            asyncio.ensure_future(self.st.power_on())

    def toggle_power(self):
        if self.power == ON or self.waking:
            self.power_off()
        else:
            self.power_on()

    @property
    def status_text(self):
        if not self.has_polled:
            return "Searching…"
        if self.power == ON:
            return "Connected"
        if self.power == STANDBY:
            return "Standby"
        return "Turning on…" if self.waking else "Disconnected"

    @property
    def now_caption(self):
        if self.power == ON:
            app = self.current_app
            if app:
                return f"{app.name} in the foreground."
            inp = self.active_input
            if inp:
                return f"No known app in the foreground. Last input: {input_label(inp)}."
            return "No known app in the foreground: it could be the home screen, live TV or HDMI."
        if self.power == STANDBY:
            return "The TV is on standby."
        return "Wake-on-LAN packet sent, waiting for the TV…" if self.waking else "The TV isn't responding on the network."

    @property
    def remote_status_text(self):
        s = self.socket.state
        return {RemoteSocket.READY: "Remote ready", RemoteSocket.CONNECTING: "Connecting…",
                RemoteSocket.FETCHING: "Reading the TV token…", RemoteSocket.UNAUTHORIZED: "Token rejected by the TV",
                RemoteSocket.NO_TOKEN: "Token unavailable"}.get(s, "Reconnecting…" if self.power == ON else "TV off")


PS5_INPUT = "HDMI2"
PS5_INPUT_NAME = "HDMI 2"
CONSOLES = {PS5_INPUT: "PS5", "HDMI1": "Switch"}


def input_label(inp):
    name = inp.get("name") or inp.get("id")
    console = CONSOLES.get(inp.get("id"))
    return f"{name} · {console}" if console else name
