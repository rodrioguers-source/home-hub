"""One-off secret transfer between the Mac and the hub over the home network.

The laptop listens (hub.receive_secrets) with a self-signed certificate made for this run; the Mac always
dials out (hub.send_secrets), pins the certificate's fingerprint and proves itself with a 6-digit code.

SmartThings refresh tokens are single-use, so the item moves with a two-step ownership change that can
leave nobody refreshing (safe, fixed by running the transfer again) but never both machines:
- to the hub: the Mac marks its 1Password copy "hub" first; the hub stores its copy marked "mac" and only
  switches it to "hub" once the Mac confirms.
- back: the hub marks its copy "mac" first and keeps it so once the Mac confirms it has saved the token;
  the Mac then marks its 1Password copy "mac".
"""
import contextlib
import datetime
import hashlib
import hmac
import json
import os
import secrets as _random
import shutil
import socket
import ssl
import struct
import tempfile
import time

from . import lan, vault

secret_store = vault.secret_store

ST_ITEM = "SmartThings OAuth"
ITEMS = ["SmartThings OAuth", "Tuya Lamps", "PS5 Remote Play", "PSN NPSSO"]
OWNER = "refresh_owner"
PORTS = [8787, 8788]
FINGERPRINT_CHARS = 24
MAX_MESSAGE = 256 * 1024


class TransferError(Exception):
    pass


def send_msg(sock, obj):
    data = json.dumps(obj).encode()
    sock.sendall(struct.pack("!I", len(data)) + data)


def recv_msg(sock):
    head = _exact(sock, 4)
    n = struct.unpack("!I", head)[0]
    if n > MAX_MESSAGE:
        raise TransferError("Message too large.")
    try:
        return json.loads(_exact(sock, n))
    except ValueError:
        raise TransferError("Unreadable message.")


def _exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise TransferError("The other side hung up.")
        buf += chunk
    return buf


def fingerprint(der):
    return hashlib.sha256(der).hexdigest()


def spaced(fp):
    short = fp[:FINGERPRINT_CHARS]
    return " ".join(short[i:i + 4] for i in range(0, len(short), 4))


def normalise_fingerprint(text):
    return "".join(c for c in (text or "").lower() if c in "0123456789abcdef")


