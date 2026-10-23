"""PS5 wake / rest mode over Remote Play (pyremoteplay), pairing done by ps5_pair.py.

The registration lives only in the 1Password item "PS5 Remote Play" (field "credential",
a JSON blob). It is read once per process, kept in memory and scrubbed from errors.

    python ps5_control.py status | wake [--no-wait] | standby [--creds-stdin]

With --creds-stdin the credential JSON is read from the first stdin line instead of 1Password.
"""
import asyncio
import json
import logging
import os
import sys
import threading
import time
import warnings

warnings.filterwarnings("ignore")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import op_cli  # noqa: E402

PS5_HOST = os.environ.get("PS5_HOST", "192.168.0.45")
OP_ITEM = "PS5 Remote Play"
OP_FIELD = "credential"
STATUS_ON = 200
STATUS_STANDBY = 620
WAKE_TIMEOUT = 40
STANDBY_TIMEOUT = 25


class PS5Error(Exception):
    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


_secrets = set()
_lock = threading.Lock()
_creds = None


class _Capture(logging.Handler):
    """Keeps pyremoteplay's messages off stderr; the last few explain failures."""

    def __init__(self):
        super().__init__(logging.INFO)
        self.lines = []

    def emit(self, record):
        try:
            self.lines = (self.lines + [scrub(record.getMessage())])[-10:]
        except Exception:
            pass


_log = _Capture()
_rp_logger = logging.getLogger("pyremoteplay")
_rp_logger.addHandler(_log)
_rp_logger.setLevel(logging.INFO)
_rp_logger.propagate = False


def scrub(text):
    text = str(text)
    for s in _secrets:
        if s and len(s) > 4:
            text = text.replace(s, "***")
    return text[:240]


def _op_path():
    return op_cli.op_path()


def _remember(creds):
    for k in ("RegistKey", "RP-Key", "wake_credential"):
        if creds.get(k):
            _secrets.add(str(creds[k]))


def wake_credential(regist_key):
    from pyremoteplay.util import format_regist_key
    return format_regist_key(regist_key)


def load_creds():
    global _creds
    with _lock:
        if _creds is not None:
            return _creds
        try:
            r = op_cli.run(["item", "get", OP_ITEM, "--fields", OP_FIELD, "--reveal", "--format", "json"], title=OP_ITEM)
        except Exception:
            raise PS5Error("1Password CLI (op) isn't available.", "op_unavailable")
        if r.returncode != 0:
            err = r.stderr.lower()
            if "isn't an item" in err or "not found" in err or "no item" in err or "isn't a field" in err:
                raise PS5Error("PS5 isn't paired yet. Run helper/ps5_pair.py.", "not_paired")
            raise PS5Error(f"Couldn't read '{OP_ITEM}' from 1Password.", "op_failed")
        try:
            creds = parse_creds(json.loads(r.stdout)["value"])
        except Exception:
            raise PS5Error(f"'{OP_ITEM}' in 1Password is malformed. Pair again with ps5_pair.py.", "bad_creds")
        _remember(creds)
        _creds = creds
        return creds


def parse_creds(raw):
    creds = json.loads(raw)
    creds["wake_credential"] = wake_credential(creds["RegistKey"])
    bytes.fromhex(creds["RP-Key"])
    creds["host_id"]
    return creds


def use_creds(raw):
    """For a caller that already holds the item (the home hub), so this process never runs op."""
    global _creds
    try:
        creds = parse_creds(raw)
    except Exception:
        raise PS5Error(f"'{OP_ITEM}' in 1Password is malformed. Pair again with ps5_pair.py.", "bad_creds")
    _remember(creds)
    with _lock:
        _creds = creds


def reset():
    global _creds
    with _lock:
        _creds = None


def _host(creds=None):
    host = (creds or {}).get("host") or PS5_HOST
    if _raw_status(host):
        return host
    # The router can hand the PS5 a new address; find it by broadcast, preferring the paired console's id.
    from pyremoteplay import ddp
    try:
        found = [d for d in ddp.search(host_type="PS5") if d.get("host-ip")]
    except OSError:
        return host
    want = (creds or {}).get("host_id")
    match = next((d for d in found if want and d.get("host-id") == want), found[0] if found else None)
    return match["host-ip"] if match else host


