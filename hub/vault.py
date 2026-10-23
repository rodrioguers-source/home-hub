"""Points the helper modules at the hub's secret store: Windows Credential Manager through `keyring`.

Nothing on the hub runs `op`. The secrets arrive once from the Mac (hub.receive_secrets) and the hub keeps
them, rotating the SmartThings refresh token in place.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "..", "helper")
LUZES = os.path.join(HERE, "..", "luzes")
for p in (HELPER, LUZES):
    if p not in sys.path:
        sys.path.insert(0, p)

import secret_store  # noqa: E402


class SecretsError(Exception):
    pass


def configure(cfg, backend="keyring"):
    """`backend="op"` keeps 1Password, for trying the hub on the Mac with your own sign-in."""
    os.environ["HOME_ST_HOST"] = "hub"
    os.environ["HOME_SECRETS"] = backend
    os.environ["HOME_KEYRING_SERVICE"] = cfg.get("keyring_service") or "home-hub"


def field(title, name="credential"):
    """One field, or None when the item or field doesn't exist."""
    try:
        return (secret_store.get_field(title, name) or "").strip() or None
    except secret_store.SecretError as e:
        raise SecretsError(str(e))
