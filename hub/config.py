"""Hub settings: hub-config.json in the data folder, every key optional. Nothing secret lives here."""
import json
import os
import sys

DEFAULTS = {
    "port": 8787,
    # "auto" binds the laptop's LAN IPv4 address (plus 127.0.0.1); a list of addresses overrides it.
    "bind": "auto",
    # The phone's one address, http://homehub.local:8787; the Mac answers for it while the hub is down.
    # "" turns the announcement off (e.g. when the laptop itself is renamed homehub instead).
    "mdns_name": "homehub",
    "room": "Living Room",
    "tv_host": "192.168.0.97",
    "tv_mac": "28:07:08:A8:9D:06",
    "tv_remote_name": "Home Hub",
    "ps5_host": "192.168.0.45",
    "ps5_name": "PS5-011",
    "latitude": 51.5362,
    "longitude": -0.1033,
    "place": "Islington",
    "items": {
        "tv": "Samsung TV Hub",
        "lights": "Tuya Lamps",
        "smartthings": "SmartThings OAuth",
        "ps5": "PS5 Remote Play",
        "psn": "PSN NPSSO",
    },
    "keyring_service": "home-hub",
    "notifications": True,
    "theme": "dark",
}


def data_dir():
    if os.environ.get("HOME_HUB_DATA"):
        return os.environ["HOME_HUB_DATA"]
    if os.name == "nt":
        return os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "HomeHub")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/HomeHub")
    return os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "HomeHub")


class Config(dict):
    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name)

    def item(self, key):
        return self["items"][key]


def load(path=None, overrides=None):
    folder = data_dir()
    path = path or os.path.join(folder, "hub-config.json")
    cfg = Config(json.loads(json.dumps(DEFAULTS)))
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
        for k, v in raw.items():
            if k == "items" and isinstance(v, dict):
                cfg["items"].update(v)
            else:
                cfg[k] = v
    cfg.update(overrides or {})
    cfg["data_dir"] = cfg.get("data_dir") or folder
    cfg["config_path"] = path
    return cfg
