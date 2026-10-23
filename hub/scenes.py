"""Scenes, automations and the Alexa virtual-switch triggers (Scenes.swift, Automations.swift, VoiceTriggers.swift)."""
import asyncio
import datetime
import time

from . import ps5 as ps5mod
from .helper import Failure
from .tv import ON, PS5_INPUT, PS5_INPUT_NAME, app_by_key

WAKE_TIMEOUT = 25
PLAYSTATION_BLUE = "0050ff"

SCENES = [
    {"id": "cinema", "name": "Cinema", "subtitle": "Warm 20% · TV on · open app", "icon": "popcorn.fill",
     "colours": (0xFF7A2F, 0x5A160B), "default_app": "stremio",
     "tracks": [[("lights", ("white", 20, 0), "Lights warm white 20%")], [("tvOn",), ("openApp",)]]},
    {"id": "gaming", "name": "Gaming", "subtitle": "Blue · TV & PS5 on · HDMI 2", "icon": "gamecontroller.fill",
     "colours": (0x0070D1, 0x00072D),
     "tracks": [[("lights", ("colour", PLAYSTATION_BLUE), "Lights PlayStation blue")],
                [("tvOn",), ("input", PS5_INPUT, ["KEY_HDMI"], f"Switch to {PS5_INPUT_NAME} (PS5)")],
                [("ps5Wake",)]]},
    {"id": "goodnight", "name": "Good night", "subtitle": "TV off · lights off", "icon": "moon.stars.fill",
     "colours": (0x4B4FB8, 0x0D0E26), "tracks": [[("tvOff",)], [("lights", ("off",), "Lights off")]]},
    {"id": "normal", "name": "Back to normal", "subtitle": "Warm white 100%", "icon": "sun.max.fill",
     "colours": (0xE8A93A, 0x5C3A08), "tracks": [[("lights", ("white", 100, 0), "Lights warm white 100%")]]},
]


def scene_by_id(i):
    return next((s for s in SCENES if s["id"] == i), None)


def done(t=None):
    return ("done", t)


def warning(t):
    return ("warning", t)


def failed(t):
    return ("failed", t)


def skipped(t):
    return ("skipped", t)


class LiveDevices:
    def __init__(self, tv, lights, ps5):
        self.tv, self.lights_model, self.ps5 = tv, lights, ps5

    @property
    def last_manual_lights_change(self):
        return self.lights_model.last_manual_change

    async def lights(self, look, manual):
        if look[0] == "off":
            r = await self.lights_model.apply_look("off", manual)
        elif look[0] == "white":
            r = await self.lights_model.apply_look("white", manual, brightness=look[1], temp=look[2])
        else:
            r = await self.lights_model.apply_look("colour", manual, hex_=look[1])
        responded, total, error = r
        if error:
            return failed(error)
        if total == 0:
            return failed("No lights found.")
        if responded == 0:
            return failed("None of the lights responded.")
        if responded < total:
            return warning(f"{responded} of {total} lights responded.")
        return done()

    async def lights_any_on(self):
        return await self.lights_model.any_on_now()

    async def tv_on(self):
        tv = self.tv
        if tv.power == ON:
            return done("Already on")
        start = time.time()
        last = 0
        while time.time() - start < WAKE_TIMEOUT:
            # Magic packets are fire-and-forget UDP, so resend in case one is dropped.
            if time.time() - last >= 5:
                tv.power_on()
                last = time.time()
            await asyncio.sleep(0.5)
            if tv.power == ON:
                return done(f"On after {int(round(time.time() - start))} s")
        tv.waking = False
        return failed(f"The TV didn't wake within {WAKE_TIMEOUT} s. Check it's plugged in and on the network.")

    async def tv_off(self):
        if self.tv.power != ON:
            return skipped("Already off")
        problem = await self._remote_problem(6)
        if problem:
            return failed(problem)
        self.tv.power_off()
        return done("Power off sent")

    async def open_app(self, app):
        tv = self.tv
        if tv.power != ON:
            return failed("The TV isn't on.")
        await tv.wait_for_cloud_ready()
        result = await tv.open(app)
        if result is None:
            return warning(f"Couldn't send {app.name} to the TV: SmartThings and the remote were both unavailable.")
        if not result["confirmed"] and tv.st.usable:
            # Unconfirmed launches right after waking are often dropped; resending to an open app is harmless.
            await asyncio.sleep(6)
            await tv.st.launch(app.id)
        if result["confirmed"]:
            return done(f"{app.name} is on screen ({result['method']})")
        return done(f"Sent to the TV ({result['method']})")

    async def keys(self, keys):
        if self.tv.power != ON:
            return failed("The TV isn't on.")
        problem = await self._remote_problem(12)
        if problem:
            return failed(problem)
        await asyncio.sleep(1.5)
        for k in keys:
            self.tv.key(k)
            await asyncio.sleep(0.6)
        return done(f"Sent {', '.join(keys)}")

    async def input(self, id, fallback_keys):
        if self.tv.power != ON:
            return failed("The TV isn't on.")
        st = self.tv.st
        name = (st.input(id) or {}).get("name") or id
        return await input_switch(id, fallback_keys, name, lambda: st.worth_trying, lambda: st.unavailable_reason,
                                  st.set_input, self.keys)

    async def ps5_wake(self):
        await self.ps5.probe()
        if self.ps5.status == ps5mod.ON:
            return done("Already on")
        if self.ps5.status == ps5mod.OFF:
            return warning("The PS5 isn't answering on the network (fully off?).")
        ok, text, code = await self.ps5.set_power(True)
        if ok:
            return done(text)
        return skipped(text) if code == "not_paired" else failed(text)

    async def _remote_problem(self, timeout):
        sock = self.tv.socket
        start = time.time()
        while time.time() - start < timeout:
            if sock.state == sock.READY:
                return None
            if sock.state == sock.NO_TOKEN:
                return "The remote has no TV token. Run python -m hub.pair_tv."
            if sock.state == sock.UNAUTHORIZED:
                return "The TV rejected the remote's token."
            sock.connect_if_needed()
            await asyncio.sleep(0.3)
        return "The remote didn't connect in time."


