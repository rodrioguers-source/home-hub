"""Tuya bulbs through the helper's lights.* methods, plus the presets (Lights.swift, LightPresets.swift)."""
import asyncio
import colorsys
import os
import re
import secrets
import time

from .helper import Failure
from .store import JSONFile

POLL_INTERVAL = 10
RETRY_UNAVAILABLE = 300
CUSTOM_NAMES = {}
SWATCHES = [("Red", "ff2a1f"), ("Orange", "ff6a00"), ("Amber", "ffb000"), ("Green", "2bd45a"),
            ("Cyan", "00c8ff"), ("Blue", "1f4dff"), ("Purple", "8a2bff"), ("Pink", "ff2d91")]


def ip_order(ip):
    n = 0
    for part in (ip or "").split("."):
        n = n * 256 + (int(part) if part.isdigit() else 0)
    return n


def labels(bulbs):
    """Device names are kept only when they differ by more than a trailing number; else "Light 1–4" in IP order."""
    ordered = sorted(bulbs, key=lambda b: ip_order(b[2]))
    bases = [re.sub(r"[\s\d]+$", "", b[1].lower()) for b in bulbs]
    distinct = len(set(bases)) == len(bases)
    return {b[0]: CUSTOM_NAMES.get(b[2]) or (b[1] if distinct else f"Light {n + 1}") for n, b in enumerate(ordered)}


