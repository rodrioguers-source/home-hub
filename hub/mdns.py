"""Publishes homehub.local -> this laptop's LAN address over mDNS, plus a "Home Hub" _http._tcp service, so the
phone keeps one address whichever machine is up. While the hub is down the Mac answers for the same names.

When the hub comes back, it first waits (up to GRACE seconds) for the Mac to let go, which the Mac does
within one 4 s poll of the hub answering. After that it announces anyway: the Mac's record is "unique",
so its mDNSResponder withdraws on seeing the hub's announcement.
"""
import asyncio
import time

from . import lan

SERVICE_TYPE = "_http._tcp.local."
INSTANCE = "Home Hub"
# Short, so a phone holding a dead machine's address asks again well before the Mac takes over (60 s).
HOST_TTL = 30
OTHER_TTL = 120
RETRY = 5
GRACE = 30


class Conflict(Exception):
    pass


class ZeroconfBackend:
    """The real network side, kept apart so the self-test can swap it."""

    def __init__(self, ip):
        from zeroconf.asyncio import AsyncZeroconf
        self.zc = AsyncZeroconf(interfaces=[ip])

    async def holder(self, name, timeout=3.0):
        from zeroconf import AddressResolver
        r = AddressResolver(name)
        if await r.async_request(self.zc.zeroconf, timeout * 1000):
            return next(iter(r.parsed_addresses()), None)
        return None

    async def register(self, info, probe):
        from zeroconf import NonUniqueNameException
        try:
            await (await self.zc.async_register_service(info, cooperating_responders=not probe))
        except NonUniqueNameException:
            raise Conflict()

    async def unregister(self, info):
        await (await self.zc.async_unregister_service(info))

    async def close(self):
        await self.zc.async_close()


def service_info(name, ip, port):
    from zeroconf import ServiceInfo
    return ServiceInfo(SERVICE_TYPE, f"{INSTANCE}.{SERVICE_TYPE}", port=port, server=f"{name}.local.",
                       host_ttl=HOST_TTL, other_ttl=OTHER_TTL, parsed_addresses=[ip], properties={"path": "/"})


class Publisher:
    def __init__(self, name, port, log, address=lan.primary_address, backend=ZeroconfBackend, info=service_info,
                 clock=None):
        self.name, self.port, self.log = name, port, log
        self.address, self.backend, self.make_info = address, backend, info
        self.clock = clock or time.monotonic
        self.ip = None
        self.info = None
        self.zc = None
        self.state = "idle"
        self.waiting_since = None

    @property
    def fqdn(self):
        return f"{self.name}.local."

    async def run(self):
        try:
            while True:
                await self.step()
                await asyncio.sleep(RETRY)
        finally:
            await self.stop()

    async def step(self):
        ip = self.address()
        if self.state == "published" and ip == self.ip:
            return
        if self.ip is not None and ip != self.ip:
            await self.stop()
            if ip:
                self.log(f"LAN address changed to {ip}; announcing {self.name}.local again")
        if not ip:
            return
        try:
            if self.zc is None:
                self.zc = self.backend(ip)
                self.ip = ip
            holder = await self.zc.holder(self.fqdn)
            graced = self.waiting_since is not None and self.clock() - self.waiting_since >= GRACE
            if holder and holder != ip and not graced:
                self._wait(f"{self.name}.local is answered by {holder} (the Mac, while the hub was down)")
                return
            info = self.make_info(self.name, ip, self.port)
            await self.zc.register(info, probe=not graced)
            self.info = info
            self.state = "published"
            self.waiting_since = None
            self.log(f"published {self.name}.local -> {ip} (mDNS, TTL {HOST_TTL} s)")
        except Conflict:
            self._wait(f"{self.name}.local is still held by another device")
        except (OSError, RuntimeError) as e:
            if self.state != "failed":
                self.log(f"couldn't publish {self.name}.local: {type(e).__name__}: {e}")
            self.state = "failed"
            await self.stop(keep_state=True)

    def _wait(self, why):
        if self.waiting_since is None:
            self.waiting_since = self.clock()
            self.log(f"{why}; waiting up to {GRACE} s for it to let go")
        self.state = "waiting"

    async def stop(self, keep_state=False):
        zc, info = self.zc, self.info
        self.zc = self.info = None
        self.ip = None
        if not keep_state:
            self.state = "idle"
        if zc is None:
            return
        try:
            if info is not None:
                await zc.unregister(info)
        except Exception:
            pass
        try:
            await zc.close()
        except Exception:
            pass
