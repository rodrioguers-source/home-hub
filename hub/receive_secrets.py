"""Receives the home secrets from the Mac, once, and stores them in Windows Credential Manager.

    python -m hub.receive_secrets            wait up to 10 minutes for one transfer (either direction)
    python -m hub.receive_secrets --status   list the stored items and their field names (never values)

It prints a 6-digit code and a certificate fingerprint to type on the Mac, accepts one transfer, then exits.
The same run also serves `send_secrets --back`, which returns SmartThings to the Mac.
"""
import argparse
import sys

from . import config as config_mod
from . import lan, vault


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m hub.receive_secrets")
    ap.add_argument("--config")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--bind", help="address to listen on (default: this laptop's LAN address)")
    args = ap.parse_args(argv)
    cfg = config_mod.load(args.config)
    vault.configure(cfg)
    from . import transfer
    store = vault.secret_store
    if args.status:
        try:
            titles = store.titles()
            for title in titles:
                fields = store.get_fields(title) or {}
                extra = f", refresh_owner={fields.get('refresh_owner') or 'mac'}" if title == transfer.ST_ITEM else ""
                print(f"{title}: {', '.join(sorted(fields))}{extra}")
        except store.SecretError as e:
            print(e)
            return 2
        if not titles:
            print("Nothing stored yet.")
        return 0
    bind = args.bind or lan.primary_address()
    if not bind:
        print("No network address found. Is the laptop on the home Wi-Fi?")
        return 1
    try:
        receiver = transfer.Receiver(bind)
    except ImportError:
        print("The cryptography package is missing. Run: .venv\\Scripts\\python -m pip install -r hub\\requirements.txt")
        return 2
    except transfer.TransferError as e:
        print(e)
        return 1
    host, port = receiver.address[:2]
    print(f"Waiting for the Mac on {host}:{port} (10 minutes).")
    print("On the Mac, run:")
    print(f"    .venv/bin/python -m hub.send_secrets --to {host}:{port}")
    print(f"Code:         {receiver.code[:3]} {receiver.code[3:]}")
    print(f"Fingerprint:  {transfer.spaced(receiver.fingerprint)}")
    try:
        result = receiver.serve()
    except transfer.TransferError as e:
        print(e)
        return 1
    except KeyboardInterrupt:
        return 130
    if result == "sent":
        print("Done. Restart the hub (Task Scheduler › Home Hub) so it picks them up.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