async def input_switch(id, fallback_keys, name, can_try, unavailable, cloud, keys, attempts=3, retry_delay=3):
    reason = unavailable() or "SmartThings unavailable"
    # Just after Wake-on-LAN the cloud may still see the TV as offline, so allow a few tries.
    for attempt in range(attempts):
        if not can_try():
            reason = unavailable() or reason
            break
        if attempt > 0:
            await asyncio.sleep(retry_delay)
        error = await cloud(id)
        if error is None:
            return done(f"{name} via SmartThings")
        reason = error
    fallback = await keys(fallback_keys)
    if fallback[0] == "done":
        why = reason.strip(". ")
        return warning(f"Sent {', '.join(fallback_keys)} instead: SmartThings didn't switch ({why}).")
    return fallback


class SceneRunner:
    def __init__(self, devices, settings, log=None):
        self.devices = devices
        self.settings = settings
        self.log = log or (lambda m: None)
        self.current = None
        self.chosen_apps = {s["id"]: settings.get(f"scene.{s['id']}.app") for s in SCENES if settings.get(f"scene.{s['id']}.app")}

    @property
    def running(self):
        return bool(self.current) and not self.current["finished"]

    def app_for(self, scene):
        fallback = scene.get("default_app")
        if not fallback:
            return None
        return app_by_key(self.chosen_apps.get(scene["id"]) or fallback) or app_by_key(fallback)

    def set_app(self, scene, app):
        self.chosen_apps[scene["id"]] = app.key
        self.settings.set(f"scene.{scene['id']}.app", app.key)

    def _label(self, action, scene):
        kind = action[0]
        if kind == "lights":
            return action[2]
        if kind == "input":
            return action[3]
        if kind == "keys":
            return action[2]
        if kind == "openApp":
            app = self.app_for(scene)
            return f"Open {app.name if app else 'app'}"
        return {"tvOn": "Turn the TV on", "tvOff": "Turn the TV off", "ps5Wake": "Wake the PS5"}[kind]

    def steps(self, scene):
        out = []
        for t, track in enumerate(scene["tracks"]):
            for action in track:
                out.append({"id": len(out), "track": t, "action": action, "label": self._label(action, scene),
                            "status": ("pending", None)})
        return out

    def run(self, scene):
        if self.running:
            return None
        return asyncio.ensure_future(self.run_and_wait(scene))

    async def run_and_wait(self, scene):
        if self.running:
            return
        self.current = {"scene": scene, "steps": self.steps(scene), "finished": False, "started_at": time.time()}
        self.log(f"scene {scene['id']} start")
        await asyncio.gather(*(self._track(t) for t in range(len(scene["tracks"]))))
        self.current["finished"] = True
        self.log(f"scene {scene['id']} end: {summary(self.current)}")

    async def _track(self, track):
        blocked = None
        for step in [s for s in self.current["steps"] if s["track"] == track]:
            if blocked:
                self._set(step, skipped(blocked))
                continue
            self._set(step, ("running", None))
            try:
                result = await self._perform(step["action"])
            except Exception as e:
                result = failed(f"Unexpected error ({type(e).__name__}).")
            self._set(step, result)
            if result[0] == "failed":
                blocked = "Skipped: the step before it failed."

    async def _perform(self, action):
        d = self.devices
        kind = action[0]
        if kind == "lights":
            return await d.lights(action[1], manual=True)
        if kind == "tvOn":
            return await d.tv_on()
        if kind == "tvOff":
            return await d.tv_off()
        if kind == "keys":
            return await d.keys(action[1])
        if kind == "input":
            return await d.input(action[1], action[2])
        if kind == "ps5Wake":
            return await d.ps5_wake()
        app = self.app_for(self.current["scene"])
        if not app:
            return failed("No app set for this scene.")
        return await d.open_app(app)

    def _set(self, step, status):
        step["status"] = status
        self.log(f"  [track {step['track']}] {step['label']}: {status[0]}{': ' + status[1] if status[1] else ''}")

    def dismiss(self):
        if not self.running:
            self.current = None


