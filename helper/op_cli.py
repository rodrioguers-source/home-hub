"""Runs the 1Password CLI (`op`) for the helper modules and the home hub.

Vaults are optional. HOME_OP_VAULT names one vault for every item, and HOME_OP_VAULTS (JSON object,
item title -> vault) overrides it per item. With neither set, the commands are exactly the ones the
Mac app has always run, so `op` searches every vault the signed-in account can see.

HOME_OP_PATH points at a specific `op` binary. The home hub sets `extra_env` so its service-account
token reaches `op` through that child's environment only.
"""
import json
import os
import shutil
import subprocess

OP_CANDIDATES = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"]

extra_env = None


def op_path():
    explicit = os.environ.get("HOME_OP_PATH")
    if explicit:
        return explicit
    found = next((p for p in OP_CANDIDATES if os.access(p, os.X_OK)), None)
    return found or shutil.which("op") or "op"


def vault_for(title):
    try:
        per_item = json.loads(os.environ.get("HOME_OP_VAULTS") or "{}")
    except ValueError:
        per_item = {}
    if not isinstance(per_item, dict):
        per_item = {}
    return per_item.get(title) or os.environ.get("HOME_OP_VAULT") or None


def command(args, title=None):
    cmd = [op_path()] + list(args)
    vault = vault_for(title) if title else None
    if vault:
        cmd += ["--vault", vault]
    return cmd


def run(args, title=None, input=None, timeout=120):
    """`title` is the item the command touches, so its vault can be added. Secrets only ever travel on stdin."""
    env = None
    if extra_env is not None:
        env = dict(os.environ)
        env.update(extra_env())
    kwargs = {"input": input} if input is not None else {"stdin": subprocess.DEVNULL}
    return subprocess.run(command(args, title), capture_output=True, text=True, timeout=timeout, env=env, **kwargs)


def not_found(stderr):
    err = (stderr or "").lower()
    return "isn't an item" in err or "not found" in err or "no item" in err or "isn't a field" in err
