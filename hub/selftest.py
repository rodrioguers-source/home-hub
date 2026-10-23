"""Offline self-test for the hub: python -m hub.selftest

Everything is mocked. Nothing talks to the TV, bulbs, PS5, SmartThings or 1Password: `op` is replaced by a
tripwire, outbound UDP is refused, and the only sockets opened are on 127.0.0.1.
"""
import asyncio
import base64
import hashlib
import json
import os
import shutil
import socket
import struct
import sys
import tempfile
import time
import traceback
import urllib.request

from . import config as config_mod
from . import vault

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else f"  ({detail})"))


op_calls = []


def _tripwire(*a, **k):
    op_calls.append(a)
    raise RuntimeError("op must not run during the self-test")


_real_sendto = socket.socket.sendto


def _guarded_sendto(self, data, *args):
    addr = args[-1]
    if not str(addr[0]).startswith("127."):
        raise OSError(f"self-test refused UDP to {addr[0]}")
    return _real_sendto(self, data, *args)


class FakeHelper:
    def __init__(self):
        self.calls = []
        self.responses = {}
        self.fail = {}

    async def call(self, method, params=None, timeout=150):
        self.calls.append((method, dict(params or {})))
        await asyncio.sleep(0)
        if method in self.fail:
            from .helper import Failure
            msg, code = self.fail[method]
            raise Failure(msg, code)
        r = self.responses.get(method)
        return r(params or {}) if callable(r) else json.loads(json.dumps(r)) if r is not None else {}

    async def ps5(self, action, creds, host=None):
        self.calls.append(("ps5." + action, {"host": host}))
        return {}


def bulb_rows(on=True, brightness=80, temp=20, mode="white", color=None):
    return [{"name": f"Bulb {i}", "index": i, "ip": f"192.168.0.{40 + i}", "ok": True, "on": on, "mode": mode,
             "brightness": brightness, "temp": temp, "color": color} for i in (1, 2, 3, 4)]


class FakeNet:
    def __init__(self):
        self.state = "unreachable"
        self.host_ok = "192.168.0.97"
        self.discovered = None
        self.wakes = 0
        self.discover_calls = 0
        self.apps = {}
        self.launches = []

    async def power(self, host):
        if host != self.host_ok:
            return "unreachable", None, None
        return self.state, ("QE55" if self.state != "unreachable" else None), "28:07:08:a8:9d:06"

    async def status(self, host, app_id):
        return self.apps.get(app_id)

    async def launch(self, host, app_id):
        self.launches.append(app_id)

    async def discover(self, prefixes, mac):
        self.discover_calls += 1
        return self.discovered

    def wake(self, mac, host=None):
        self.wakes += 1
        return 102


class FakeWS:
    def __init__(self, script):
        self.inbox = asyncio.Queue()
        for m in script:
            self.inbox.put_nowait(m)
        self.sent = []
        self.closed = False

    async def recv(self):
        m = await self.inbox.get()
        if m is None:
            from .wsclient import WSError
            raise WSError("closed")
        return json.dumps(m)

    async def send(self, text):
        self.sent.append(json.loads(text))

    async def ping(self):
        pass

    async def close(self):
        self.closed = True


class FakeKeyring:
    """Stands in for `keyring`, with Windows Credential Manager's size cap, so nothing reaches a real store."""
    LIMIT = 1280

    def __init__(self):
        self.data = {}
        self.writes = 0
        self.fail_after = None

    def get_password(self, service, name):
        return self.data.get((service, name))

    def set_password(self, service, name, value):
        if self.fail_after is not None and self.writes >= self.fail_after:
            raise OSError("simulated failure")
        if len(value) > self.LIMIT:
            raise ValueError("value too long for Credential Manager")
        self.writes += 1
        self.data[(service, name)] = value

    def delete_password(self, service, name):
        self.data.pop((service, name), None)


fake_keyring = FakeKeyring()


def test_config(tmp):
    print("config and secrets")
    path = os.path.join(tmp, "hub-config.json")
    with open(path, "w") as f:
        json.dump({"keyring_service": "home-hub-test", "items": {"psn": "PSN Test"}, "port": 9999}, f)
    cfg = config_mod.load(path)
    check("config file overrides defaults", cfg["keyring_service"] == "home-hub-test" and cfg["port"] == 9999)
    check("items merge with defaults", cfg.item("psn") == "PSN Test" and cfg.item("smartthings") == "SmartThings OAuth")
    check("TV host default is not the old address", cfg["tv_host"] != "192.168.0.23")
    vault.configure(cfg)
    import secret_store
    check("hub uses the keyring and marks itself as the SmartThings host",
          secret_store.backend() == "keyring" and os.environ.get("HOME_ST_HOST") == "hub" and secret_store.service() == "home-hub-test")
    check("no service-account token anywhere", "OP_SERVICE_ACCOUNT_TOKEN" not in os.environ)
    return cfg


def test_secret_store():
    print("keyring secret store")
    import secret_store as ss
    big = "x" * 3000
    ss.save_fields("Tuya Lamps", {"credential": big})
    check("large items are split under the Credential Manager cap", ss.get_field("Tuya Lamps") == big
          and max(len(v) for v in fake_keyring.data.values()) <= FakeKeyring.LIMIT)
    ss.save_fields("Tuya Lamps", {"note": "n"})
    check("save merges fields", ss.get_fields("Tuya Lamps") == {"credential": big, "note": "n"})
    parts = [k for k in fake_keyring.data if k[1].startswith("item:Tuya Lamps:")]
    check("old parts are cleaned up", len(parts) == 4, len(parts))
    fake_keyring.fail_after = fake_keyring.writes + 2
    try:
        ss.save_fields("Tuya Lamps", {"credential": "y" * 3000})
        check("a failed write raises", False)
    except ss.SecretError as e:
        check("a failed write raises", e.code == "keyring_write_failed")
    fake_keyring.fail_after = None
    check("a half-written item still reads as the old one", ss.get_field("Tuya Lamps") == big)
    check("missing items read as None", ss.get_fields("Nope") is None and ss.get_field("Nope") is None)
    check("titles are tracked", ss.titles() == ["Tuya Lamps"])
    ss.delete_item("Tuya Lamps")
    check("delete removes every part", not [k for k in fake_keyring.data if "Tuya" in k[1]] and ss.titles() == [])