def summary(run):
    if not run["finished"]:
        return "Running…"
    kinds = [s["status"][0] for s in run["steps"]]
    if "failed" in kinds:
        return "Didn't finish"
    return "Done, with warnings" if "warning" in kinds else "Done"



AUTOMATIONS = ["ps5Blue", "tvOffNormal", "tvOnEvening"]
AUTOMATION_LOOKS = {"ps5Blue": ("colour", PLAYSTATION_BLUE), "tvOffNormal": ("white", 100, 0), "tvOnEvening": ("white", 40, 0)}
MANUAL_GRACE = 120
COOLDOWN = 60
EVENING_FROM = 18
EVENING_UNTIL = 4


def tv_hold(on):
    # Turning off holds longer: one missed poll reads as "off", while an "on" answer is positive evidence.
    return 3 if on else 12


def ps5_hold(on):
    return 0 if on else 75


class Debounced:
    """Turns samples into confirmed transitions. The first sample only sets the baseline."""

    def __init__(self, hold):
        self.hold = hold
        self.confirmed = None
        self._candidate = None
        self._since = 0

    def feed(self, state, now):
        if self.confirmed is None:
            self.confirmed = state
            return None
        current = self.confirmed
        if state == current:
            self._candidate = None
            return None
        if self._candidate != state:
            self._candidate, self._since = state, now
        if now - self._since < self.hold(state):
            return None
        self.confirmed, self._candidate = state, None
        return current, state


class AutomationLogic:
    def __init__(self):
        self.tv = Debounced(tv_hold)
        self.ps5 = Debounced(ps5_hold)
        self.last_fired = {}

    def step(self, tv_on, ps5_on, now, enabled, last_manual, scene_running, hour=None):
        triggered = []
        if tv_on is not None:
            change = self.tv.feed(tv_on, now)
            if change:
                if change[1]:
                    h = datetime.datetime.fromtimestamp(now).hour if hour is None else hour
                    if h >= EVENING_FROM or h < EVENING_UNTIL:
                        triggered.append("tvOnEvening")
                else:
                    triggered.append("tvOffNormal")
        if ps5_on is not None:
            change = self.ps5.feed(ps5_on, now)
            if change and change[1]:
                triggered.append("ps5Blue")
        out = []
        for kind in triggered:
            if kind not in enabled:
                continue
            if scene_running:
                out.append(("skip", kind, "a scene was running"))
            elif now - last_manual < MANUAL_GRACE:
                out.append(("skip", kind, "you changed the lights in the last 2 min"))
            elif kind in self.last_fired and now - self.last_fired[kind] < COOLDOWN:
                out.append(("skip", kind, "it ran less than a minute ago"))
            elif kind == "tvOnEvening" and self.ps5.confirmed is True:
                out.append(("skip", kind, "the PS5 is on, keeping the gaming lights"))
            else:
                self.last_fired[kind] = now
                out.append(("fire", kind, None))
        return out


class AutomationEngine:
    def __init__(self, devices, runner, settings, log=None):
        self.devices, self.runner, self.settings = devices, runner, settings
        self.log = log or (lambda m: None)
        self.enabled = {k for k in AUTOMATIONS if settings.get(f"automation.{k}")}
        self.events = {}
        self.logic = AutomationLogic()

    def set(self, kind, on):
        (self.enabled.add if on else self.enabled.discard)(kind)
        self.settings.set(f"automation.{kind}", bool(on))

    async def run(self, tv, ps5):
        while True:
            self.sample(tv.power == ON if tv.has_polled else None, ps5.status == ps5mod.ON if ps5.has_polled else None)
            await asyncio.sleep(1)

    def sample(self, tv_on, ps5_on, now=None, hour=None):
        now = time.time() if now is None else now
        for kind_, kind, reason in self.logic.step(tv_on, ps5_on, now, self.enabled, self.devices.last_manual_lights_change,
                                                   self.runner.running, hour):
            if kind_ == "skip":
                self._record(kind, f"Skipped: {reason}")
            else:
                asyncio.ensure_future(self.fire(kind))

    async def fire(self, kind):
        self.log(f"automation {kind} fired")
        if kind == "tvOffNormal":
            on = await self.devices.lights_any_on()
            if on is None:
                return self._record(kind, "Skipped: couldn't read the lights")
            if not on:
                return self._record(kind, "Skipped: the lights were off")
        # Re-checked because reading the lights can take a few seconds.
        if time.time() - self.devices.last_manual_lights_change < MANUAL_GRACE or self.runner.running:
            return self._record(kind, "Skipped: you changed the lights in the meantime")
        status = await self.devices.lights(AUTOMATION_LOOKS[kind], manual=False)
        if status[0] == "done":
            self._record(kind, "Ran")
        elif status[0] == "warning":
            self._record(kind, f"Ran: {status[1]}")
        elif status[0] == "failed":
            self._record(kind, f"Failed: {status[1]}")

    def _record(self, kind, text):
        self.events[kind] = {"at": time.time(), "text": text}
        self.log(f"automation {kind}: {text}")