def _raw_status(host):
    from pyremoteplay import ddp
    try:
        return ddp.get_status(host) or {}
    except OSError as e:
        raise PS5Error(f"Network error talking to the PS5: {type(e).__name__}", "network")


def status(host=None):
    """Read-only DDP probe; never needs credentials."""
    s = _raw_status(host or _host())
    code = s.get("status-code")
    state = {STATUS_ON: "on", STATUS_STANDBY: "standby"}.get(code, "unreachable" if not s else "unknown")
    return {
        "state": state,
        "status_code": code,
        "host_name": s.get("host-name"),
        "host_type": s.get("host-type"),
        "system_version": s.get("system-version"),
        "running_app": s.get("running-app-name"),
        "running_app_id": s.get("running-app-titleid"),
    }


def _wait_for(host, want, timeout):
    start = time.time()
    while time.time() - start < timeout:
        if _raw_status(host).get("status-code") == want:
            return True
        time.sleep(1)
    return False


def wake(wait=True, timeout=WAKE_TIMEOUT):
    creds = load_creds()
    host = _host(creds)
    s = _raw_status(host)
    if not s:
        raise PS5Error("PS5 didn't answer on the network (fully off, or another IP?).", "unreachable")
    if s.get("status-code") == STATUS_ON:
        return {"sent": False, "state": "on", "already": True}
    from pyremoteplay import ddp
    ddp.wakeup(host, creds["wake_credential"], host_type=creds.get("host_type", "PS5"))
    if not wait:
        return {"sent": True, "state": "waking"}
    if _wait_for(host, STATUS_ON, timeout):
        return {"sent": True, "state": "on"}
    raise PS5Error("Wake sent but the PS5 is still in rest mode. Re-pair if this keeps happening.", "wake_timeout")


async def _standby_async(host, creds, timeout):
    from pyremoteplay.session import Session
    profile = {"hosts": {creds["host_id"]: {
        "type": creds.get("host_type", "PS5"),
        "data": {"RegistKey": creds["RegistKey"], "RP-Key": creds["RP-Key"]},
    }}}
    session = Session(host, profile)
    try:
        if not await asyncio.wait_for(session.start(wakeup=False), timeout):
            raise PS5Error(f"Remote Play session failed: {scrub(session.error) or 'no reason given'}", "session_failed")
        if not await session.async_wait(timeout):
            raise PS5Error("Remote Play session never became ready.", "session_timeout")
        await session.async_standby()
        # async_standby returns immediately in 0.7.6; give the loop time to flush the packet.
        await asyncio.sleep(1.5)
    except asyncio.TimeoutError:
        raise PS5Error("Remote Play session timed out.", "session_timeout")
    finally:
        session.stop()


def standby(timeout=STANDBY_TIMEOUT):
    creds = load_creds()
    host = _host(creds)
    s = _raw_status(host)
    if not s:
        raise PS5Error("PS5 didn't answer on the network.", "unreachable")
    if s.get("status-code") == STATUS_STANDBY:
        return {"sent": False, "state": "standby", "already": True}
    loop = asyncio.new_event_loop()
    try:
        loop.run_until_complete(_standby_async(host, creds, timeout))
    except PS5Error:
        raise
    except Exception as e:
        hint = "; ".join(_log.lines[-2:])
        raise PS5Error(scrub(f"Standby failed ({type(e).__name__}). {hint}".strip()), "standby_failed")
    finally:
        loop.close()
    if _wait_for(host, STATUS_STANDBY, timeout):
        return {"sent": True, "state": "standby"}
    raise PS5Error("Standby sent but the PS5 still reports on. A game may be blocking rest mode.", "standby_timeout")


def main(argv):
    if not argv or argv[0] not in ("status", "wake", "standby"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        if "--creds-stdin" in argv:
            use_creds(sys.stdin.readline().strip())
        if argv[0] == "status":
            out = status()
        elif argv[0] == "wake":
            out = wake(wait="--no-wait" not in argv)
        else:
            out = standby()
    except PS5Error as e:
        print(json.dumps({"ok": False, "error": scrub(e), "code": e.code}))
        return 1
    print(json.dumps({"ok": True, "result": out}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