def test_smartthings_owner():
    print("SmartThings refresh ownership")
    import secret_store as ss
    import smartthings as st
    check("Mac owns by default", st.may_refresh({}, "mac") and not st.may_refresh({}, "hub"))
    check("hub owns when the field says so", st.may_refresh({"refresh_owner": "hub"}, "hub")
          and not st.may_refresh({"refresh_owner": "hub"}, "mac"))
    base = {"client_id": "c", "client_secret": "s", "refresh_token": "r", "access_token": "a", "access_expires_at": "0"}
    refreshed = []
    orig = (st.token_request, st.HOST_ID, st.LOCK_PATH, st.op_get_item, st.op_save_fields)
    st.token_request = lambda *a: refreshed.append(a) or {"access_token": "A2", "refresh_token": "R2", "expires_in": 3600}
    st.LOCK_PATH = os.path.join(tempfile.gettempdir(), f"hub-selftest-{os.getpid()}.lock")
    try:
        ss.replace_item("SmartThings OAuth", dict(base, refresh_owner="mac"))
        st.HOST_ID = "hub"
        try:
            st.SmartThings().access_token()
            check("hub won't refresh what the Mac owns", False, "no error")
        except st.SmartThingsError as e:
            check("hub won't refresh what the Mac owns", e.code == "st_not_owner" and not refreshed, e.code)
        ss.save_fields("SmartThings OAuth", {"refresh_owner": "hub"})
        check("hub refreshes once it owns", st.SmartThings().access_token() == "A2" and refreshed)
        f = ss.get_fields("SmartThings OAuth")
        check("rotated token is written back to the keyring", f["refresh_token"] == "R2" and f["access_token"] == "A2"
              and f["refresh_owner"] == "hub")
        os.environ["HOME_SECRETS"] = "op"
        item = {"fields": [{"label": k, "value": v} for k, v in dict(base, refresh_owner="hub").items()]}
        saved = []
        st.op_get_item = lambda title=None: item
        st.op_save_fields = lambda values, title=None: saved.append(values)
        st.HOST_ID = "mac"
        refreshed.clear()
        try:
            st.SmartThings().access_token()
            check("Mac (1Password) won't refresh what the hub owns", False, "no error")
        except st.SmartThingsError as e:
            check("Mac (1Password) won't refresh what the hub owns", e.code == "st_not_owner" and not refreshed and not saved)
        item["fields"][-1]["value"] = "mac"
        check("Mac path still writes through op as before", st.SmartThings().access_token() == "A2" and saved[0]["refresh_token"] == "R2")

        # Fake 1Password items by title (no real op); the Mac's own item wins when it exists.
        store = {"SmartThings OAuth": dict(base, refresh_owner="hub")}
        asked, writes = [], []

        def fake_get(title=None):
            asked.append(title)
            f = store.get(title)
            return None if f is None else {"fields": [{"label": k, "value": v} for k, v in f.items()]}

        def fake_save(values, title=None):
            writes.append((title or st.item_title(), dict(values)))
            store.setdefault(title or st.item_title(), {}).update(values)
        st.op_get_item, st.op_save_fields = fake_get, fake_save
        st.forget_item_choice()
        refreshed.clear()
        c = st.SmartThings()
        try:
            c.access_token()
            check("no Mac item: falls back to the shared one (owned by the hub, so no refresh)", False, "no error")
        except st.SmartThingsError as e:
            check("no Mac item: falls back to the shared one (owned by the hub, so no refresh)", e.code == "st_not_owner"
                  and asked[0] == "SmartThings OAuth Mac" and st.item_title() == "SmartThings OAuth" and not refreshed and not writes)
        check("chain reports the shared item and no refresh", c.chain() == {"item": "SmartThings OAuth", "may_refresh": False})
        store["SmartThings OAuth Mac"] = dict(base, refresh_owner="mac", client_id="mac-c")
        c.retry()
        st.forget_item_choice()
        asked.clear()
        c = st.SmartThings()
        check("Mac item present: the Mac refreshes its own chain", c.access_token() == "A2" and st.item_title() == "SmartThings OAuth Mac"
              and refreshed[-1][0] == "mac-c")
        check("…writes only to the Mac item and never touches the hub's", writes and all(t == "SmartThings OAuth Mac" for t, _ in writes)
              and store["SmartThings OAuth"]["refresh_token"] == "r" and store["SmartThings OAuth"]["refresh_owner"] == "hub")
        check("chain reports the Mac's own item", c.chain() == {"item": "SmartThings OAuth Mac", "may_refresh": True})
        os.environ["HOME_ST_ITEM"] = "SmartThings OAuth"
        check("HOME_ST_ITEM forces a title", st.item_title() == "SmartThings OAuth")
        del os.environ["HOME_ST_ITEM"]
        from hub import transfer
        writes.clear()
        ops = transfer.MacOps()
        ops.save_tokens({"refresh_token": "moved"})
        check("send_secrets still reads and writes the shared item, not the Mac's own",
              ops.owner() == "hub" and writes == [("SmartThings OAuth", {"refresh_token": "moved"})]
              and store["SmartThings OAuth Mac"]["refresh_token"] != "moved")

        calls = []
        status = {"value": "on"}

        def fake_api(method, path, body=None):
            calls.append((method, path))
            if method == "GET":
                return {"switch": {"value": status["value"]}}
            status["value"] = "off"
            return {}
        c.api = fake_api
        c._trigger_ids = {"sw1"}
        check("claim: first caller switches it off and wins", c.claim_trigger("sw1") == {"device_id": "sw1", "claimed": True}
              and calls == [("GET", "/devices/sw1/components/main/capabilities/switch/status"), ("POST", "/devices/sw1/commands")])
        calls.clear()
        check("claim: already off means someone else ran it", c.claim_trigger("sw1")["claimed"] is False and calls == [
            ("GET", "/devices/sw1/components/main/capabilities/switch/status")])
        try:
            c.claim_trigger("tv")
            check("claim refuses unknown switches", False)
        except st.SmartThingsError as e:
            check("claim refuses unknown switches", e.code == "unknown_trigger")
    finally:
        os.environ["HOME_SECRETS"] = "keyring"
        os.environ.pop("HOME_ST_ITEM", None)
        st.token_request, st.HOST_ID, st.LOCK_PATH, st.op_get_item, st.op_save_fields = orig
        st.forget_item_choice()
        ss.delete_item("SmartThings OAuth")


class FakeMac:
    def __init__(self, items, owner="mac"):
        self.items = items
        self.current_owner = owner
        self.saved = []
        self.save_error = None

    def owner(self):
        return self.current_owner if "SmartThings OAuth" in self.items else None

    def read(self, title):
        f = self.items.get(title)
        return dict(f, refresh_owner=self.current_owner) if f is not None and title == "SmartThings OAuth" else f

    def set_owner(self, owner):
        self.current_owner = owner

    def save_tokens(self, fields):
        if self.save_error:
            raise self.save_error
        self.saved.append(fields)
        self.items["SmartThings OAuth"] = dict(self.items.get("SmartThings OAuth") or {}, **fields)

    def lock(self):
        import contextlib
        return contextlib.nullcontext()


def test_transfer():
    print("secret transfer (loopback TLS)")
    try:
        import cryptography  # noqa: F401
    except ImportError:
        print("  skip (the cryptography package isn't installed for this Python)")
        return
    import contextlib
    import threading
    import secret_store as ss
    from . import transfer as T
    logs = []

    def receiver(timeout=20):
        r = T.Receiver("127.0.0.1", ports=[0], lock=contextlib.nullcontext, log=logs.append, timeout=timeout)
        out = {}
        t = threading.Thread(target=lambda: out.setdefault("r", _catch(r.serve)), daemon=True)
        t.start()
        return r, f"127.0.0.1:{r.address[1]}", t, out

    def _catch(fn):
        try:
            return fn()
        except T.TransferError as e:
            return e
    st_fields = {"client_id": "cid", "client_secret": "csecret", "refresh_token": "R-mac", "access_token": "A-mac",
                 "access_expires_at": "123"}
    tuya = {"credential": json.dumps({"devices": [{"name": f"Lamp {i}", "key": "k" * 16} for i in range(40)]})}
    mac = FakeMac({"SmartThings OAuth": dict(st_fields), "Tuya Lamps": tuya, "PS5 Remote Play": {"credential": '{"RegistKey":"ab"}'}})
    r, addr, t, out = receiver()
    check("code is 6 digits, fingerprint shown in groups", len(r.code) == 6 and r.code.isdigit() and len(T.spaced(r.fingerprint)) == 29)
    try:
        T.send(addr, r.fingerprint, "000000" if r.code != "000000" else "111111", mac=mac, log=logs.append)
        check("wrong code refused", False)
    except T.TransferError as e:
        check("wrong code refused, nothing changed", "Wrong code" in str(e) and mac.current_owner == "mac" and not ss.titles())
    try:
        T.send(addr, "ffff" * 6, r.code, mac=mac, log=logs.append)
        check("wrong fingerprint refused", False)
    except T.TransferError as e:
        check("wrong fingerprint refused before sending", "doesn't match" in str(e) and mac.current_owner == "mac")
    saved = T.send(addr, T.spaced(r.fingerprint), r.code, mac=mac, log=logs.append)
    t.join(10)
    check("receiver stops after one transfer", out.get("r") == "sent" and not t.is_alive(), out)
    check("items sent (missing ones skipped)", saved == ["PS5 Remote Play", "SmartThings OAuth", "Tuya Lamps"], saved)
    hub_st = ss.get_fields("SmartThings OAuth")
    check("hub owns SmartThings, Mac's copy is marked hub", hub_st["refresh_owner"] == "hub" and mac.current_owner == "hub"
          and hub_st["refresh_token"] == "R-mac")
    check("large Tuya item arrives intact", ss.get_fields("Tuya Lamps") == tuya)
    every = json.dumps(logs)
    check("no secret value in any log line", all(v not in every for v in ("csecret", "R-mac", "A-mac", "k" * 16)))

    ss.save_fields("SmartThings OAuth", {"refresh_token": "R-hub-rotated"})
    r, addr, t, out = receiver()
    saved = T.send(addr, r.fingerprint, r.code, mac=mac, log=logs.append)
    t.join(10)
    check("sending again leaves the hub's newer SmartThings alone", "SmartThings OAuth" not in saved
          and ss.get_field("SmartThings OAuth", "refresh_token") == "R-hub-rotated")

    r, addr, t, out = receiver()
    mac.save_error = OSError("1Password locked")
    try:
        T.back(addr, r.fingerprint, r.code, mac=mac, log=logs.append)
        check("failed back keeps the hub in charge", False)
    except OSError:
        time.sleep(0.5)
        check("failed back keeps the hub in charge", ss.get_field("SmartThings OAuth", "refresh_owner") == "hub"
              and mac.current_owner == "hub")
    r.deadline = 0
    mac.save_error = None
    r, addr, t, out = receiver()
    T.back(addr, r.fingerprint, r.code, mac=mac, log=logs.append)
    t.join(10)
    check("back brings the rotated token to the Mac", out.get("r") == "back" and mac.saved[-1]["refresh_token"] == "R-hub-rotated"
          and "refresh_owner" not in mac.saved[-1])
    check("after back only the Mac owns it", mac.current_owner == "mac" and ss.get_field("SmartThings OAuth", "refresh_owner") == "mac")
    r, addr, t, out = receiver(timeout=5)
    try:
        T.back(addr, r.fingerprint, r.code, mac=mac, log=logs.append)
        check("back refused when the Mac already owns it", False)
    except T.TransferError:
        check("back refused when the Mac already owns it", True)

    fresh = FakeMac({"SmartThings OAuth": dict(st_fields)})
    ss.delete_item("SmartThings OAuth")
    fake_keyring.fail_after = fake_keyring.writes
    r, addr, t, out = receiver(timeout=5)
    try:
        T.send(addr, r.fingerprint, r.code, mac=fresh, log=logs.append)
        check("failed save hands SmartThings back to the Mac", False)
    except T.TransferError:
        check("failed save hands SmartThings back to the Mac", fresh.current_owner == "mac")
    fake_keyring.fail_after = None
    try:
        T.connect("8.8.8.8:8787", "a" * 24)
        check("non-LAN addresses refused", False)
    except T.TransferError:
        check("non-LAN addresses refused", True)


