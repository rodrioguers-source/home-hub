"""The building's shared washing machine through the read-only st.washer (Washer.swift). Everyone's cycles show
as a free/busy chip; a claimed cycle gets the full bar and a notification when it ends."""
import asyncio
import math
import time

from .helper import Failure, is_auth_failure
from .text import clock, format_duration, parse_iso

POLL_ACTIVE = 60
POLL_IDLE = 300
POLL_MISSING = 1800
MAX_BACKOFF = 900
CLAIM_KEPT_FOR = 30 * 60
SAME_CYCLE_WITHIN = 20 * 60

PHASES = {"wash": "Washing", "rinse": "Rinsing", "spin": "Spinning", "weightSensing": "Weighing", "drying": "Drying",
          "dry": "Drying", "airWash": "Air wash", "cooling": "Cooling", "delayWash": "Delayed start",
          "wrinklePrevent": "Anti-crease", "finish": "Finishing"}


def active(s):
    return (s or {}).get("state") in ("running", "paused")


def estimated_start(s, now):
    done = parse_iso(s.get("completion_time"))
    if done is not None and s.get("operation_min") is not None:
        return done - s["operation_min"] * 60
    p, left = s.get("progress"), s.get("remaining_min")
    if done is not None and left is not None and p and 0 < p < 100:
        return done - left * 60 / (1 - p / 100)
    return now


def minutes_left(s, now):
    done = parse_iso(s.get("completion_time"))
    if s.get("state") == "running" and done is not None:
        return max(int(math.ceil((done - now) / 60)), 0)
    return None if s.get("remaining_min") is None else max(s["remaining_min"], 0)


def phase_name(raw):
    if not raw or raw == "none":
        return None
    return PHASES.get(raw) or raw[:1].upper() + raw[1:]


def minutes_text(m):
    return "Almost done" if m <= 0 else f"{format_duration(m * 60)} left"


def detail(s, fetched_at):
    parts = [s.get("label") or "Washing machine"]
    t = s.get("temp")
    if t and t != "none":
        parts.append("Cold" if t == "cold" else f"{t} °C")
    spin = s.get("spin")
    if spin:
        parts.append({"noSpin": "No spin", "rinseHold": "Rinse hold"}.get(spin) or f"{spin} rpm")
    r = s.get("rinses")
    if r and str(r).isdigit():
        n = int(r)
        parts.append("1 rinse" if n == 1 else f"{n} rinses")
    if active(s) and s.get("progress") is not None:
        parts.append(f"{s['progress']}%")
    if s.get("kids_lock") is True:
        parts.append("Child lock on")
    if fetched_at:
        parts.append(f"Checked {clock(fetched_at)}")
    return " · ".join(parts)


def title(d):
    k = d["kind"]
    if k == "running":
        return phase_name(d["phase"]) or "Washing"
    if k == "paused":
        p = phase_name(d["phase"])
        return f"Paused · {p}" if p else "Paused"
    return "Your washing is done" if k == "finished" else ""


def trailing(d):
    k = d["kind"]
    if k == "running":
        left, done = d["remaining"], d["done"]
        t = minutes_text(left) if left is not None else ""
        if done is None or (left if left is not None else 1) <= 0:
            return t
        return f"{t} · done {clock(done)}" if t else f"Done {clock(done)}"
    if k == "paused":
        return minutes_text(d["remaining"]) if d["remaining"] is not None else ""
    return f"Finished at {clock(d['at'])}" if k == "finished" else ""


def _compact(m):
    if m <= 0:
        return "Busy"
    return f"{m}m" if m < 60 else f"{m // 60}h{m % 60:02d}"


def chip(a):
    if a["kind"] == "free":
        return "Free", "Washer free"
    left = a.get("remaining")
    if a["kind"] == "busy":
        done = a.get("done")
        sentence = "Washer busy" + (f" · {minutes_text(left)}" if left is not None else "")
        if done is not None and (left if left is not None else 1) > 0:
            sentence += f" · done {clock(done)}"
        return (_compact(left) if left is not None else "Busy"), sentence
    return "Paused", "Washer paused" + (f" · {minutes_text(left)}" if left is not None else "")


def fills(phases, progress, current):
    """Phases before the current one are full and later ones empty; the current one is filled from overall progress."""
    p = min(max((progress or 0) / 100, 0), 1)
    weights = [float(max(ph.get("minutes") or 0, 1)) for ph in phases]
    total = sum(weights)
    at = next((i for i, ph in enumerate(phases) if ph.get("name") == current), None)
    if len(phases) <= 1 or at is None:
        return [[1.0, p]]
    out, start = [], 0.0
    for i, w in enumerate(weights):
        if i < at:
            out.append([w, 1.0])
        elif i > at:
            out.append([w, 0.0])
        else:
            out.append([w, min(max((p * total - start) / w, 0.06), 0.97)])
        start += w
    return out