def _rgb(hex_):
    v = int(hex_.replace("#", ""), 16)
    return ((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255


def _hex(r, g, b):
    return "%02x%02x%02x" % (int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))


def white_hex(temp):
    t = min(max(temp, 0), 100) / 100
    warm, cool = (1.0, 0.72, 0.38), (0.80, 0.90, 1.0)
    return _hex(*(w + (c - w) * t for w, c in zip(warm, cool)))


def hsv(hex_):
    try:
        return colorsys.rgb_to_hsv(*_rgb(hex_)) if hex_ else None
    except ValueError:
        return None


def split(hex_):
    """The bulbs report colour with the brightness baked in; this splits it into a full-value hex and a percentage."""
    c = hsv(hex_)
    if c is None:
        return None
    return _hex(*colorsys.hsv_to_rgb(c[0], c[1], 1)), max(1, int(round(c[2] * 100)))


def scaled(hex_, brightness):
    c = hsv(hex_)
    if c is None:
        return hex_
    return _hex(*colorsys.hsv_to_rgb(c[0], c[1], brightness / 100))


class Bulb:
    def __init__(self, id, device_name, ip, label):
        self.id, self.device_name, self.ip, self.label = id, device_name, ip, label
        self.reachable = False
        self.on = False
        self.brightness = 100.0
        self.temp = 0.0
        self.colour = None
        self.error = None

    @property
    def subtitle(self):
        if not self.reachable:
            return f"Not responding · {self.ip}"
        if not self.on:
            return "Off"
        return f"{'Colour' if self.colour else 'White'} · {int(self.brightness)}%"


def look(on=True, mode="white", brightness=100, temp=0, colour=None, index=None):
    return {"index": index, "on": on, "mode": mode, "brightness": brightness, "temp": temp, "colour": colour}


BUILT_INS = [
    {"id": "bright", "name": "Bright", "looks": [look(brightness=100, temp=70)]},
    {"id": "focus", "name": "Focus", "looks": [look(brightness=80, temp=45)]},
    {"id": "relax", "name": "Relax", "looks": [look(brightness=45, temp=15)]},
    {"id": "movie", "name": "Movie night", "looks": [look(brightness=12, temp=0)]},
    {"id": "sunset", "name": "Sunset", "looks": [look(mode="colour", colour=c, brightness=b) for c, b in
                                                 (("ff5a00", 60), ("ff2d6f", 45), ("ffa000", 55), ("8a2bff", 40))]},
]
SLOT_COUNT = 5


def is_built_in(p):
    return any(l.get("index") is None for l in p["looks"])


def look_from_row(row):
    if not row.get("ok") or row.get("index") is None:
        return None
    if row.get("mode") == "colour" and row.get("color") and split(row["color"]):
        h, b = split(row["color"])
        return look(row.get("on") or False, "colour", b, row.get("temp") or 0, h, row["index"])
    return look(row.get("on") or False, "white", max(1, row.get("brightness") or 100), row.get("temp") or 0, None, row["index"])


def look_hex(l):
    if not l["on"]:
        return None
    if l["mode"] == "colour" and l.get("colour"):
        return l["colour"]
    return white_hex(l["temp"])


def look_summary(l):
    if not l["on"]:
        return "Off"
    if l["mode"] == "colour":
        return f"Colour {l['brightness']}%"
    t = l["temp"]
    tone = "Very warm" if t < 10 else "Warm" if t < 30 else "Neutral" if t < 60 else "Cool"
    return f"{tone} white {l['brightness']}%"


def same_look(a, b):
    return {k: v for k, v in a.items() if k != "index"} == {k: v for k, v in b.items() if k != "index"}


def look_matches(l, bulb):
    if bulb.on != l["on"]:
        return False
    if not l["on"]:
        return True
    if l["mode"] == "colour":
        want, got = hsv(l.get("colour")), hsv(bulb.colour)
        if not want or not got:
            return False
        gap = abs(want[0] - got[0])
        hue_ok = want[1] < 0.15 or min(gap, 1 - gap) < 0.03
        return hue_ok and abs(want[1] - got[1]) < 0.12 and abs(l["brightness"] / 100 - got[2]) < 0.05
    return bulb.colour is None and abs(bulb.brightness - l["brightness"]) <= 3 and abs(bulb.temp - l["temp"]) <= 3


def resolved(p, bulbs):
    if not is_built_in(p):
        return list(p["looks"]) if not bulbs else [l for l in p["looks"] if any(b.id == l["index"] for b in bulbs)]
    if not p["looks"]:
        return []
    return [dict(p["looks"][i % len(p["looks"])], index=b.id) for i, b in enumerate(bulbs)]


def is_active(p, bulbs):
    pairs = [(l, b) for l in resolved(p, bulbs) for b in bulbs if b.id == l["index"] and b.reachable]
    return bool(pairs) and all(look_matches(l, b) for l, b in pairs)


def preset_summary(p, names):
    looks = p["looks"]
    built = is_built_in(p)
    if looks and all(same_look(l, looks[0]) for l in looks):
        if built or len(looks) > 1:
            return f"{look_summary(looks[0])} on all lights"
        return f"{names.get(looks[0].get('index') or 0, 'Light')}: {look_summary(looks[0])}"
    return "\n".join(f"{'Light ' + str(i + 1) if built else names.get(l.get('index') or 0, 'Light ' + str(l.get('index') or 0))}: "
                     f"{look_summary(l)}" for i, l in enumerate(looks))


NAME_MAX = 40
_HEX = re.compile(r"^[0-9a-f]{6}$")
_CUSTOM_ID = re.compile(r"^custom-[0-9a-z-]{1,40}$")


def default_name(slot):
    return f"Preset {slot + 1}"


def clean_name(name, slot):
    text = " ".join(name.split())[:NAME_MAX].strip() if isinstance(name, str) else ""
    return text or default_name(slot)


def _int(v, lo, hi):
    return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def clean_looks(raw):
    """Looks sent from the Mac or another client, or None if any of them isn't a saved bulb look."""
    if not isinstance(raw, list) or not 1 <= len(raw) <= 32:
        return None
    out = []
    for l in raw:
        if not isinstance(l, dict) or not _int(l.get("index"), 1, 64) or not isinstance(l.get("on"), bool):
            return None
        if l.get("mode") not in ("white", "colour") or not _int(l.get("brightness"), 0, 100) or not _int(l.get("temp"), 0, 100):
            return None
        colour = l.get("colour")
        if colour is not None and not (isinstance(colour, str) and _HEX.match(colour.lower())):
            return None
        if l["mode"] == "colour" and colour is None:
            return None
        out.append(look(l["on"], l["mode"], l["brightness"], l["temp"], colour.lower() if colour else None, l["index"]))
    if len({l["index"] for l in out}) != len(out):
        return None
    return sorted(out, key=lambda l: l["index"])


def valid_slot(slot):
    return _int(slot, 0, SLOT_COUNT - 1)


class PresetStore:
    def __init__(self, path):
        self.file = JSONFile(path, {"version": 1, "slots": [None] * SLOT_COUNT})
        raw = list(self.file.data.get("slots") or [])[:SLOT_COUNT]
        self.slots = [None] * SLOT_COUNT
        for i, p in enumerate(raw):
            if isinstance(p, dict) and p.get("looks") and not is_built_in(p):
                p["looks"] = [dict(look(), **l) for l in p["looks"]]
                self.slots[i] = p

    def save(self, slot, name, looks):
        """Fills or replaces a slot; a replaced slot keeps its id so results still line up."""
        old = self.slots[slot]
        pid = old["id"] if old else f"custom-{secrets.token_hex(4)}"
        self.slots[slot] = {"id": pid, "name": clean_name(name, slot), "looks": looks}
        self._persist()
        return self.slots[slot]

    def rename(self, slot, name):
        if not self.slots[slot]:
            return False
        self.slots[slot]["name"] = clean_name(name, slot)
        self._persist()
        return True

    def clear(self, slot):
        self.slots[slot] = None
        self._persist()

    def import_slots(self, incoming):
        """Copies presets into empty slots only, so nothing saved here is ever overwritten."""
        imported, kept, invalid = [], [], []
        taken = {p["id"] for p in self.slots if p}
        for i, p in enumerate(list(incoming)[:SLOT_COUNT]):
            if p is None:
                continue
            looks = clean_looks(p.get("looks")) if isinstance(p, dict) else None
            if looks is None:
                invalid.append(i)
                continue
            if self.slots[i]:
                kept.append(i)
                continue
            pid = p.get("id") if isinstance(p.get("id"), str) and _CUSTOM_ID.match(p["id"]) and p["id"] not in taken else None
            pid = pid or f"custom-{secrets.token_hex(4)}"
            taken.add(pid)
            self.slots[i] = {"id": pid, "name": clean_name(p.get("name"), i), "looks": looks}
            imported.append(i)
        if imported:
            self._persist()
        return imported, kept, invalid

    def _persist(self):
        self.file.data = {"version": 1, "slots": self.slots}
        self.file.save()


class LightsModel:
    def __init__(self, helper, presets, clock=time.time):
        self.helper = helper
        self.presets = presets
        self.now = clock
        self.bulbs = []
        self.loaded = False
        self.refreshing = False
        self.unavailable = None
        self.unavailable_at = None
        self.last_error = None
        self.preset_busy = None
        self.preset_result = None
        self._result_task = None
        self._debounce = {}
        self._last_local = 0.0
        self.last_manual_change = 0.0

    async def run(self):
        await self.refresh()
        while True:
            await asyncio.sleep(30)
            # The keyring never prompts, so a failed read can be retried on its own.
            if self.unavailable and self.now() - (self.unavailable_at or 0) > RETRY_UNAVAILABLE:
                await self.retry()

    async def retry(self):
        try:
            await self.helper.call("retry", {"what": "lights"}, timeout=45)
        except Failure:
            pass
        self.unavailable = None
        await self.refresh()

    def _set_unavailable(self, message):
        self.unavailable = message
        self.unavailable_at = self.now()

    async def refresh(self):
        if self.refreshing:
            return
        self.refreshing = True
        try:
            rows = await self.helper.call("lights.status", {"target": "all"})
            self.unavailable = None
            self.apply_rows(rows)
        except Failure as e:
            if e.code == "lights_unavailable":
                self._set_unavailable(str(e))
            else:
                self.last_error = str(e)
        finally:
            self.loaded = True
            self.refreshing = False

    def apply_rows(self, rows, fresh=False):
        recent = not fresh and self.now() - self._last_local < 3
        names = labels([(r["index"], r.get("name") or "", r.get("ip") or "") for r in rows if r.get("index") is not None])
        out = []
        for r in rows:
            i = r.get("index")
            if i is None:
                continue
            b = next((x for x in self.bulbs if x.id == i), None) or Bulb(i, r.get("name") or "", r.get("ip") or "", names.get(i, r.get("name")))
            b.label = names.get(i) or r.get("name")
            b.ip = r.get("ip") or b.ip
            b.reachable = bool(r.get("ok"))
            b.error = None if r.get("ok") else r.get("error")
            if r.get("ok") and not recent:
                b.on = bool(r.get("on"))
                if r.get("brightness") is not None:
                    b.brightness = float(r["brightness"])
                if r.get("temp") is not None:
                    b.temp = float(r["temp"])
                b.colour = r.get("color") if r.get("mode") == "colour" else None
            out.append(b)
        self.bulbs = sorted(out, key=lambda b: ip_order(b.ip))

    def _targets(self, index):
        return [b for b in self.bulbs if (index is None and b.reachable) or b.id == index]

    def set_power(self, index, on):
        for b in self._targets(index):
            b.on = on
        self._send(f"lights.{'on' if on else 'off'}", {}, index, "power", 0)

    def set_brightness(self, index, pct):
        for b in self._targets(index):
            b.brightness = pct
        self._send("lights.brightness", {"pct": int(round(pct))}, index, "brightness")

    def set_temp(self, index, pct):
        for b in self._targets(index):
            b.temp, b.colour = pct, None
        self._send("lights.temp", {"pct": int(round(pct))}, index, "colour")

    def set_colour(self, index, hex_):
        for b in self._targets(index):
            b.colour = "#" + hex_
        self._send("lights.colour", {"value": hex_}, index, "colour")

    def _send(self, method, params, index, key, delay=0.3):
        """Debounced per target and kind, so a dragged slider sends only the settled value."""
        self._last_local = self.last_manual_change = self.now()
        target = "all" if index is None else str(index)
        ident = f"{target}|{key}"
        old = self._debounce.get(ident)
        if old:
            old.cancel()
        payload = dict(params, target=target)

        async def go():
            if delay:
                await asyncio.sleep(delay)
            try:
                rows = await self.helper.call(method, payload)
                failed = [r for r in rows if not r.get("ok")]
                self.last_error = f"{len(failed)} light(s) didn't respond." if failed else None
            except Failure as e:
                self.last_error = str(e)
            self._last_local = self.now()
        self._debounce[ident] = asyncio.ensure_future(go())

    async def apply_look(self, kind, manual, brightness=100, temp=0, hex_=None):
        """kind is off, white or colour; one helper call for all lights. Returns (responded, total, error)."""
        if manual:
            self.last_manual_change = self.now()
        self._last_local = self.now()
        for b in self._targets(None):
            if kind == "off":
                b.on = False
            elif kind == "white":
                b.on, b.brightness, b.temp, b.colour = True, float(brightness), float(temp), None
            else:
                b.on, b.colour = True, "#" + hex_
        method, params = {"off": ("lights.off", {}), "white": ("lights.white", {"brightness": brightness, "temp": temp}),
                          "colour": ("lights.colour", {"value": hex_})}[kind]
        try:
            rows = await self.helper.call(method, dict(params, target="all"))
        except Failure as e:
            if e.code == "lights_unavailable":
                self._set_unavailable(str(e))
            return 0, 0, str(e)
        self._last_local = self.now()
        if manual:
            self.last_manual_change = self.now()
        self.unavailable = None
        failed = len([r for r in rows if not r.get("ok")])
        self.last_error = None if failed == 0 else f"{failed} light(s) didn't respond."
        return len(rows) - failed, len(rows), None

    async def any_on_now(self):
        self.last_error = None
        await self.refresh()
        if self.unavailable or self.last_error or not self.reachable:
            return None
        return self.any_on

    async def apply_preset(self, p, manual):
        looks = resolved(p, self.bulbs)
        if not looks:
            return 0, 0, "No lights found.", []
        if manual:
            self.last_manual_change = self.now()
        self._last_local = self.now()
        for l in looks:
            b = next((x for x in self.bulbs if x.id == l["index"]), None)
            if not b:
                continue
            b.on = l["on"]
            if not l["on"]:
                continue
            b.brightness = float(l["brightness"])
            if l["mode"] == "colour" and l.get("colour"):
                b.colour = "#" + scaled(l["colour"], l["brightness"])
            else:
                b.temp, b.colour = float(l["temp"]), None
        params = [{k: v for k, v in dict(l, index=l["index"] or 0).items() if not (k == "colour" and v is None)} for l in looks]
        try:
            rows = await self.helper.call("lights.apply", {"looks": params})
        except Failure as e:
            if e.code == "lights_unavailable":
                self._set_unavailable(str(e))
            return 0, 0, str(e), []
        self._last_local = self.now()
        if manual:
            self.last_manual_change = self.now()
        self.unavailable = None
        failed = [next((b.label for b in self.bulbs if b.id == r.get("index")), r.get("name")) for r in rows if not r.get("ok")]
        if not failed:
            self.last_error = None
        return len(rows) - len(failed), len(rows), None, failed

    async def capture_looks(self):
        """Reads every bulb for a new preset; returns the looks and the labels of bulbs that didn't answer."""
        try:
            rows = await self.helper.call("lights.status", {"target": "all"})
        except Failure as e:
            if e.code == "lights_unavailable":
                self._set_unavailable(str(e))
            raise
        self.unavailable = None
        self.apply_rows(rows, fresh=True)
        looks = sorted((l for l in map(look_from_row, rows) if l), key=lambda l: l["index"])
        missing = [next((b.label for b in self.bulbs if b.id == r.get("index")), r.get("name") or "A light")
                   for r in rows if not r.get("ok")]
        if not looks:
            raise Failure("None of the lights responded.")
        return looks, missing

    async def run_preset(self, p):
        if self.preset_busy:
            return
        self.preset_busy = p["id"]
        try:
            responded, total, error, failed = await self.apply_preset(p, manual=True)
        finally:
            self.preset_busy = None
        if error:
            text = f"Couldn't apply {p['name']}: {error}"
        elif responded == 0:
            text = "None of the lights responded."
        elif failed:
            text = f"{p['name']}: {join_names(failed)} didn't respond."
        else:
            text = None
        self._show({"id": p["id"], "text": text, "failed": bool(error) or responded == 0})

    def _show(self, result):
        self.preset_result = result
        if self._result_task:
            self._result_task.cancel()

        async def clear():
            await asyncio.sleep(3 if result["text"] is None else 10)
            self.preset_result = None
        self._result_task = asyncio.ensure_future(clear())

    def all_presets(self):
        return BUILT_INS + [p for p in self.presets.slots if p]

    @property
    def reachable(self):
        return [b for b in self.bulbs if b.reachable]

    @property
    def any_on(self):
        return any(b.on for b in self.reachable)

    @property
    def master_brightness(self):
        on = [b for b in self.reachable if b.on]
        return sum(b.brightness for b in on) / len(on) if on else 100

    @property
    def master_subtitle(self):
        on = len([b for b in self.reachable if b.on])
        missing = len(self.bulbs) - len(self.reachable)
        text = "All off" if on == 0 else f"{on} of {len(self.bulbs)} on"
        return text + (f" · {missing} not responding" if missing > 0 else "")

    @property
    def master_temp(self):
        l = [b for b in self.reachable if b.on and b.colour is None]
        return sum(b.temp for b in l) / len(l) if l else 0


def join_names(names):
    return "".join(names) if len(names) <= 1 else ", ".join(names[:-1]) + " and " + names[-1]


def presets_path(cfg):
    return os.path.join(cfg["data_dir"], "light-presets.json")