def make_certificate():
    """An EC certificate for this run only. Returns (cert_pem, key_pem, fingerprint of the DER)."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "home-hub-transfer")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(minutes=5))
            .not_valid_after(now + datetime.timedelta(hours=2)).sign(key, hashes.SHA256()))
    key_pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return (cert.public_bytes(serialization.Encoding.PEM), key_pem,
            fingerprint(cert.public_bytes(serialization.Encoding.DER)))


def server_context(cert_pem, key_pem):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    # ssl only loads certificates from files: a private temp folder holds them for the one call.
    folder = tempfile.mkdtemp(prefix="hub-tls-")
    try:
        cert_path, key_path = os.path.join(folder, "c.pem"), os.path.join(folder, "k.pem")
        for path, data in ((cert_path, cert_pem), (key_path, key_pem)):
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(data)
        ctx.load_cert_chain(cert_path, key_path)
    finally:
        shutil.rmtree(folder, ignore_errors=True)
    return ctx


def _clean(items):
    if not isinstance(items, dict) or not items:
        raise TransferError("No items in the transfer.")
    out = {}
    for title, fields in items.items():
        if not isinstance(title, str) or not isinstance(fields, dict) or not 0 < len(title) <= 100:
            raise TransferError("Malformed item.")
        out[title] = {str(k): str(v) for k, v in fields.items() if v not in (None, "")}
    return out


def st_owner(using="keyring"):
    fields = secret_store.get_fields(ST_ITEM, using=using)
    if fields is None:
        return None
    return (fields.get(OWNER) or "mac").strip().lower()


class Receiver:
    """The laptop side: accepts one transfer (either direction), then stops."""

    def __init__(self, bind, ports=None, code=None, lock=None, log=print, timeout=600, max_wrong=5):
        self.code = code or f"{_random.randbelow(1_000_000):06d}"
        self.cert_pem, key_pem, self.fingerprint = make_certificate()
        self.ctx = server_context(self.cert_pem, key_pem)
        self.lock = lock or _st_lock
        self.log = log
        self.deadline = time.time() + timeout
        self.wrong = 0
        self.max_wrong = max_wrong
        self.sock = None
        for port in ports or PORTS:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            try:
                s.bind((bind, port))
            except OSError:
                s.close()
                continue
            s.listen(2)
            self.sock = s
            break
        if self.sock is None:
            raise TransferError(f"Couldn't listen on {bind} ports {', '.join(map(str, ports or PORTS))}.")
        self.address = self.sock.getsockname()

    def serve(self):
        """Returns "sent" or "back" after one completed transfer, or raises TransferError."""
        try:
            while True:
                left = self.deadline - time.time()
                if left <= 0:
                    raise TransferError("Timed out: nothing arrived within 10 minutes.")
                if self.wrong >= self.max_wrong:
                    raise TransferError("Too many wrong codes. Start again for a new code.")
                self.sock.settimeout(left)
                try:
                    raw, peer = self.sock.accept()
                except socket.timeout:
                    continue
                if not lan.is_local(peer[0]):
                    raw.close()
                    continue
                try:
                    raw.settimeout(120)
                    conn = self.ctx.wrap_socket(raw, server_side=True)
                except (ssl.SSLError, OSError):
                    raw.close()
                    continue
                try:
                    result = self._handle(conn, peer[0])
                except (TransferError, secret_store.SecretError, OSError, ssl.SSLError) as e:
                    self.log(f"Transfer from {peer[0]} failed: {e}")
                    result = None
                finally:
                    with contextlib.suppress(OSError):
                        conn.close()
                if result:
                    return result
        finally:
            self.sock.close()

    def _handle(self, conn, peer):
        hello = recv_msg(conn)
        if not hmac.compare_digest(str(hello.get("code", "")), self.code):
            self.wrong += 1
            send_msg(conn, {"ok": False, "error": "Wrong code."})
            return None
        send_msg(conn, {"ok": True, "st_owner": st_owner(), "titles": secret_store.titles()})
        req = recv_msg(conn)
        if req.get("op") == "send":
            return self._receive(conn, _clean(req.get("items")))
        if req.get("op") == "back":
            return self._give_back(conn)
        raise TransferError("Unknown request.")

    def _receive(self, conn, items):
        with self.lock():
            if ST_ITEM in items and st_owner() == "hub":
                raise TransferError("The hub already refreshes SmartThings; refusing an older copy.")
            for title, fields in items.items():
                if title == ST_ITEM:
                    fields = dict(fields, **{OWNER: "mac"})
                secret_store.replace_item(title, fields, using="keyring")
                if secret_store.get_fields(title, using="keyring") != fields:
                    raise TransferError(f"'{title}' didn't read back the same.")
            send_msg(conn, {"ok": True, "saved": sorted(items)})
            confirm = recv_msg(conn)
            if not confirm.get("commit"):
                raise TransferError("The Mac didn't confirm.")
            if ST_ITEM in items:
                secret_store.save_fields(ST_ITEM, {OWNER: "hub"}, using="keyring")
            send_msg(conn, {"ok": True, "committed": True})
        self.log(f"Saved {', '.join(sorted(items))}" + (" and took over SmartThings." if ST_ITEM in items else "."))
        return "sent"

    def _give_back(self, conn):
        with self.lock():
            fields = secret_store.get_fields(ST_ITEM, using="keyring")
            if not fields:
                raise TransferError("The hub has no SmartThings item to give back.")
            before = (fields.get(OWNER) or "mac").strip().lower()
            secret_store.save_fields(ST_ITEM, {OWNER: "mac"}, using="keyring")
            committed = False
            try:
                send_msg(conn, {"ok": True, "item": {k: v for k, v in fields.items() if k != OWNER}})
                if recv_msg(conn).get("saved"):
                    send_msg(conn, {"ok": True, "committed": True})
                    committed = True
            finally:
                if not committed:
                    secret_store.save_fields(ST_ITEM, {OWNER: before}, using="keyring")
        if not committed:
            raise TransferError("The Mac didn't confirm it saved SmartThings; the hub keeps it.")
        self.log("SmartThings handed back to the Mac. The hub no longer refreshes it.")
        return "back"


@contextlib.contextmanager
def _st_lock():
    import smartthings
    with smartthings._FileLock():
        yield


class MacOps:
    """The Mac's 1Password side, kept apart so the self-test can swap it. Always the shared item, never
    the Mac's own "SmartThings OAuth Mac" chain."""

    def owner(self):
        import smartthings
        fields = smartthings.item_fields(smartthings.op_get_item(ST_ITEM))
        return (fields.get(OWNER) or "mac").strip().lower() if fields else None

    def read(self, title):
        return secret_store.get_fields(title, using="op")

    def set_owner(self, owner):
        import smartthings
        smartthings.op_set_owner(owner, ST_ITEM)

    def save_tokens(self, fields):
        import smartthings
        smartthings.op_save_fields(fields, ST_ITEM)

    def lock(self):
        return _st_lock()


