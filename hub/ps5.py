"""PS5 status by device discovery on UDP 9302, power through ps5_control.py, PSN through the helper (PS5.swift)."""
import asyncio
import json
import socket
import time

from . import vault
from .helper import Failure

BACKGROUND_POLL = 30
VISIBLE_POLL = 5
PSN_TTL = 60
ON, REST, OFF = "on", "rest", "off"

POWER_MESSAGES = {
    "not_paired": "Not paired yet. Pair on the Mac with ps5_pair.py, then send the secrets.",
    "op_unavailable": "The credential store isn't available.",
    "op_failed": "Couldn't read the PS5 pairing from the credential store.",
    "bad_creds": "The PS5 pairing looks broken. Pair again with ps5_pair.py on the Mac, then send the secrets again.",
    "unreachable": "The PS5 isn't answering on the network.",
    "network": "Network error talking to the PS5.",
    "wake_timeout": "Wake sent, but it's still in rest mode.",
    "session_failed": "The Remote Play session failed.",
    "session_timeout": "The Remote Play session timed out.",
    "standby_failed": "Couldn't put the PS5 into rest mode.",
    "standby_timeout": "Rest mode sent, but it still reports on. A game may be blocking it.",
}


def probe_blocking(host, timeout=1.5):
    """"200 Ok" means on, "620" rest mode, silence off or unreachable. No auth needed."""
    msg = b"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n"
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        try:
            s.sendto(msg, (host, 9302))
            data, _ = s.recvfrom(2048)
        except OSError:
            return OFF
    return parse_reply(data)[0]


def parse_reply(data):
    lines = data.decode("utf-8", "replace").split("\n")
    fields = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
    first = lines[0]
    status = ON if " 200" in first else REST if " 620" in first else OFF
    return status, fields


def search_blocking(timeout=2.0):
    """Broadcast SRCH; returns [(ip, host_id, status)] for every PS5 that answers."""
    msg = b"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n"
    found = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        s.settimeout(timeout)
        try:
            s.sendto(msg, ("255.255.255.255", 9302))
            while True:
                data, addr = s.recvfrom(2048)
                status, fields = parse_reply(data)
                if fields.get("host-type", "PS5").upper() == "PS5":
                    found.append((addr[0], fields.get("host-id"), status))
        except OSError:
            pass
    return found


def wake_message(regist_key):
    credential = str(int.from_bytes(bytes.fromhex(bytes.fromhex(regist_key).decode()), "big"))
    return (f"WAKEUP * HTTP/1.1\nuser-credential:{credential}\nclient-type:vr\nauth-type:R\nmodel:w\napp-type:r\n"
            "device-discovery-protocol-version:00030010\n").encode()


def wake_blocking(host, creds_json):
    """The same DDP packet pyremoteplay sends, so waking needs no Remote Play session (or library)."""
    try:
        creds = json.loads(creds_json)
        msg = wake_message(creds["RegistKey"])
    except (ValueError, KeyError, TypeError):
        raise Failure("The PS5 pairing looks broken. Pair again with ps5_pair.py on the Mac, then send the secrets again.", "bad_creds")
    port = 987 if creds.get("host_type") == "PS4" else 9302
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.bind(("0.0.0.0", 9303))
        except OSError:
            pass
        try:
            s.sendto(msg, (host or creds.get("host"), port))
        except OSError:
            raise Failure("Network error talking to the PS5.", "network")


def hours(seconds):
    h = seconds / 3600
    if h >= 10:
        return f"{int(round(h))} h"
    return f"{h:.1f} h" if h >= 1 else f"{seconds // 60} min"


