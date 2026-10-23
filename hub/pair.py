"""Shows a 6-digit code for pairing a phone (or the Mac) with the running hub: python -m hub.pair"""
import argparse
import json
import sys
import urllib.request

from . import config as config_mod


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m hub.pair")
    ap.add_argument("--config")
    args = ap.parse_args(argv)
    cfg = config_mod.load(args.config)
    url = f"http://127.0.0.1:{cfg['port']}/api/pairing/local-start"
    req = urllib.request.Request(url, data=b"{}", method="POST", headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            code = json.loads(r.read())["code"]
    except Exception:
        print("Couldn't reach the hub on this laptop. Is it running? (Task Scheduler › Home Hub)")
        return 1
    print(f"Pairing code: {code[:3]} {code[3:]}")
    print("Enter it on the phone (or in the Mac app's Use home hub dialogue) within 5 minutes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
