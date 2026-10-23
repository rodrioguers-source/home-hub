"""A minimal asyncio WebSocket client (RFC 6455): text frames, ping/pong, close. Enough for the TV's remote channel."""
import asyncio
import base64
import hashlib
import os
import ssl
import struct
import urllib.parse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC525B1"


class WSError(Exception):
    pass


class WebSocket:
    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer
        self.closed = False
        self._send_lock = asyncio.Lock()

    async def _frame(self, opcode, payload):
        head = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = os.urandom(4)
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        async with self._send_lock:
            if self.closed:
                raise WSError("closed")
            self.writer.write(head + mask + body)
            await self.writer.drain()

    async def send(self, text):
        await self._frame(0x1, text.encode("utf-8"))

    async def ping(self):
        await self._frame(0x9, b"")

    async def recv(self):
        """The next text message; raises WSError when the connection ends."""
        parts = b""
        while True:
            try:
                b1, b2 = await self.reader.readexactly(2)
                n = b2 & 0x7F
                if n == 126:
                    n = struct.unpack("!H", await self.reader.readexactly(2))[0]
                elif n == 127:
                    n = struct.unpack("!Q", await self.reader.readexactly(8))[0]
                if n > 4 * 1024 * 1024:
                    raise WSError("frame too large")
                mask = await self.reader.readexactly(4) if b2 & 0x80 else None
                data = await self.reader.readexactly(n)
            except (asyncio.IncompleteReadError, ConnectionError, OSError) as e:
                self.closed = True
                raise WSError(type(e).__name__)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            opcode = b1 & 0x0F
            if opcode == 0x8:
                await self.close()
                raise WSError("closed by peer")
            if opcode == 0x9:
                await self._frame(0xA, data)
                continue
            if opcode == 0xA:
                continue
            parts += data
            if b1 & 0x80:
                return parts.decode("utf-8", "replace")

    async def close(self):
        if self.closed:
            return
        try:
            await self._frame(0x8, b"")
        except Exception:
            pass
        self.closed = True
        try:
            self.writer.close()
        except Exception:
            pass


async def connect(url, timeout=8, insecure_host=None):
    """`insecure_host` accepts that host's self-signed certificate (the TV's) and nothing else."""
    u = urllib.parse.urlsplit(url)
    secure = u.scheme == "wss"
    port = u.port or (443 if secure else 80)
    ctx = None
    if secure:
        ctx = ssl.create_default_context()
        if insecure_host and u.hostname == insecure_host:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
    reader, writer = await asyncio.wait_for(asyncio.open_connection(u.hostname, port, ssl=ctx), timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    path = (u.path or "/") + (f"?{u.query}" if u.query else "")
    req = (f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    writer.write(req.encode())
    await writer.drain()
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout)
    except Exception as e:
        writer.close()
        raise WSError(f"handshake failed ({type(e).__name__})")
    lines = head.decode("latin-1").split("\r\n")
    if " 101 " not in lines[0] + " ":
        writer.close()
        raise WSError(lines[0][:80])
    headers = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
    expect = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
    # Some Samsung TVs answer the upgrade with a wrong Sec-WebSocket-Accept; their cert is already unchecked anyway.
    if headers.get("sec-websocket-accept") != expect and not insecure_host:
        writer.close()
        raise WSError("bad handshake")
    return WebSocket(reader, writer)