class PS5Model:
    def __init__(self, cfg, helper, probe=None, clock=time.time, settings=None, search=None):
        self.cfg = cfg
        self.helper = helper
        self.now = clock
        self.settings = settings
        self._probe = probe or (lambda host: asyncio.get_running_loop().run_in_executor(None, probe_blocking, host))
        self._search = search or (lambda: asyncio.get_running_loop().run_in_executor(None, search_blocking))
        self._last_search = None
        self.host = (settings.get("ps5_host") if settings else None) or cfg["ps5_host"]
        self.status = OFF
        self.has_polled = False
        self.psn = None
        self.psn_loading = False
        self.psn_fetched_at = None
        self.psn_helper_error = None
        self.power_busy = False
        self.power_error = None
        self._creds = None
        self._last_probe = 0

    async def run(self):
        while True:
            if self.now() - self._last_probe >= BACKGROUND_POLL - 0.5:
                await self.probe()
            await asyncio.sleep(VISIBLE_POLL)

    async def probe(self):
        self._last_probe = self.now()
        status = await self._probe(self.host)
        if status == OFF and self.now() - (self._last_search or -1e9) > 60:
            self._last_search = self.now()
            status = await self._rediscover() or status
        self.status = status
        self.has_polled = True

    async def _rediscover(self):
        """The router can hand the PS5 a new address; prefer the paired console's id when several answer."""
        found = await self._search()
        if not found:
            return None
        want = None
        try:
            want = json.loads(self._creds).get("host_id") if self._creds else None
        except (ValueError, AttributeError):
            pass
        ip, _, status = next((f for f in found if want and f[1] == want), found[0])
        if ip != self.host:
            self.host = ip
            if self.settings is not None:
                self.settings.set("ps5_host", ip)
        return status

    def _read_creds(self):
        raw = vault.field(self.cfg.item("ps5"))
        if not raw:
            raise Failure("PS5 isn't paired yet. Pair on the Mac with ps5_pair.py, then send the secrets.", "not_paired")
        return raw

    async def set_power(self, on):
        """Returns (ok, text, code). Wake or rest mode, then re-probe until the console agrees."""
        if self.power_busy:
            return False, "Already changing power.", None
        self.power_busy = True
        self.power_error = None
        try:
            try:
                if self._creds is None:
                    try:
                        self._creds = await asyncio.get_running_loop().run_in_executor(None, self._read_creds)
                    except vault.SecretsError:
                        raise Failure("Couldn't read the PS5 pairing from the credential store.", "op_failed")
                if on:
                    await asyncio.get_running_loop().run_in_executor(None, wake_blocking, self.host, self._creds)
                else:
                    await self.helper.ps5("standby", self._creds, self.host)
            except Failure as e:
                if e.code == "bad_creds":
                    self._creds = None
                message = POWER_MESSAGES.get(e.code) or str(e)
                self.power_error = message
                await self.probe()
                return False, message, e.code
            want = ON if on else REST
            start = self.now()
            while self.now() - start < 40:
                await self.probe()
                if self.status == want:
                    return True, (f"On after {int(round(self.now() - start))} s" if on else "In rest mode"), None
                await asyncio.sleep(2)
            message = "Wake sent, but it hasn't come on yet." if on else "Rest mode sent, but it still reports on."
            self.power_error = message
            return False, message, None
        finally:
            self.power_busy = False

    async def refresh_psn(self, force=False):
        if not force and self.psn_fetched_at and self.now() - self.psn_fetched_at < PSN_TTL:
            return
        if self.psn_loading:
            return
        self.psn_loading = True
        try:
            summary = await self.helper.call("psn.summary", {"force": force})
            self.psn = summary
            self.psn_helper_error = None
            self.psn_fetched_at = self.now() if summary.get("state") == "ready" else None
        except Failure as e:
            self.psn_helper_error = str(e)
        finally:
            self.psn_loading = False

    @property
    def playing_caption(self):
        presence = (self.psn or {}).get("presence") or {}
        parts = []
        if presence.get("platform") and presence.get("online_status") == "online":
            parts.append(f"On {presence['platform']}")
        if self.psn_fetched_at:
            minutes = int((self.now() - self.psn_fetched_at) / 60)
            parts.append("Updated just now" if minutes < 1 else f"Updated {minutes} min ago")
        return " · ".join(parts) if parts else "From your PSN presence"