def ws_frame(data):
    n = len(data)
    return bytes([0x81, n]) + data if n < 126 else bytes([0x81, 126]) + struct.pack("!H", n) + data


async def ws_server(reader, writer):
    head = await reader.readuntil(b"\r\n\r\n")
    key = [l.split(":", 1)[1].strip() for l in head.decode().split("\r\n") if l.lower().startswith("sec-websocket-key")][0]
    accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC525B1").encode()).digest()).decode()
    writer.write(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())
    hello = json.dumps({"event": "ms.channel.connect", "data": {"token": "12345678"}}).encode()
    writer.write(bytes([0x81, len(hello)]) + hello)
    writer.write(bytes([0x89, 0]))
    while True:
        b1, b2 = await reader.readexactly(2)
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack("!H", await reader.readexactly(2))[0]
        mask = await reader.readexactly(4)
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(await reader.readexactly(n)))
        op = b1 & 0x0F
        if op == 0x8:
            writer.close()
            return
        if op == 0xA:
            writer.write(bytes([0x81, 4]) + b"pong")
        elif op == 0x1:
            writer.write(ws_frame(b"echo:" + data))


async def test_wsclient():
    print("WebSocket client (loopback)")
    from . import wsclient
    server = await asyncio.start_server(ws_server, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    try:
        ws = await wsclient.connect(f"ws://127.0.0.1:{port}/api/v2/channels/samsung.remote.control?name=x")
        first = json.loads(await ws.recv())
        check("handshake and first message", first["event"] == "ms.channel.connect")
        got_pong = await asyncio.wait_for(ws.recv(), 3)
        check("answers a server ping", got_pong == "pong")
        await ws.send(json.dumps({"method": "x" * 200}))
        check("masked text round trip", (await asyncio.wait_for(ws.recv(), 3)).startswith("echo:{"))
        await ws.close()
    finally:
        server.close()


async def test_remote_socket():
    print("TV remote socket")
    from .tv import RemoteSocket
    sockets = []

    async def connector(url):
        check("token and name in the URL", "token=tok" in url and "name=" in url and url.startswith("wss://192.168.0.97:8002/"))
        ws = FakeWS([{"event": "ms.channel.connect", "data": {"token": "fresh"}}])
        sockets.append(ws)
        return ws
    rs = RemoteSocket(lambda: "192.168.0.97", "Home Hub", lambda: "tok", connector)
    rs.key("KEY_VOLUP")
    check("not allowed: nothing queued", not rs.pending and rs.state == "idle")
    rs.allowed = True
    for _ in range(25):
        rs.key("KEY_MUTE")
    check("queue capped at 20", len(rs.pending) == 20)
    for _ in range(20):
        await asyncio.sleep(0.01)
    check("ready after ms.channel.connect", rs.state == "ready" and rs.token == "fresh")
    check("queued keys flushed", sockets and len(sockets[0].sent) == 20 and sockets[0].sent[0]["params"]["DataOfCmd"] == "KEY_MUTE")
    rs.launch("111299001912")
    await asyncio.sleep(0.02)
    last = sockets[0].sent[-1]
    check("deep link launch payload", last["method"] == "ms.channel.emit" and last["params"]["data"]["action_type"] == "DEEP_LINK")
    rs.disconnect()

    async def deny(url):
        return FakeWS([{"event": "ms.channel.unauthorized"}])
    rs2 = RemoteSocket(lambda: "192.168.0.97", "Home Hub", lambda: "tok", deny)
    rs2.allowed = True
    rs2.connect_if_needed()
    for _ in range(10):
        await asyncio.sleep(0.01)
    check("unauthorized sticks until retry", rs2.state == "unauthorized")
    rs3 = RemoteSocket(lambda: "192.168.0.97", "Home Hub", lambda: None, deny)
    rs3.allowed = True
    rs3.connect_if_needed()
    for _ in range(10):
        await asyncio.sleep(0.01)
    check("no token from 1Password", rs3.state == "tokenUnavailable")


class FakeST:
    def __init__(self):
        self.usable = False
        self.worth_trying = True
        self.unavailable_reason = None
        self.status = None
        self.chosen_input = None
        self.current_input = None
        self.launched = []
        self.powered = 0
        self.inputs_set = []
        self.input_error = None

    async def launch(self, app_id):
        self.launched.append(app_id)
        return None

    async def power_on(self):
        self.powered += 1

    async def fetch(self, refresh=False):
        pass

    async def set_input(self, id):
        self.inputs_set.append(id)
        return self.input_error

    def input(self, id):
        return None


async def test_tv_model(tmp):
    print("TV model")
    from .store import Settings
    from .tv import TVModel, app_by_key
    clock = [1000.0]
    net = FakeNet()
    st = FakeST()
    settings = Settings(os.path.join(tmp, "tv-state.json"))
    cfg = config_mod.load(os.path.join(tmp, "none.json"))
    tv = TVModel(cfg, settings, st, lambda: None, net=net, connector=None, clock=lambda: clock[0])
    tv.socket.connect_if_needed = lambda: None
    tv.host = "192.168.0.23"
    net.discovered = "192.168.0.97"
    net.state = "on"
    await tv.poll()
    check("finds the TV by MAC after a DHCP change", tv.host == "192.168.0.97" and tv.power == "on")
    check("remembers the new address", Settings(os.path.join(tmp, "tv-state.json")).get("tv_host") == "192.168.0.97")
    calls = net.discover_calls
    net.state = "unreachable"
    clock[0] += 5
    await tv.poll()
    await tv.poll()
    check("tolerates two missed polls while on", tv.power == "on")
    await tv.poll()
    check("then reports unreachable", tv.power == "unreachable")
    check("no rediscovery within a minute", net.discover_calls == calls, net.discover_calls - calls)
    clock[0] += 61
    await tv.poll()
    check("rediscovers after a minute", net.discover_calls == calls + 1, net.discover_calls - calls)
    net.discovered = None
    tv.power_on()
    check("power on sends Wake-on-LAN", net.wakes == 1 and tv.waking)
    clock[0] += 3
    await tv.poll()
    check("keeps sending while waking", net.wakes == 2)
    clock[0] += 41
    await tv.poll()
    check("stops waking after 40 s", not tv.waking)
    net.state = "on"
    await tv.poll()
    tv.power_off()
    check("off without a remote is held", tv._off_requested_at is not None and tv.power == "standby")
    tv.socket.state = "ready"
    tv.socket.allowed = True
    sent = []
    tv.socket.key = lambda k: sent.append(k)
    clock[0] += 2
    await tv.poll()
    check("held off goes out once the remote is ready", sent == ["KEY_POWER"] and tv._off_requested_at is None)
    await tv.poll()
    check("trusts the click while the TV still says on", tv.power == "standby")
    clock[0] += 31
    await tv.poll()
    check("then believes the TV again", tv.power == "on")
    st.usable = True
    st.status = {"tv_channel_name": "IkWsFHtOY9.Stremio"}
    check("current app falls back to SmartThings", tv.current_app and tv.current_app.key == "stremio")
    st.usable = False
    tv.socket.state = "idle"
    tv.socket.connect_if_needed = lambda: None
    tv.now = time.time
    app = app_by_key("youtube")
    net.apps[app.id] = None
    t0 = time.time()
    result = await tv.open(app)
    check("launch chain falls through to REST", result and result["method"] == "local network" and net.launches == [app.id],
          result)
    check("launch chain respects the windows", time.time() - t0 > 11)


class FakeDevices:
    def __init__(self):
        self.log = []
        self.last_manual_lights_change = 0
        self.results = {}
        self.any_on = True

    async def _r(self, name, *a):
        self.log.append((name,) + a)
        await asyncio.sleep(0.01)
        return self.results.get(name, ("done", None))

    async def lights(self, look, manual):
        return await self._r("lights", look, manual)

    async def lights_any_on(self):
        return self.any_on

    async def tv_on(self):
        return await self._r("tvOn")

    async def tv_off(self):
        return await self._r("tvOff")

    async def open_app(self, app):
        return await self._r("openApp", app.key)

    async def keys(self, keys):
        return await self._r("keys", keys)

    async def input(self, id, fallback):
        return await self._r("input", id)

    async def ps5_wake(self):
        return await self._r("ps5Wake")


async def test_scenes(tmp):
    print("scenes")
    from .scenes import SceneRunner, input_switch, scene_by_id, summary
    from .store import Settings
    from .tv import app_by_key
    d = FakeDevices()
    settings = Settings(os.path.join(tmp, "scenes.json"))
    r = SceneRunner(d, settings)
    check("cinema opens Stremio by default", r.app_for(scene_by_id("cinema")).key == "stremio")
    r.set_app(scene_by_id("cinema"), app_by_key("netflix"))
    check("chosen app is saved", Settings(os.path.join(tmp, "scenes.json")).get("scene.cinema.app") == "netflix")
    await r.run_and_wait(scene_by_id("cinema"))
    names = [x[0] for x in d.log]
    check("cinema runs lights, TV on, app", sorted(names) == ["lights", "openApp", "tvOn"] and ("openApp", "netflix") in d.log)
    check("cinema summary", summary(r.current) == "Done")
    check("labels", [s["label"] for s in r.current["steps"]] == ["Lights warm white 20%", "Turn the TV on", "Open Netflix"])
    d.log.clear()
    d.results["tvOn"] = ("failed", "The TV didn't wake within 25 s.")
    await r.run_and_wait(scene_by_id("gaming"))
    st = {s["label"]: s["status"] for s in r.current["steps"]}
    check("a failed step skips the rest of its track", st["Switch to HDMI 2 (PS5)"] == ("skipped", "Skipped: the step before it failed."))
    check("other tracks still run", st["Wake the PS5"][0] == "done" and st["Lights PlayStation blue"][0] == "done")
    check("failed summary", summary(r.current) == "Didn't finish")
    d.results.clear()
    d.results["ps5Wake"] = ("warning", "The PS5 isn't answering on the network (fully off?).")
    await r.run_and_wait(scene_by_id("gaming"))
    check("warning summary", summary(r.current) == "Done, with warnings")
    tries = []

    async def cloud(i):
        tries.append(i)
        return "Device offline."

    async def keys(k):
        return ("done", "Sent")
    res = await input_switch("HDMI2", ["KEY_HDMI"], "HDMI 2", lambda: True, lambda: None, cloud, keys, retry_delay=0)
    check("input switch tries 3 times then falls back", len(tries) == 3 and res == ("warning",
          "Sent KEY_HDMI instead: SmartThings didn't switch (Device offline)."), res)

    async def ok(i):
        return None
    res = await input_switch("HDMI2", ["KEY_HDMI"], "HDMI 2", lambda: True, lambda: None, ok, keys, retry_delay=0)
    check("input switch via SmartThings", res == ("done", "HDMI 2 via SmartThings"))


async def test_automations(tmp):
    print("automations")
    from .scenes import AutomationEngine, AutomationLogic, Debounced, tv_hold
    from .store import Settings
    db = Debounced(tv_hold)
    check("first sample is the baseline", db.feed(False, 0) is None and db.confirmed is False)
    check("on needs 3 s", db.feed(True, 1) is None and db.feed(True, 3.9) is None and db.feed(True, 4) == (False, True))
    check("off needs 12 s", db.feed(False, 10) is None and db.feed(False, 21) is None and db.feed(False, 22) == (True, False))
    lg = AutomationLogic()
    all_on = {"ps5Blue", "tvOffNormal", "tvOnEvening"}
    lg.step(False, False, 0, all_on, -1e9, False, hour=20)
    lg.step(True, False, 1, all_on, -1e9, False, hour=20)
    check("TV on in the evening fires", lg.step(True, False, 5, all_on, -1e9, False, hour=20) == [("fire", "tvOnEvening", None)])
    lg2 = AutomationLogic()
    lg2.step(False, False, 0, all_on, -1e9, False, hour=12)
    lg2.step(True, False, 1, all_on, -1e9, False, hour=12)
    check("not in the afternoon", lg2.step(True, False, 5, all_on, -1e9, False, hour=12) == [])
    lg3 = AutomationLogic()
    lg3.step(False, False, 0, all_on, -1e9, False)
    out = lg3.step(False, True, 1, all_on, 0, False)
    check("manual grace", out == [("skip", "ps5Blue", "you changed the lights in the last 2 min")], out)
    lg4 = AutomationLogic()
    lg4.step(False, True, 0, all_on, -1e9, False, hour=21)
    lg4.step(True, True, 1, all_on, -1e9, False, hour=21)
    out = lg4.step(True, True, 5, all_on, -1e9, False, hour=21)
    check("evening skipped while the PS5 is on", out == [("skip", "tvOnEvening", "the PS5 is on, keeping the gaming lights")], out)
    lg5 = AutomationLogic()
    lg5.step(False, False, 0, all_on, -1e9, False)
    check("scene running blocks", lg5.step(False, True, 1, all_on, -1e9, True) == [("skip", "ps5Blue", "a scene was running")])
    lg6 = AutomationLogic()
    lg6.step(None, False, 0, all_on, -1e9, False)
    lg6.step(None, True, 1, all_on, -1e9, False)
    lg6.step(None, False, 2, all_on, -1e9, False)
    lg6.step(None, False, 80, all_on, -1e9, False)
    out = lg6.step(None, True, 81, all_on, -1e9, False)
    check("cooldown", out == [] or out == [("fire", "ps5Blue", None)])

    class Runner:
        running = False
    d = FakeDevices()
    d.last_manual_lights_change = 0
    eng = AutomationEngine(d, Runner(), Settings(os.path.join(tmp, "auto.json")))
    eng.set("tvOffNormal", True)
    check("toggle is saved", Settings(os.path.join(tmp, "auto.json")).get("automation.tvOffNormal") is True)
    d.any_on = False
    await eng.fire("tvOffNormal")
    check("TV off skips when lights are off", eng.events["tvOffNormal"]["text"] == "Skipped: the lights were off")
    d.any_on = True
    await eng.fire("tvOffNormal")
    check("TV off sets warm white 100", eng.events["tvOffNormal"]["text"] == "Ran" and d.log[-1] == ("lights", ("white", 100, 0), False))


async def test_voice(tmp):
    print("Alexa triggers")
    from .helper import Failure
    from .scenes import SWITCH_NAMES, SceneRunner, VoiceTriggers
    from .store import Settings
    now = time.time()
    iso = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - 5))
    old = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now - 600))

    class Source:
        def __init__(self):
            self.data = {"triggers": [], "missing": []}
            self.resets = []
            self.names = None
            self.fail = False

        async def fetch(self, names):
            self.names = names
            if self.fail:
                raise Failure("SmartThings didn't answer.", "network")
            return json.loads(json.dumps(self.data))

        async def claim(self, i):
            self.resets.append(i)
            if i in self.taken:
                return False
            self.taken.add(i)
            return True
    src = Source()
    src.taken = set()
    d = FakeDevices()
    runner = SceneRunner(d, Settings(None))
    v = VoiceTriggers(src, runner, Settings(None))
    check("enabled by default", v.enabled)
    src.data = {"triggers": [{"device_id": "g1", "name": "Gaming", "on": True, "changed_at": old}], "missing": ["Cinema"]}
    delay = await v.tick(now)
    check("asks for the four switch names", src.names == SWITCH_NAMES and len(SWITCH_NAMES) == 4)
    check("stale switch is reset but ignored", src.resets == ["g1"] and "Ignored" in v.last["text"] and not d.log)
    check("missing switches are reported", v.problem == "Not found in SmartThings: Cinema." and delay == 4)
    src.data = {"triggers": [{"device_id": "n1", "name": "Back to Normal", "on": True, "changed_at": iso}], "missing": []}
    await v.tick(now)
    await v.wait_for_run()
    check("fresh switch runs its scene", ("lights", ("white", 100, 0), True) in d.log and v.last["text"] == "Back to normal: Done")
    n = len(d.log)
    await v.tick(now)
    await v.wait_for_run()
    check("same switch-on never runs twice", len(d.log) == n and src.resets.count("n1") == 2)
    src.data = {"triggers": [{"device_id": "c1", "name": "Cinema", "on": True, "changed_at": iso}], "missing": []}
    src.taken.add("c1")
    await v.tick(now)
    await v.wait_for_run()
    check("switch the Mac already claimed: not run here", len(d.log) == n and v.last["text"] == "Cinema: Already handled by the Mac")
    src.fail = True
    check("backs off on failure", await v.tick(now) == 30 and v.problem == "SmartThings didn't answer.")


