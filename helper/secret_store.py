"""Where the home secrets live: 1Password through `op` (the Mac, and the default) or the OS keyring (the hub).

HOME_SECRETS=keyring switches to the keyring: service "home-hub" (HOME_KEYRING_SERVICE overrides it), one
logical entry per item holding a JSON object of its fields. Windows Credential Manager caps an entry at 2560
bytes and keyring stores UTF-16, so each item is split into parts of CHUNK characters under a fresh
generation id, and a small index entry naming that generation is written last. A reader therefore sees either
the old item or the new one, never a mix.
"""
import hashlib
import json
import os
import secrets as _random
import threading

import op_cli

CHUNK = 900
_lock = threading.Lock()


class SecretError(Exception):
    def __init__(self, message, code=None, detail=""):
        super().__init__(message)
        self.code = code
        self.detail = detail


def backend(using=None):
    return (using or os.environ.get("HOME_SECRETS") or "op").strip().lower()


def service():
    return os.environ.get("HOME_KEYRING_SERVICE") or "home-hub"


def _op_detail(stderr):
    lines = (stderr or "").strip().splitlines()
    return lines[-1][:200] if lines else ""


def _op_field(title, field):
    try:
        r = op_cli.run(["item", "get", title, "--fields", field, "--reveal", "--format", "json"], title=title)
    except Exception as e:
        raise SecretError("1Password CLI (op) isn't available.", "op_unavailable", type(e).__name__)
    if r.returncode != 0:
        if op_cli.not_found(r.stderr):
            return None
        raise SecretError(f"Couldn't read '{title}' from 1Password.", "op_failed", _op_detail(r.stderr))
    try:
        return json.loads(r.stdout).get("value") or None
    except ValueError:
        raise SecretError(f"'{title}' in 1Password isn't in the expected shape.", "op_failed")


def _op_fields(title):
    try:
        r = op_cli.run(["item", "get", title, "--format", "json", "--reveal"], title=title)
    except Exception as e:
        raise SecretError("1Password CLI (op) isn't available.", "op_unavailable", type(e).__name__)
    if r.returncode != 0:
        if op_cli.not_found(r.stderr):
            return None
        raise SecretError(f"Couldn't read '{title}' from 1Password.", "op_failed", _op_detail(r.stderr))
    item = json.loads(r.stdout)
    return {f.get("label"): f.get("value", "") for f in item.get("fields", []) if f.get("label")}


def _keyring():
    try:
        import keyring
    except ImportError:
        raise SecretError("The keyring package isn't installed (pip install -r hub/requirements.txt).", "keyring_missing")
    return keyring


def _get(kr, name):
    try:
        return kr.get_password(service(), name)
    except Exception as e:
        raise SecretError("Couldn't read the credential store.", "keyring_failed", type(e).__name__)


def _set(kr, name, value):
    try:
        kr.set_password(service(), name, value)
    except Exception as e:
        raise SecretError("Couldn't write to the credential store.", "keyring_write_failed", type(e).__name__)


def _delete(kr, name):
    try:
        kr.delete_password(service(), name)
    except Exception:
        pass


def _index_name(title):
    return f"item:{title}"


def _kr_fields(title):
    kr = _keyring()
    raw = _get(kr, _index_name(title))
    if not raw:
        return None
    try:
        index = json.loads(raw)
        parts = [_get(kr, f"item:{title}:{index['gen']}:{i}") for i in range(int(index["parts"]))]
        if any(p is None for p in parts):
            raise ValueError("missing part")
        blob = "".join(parts)
        if hashlib.sha256(blob.encode()).hexdigest() != index["sha"]:
            raise ValueError("checksum")
        fields = json.loads(blob)
    except (ValueError, KeyError, TypeError):
        raise SecretError(f"'{title}' in the credential store is damaged. Send the secrets again.", "keyring_damaged")
    return {str(k): str(v) for k, v in fields.items()}


def _kr_write(title, fields):
    kr = _keyring()
    old = _get(kr, _index_name(title))
    blob = json.dumps(fields, separators=(",", ":"), sort_keys=True)
    gen = _random.token_hex(4)
    parts = [blob[i:i + CHUNK] for i in range(0, len(blob), CHUNK)] or [""]
    try:
        for i, p in enumerate(parts):
            _set(kr, f"item:{title}:{gen}:{i}", p)
        _set(kr, _index_name(title), json.dumps({"v": 1, "gen": gen, "parts": len(parts),
                                                "sha": hashlib.sha256(blob.encode()).hexdigest()}))
    except SecretError:
        for i in range(len(parts)):
            _delete(kr, f"item:{title}:{gen}:{i}")
        raise
    if old:
        try:
            o = json.loads(old)
            for i in range(int(o["parts"])):
                _delete(kr, f"item:{title}:{o['gen']}:{i}")
        except (ValueError, KeyError, TypeError):
            pass
    _remember(kr, title)


def _remember(kr, title):
    try:
        known = set(json.loads(_get(kr, "titles") or "[]"))
    except ValueError:
        known = set()
    if title not in known:
        known.add(title)
        _set(kr, "titles", json.dumps(sorted(known)))


def get_fields(title, using=None):
    """All fields as label -> value, or None when the item doesn't exist. `using` overrides HOME_SECRETS."""
    if backend(using) == "keyring":
        return _kr_fields(title)
    return _op_fields(title)


def get_field(title, field="credential", using=None):
    """One field, or None when the item or field doesn't exist."""
    if backend(using) == "keyring":
        value = (_kr_fields(title) or {}).get(field)
        return value or None
    return _op_field(title, field)


def save_fields(title, values, using=None):
    """Merges `values` into the item (creating it). Keyring only: the Mac writes 1Password through its own code."""
    if backend(using) != "keyring":
        raise SecretError("save_fields is only for the keyring backend.", "wrong_backend")
    with _lock:
        fields = _kr_fields(title) or {}
        fields.update({str(k): str(v) for k, v in values.items()})
        _kr_write(title, fields)


def replace_item(title, fields, using=None):
    if backend(using) != "keyring":
        raise SecretError("replace_item is only for the keyring backend.", "wrong_backend")
    with _lock:
        _kr_write(title, {str(k): str(v) for k, v in fields.items()})


def delete_item(title):
    kr = _keyring()
    with _lock:
        old = _get(kr, _index_name(title))
        _delete(kr, _index_name(title))
        if old:
            try:
                o = json.loads(old)
                for i in range(int(o["parts"])):
                    _delete(kr, f"item:{title}:{o['gen']}:{i}")
            except (ValueError, KeyError, TypeError):
                pass
        try:
            known = set(json.loads(_get(kr, "titles") or "[]")) - {title}
            _set(kr, "titles", json.dumps(sorted(known)))
        except ValueError:
            pass


def titles():
    """Item titles stored in the keyring (it has no listing call, so they are tracked in a "titles" entry)."""
    try:
        return json.loads(_get(_keyring(), "titles") or "[]")
    except ValueError:
        return []