def connect(address, fp, timeout=20):
    host, _, port = address.rpartition(":")
    if not host or not port.isdigit():
        raise TransferError("Give the laptop's address as IP:port, e.g. 192.168.0.15:8787.")
    if not lan.is_local(host):
        raise TransferError("Only addresses on the home network are allowed.")
    want = normalise_fingerprint(fp)
    if len(want) < FINGERPRINT_CHARS:
        raise TransferError(f"The fingerprint needs all {FINGERPRINT_CHARS} characters the laptop shows.")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    raw = socket.create_connection((host, int(port)), timeout=timeout)
    conn = ctx.wrap_socket(raw)
    if not fingerprint(conn.getpeercert(binary_form=True)).startswith(want):
        conn.close()
        raise TransferError("The laptop's certificate doesn't match that fingerprint. Nothing was sent.")
    conn.settimeout(120)
    return conn


def _hello(conn, code):
    send_msg(conn, {"v": 1, "code": code})
    reply = recv_msg(conn)
    if not reply.get("ok"):
        raise TransferError(reply.get("error") or "The laptop refused.")
    return reply


def send(address, fp, code, mac=None, items=None, log=print):
    """Mac -> hub. Returns the titles the hub saved."""
    mac = mac or MacOps()
    conn = connect(address, fp)
    try:
        hub_owner = _hello(conn, code).get("st_owner")
        with mac.lock():
            mac_owner = mac.owner()
            include_st = mac_owner is not None and hub_owner != "hub"
            if mac_owner == "mac" and hub_owner == "hub":
                log("Both machines think they own SmartThings. Skipping it: run helper/smartthings_auth.py on the Mac, "
                    "then send again.")
            elif mac_owner is not None and hub_owner == "hub":
                log("SmartThings already lives on the hub, so it isn't sent again.")
            changed = False
            if include_st and mac_owner == "mac":
                mac.set_owner("hub")
                changed = True
            payload = {}
            saved = False
            try:
                for title in items or ITEMS:
                    if title == ST_ITEM and not include_st:
                        continue
                    fields = mac.read(title)
                    if fields is None:
                        log(f"'{title}' isn't in 1Password; skipped.")
                        continue
                    if title == ST_ITEM:
                        fields = {k: v for k, v in fields.items() if k != OWNER}
                    payload[title] = {k: v for k, v in fields.items() if v}
                if not payload:
                    raise TransferError("Nothing to send.")
                send_msg(conn, {"op": "send", "items": payload})
                reply = recv_msg(conn)
                if not reply.get("ok"):
                    raise TransferError(reply.get("error") or "The hub didn't save them.")
                saved = True
                send_msg(conn, {"commit": True})
                if not recv_msg(conn).get("committed"):
                    raise TransferError("The hub didn't confirm.")
            except Exception:
                if changed and not saved:
                    with contextlib.suppress(Exception):
                        mac.set_owner("mac")
                if saved and ST_ITEM in payload:
                    log("The hub saved SmartThings but the last step failed, so neither machine refreshes it now. "
                        "Run send_secrets again.")
                raise
        return sorted(payload)
    finally:
        with contextlib.suppress(OSError):
            conn.close()


def back(address, fp, code, mac=None, log=print):
    """Hub -> Mac for SmartThings, pulled by the Mac."""
    mac = mac or MacOps()
    conn = connect(address, fp)
    try:
        hub_owner = _hello(conn, code).get("st_owner")
        with mac.lock():
            if hub_owner is None:
                raise TransferError("The hub has no SmartThings item.")
            if mac.owner() == "mac" and hub_owner != "hub":
                raise TransferError("The Mac already refreshes SmartThings; nothing to bring back.")
            send_msg(conn, {"op": "back"})
            reply = recv_msg(conn)
            if not reply.get("ok") or not isinstance(reply.get("item"), dict):
                raise TransferError(reply.get("error") or "The hub didn't send SmartThings.")
            fields = {k: str(v) for k, v in reply["item"].items() if k != OWNER}
            mac.save_tokens(fields)
            send_msg(conn, {"saved": True})
            if not recv_msg(conn).get("committed"):
                raise TransferError("The hub didn't confirm, so it keeps SmartThings. Run --back again.")
            mac.set_owner("mac")
        return True
    finally:
        with contextlib.suppress(OSError):
            conn.close()