async def test_washer(tmp):
    print("washer")
    from . import washer as W
    from .store import Settings
    from .helper import Failure
    clock = [1_700_000_000.0]
    h = FakeHelper()
    sent = []
    settings = Settings(os.path.join(tmp, "washer.json"))
    w = W.WasherModel(h, settings, lambda t, b: sent.append((t, b)), clock=lambda: clock[0])
    done_at = clock[0] + 40 * 60
    iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
    running = {"found": True, "label": "Washer", "state": "running", "phase": "wash", "progress": 30, "remaining_min": 40,
               "operation_min": 60, "completion_time": iso(done_at), "phases": [{"name": "wash", "minutes": 30},
               {"name": "rinse", "minutes": 15}, {"name": "spin", "minutes": 15}], "temp": "40", "spin": "1200", "rinses": "2"}
    h.responses["st.washer"] = running
    await w.fetch()
    check("polls every minute during a cycle", w.interval == 60 and w.phase == "ready")
    a = w.availability()
    check("busy chip text", W.chip(a) == ("40m", f"Washer busy · 40 min left · done {W.clock(done_at)}"), W.chip(a))
    check("claim needs a running washer", w.claim_current() is True and w.claim and not w.notify_when_free)
    check("claim is saved", Settings(os.path.join(tmp, "washer.json")).get("washer.claim") is not None)
    d = w.display()
    check("claimed bar", d["kind"] == "running" and W.title(d) == "Washing" and W.trailing(d) == f"40 min left · done {W.clock(done_at)}")
    seg = W.fills(running["phases"], 30, "wash")
    check("progress segments", len(seg) == 3 and seg[1][1] == 0 and 0.06 <= seg[0][1] <= 0.97, seg)
    clock[0] += 45 * 60
    finished = dict(running, state="ready", phase="none", progress=100, remaining_min=0, state_since=iso(clock[0] - 60))
    h.responses["st.washer"] = finished
    await w.fetch()
    check("notifies when your washing is done", sent == [("Your washing is done", f"Finished at {W.clock(clock[0] - 60)}")], sent)
    check("finished bar", w.display()["kind"] == "finished" and W.title(w.display()) == "Your washing is done")
    await w.fetch()
    check("only one notification", len(sent) == 1)
    clock[0] += 31 * 60
    await w.fetch()
    check("claim dropped 30 min after the end", w.claim is None and W.chip(w.availability()) == ("Free", "Washer free"))
    h.responses["st.washer"] = running
    await w.fetch()
    w.set_notify_when_free(True)
    h.responses["st.washer"] = finished
    await w.fetch()
    check("tell me when it's free", sent[-1][0] == "The washer is free" and not w.notify_when_free)
    h.fail["st.washer"] = ("SmartThings token refresh is owned by the Mac app", "st_not_owner")
    await w.fetch()
    check("auth failure blocks polling", w.blocked_at is not None and not w.due(clock[0] + 10_000))
    w.smartthings_ok = lambda: clock[0] + 1
    check("until SmartThings works again", w.due(clock[0] + 10_000))
    h.fail["st.washer"] = ("timeout", "network")
    await w.fetch()
    await w.fetch()
    check("backoff doubles", w.interval == 240)
    check("duration text", W.minutes_text(75) == "1 h 15 min left" and W.minutes_text(0) == "Almost done")


