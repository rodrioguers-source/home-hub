"""Sends the home secrets from 1Password on this Mac to the hub laptop, over the home network.

    .venv/bin/python -m hub.send_secrets --to 192.168.0.15:8787          Mac -> hub (and SmartThings refresh)
    .venv/bin/python -m hub.send_secrets --to 192.168.0.15:8787 --back   SmartThings refresh back to the Mac

Run hub.receive_secrets on the laptop first: it shows the code and fingerprint asked for here. The Mac only
dials out; values are never printed or logged.
"""
import argparse
import getpass
import sys

from . import transfer, vault


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m hub.send_secrets")
    ap.add_argument("--to", required=True, help="the address hub.receive_secrets printed, e.g. 192.168.0.15:8787")
    ap.add_argument("--back", action="store_true", help="bring SmartThings refresh back from the hub to the Mac")
    ap.add_argument("--only", action="append", choices=transfer.ITEMS, help="send just this item (repeatable)")
    args = ap.parse_args(argv)
    code = "".join(c for c in getpass.getpass("Code shown on the laptop: ") if c.isdigit())
    fp = input("Fingerprint shown on the laptop: ")
    try:
        if args.back:
            transfer.back(args.to, fp, code)
            print("SmartThings is back on the Mac, and the hub no longer refreshes it. Turn off Use home hub if it's on.")
        else:
            saved = transfer.send(args.to, fp, code, items=args.only)
            print(f"Sent: {', '.join(saved)}.")
            if transfer.ST_ITEM in saved:
                print("The hub now refreshes SmartThings, and this Mac's 1Password copy of the token is out of date. "
                      "To move it back later, use --back.")
    except (transfer.TransferError, vault.secret_store.SecretError) as e:
        print(e)
        return 1
    except Exception as e:
        if type(e).__name__ != "SmartThingsError":
            raise
        print(e)
        return 1
    except OSError as e:
        print(f"Couldn't reach the laptop at {args.to} ({type(e).__name__}). Is receive_secrets running, and the firewall rule in place?")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
