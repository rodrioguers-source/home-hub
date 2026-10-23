"""Samsung's cloud view of the TV through the helper's st.* methods (SmartThings.swift). After an auth
failure it stops polling until retry(), so a broken token never turns into a request loop."""
import asyncio
import time

from .helper import Failure, is_auth_failure

POLL_WHILE_ON = 45
POLL_WHILE_OFF = 300


def _options(raw):
    out = []
    for o in raw or []:
        if isinstance(o, dict):
            i, n = o.get("id"), o.get("name")
            out.append({"id": i or n or "", "name": n or i or ""})
        else:
            out.append({"id": str(o), "name": str(o)})
    return out


def matches(option, value):
    return value is not None and (value == option["id"] or value == option["name"])


class STModel:
    IDLE, READY, UNAVAILABLE = "idle", "ready", "unavailable"

    def __init__(self, helper, clock=time.time):
        self.helper = helper
        self.now = clock
        self.phase = self.IDLE
        self.reason = None
        self.status = None
        self.fetched_at = None
        self.loading = False
        self.command_error = None
        self.busy = None
        self.chosen_input = None
        self._reported_input = None
        self._last_poll_on = None
        self.is_tv_on = lambda: True
        self.ok_at = None

    @property
    def usable(self):
        if self.phase != self.READY or self.status is None:
            return False
        return (self.status.get("health") or "").upper() != "OFFLINE"

    @property
    def worth_trying(self):
        return self.phase != self.UNAVAILABLE

    @property
    def unavailable_reason(self):
        return self.reason if self.phase == self.UNAVAILABLE else None

    @property
    def notice(self):
        if self.phase == self.IDLE:
            return "Checking SmartThings…" if self.loading else "SmartThings not checked yet."
        if self.phase == self.UNAVAILABLE:
            return f"SmartThings unavailable: {self.reason}"
        if ((self.status or {}).get("health") or "").upper() == "OFFLINE":
            return "SmartThings sees the TV as offline."
        if self.command_error:
            return f"Last change didn't go through: {self.command_error}"
        return None

    def input(self, id):
        return next((o for o in (self.status or {}).get("inputs") or [] if matches(o, id)), None)

    @property
    def current_input(self):
        return self.input((self.chosen_input or {}).get("id") or (self.status or {}).get("input_source"))

    async def run(self):
        while True:
            if self.worth_trying:
                on = self.is_tv_on()
                interval = POLL_WHILE_ON if on else POLL_WHILE_OFF
                due = self.fetched_at is None or self.now() - self.fetched_at >= interval - 1
                if due or on != self._last_poll_on:
                    await self.fetch()
            await asyncio.sleep(15)

    async def fetch(self, refresh=False):
        if self.loading:
            return
        self.loading = True
        self._last_poll_on = self.is_tv_on()
        try:
            self.absorb(await self.helper.call("st.status", {"refresh": refresh}))
            self.fetched_at = self.now()
            self.ok_at = self.fetched_at
            self.phase = self.READY
        except Failure as e:
            self.phase, self.reason = self.UNAVAILABLE, str(e)
        finally:
            self.loading = False

    def absorb(self, new):
        new = dict(new or {})
        for k in ("inputs", "picture_modes", "sound_modes"):
            new[k] = _options(new.get(k))
        self.status = new
        self._reported_input = new.get("input_source")
        c = self.chosen_input
        if c and new.get("input_source") and new.get("input_source") != c["stale"]:
            self.chosen_input = None

    def note_chosen_input(self, id, stale):
        self.chosen_input = {"id": id, "stale": stale, "at": self.now()}

    async def retry(self):
        try:
            await self.helper.call("st.retry", timeout=10)
        except Failure:
            pass
        self.phase = self.IDLE
        self.command_error = None
        await self.fetch(refresh=True)

    async def set_input(self, id):
        before = self._reported_input

        def optimistic(s):
            s["input_source"] = id
        error = await self._command("st.set_input", {"id": id}, f"input:{id}", optimistic)
        if error is None:
            self.note_chosen_input(id, before)
        return error

    async def power_on(self):
        try:
            await self.helper.call("st.power_on", {}, timeout=30)
        except Failure:
            pass

    async def launch(self, app_id):
        return await self._command("st.launch", {"app_id": app_id}, None, lambda s: None)

    async def _command(self, method, params, busy, optimistic):
        if busy:
            self.busy = busy
        try:
            await self.helper.call(method, params, timeout=60)
            self.command_error = None
            if self.status is not None:
                optimistic(self.status)

            async def later():
                await asyncio.sleep(3)
                await self.fetch()
            asyncio.ensure_future(later())
            return None
        except Failure as e:
            return self._fail(e)
        finally:
            if busy and self.busy == busy:
                self.busy = None

    def _fail(self, e):
        message = str(e)
        self.command_error = message
        if is_auth_failure(e.code):
            self.phase, self.reason = self.UNAVAILABLE, message
        return message