async def test_lights(tmp):
    print("lights and presets")
    from . import lights as L
    check("labels fall back to Light N", L.labels([(1, "Lamp 1", "192.168.0.42"), (2, "Lamp 2", "192.168.0.41")]) == {2: "Light 1", 1: "Light 2"})
    check("distinct names are kept", L.labels([(1, "Sofa", "1.1.1.2"), (2, "Desk", "1.1.1.1")]) == {1: "Sofa", 2: "Desk"})
    check("warm and cool white", L.white_hex(0) == "ffb861" and L.white_hex(100) == "cce6ff", (L.white_hex(0), L.white_hex(100)))
    check("split colour", L.split("7f0000") == ("ff0000", 50), L.split("7f0000"))
    check("scaled colour", L.scaled("ff0000", 50) == "800000", L.scaled("ff0000", 50))
    h = FakeHelper()
    h.responses["lights.status"] = bulb_rows()
    h.responses["lights.apply"] = lambda p: [{"name": "x", "index": l["index"], "ok": l["index"] != 4} for l in p["looks"]]
    h.responses["lights.white"] = bulb_rows()
    lm = L.LightsModel(h, L.PresetStore(os.path.join(tmp, "light-presets.json")))
    await lm.refresh()
    check("bulbs load in IP order", [b.label for b in lm.bulbs] == ["Light 1", "Light 2", "Light 3", "Light 4"])
    check("master values", lm.master_subtitle == "4 of 4 on" and round(lm.master_brightness) == 80)
    sunset = next(p for p in L.BUILT_INS if p["id"] == "sunset")
    looks = L.resolved(sunset, lm.bulbs)
    check("built-in looks go round the bulbs", [l["colour"] for l in looks] == ["ff5a00", "ff2d6f", "ffa000", "8a2bff"])
    await lm.run_preset(sunset)
    check("preset result names the silent bulb", lm.preset_result and lm.preset_result["text"] == "Sunset: Light 4 didn't respond.",
          lm.preset_result)
    sent = [c for c in h.calls if c[0] == "lights.apply"][-1][1]["looks"]
    check("apply sends one look per bulb", len(sent) == 4 and all("colour" in l for l in sent))
    relax = next(p for p in L.BUILT_INS if p["id"] == "relax")
    for b in lm.bulbs:
        b.on, b.brightness, b.temp, b.colour, b.reachable = True, 45, 15, None, True
    check("active preset is ticked", L.is_active(relax, lm.bulbs) and not L.is_active(sunset, lm.bulbs))
    r = await lm.apply_look("white", True, 100, 0)
    check("scene look reports responders", r == (4, 4, None))
    h.fail["lights.status"] = ("Couldn't read the light keys", "lights_unavailable")
    await lm.refresh()
    check("unavailable is reported", lm.unavailable == "Couldn't read the light keys")
    with open(os.path.join(tmp, "mac-presets.json"), "w") as f:
        json.dump({"version": 1, "slots": [{"id": "custom-1", "name": "Mine", "looks": [
            {"index": 1, "on": True, "mode": "white", "brightness": 30, "temp": 10}]}, None]}, f)
    store = L.PresetStore(os.path.join(tmp, "mac-presets.json"))
    check("reads the Mac's light-presets.json", store.slots[0]["name"] == "Mine" and len(store.slots) == 5)

    good = [{"index": 2, "on": True, "mode": "colour", "brightness": 60, "temp": 0, "colour": "FF2D6F"},
            {"index": 1, "on": False, "mode": "white", "brightness": 50, "temp": 10}]
    cleaned = L.clean_looks(good)
    check("clean_looks sorts, lower-cases and fills colour", cleaned and [l["index"] for l in cleaned] == [1, 2]
          and cleaned[1]["colour"] == "ff2d6f" and cleaned[0]["colour"] is None, cleaned)
    for bad in ([], "x", [{"index": 0, "on": True, "mode": "white", "brightness": 5, "temp": 0}],
                [{"index": 1, "on": "yes", "mode": "white", "brightness": 5, "temp": 0}],
                [{"index": 1, "on": True, "mode": "party", "brightness": 5, "temp": 0}],
                [{"index": 1, "on": True, "mode": "colour", "brightness": 5, "temp": 0}],
                [{"index": 1, "on": True, "mode": "white", "brightness": 500, "temp": 0}],
                [{"index": 1, "on": True, "mode": "colour", "brightness": 5, "temp": 0, "colour": "<script>"}],
                [{"index": 1, "on": True, "mode": "white", "brightness": True, "temp": 0}],
                good + [dict(good[0])]):
        check(f"clean_looks refuses {json.dumps(bad)[:60]}", L.clean_looks(bad) is None)
    check("names are trimmed, collapsed and capped", L.clean_name("  Movie   night  ", 0) == "Movie night"
          and L.clean_name("", 2) == "Preset 3" and L.clean_name(None, 0) == "Preset 1" and len(L.clean_name("x" * 99, 0)) == 40
          and L.clean_name(42, 1) == "Preset 2")
    pid = store.slots[0]["id"]
    store.save(0, "Mine again", cleaned)
    check("replacing a slot keeps its id", store.slots[0]["id"] == pid and store.slots[0]["name"] == "Mine again")
    check("rename", store.rename(0, " Cosy ") and store.slots[0]["name"] == "Cosy")
    check("rename of an empty slot fails", not store.rename(3, "x"))
    store.clear(0)
    check("clear empties the slot", store.slots[0] is None)
    store.save(1, "Hub one", cleaned)
    incoming = [{"id": "custom-aa11", "name": "From Mac", "looks": good}, {"id": "custom-bb22", "name": "Clash", "looks": good},
                None, {"id": "custom-cc33", "name": "Bad", "looks": "nope"}, {"id": "../x", "name": "Odd id", "looks": good}]
    imported, kept, invalid = store.import_slots(incoming)
    check("import fills empty slots only", imported == [0, 4] and kept == [1] and invalid == [3], (imported, kept, invalid))
    check("import never overwrites the hub's slot", store.slots[1]["name"] == "Hub one")
    check("import keeps a safe id and replaces an odd one", store.slots[0]["id"] == "custom-aa11"
          and store.slots[4]["id"].startswith("custom-") and store.slots[4]["id"] != "../x")
    again = L.PresetStore(os.path.join(tmp, "mac-presets.json"))
    check("edits persist", [p and p["name"] for p in again.slots] == ["From Mac", "Hub one", None, None, "Odd id"])

    h.fail.pop("lights.status", None)
    rows = bulb_rows()
    rows[2] = {"name": "Bulb 3", "index": 3, "ip": "192.168.0.43", "ok": False}
    rows[1].update(mode="colour", color="#7f0000")
    h.responses["lights.status"] = rows
    looks, missing = await lm.capture_looks()
    check("capture reads every answering bulb", [l["index"] for l in looks] == [1, 2, 4] and missing == ["Light 3"], (looks, missing))
    check("capture splits colour and level", looks[1]["mode"] == "colour" and looks[1]["colour"] == "ff0000" and looks[1]["brightness"] == 50)
    h.responses["lights.status"] = [dict(r, ok=False) for r in bulb_rows()]
    try:
        await lm.capture_looks()
        check("capture with no bulbs fails", False)
    except Exception as e:
        check("capture with no bulbs fails", "None of the lights responded" in str(e))
    h.fail["lights.status"] = ("Couldn't read the light keys", "lights_unavailable")
    try:
        await lm.capture_looks()
    except Exception:
        pass
    check("capture marks the lights unavailable", lm.unavailable == "Couldn't read the light keys")
    h.fail.pop("lights.status", None)