class WasherModel:
    IDLE, READY, MISSING, UNAVAILABLE = "idle", "ready", "missing", "unavailable"

    def __init__(self, helper, settings, notify, clock=time.time):
        self.helper, self.settings, self.notify, self.now = helper, settings, notify, clock
        self.phase = self.IDLE
        self.reason = None
        self.status = None
        self.fetched_at = None
        self.claim = settings.get("washer.claim")
        self.notify_when_free = bool(settings.get("washer.notifyWhenFree"))
        self.failures = 0
        self.blocked_at = None
        self._attempted_at = None
        self._last_poll_active = None
        self._loading = False
        self.smartthings_ok = lambda: None

    def _save(self):
        self.settings.set("washer.claim", self.claim)
        self.settings.set("washer.notifyWhenFree", self.notify_when_free)

    @property
    def interval(self):
        if self.failures > 0:
            return min(POLL_ACTIVE * 2 ** self.failures, MAX_BACKOFF)
        if self.phase == self.MISSING:
            return POLL_MISSING
        return POLL_ACTIVE if active(self.status) else POLL_IDLE

    def due(self, now=None):
        now = self.now() if now is None else now
        if self.blocked_at is not None:
            ok = self.smartthings_ok()
            if ok is None or ok <= self.blocked_at:
                return False
        return self._attempted_at is None or now - self._attempted_at >= self.interval - 1

    async def run(self):
        while True:
            await self.tick()
            await asyncio.sleep(15)

    async def tick(self, now=None):
        if self.due(now):
            await self.fetch(now)

    async def fetch(self, now=None):
        if self._loading:
            return
        now = self.now() if now is None else now
        self._loading = True
        self._attempted_at = now
        try:
            new = await self.helper.call("st.washer", timeout=90)
        except Failure as e:
            if is_auth_failure(e.code):
                self.blocked_at, self.failures = now, 0
            else:
                self.blocked_at = None
                self.failures += 1
            self.phase, self.reason = self.UNAVAILABLE, str(e)
            return
        finally:
            self._loading = False
        self.failures = 0
        self.blocked_at = None
        self.fetched_at = now
        if not new.get("found", True):
            self.status = None
            self.phase = self.MISSING
            return
        self.status = new
        self.phase = self.READY
        self._follow(new, now)

    def claim_current(self, now=None):
        now = self.now() if now is None else now
        if not active(self.status):
            return False
        self.claim = {"start": estimated_start(self.status, now), "finishedAt": None, "notified": False}
        self.notify_when_free = False
        self._last_poll_active = True
        self._save()
        return True

    def unclaim(self):
        self.claim = None
        self._save()

    def set_notify_when_free(self, on):
        self.notify_when_free = bool(on) and active(self.status)
        self._save()

    def _follow(self, s, now):
        try:
            if active(s):
                c = self.claim
                if not c:
                    return
                start = estimated_start(s, now)
                # Seen running since the last poll means the same cycle even if a long pause moved the estimate.
                same = c.get("finishedAt") is None and (self._last_poll_active is True or abs(start - c["start"]) < SAME_CYCLE_WITHIN)
                if same:
                    c["start"] = start
                else:
                    self.claim = None
                self._save()
                return
            since = parse_iso(s.get("state_since"))
            ended = min(since, now) if since is not None else now
            c = self.claim
            if c and c.get("finishedAt") is None:
                c["finishedAt"] = now if ended < c["start"] else ended
                if not c.get("notified") and now - c["finishedAt"] < CLAIM_KEPT_FOR:
                    self.notify("Your washing is done", f"Finished at {clock(c['finishedAt'])}")
                c["notified"] = True
            if self.notify_when_free:
                self.notify_when_free = False
                self.notify("The washer is free", f"Finished at {clock(ended)}")
            if self.claim and self.claim.get("finishedAt") and now - self.claim["finishedAt"] >= CLAIM_KEPT_FOR:
                self.claim = None
            self._save()
        finally:
            self._last_poll_active = active(s)

    def _live_claim(self, now):
        c = self.claim
        if not c:
            return None
        if c.get("finishedAt") and now - c["finishedAt"] >= CLAIM_KEPT_FOR:
            return None
        return c

    def display(self, now=None):
        now = self.now() if now is None else now
        s, c = self.status, self._live_claim(now)
        if not s or not c:
            return {"kind": "hidden"}
        if c.get("finishedAt"):
            return {"kind": "hidden"} if active(s) else {"kind": "finished", "at": c["finishedAt"]}
        if s.get("state") == "running":
            return {"kind": "running", "phase": s.get("phase"), "progress": s.get("progress"),
                    "remaining": minutes_left(s, now), "done": parse_iso(s.get("completion_time"))}
        if s.get("state") == "paused":
            return {"kind": "paused", "phase": s.get("phase"), "progress": s.get("progress"), "remaining": minutes_left(s, now)}
        return {"kind": "hidden"}

    def availability(self, now=None):
        now = self.now() if now is None else now
        s = self.status
        if not s or self.display(now)["kind"] != "hidden":
            return None
        if s.get("state") == "running":
            return {"kind": "busy", "remaining": minutes_left(s, now), "done": parse_iso(s.get("completion_time"))}
        if s.get("state") == "paused":
            return {"kind": "paused", "remaining": minutes_left(s, now)}
        return {"kind": "free"}

    def web_state(self, now=None):
        now = self.now() if now is None else now
        s = self.status
        if not s:
            return None
        d = self.display(now)
        bar = None
        if d["kind"] in ("running", "paused"):
            bar = {"kind": d["kind"], "title": title(d), "trailing": trailing(d),
                   "segments": fills(s.get("phases") or [], d["progress"], d["phase"]), "note": None}
        elif d["kind"] == "finished":
            bar = {"kind": "finished", "title": title(d), "trailing": trailing(d), "segments": [],
                   "note": f"Unload me · {format_duration(max(now - d['at'], 60))} ago"}
        a = self.availability(now)
        c = None
        if a:
            short, sentence = chip(a)
            c = {"short": short, "sentence": sentence, "free": a["kind"] == "free", "notify": self.notify_when_free}
        return {"chip": c, "bar": bar, "detail": detail(s, self.fetched_at)}
