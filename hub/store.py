"""Small JSON files in the data folder: settings the Mac keeps in UserDefaults, the paired phones, presets."""
import json
import os
import tempfile
import threading


class JSONFile:
    def __init__(self, path, default=None):
        self.path = path
        self.lock = threading.Lock()
        self.data = default if default is not None else {}
        if path and os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as f:
                    self.data = json.load(f)
            except (OSError, ValueError):
                pass

    def save(self):
        if not self.path:
            return
        with self.lock:
            folder = os.path.dirname(self.path)
            os.makedirs(folder, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=folder, prefix=".tmp-", suffix=".json")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(self.data, f, indent=2, sort_keys=True)
                if os.name != "nt":
                    os.chmod(tmp, 0o600)
                os.replace(tmp, self.path)
            except OSError:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass


class Settings(JSONFile):
    """The hub's UserDefaults: flat keys, saved on every write."""

    def get(self, key, default=None):
        return self.data.get(key, default)

    def set(self, key, value):
        if value is None:
            self.data.pop(key, None)
        else:
            self.data[key] = value
        self.save()


def settings(cfg):
    return Settings(os.path.join(cfg["data_dir"], "hub-state.json") if cfg.get("data_dir") else None)