async def test_web(tmp, cfg):
    print("web server, pairing and API")
    from . import lan
    from .app import Hub
    from .store import Settings
    from .web import COOKIE
    check("LAN policy", lan.is_local("192.168.0.5") and lan.is_local("10.1.2.3") and lan.is_local("172.20.0.1")
          and lan.is_local("fe80::1") and lan.is_local("fd00::1") and lan.is_local("::ffff:192.168.1.2")
          and not lan.is_local("100.64.0.1") and not lan.is_local("8.8.8.8") and not lan.is_local("172.32.0.1")
          and not lan.is_local("2001:db8::1") and lan.is_local("127.0.0.1") and not lan.is_local("127.0.0.1", allow_loopback=False))
    data = os.path.join(tmp, "webhub")
    c = config_mod.Config(dict(cfg, data_dir=data, port=0, bind=["127.0.0.1"], notifications=False))
    h = FakeHelper()
    h.responses["lights.status"] = bulb_rows()
    h.responses["lights.on"] = bulb_rows()
    h.responses["st.status"] = {"health": "ONLINE", "power": "on", "inputs": [{"id": "HDMI2", "name": "HDMI 2"}]}

    async def probe(host):
        return "rest"

    async def search():
        return []
    hub = Hub(c, helper=h, tv_net=FakeNet(), ps5_probe=probe, ps5_search=search, settings=Settings(os.path.join(data, "hub-state.json")))
    await hub.start(devices=False)
    port = hub.server.servers[0].sockets[0].getsockname()[1]
    hub.server.port = port
    base = f"http://127.0.0.1:{port}"

    def req(path, body=None, cookie=None, headers=None, method=None):
        hdrs = dict(headers or {})
        if body is not None and "Content-Type" not in hdrs:
            hdrs["Content-Type"] = "application/json"
        if cookie:
            hdrs["Cookie"] = f"{COOKIE}={cookie}"
        data_ = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(base + path, data=data_, headers=hdrs, method=method)
        try:
            with urllib.request.urlopen(r, timeout=10) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()

    async def areq(*a, **k):
        return await asyncio.get_running_loop().run_in_executor(None, lambda: req(*a, **k))

    try:
        s, hd, body = await areq("/")
        check("page served", s == 200 and b"<title>Living Room</title>" in body and b"home hub" in body)
        check("security headers", "default-src 'self'" in hd.get("Content-Security-Policy", "") and hd.get("X-Frame-Options") == "DENY")
        s, hd, body = await areq("/icon-180.png")
        check("icon is a 180 px PNG", s == 200 and body[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack("!II", body[16:24]) == (180, 180))
        s, _, _ = await areq("/api/state")
        check("unpaired device gets 401", s == 401)
        s, _, body = await areq("/api/pair", {"code": "123456"})
        check("no code active", s == 403 and json.loads(body)["code"] == "no_code")
        s, _, body = await areq("/api/pairing/local-start", {})
        code = json.loads(body)["code"]
        check("local pairing code", s == 200 and len(code) == 6 and code.isdigit())
        wrong = "000000" if code != "000000" else "111111"
        s, _, body = await areq("/api/pair", {"code": wrong})
        check("wrong code", s == 401 and json.loads(body)["code"] == "wrong")
        s, hd, body = await areq("/api/pair", {"code": code}, headers={"User-Agent": "Mozilla/5.0 (iPhone) Safari"})
        cookie = hd.get("Set-Cookie", "")
        token = cookie.split(";")[0].split("=", 1)[1] if "=" in cookie else ""
        check("pairs and sets the cookie", s == 200 and "HttpOnly" in cookie and "SameSite=Strict" in cookie and "Max-Age=34560000" in cookie)
        with open(os.path.join(data, "web-devices.json")) as f:
            stored = f.read()
        check("only the token's hash is stored", token and token not in stored and hashlib.sha256(token.encode()).hexdigest() in stored)
        check("device label", json.loads(stored)["devices"][0]["label"] == "iPhone · Safari")
        s, _, body = await areq("/api/pair", {"code": code})
        check("a code works once", s == 403)
        s, _, body = await areq("/api/state?focus=now", cookie=token)
        st = json.loads(body)
        check("state has every section", s == 200 and set(st) == {"theme", "room", "tv", "lights", "scenes", "ps5", "washer", "weather", "match"})
        check("state keys are camelCase", "remoteReady" in st["tv"] and "anyOn" in st["lights"] and "switchNote" in st["ps5"])
        check("scenes listed", [x["id"] for x in st["scenes"]["list"]] == ["cinema", "gaming", "goodnight", "normal"])
        s, _, _ = await areq("/api/tv/key", "x", cookie=token, headers={"Content-Type": "text/plain"})
        check("non-JSON POST refused", s == 415)
        s, _, _ = await areq("/api/tv/key", {"key": "KEY_VOLUP"}, cookie=token, headers={"Origin": "http://evil.example"})
        check("cross-origin POST refused", s == 403)
        s, _, _ = await areq("/api/state", cookie=token, headers={"Host": "rebind.example:8787"})
        check("unknown Host refused (DNS rebinding)", s == 421)
        s, _, body = await areq("/api/tv/key", {"key": "KEY_POWER"}, cookie=token)
        check("keys outside the whitelist refused", s == 400)
        s, _, body = await areq("/api/tv/key", {"key": "KEY_VOLUP"}, cookie=token)
        check("TV off answers 409", s == 409 and json.loads(body)["code"] == "tv_off")
        s, _, body = await areq("/api/rpc", {"method": "st.reset_trigger", "params": {}}, cookie=token)
        check("rpc refuses methods outside the list", s == 400)
        s, _, body = await areq("/api/rpc", {"method": "st.status", "params": {"refresh": False}}, cookie=token)
        check("rpc runs st.status on the hub", s == 200 and json.loads(body)["result"]["power"] == "on" and hub.st.usable)
        s, _, _ = await areq("/api/automations/set", {"kind": "ps5Blue", "on": True}, cookie=token)
        s2, _, body = await areq("/api/hub", cookie=token)
        hs = json.loads(body)
        check("hub state for the Mac", s == 200 and s2 == 200 and hs["automations"]["enabled"] == ["ps5Blue"] and hs["voice"]["enabled"])
        s, _, _ = await areq("/api/scenes/app", {"scene": "cinema", "app": "netflix"}, cookie=token)
        s2, _, body = await areq("/api/hub", cookie=token)
        check("scene app set from the Mac", s == 200 and json.loads(body)["scenes"]["apps"]["cinema"] == "netflix")
        await hub.lights.refresh()
        s, _, _ = await areq("/api/lights/power", {"on": True, "index": 9}, cookie=token)
        check("unknown light refused", s == 400)
        s, _, _ = await areq("/api/lights/power", {"on": False, "index": None}, cookie=token)
        check("lights power accepted", s == 200)
        s, _, body = await areq("/api/presets/save", {"slot": 2, "name": "  Sofa time "}, cookie=token)
        saved = json.loads(body)
        check("presets/save captures the bulbs into the slot", s == 200 and saved["name"] == "Sofa time"
              and hub.lights.presets.slots[2]["looks"][0]["index"] == 1, saved)
        s, _, body = await areq("/api/state?focus=lights", cookie=token)
        lst = json.loads(body)["lights"]
        check("lights state lists the slots", lst["slots"][2] == {"id": saved["id"], "name": "Sofa time"} and lst["slots"][0] is None
              and any(p["id"] == saved["id"] for p in lst["presets"]))
        s, _, body = await areq("/api/presets/rename", {"slot": 2, "name": "Reading"}, cookie=token)
        check("presets/rename", s == 200 and hub.lights.presets.slots[2]["name"] == "Reading")
        s, _, body = await areq("/api/presets/rename", {"slot": 3, "name": "x"}, cookie=token)
        check("rename an empty slot: 409", s == 409)
        for bad in ({"slot": 5}, {"slot": -1}, {"slot": "1"}, {"slot": True}, {"slot": 1, "name": 7}, {}):
            s, _, _ = await areq("/api/presets/rename", bad, cookie=token)
            check(f"presets refuse {bad}", s == 400)
        s, _, _ = await areq("/api/presets/put", {"slot": 1, "name": "x", "looks": [{"index": 1}]}, cookie=token)
        check("presets/put refuses bad looks", s == 400)
        s, _, body = await areq("/api/presets/put", {"slot": 1, "name": "From the Mac", "looks": [
            {"index": 1, "on": True, "mode": "white", "brightness": 30, "temp": 10}]}, cookie=token)
        check("presets/put stores the Mac's looks", s == 200 and hub.lights.presets.slots[1]["name"] == "From the Mac")
        s, _, body = await areq("/api/presets/import", {"slots": [
            {"id": "custom-1234", "name": "Mac 1", "looks": [{"index": 2, "on": True, "mode": "white", "brightness": 20, "temp": 0}]},
            {"id": "custom-5678", "name": "Mac 2", "looks": [{"index": 2, "on": True, "mode": "white", "brightness": 20, "temp": 0}]}]},
            cookie=token)
        imp = json.loads(body)
        check("presets/import fills empty slots and reports the kept ones", s == 200 and imp["imported"] == [0] and imp["kept"] == [1]
              and hub.lights.presets.slots[1]["name"] == "From the Mac", imp)
        s, _, body = await areq("/api/hub", cookie=token)
        hp = json.loads(body)["presets"]
        check("hub state carries the slots for the Mac", [p and p["name"] for p in hp["slots"]] == ["Mac 1", "From the Mac", "Reading", None, None]
              and "busy" in hp and "result" in hp)
        s, _, _ = await areq("/api/presets/clear", {"slot": 2}, cookie=token)
        check("presets/clear", s == 200 and hub.lights.presets.slots[2] is None)
        s, _, _ = await areq("/api/presets/clear", {"slot": 0}, cookie=token, headers={"Origin": "http://evil.example"})
        check("presets: cross-origin refused", s == 403 and hub.lights.presets.slots[0] is not None)
        s, _, _ = await areq("/api/presets/clear", {"slot": 0})
        check("presets: unpaired refused", s == 401 and hub.lights.presets.slots[0] is not None)
        s, _, _ = await areq("/api/presets/clear", "x", cookie=token, headers={"Content-Type": "text/plain"})
        check("presets: non-JSON refused", s == 415)
        s, _, _ = await areq("/api/presets/nope", {"slot": 0}, cookie=token)
        check("presets: unknown route 404", s == 404)
        h.responses["lights.status"] = [dict(r, ok=False) for r in bulb_rows()]
        s, _, body = await areq("/api/presets/save", {"slot": 3, "name": "x"}, cookie=token)
        check("presets/save with no bulbs answering: 502, slot stays empty", s == 502 and hub.lights.presets.slots[3] is None
              and hub.lights.preset_busy is None)
        h.responses["lights.status"] = bulb_rows()
        s, _, _ = await areq("/api/washer/claim", {}, cookie=token)
        check("claim needs a running washer", s == 409)
        s, _, body = await areq("/api/pairing/start", {}, cookie=token)
        check("a paired device (the Mac) can start pairing", s == 200 and len(json.loads(body)["code"]) == 6)
        s, _, _ = await areq("/api/state", cookie="x" * 30)
        check("short tokens rejected", s == 401)
        s, _, _ = await areq("/api/state", cookie=token, headers={"Host": "homehub.local:8787"})
        check("homehub.local:8787 is an allowed Host", s == 200)
        s, _, _ = await areq("/api/tv/key", {"key": "KEY_VOLUP"}, cookie=token,
                             headers={"Host": "homehub.local:8787", "Origin": "http://homehub.local:8787"})
        check("same-origin POST on homehub.local passes the origin check", s == 409)
        s, _, body = await areq("/api/devices", cookie=token)
        devs = json.loads(body)["devices"]
        check("device list for the Mac: hashes and labels, never tokens", s == 200 and devs[0]["hash"] == hashlib.sha256(token.encode()).hexdigest()
              and set(devs[0]) == {"hash", "label", "pairedAt"} and token not in body.decode())
        s, _, _ = await areq("/api/devices")
        check("device list needs a paired device", s == 401)
        mac_token = "m" * 43
        mac_hash = hashlib.sha256(mac_token.encode()).hexdigest()
        s, _, body = await areq("/api/devices/import", {"devices": [
            {"hash": mac_hash, "label": "iPhone · Safari", "pairedAt": "2026-10-17T10:00:00Z"},
            {"hash": devs[0]["hash"], "label": "dupe"}, {"hash": "not-a-hash"}, {"hash": "A" * 64}, "junk"]}, cookie=token)
        check("import adds only new, well-formed hashes", s == 200 and json.loads(body)["added"] == 1 and len(hub.pairing.devices) == 2)
        s, _, _ = await areq("/api/state", cookie=mac_token)
        check("a phone paired on the Mac while the hub was down now works on the hub", s == 200)
        s, _, _ = await areq("/api/devices/import", {"devices": "x"}, cookie=token)
        check("import refuses a non-list", s == 400)

        async def raw(payload):
            r, w = await asyncio.open_connection("127.0.0.1", port)
            w.write(payload)
            await w.drain()
            out = await asyncio.wait_for(r.read(), 5)
            w.close()
            return out
        out = await raw(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nX: " + b"a" * 17000 + b"\r\n\r\n")
        check("header limit", out.startswith(b"HTTP/1.1 431"))
        out = await raw(b"POST /api/pair HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 70000\r\n\r\n")
        check("body limit", out.startswith(b"HTTP/1.1 413"))
        out = await raw(b"NONSENSE\r\n\r\n")
        check("bad request line", out.startswith(b"HTTP/1.1 400"))
    finally:
        await hub.stop()


async def test_ps5(tmp, cfg):
    print("PS5")
    from . import ps5 as P
    from .store import Settings
    check("status replies", P.parse_reply(b"HTTP/1.1 620 Server Standby\nhost-id:ABC\nhost-type:PS5\n") == ("rest", {"host-id": "ABC", "host-type": "PS5"}))
    key = "61623132"
    msg = P.wake_message(key.encode().hex())
    check("wake credential decodes the RegistKey", b"user-credential:" + str(int("61623132", 16)).encode() + b"\n" in msg
          and msg.startswith(b"WAKEUP * HTTP/1.1\n"))
    clock = [5000.0]
    probes, searches = [], []
    answers = {"192.168.0.51": "rest"}

    async def probe(host):
        probes.append(host)
        return answers.get(host, "off")

    async def search():
        searches.append(1)
        return [("192.168.0.60", "OTHER", "on"), ("192.168.0.51", "MINE", "rest")]
    settings = Settings(os.path.join(tmp, "ps5.json"))
    m = P.PS5Model(cfg, FakeHelper(), probe=probe, clock=lambda: clock[0], settings=settings, search=search)
    m._creds = json.dumps({"host_id": "MINE", "RegistKey": key.encode().hex()})
    await m.probe()
    check("finds the paired PS5 by broadcast after a DHCP change", m.host == "192.168.0.51" and m.status == "rest", (m.host, m.status))
    check("remembers the new PS5 address", Settings(os.path.join(tmp, "ps5.json")).get("ps5_host") == "192.168.0.51")
    answers.clear()
    clock[0] += 10
    await m.probe()
    check("PS5 search at most once a minute", len(searches) == 1 and m.status == "off")
    m2 = P.PS5Model(cfg, FakeHelper(), probe=probe, clock=lambda: clock[0], settings=settings, search=search)
    check("starts from the remembered address", m2.host == "192.168.0.51")
    h = FakeHelper()
    m3 = P.PS5Model(cfg, h, probe=probe, clock=lambda: clock[0], settings=settings, search=search)
    m3._creds = m._creds
    m3._last_search = clock[0]
    answers["192.168.0.51"] = "rest"
    ok, text, code = await m3.set_power(False)
    check("rest mode goes through the helper with the current address",
          ("ps5.standby", {"host": "192.168.0.51"}) in h.calls and ok and text == "In rest mode", (ok, text))


def test_webui():
    print("web UI")
    from . import sync_webui
    page = sync_webui.build()
    with open(sync_webui.OUT, encoding="utf-8") as f:
        check("hub/web/index.html matches WebUI.swift", f.read() == page)
    check("no Mac-only wording left in the hub's page", "Can't reach the Mac" not in page and "Use Retry in the Mac" not in page)
    check("the page has its inline script", len(sync_webui.scripts(page)) >= 1)
    for label, html in (("hub page", page), ("Mac page", sync_webui.build_mac())):
        errors = sync_webui.js_errors(html)
        if errors is None:
            print(f"  skip {label}: jsc not found, script not parsed")
        else:
            check(f"{label}: script parses (jsc checkSyntax)", not errors, errors)
    test_long_press(page)
    broken = "<script>const a = 'it's';</script>"
    errors = sync_webui.js_errors(broken)
    if errors is not None:
        check("jsc check catches an apostrophe in a single-quoted string", len(errors) == 1, errors)


LONG_PRESS_HARNESS = r"""
let clock = 0; const timers = []; const on = {capture: {}, bubble: {}}; const out = [];
const Date = {now: () => clock};
function setTimeout(fn, ms) { timers.push({fn, at: clock + ms, id: timers.length + 1}); return timers.length; }
function clearTimeout(id) { const t = timers.find(t => t.id === id); if (t) t.fn = null; }
function advance(ms) { clock += ms; for (const t of timers) if (t.fn && t.at <= clock) { const f = t.fn; t.fn = null; f(); } }
const document = {addEventListener(type, fn, capture) { (on[capture ? 'capture' : 'bubble'][type] ||= []).push(fn); }};
function haptic() { out.push('haptic'); }
function slotSheet(i) { out.push('sheet ' + i); }
function tile(hold) { return {disabled: false, dataset: hold == null ? {} : {hold: String(hold)}, closest(sel) { return sel === '[data-hold]' && hold != null ? this : null; }}; }
function fire(type, target, x = 0, y = 0) {
  let stopped = false, prevented = false;
  const e = {target, clientX: x, clientY: y, preventDefault() { prevented = true; }, stopImmediatePropagation() { stopped = true; }};
  for (const f of on.capture[type] || []) { f(e); if (stopped) return {stopped, prevented}; }
  for (const f of on.bubble[type] || []) f(e);
  if (type === 'click') out.push('tap');
  return {stopped, prevented};
}
on.bubble.click = [];
BLOCK
const t = tile(2), plain = tile(null), r = [];
fire('pointerdown', t); advance(200); fire('pointerup', t); fire('click', t); advance(1000);
r.push(out.join(',')); out.length = 0;
fire('pointerdown', t); advance(520); fire('pointerup', t); const c = fire('click', t);
r.push(out.join(',') + '|' + c.stopped); out.length = 0;
advance(1000); fire('click', t); r.push(out.join(',')); out.length = 0;
fire('pointerdown', t, 0, 0); advance(100); fire('pointermove', t, 0, 30); advance(600); r.push(out.join(',')); out.length = 0;
fire('pointerdown', t); advance(100); fire('pointercancel', t); advance(600); r.push(out.join(',')); out.length = 0;
fire('pointerdown', plain); advance(600); r.push(out.join(',')); out.length = 0;
r.push(String(fire('contextmenu', t).prevented));
print(JSON.stringify(r));
"""


def test_long_press(page):
    import re
    import subprocess
    from . import sync_webui
    m = re.search(r"// Press and hold a saved preset.*?document\.addEventListener\('contextmenu'.*?\n", page, re.S)
    check("page has the long-press block", m is not None)
    tiles = re.search(r"const slot = \(L\.slots \|\| \[\]\)\.findIndex\(s => s && s\.id === p\.id\);.*?data-hold=", page, re.S)
    check("only saved slot presets carry data-hold (built-ins keep tap only)", tiles is not None)
    check("preset tiles: no callout or text selection on iOS", "-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;touch-action:manipulation" in page)
    if m is None or not os.path.exists(sync_webui.JSC):
        print("  skip long-press behaviour: jsc not found")
        return
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "hold.js")
        with open(path, "w", encoding="utf-8") as f:
            f.write(LONG_PRESS_HARNESS.replace("BLOCK", m.group(0)))
        r = subprocess.run([sync_webui.JSC, path], capture_output=True, text=True, timeout=30)
    try:
        res = json.loads(r.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        check("long-press harness runs", False, (r.stdout + r.stderr)[:300])
        return
    check("short tap: applies the preset, no sheet", res[0] == "tap", res[0])
    check("hold 500 ms: haptic and that slot's sheet; the release doesn't apply it", res[1] == "haptic,sheet 2|true", res[1])
    check("the next tap after that works normally", res[2] == "tap", res[2])
    check("finger moved (scrolling): no sheet", res[3] == "", res[3])
    check("pointercancel (iOS scroll): no sheet", res[4] == "", res[4])
    check("built-in presets: holding does nothing", res[5] == "", res[5])
    check("no context menu on a held tile", res[6] == "true", res[6])


async def test_mdns():
    print("homehub.local (mDNS)")
    from . import mdns
    net = {"holder": None, "conflict": False, "fail": None}
    events = []

    class FakeBackend:
        def __init__(self, ip):
            if net["fail"]:
                raise OSError(net["fail"])
            self.ip = ip
            events.append(("open", ip))

        async def holder(self, name, timeout=3.0):
            return net["holder"]

        async def register(self, info, probe):
            if probe and net["conflict"]:
                raise mdns.Conflict()
            events.append(("register", info["ip"], probe))

        async def unregister(self, info):
            events.append(("unregister", info["ip"]))

        async def close(self):
            events.append(("close", self.ip))

    t = [0.0]
    ip = ["192.168.0.15"]
    logs = []
    p = mdns.Publisher("homehub", 8787, logs.append, address=lambda: ip[0], backend=FakeBackend,
                       info=lambda name, a, port: {"name": name, "ip": a, "port": port}, clock=lambda: t[0])
    await p.step()
    check("hub announces homehub.local when nobody holds it", p.state == "published" and events == [("open", "192.168.0.15"),
          ("register", "192.168.0.15", True)] and "TTL 30 s" in logs[-1])
    events.clear()
    await p.step()
    check("nothing re-sent while published and the address is the same", events == [])
    ip[0] = "192.168.0.16"
    await p.step()
    check("a new LAN address: withdraw, then announce the new one", events == [("unregister", "192.168.0.15"), ("close", "192.168.0.15"),
          ("open", "192.168.0.16"), ("register", "192.168.0.16", True)] and p.state == "published")
    await p.stop()
    events.clear()

    ip[0] = "192.168.0.15"
    net["holder"] = "192.168.0.20"
    p = mdns.Publisher("homehub", 8787, logs.append, address=lambda: ip[0], backend=FakeBackend,
                       info=lambda name, a, port: {"name": name, "ip": a, "port": port}, clock=lambda: t[0])
    await p.step()
    check("hub coming back while the Mac answers: waits, doesn't announce", p.state == "waiting"
          and not any(e[0] == "register" for e in events) and "192.168.0.20" in logs[-1])
    t[0] = 8.0
    net["holder"] = None
    await p.step()
    check("…and announces once the Mac lets go", p.state == "published" and events[-1] == ("register", "192.168.0.15", True))
    await p.stop()
    events.clear()

    net["holder"], net["conflict"] = "192.168.0.20", True
    t[0] = 0.0
    p = mdns.Publisher("homehub", 8787, logs.append, address=lambda: ip[0], backend=FakeBackend,
                       info=lambda name, a, port: {"name": name, "ip": a, "port": port}, clock=lambda: t[0])
    await p.step()
    t[0] = mdns.GRACE - 1
    await p.step()
    check("still waiting just inside the grace period", p.state == "waiting" and not any(e[0] == "register" for e in events))
    t[0] = mdns.GRACE + 1
    await p.step()
    check("after the grace period it announces without probing (the Mac's unique record then yields)",
          p.state == "published" and events[-1] == ("register", "192.168.0.15", False))
    await p.stop()
    events.clear()

    net["holder"], net["conflict"] = None, True
    t[0] = 0.0
    p = mdns.Publisher("homehub", 8787, logs.append, address=lambda: ip[0], backend=FakeBackend,
                       info=lambda name, a, port: {"name": name, "ip": a, "port": port}, clock=lambda: t[0])
    await p.step()
    check("a probe conflict also waits", p.state == "waiting" and "still held" in logs[-1])
    await p.stop()
    net["conflict"] = False
    net["fail"] = "Address already in use"
    p = mdns.Publisher("homehub", 8787, logs.append, address=lambda: ip[0], backend=FakeBackend,
                       info=lambda name, a, port: {"name": name, "ip": a, "port": port}, clock=lambda: t[0])
    await p.step()
    n = len(logs)
    await p.step()
    check("port 5353 unusable: logged once, keeps retrying", p.state == "failed" and "Address already in use" in logs[n - 1] and len(logs) == n)
    net["fail"] = None
    await p.step()
    check("…and publishes once it can", p.state == "published")
    task = asyncio.ensure_future(p.run())
    await asyncio.sleep(0.05)
    events.clear()
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    check("hub shutting down withdraws the name (goodbye)", events[:2] == [("unregister", "192.168.0.15"), ("close", "192.168.0.15")])
    ip[0] = None
    p = mdns.Publisher("homehub", 8787, logs.append, address=lambda: ip[0], backend=FakeBackend,
                       info=lambda name, a, port: {"name": name, "ip": a, "port": port}, clock=lambda: t[0])
    await p.step()
    check("no LAN address: nothing announced", p.state == "idle")
    try:
        info = mdns.service_info("homehub", "192.168.0.15", 8787)
        check("real ServiceInfo: homehub.local. A record, TTLs 30/120, port 8787", info.server == "homehub.local."
              and info.parsed_addresses() == ["192.168.0.15"] and info.port == 8787 and info.host_ttl == 30 and info.other_ttl == 120
              and info.name == "Home Hub._http._tcp.local." and all(r.ttl == 30 for r in info.dns_addresses()))
    except ImportError:
        print("  skip real ServiceInfo: zeroconf not installed here")


async def run_async(tmp, cfg):
    await test_mdns()
    for fn in (test_wsclient, test_remote_socket):
        await fn()
    await test_tv_model(tmp)
    await test_scenes(tmp)
    await test_automations(tmp)
    await test_voice(tmp)
    await test_washer(tmp)
    await test_lights(tmp)
    await test_ps5(tmp, cfg)
    await test_web(tmp, cfg)


def main():
    sys.modules["keyring"] = fake_keyring
    import op_cli  # noqa: F401
    real_run = op_cli.run
    op_cli.run = _tripwire
    socket.socket.sendto = _guarded_sendto
    tmp = tempfile.mkdtemp(prefix="hub-selftest-")
    os.environ["HOME_HUB_DATA"] = tmp
    saved_env = {k: os.environ.get(k) for k in ("HOME_SECRETS", "HOME_KEYRING_SERVICE", "HOME_ST_HOST")}
    try:
        cfg = test_config(tmp)
        test_secret_store()
        test_smartthings_owner()
        test_transfer()
        asyncio.run(run_async(tmp, cfg))
        test_webui()
    except Exception:
        traceback.print_exc()
        RESULTS.append(("crashed", False, ""))
    finally:
        op_cli.run = real_run
        socket.socket.sendto = _real_sendto
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(tmp, ignore_errors=True)
    check("1Password CLI was never run", not op_calls, op_calls)
    failed = [r for r in RESULTS if not r[1]]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} checks passed")
    print("ALL CHECKS PASSED" if not failed else "SOME CHECKS FAILED")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