VOICE_INTERVAL = 4
VOICE_BACKOFF = 30
VOICE_STALE = 120
SWITCHES = {"cinema": "Cinema", "gaming": "Gaming", "goodnight": "Good Night", "normal": "Back to Normal"}
SWITCH_NAMES = [SWITCHES[s["id"]] for s in SCENES if s["id"] in SWITCHES]


class HelperTriggerSource:
    def __init__(self, helper):
        self.helper = helper

    async def fetch(self, names):
        return await self.helper.call("st.triggers", {"names": names}, timeout=60)

    async def claim(self, device_id):
        r = await self.helper.call("st.claim_trigger", {"id": device_id}, timeout=30)
        return bool((r or {}).get("claimed"))


class VoiceTriggers:
    """Polls the SmartThings switches Alexa turns on, switches them back off and runs the matching scene."""

    def __init__(self, source, runner, settings, log=None):
        self.source, self.runner, self.settings = source, runner, settings
        self.log = log or (lambda m: None)
        v = settings.get("voiceTriggers.enabled")
        self.enabled = True if v is None else bool(v)
        self.last = None
        self.problem = None
        self._handled = set()
        self._polled = False
        self._active = None

    def set(self, on):
        self.enabled = bool(on)
        self.settings.set("voiceTriggers.enabled", self.enabled)
        if not on:
            self.problem = None

    async def run(self):
        while True:
            delay = await self.tick()
            await asyncio.sleep(delay)

    async def tick(self, now=None):
        now = time.time() if now is None else now
        if not self.enabled:
            return VOICE_INTERVAL
        try:
            data = await self.source.fetch(SWITCH_NAMES)
        except Failure as e:
            self.problem = str(e)
            return VOICE_BACKOFF
        first = not self._polled
        self._polled = True
        missing = data.get("missing") or []
        self.problem = f"Not found in SmartThings: {', '.join(missing)}." if missing else None
        from .text import parse_iso
        on = [t for t in data.get("triggers") or [] if t.get("on")]
        on.sort(key=lambda t: parse_iso(t.get("changed_at")) or 0, reverse=True)
        # A switch whose reset didn't stick still reads on with the same timestamp; that must not run twice.
        keys = {f"{t['device_id']}@{t.get('changed_at') or ''}" for t in on}
        reset_failed = False
        started = False
        for t in on:
            key = f"{t['device_id']}@{t.get('changed_at') or ''}"
            is_new = key not in self._handled
            self._handled.add(key)
            claimed = True
            try:
                # The Mac polls these too while it can't reach the hub; whoever switches it off runs the scene.
                claimed = await self.source.claim(t["device_id"])
            except Failure as e:
                reset_failed = True
                self.problem = f"Couldn't switch {t.get('name')} back off: {e}"
            scene = next((s for s in SCENES if SWITCHES.get(s["id"]) == t.get("name")), None)
            if not is_new or not scene:
                continue
            if not claimed:
                self._record(scene, "Already handled by the Mac")
                continue
            changed = parse_iso(t.get("changed_at"))
            stale = now - changed > VOICE_STALE if changed is not None else first
            if stale:
                self._record(scene, "Ignored, switched on more than 2 min ago")
            elif started or self.runner.running or self._active is not None:
                self._record(scene, "Skipped, another scene was running")
            else:
                started = True
                self._start(scene)
        self._handled &= keys
        return VOICE_BACKOFF if reset_failed else VOICE_INTERVAL

    def _start(self, scene):
        self._record(scene, "Running…")

        async def go():
            try:
                await self.runner.run_and_wait(scene)
                self._record(scene, summary(self.runner.current) if self.runner.current else "Done")
            finally:
                self._active = None
        self._active = asyncio.ensure_future(go())

    async def wait_for_run(self):
        if self._active:
            await self._active

    def _record(self, scene, text):
        self.last = {"at": time.time(), "text": f"{scene['name']}: {text}"}
        self.log(f"voice trigger {scene['id']}: {text}")
