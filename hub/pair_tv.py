"""Pairs the hub with the TV's remote channel and saves the token: python -m hub.pair_tv

Run it with the TV on and someone at the TV: it shows an "Allow" prompt for the hub's remote name.
The token goes to the credential store under the item named by "items.tv" in hub-config.json.
"""
import argparse
import asyncio
import base64
import json
import sys
import urllib.parse

from . import config as config_mod
from . import vault, wsclient
from .store import settings as settings_for


async def fetch_token(host, name, timeout=40, attempts=3):
    # Some Samsung TVs drop the socket right after "Allow" and only hand out the token on the next connect.
    for attempt in range(attempts):
        try:
            return await _fetch_once(host, name, timeout)
        except wsclient.WSError:
            if attempt == attempts - 1:
                raise
            await asyncio.sleep(2)


async def _fetch_once(host, name, timeout):
    q = urllib.parse.urlencode({"name": base64.b64encode(name.encode()).decode()})
    ws = await wsclient.connect(f"wss://{host}:8002/api/v2/channels/samsung.remote.control?{q}", insecure_host=host)
    try:
        async def wait():
            while True:
                msg = json.loads(await ws.recv())
                if msg.get("event") == "ms.channel.connect":
                    return (msg.get("data") or {}).get("token")
                if msg.get("event") == "ms.channel.unauthorized":
                    return None
        return await asyncio.wait_for(wait(), timeout)
    finally:
        await ws.close()


def save(title, token):
    try:
        vault.secret_store.save_fields(title, {"credential": token})
        return True
    except vault.secret_store.SecretError:
        return False


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m hub.pair_tv")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    cfg = config_mod.load(args.config)
    vault.configure(cfg)
    host = settings_for(cfg).get("tv_host") or cfg["tv_host"]
    print(f"Connecting to the TV at {host} as '{cfg['tv_remote_name']}'. Accept the prompt on the TV…")
    try:
        tv_token = asyncio.run(fetch_token(host, cfg["tv_remote_name"]))
    except Exception as e:
        print(f"Couldn't reach the TV's remote channel ({e!r}). Is it on?")
        return 1
    if not tv_token:
        print("The TV didn't hand out a token (prompt declined or timed out).")
        return 1
    if not save(cfg.item("tv"), tv_token):
        print(f"Got a token but couldn't save it to '{cfg.item('tv')}' in the credential store.")
        return 1
    print(f"Saved to '{cfg.item('tv')}' in the credential store. Restart the hub to use it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
