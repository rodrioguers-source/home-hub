"""Wires the models together and runs them on one asyncio loop: python -m hub"""
import argparse
import asyncio
import logging
import logging.handlers
import os
import sys

from . import config as config_mod
from . import vault
from .glance import Match, Weather
from .helper import Helper
from .lights import LightsModel, PresetStore, presets_path
from .mdns import Publisher
from .notify import Notifier
from .ps5 import PS5Model
from .scenes import AutomationEngine, HelperTriggerSource, LiveDevices, SceneRunner, VoiceTriggers
from .stmodel import STModel
from .store import settings as settings_for
from .tv import ON, PS5_INPUT, TVModel
from .washer import WasherModel
from .web import API, PairingStore, Server


class Hub:
    def __init__(self, cfg, helper=None, tv_net=None, connector=None, ps5_probe=None, notifier=None, settings=None, ps5_search=None):
        self.cfg = cfg
        self.logger = logging.getLogger("hub")
        self.settings = settings if settings is not None else settings_for(cfg)
        self.helper = helper or Helper(cfg)
        self.st = STModel(self.helper)
        self.tv = TVModel(cfg, self.settings, self.st, self._tv_token, net=tv_net, connector=connector)
        self.st.is_tv_on = lambda: self.tv.power == ON
        self.lights = LightsModel(self.helper, PresetStore(presets_path(cfg) if cfg.get("data_dir") else None))
        self.ps5 = PS5Model(cfg, self.helper, probe=ps5_probe, settings=self.settings, search=ps5_search)
        self.devices = LiveDevices(self.tv, self.lights, self.ps5)
        self.runner = SceneRunner(self.devices, self.settings, self.log)
        self.automations = AutomationEngine(self.devices, self.runner, self.settings, self.log)
        self.voice = VoiceTriggers(HelperTriggerSource(self.helper), self.runner, self.settings, self.log)
        self.notify = notifier or Notifier(cfg.get("notifications", True), self.log)
        self.washer = WasherModel(self.helper, self.settings, self.notify)
        self.washer.smartthings_ok = lambda: self.st.ok_at
        self.weather = Weather(cfg, self.settings)
        self.match = Match()
        self.pairing = PairingStore(os.path.join(cfg["data_dir"], "web-devices.json") if cfg.get("data_dir") else None)
        self.api = API(self)
        self.server = Server(self.api.handle, cfg["port"], cfg.get("bind", "auto"), self.log)
        self.mdns = Publisher(cfg["mdns_name"], cfg["port"], self.log) if cfg.get("mdns_name") else None
        self.tasks = []

    def log(self, message):
        self.logger.info(message)

    def _tv_token(self):
        return vault.field(self.cfg.item("tv"))

    @property
    def theme(self):
        t = self.cfg.get("theme", "dark")
        if t == "auto":
            from .text import london, now
            h = london(now()).hour
            return "light" if 7 <= h < 19 else "dark"
        return "light" if t == "light" else "dark"

    def tv_input(self, id):
        """Through SmartThings when it's usable; the PS5 input falls back to KEY_HDMI like the Mac panel."""
        fallback = id == PS5_INPUT
        if not self.st.usable:
            if fallback:
                self.tv.key("KEY_HDMI")
            return

        async def go():
            if await self.st.set_input(id) is not None and fallback:
                self.tv.key("KEY_HDMI")
        asyncio.ensure_future(go())

    async def start(self, devices=True):
        await self.server.start()
        jobs = [self.server.watch()] + ([self.mdns.run()] if self.mdns and devices else [])
        if devices:
            jobs += [self.tv.run(), self.st.run(), self.lights.run(), self.ps5.run(), self.automations.run(self.tv, self.ps5),
                     self.voice.run(), self.washer.run(), self.weather.run(), self.match.run()]
        self.tasks = [asyncio.ensure_future(self._guard(j)) for j in jobs]

    async def _guard(self, coro):
        try:
            await coro
        except asyncio.CancelledError:
            raise
        except Exception as e:
            self.logger.exception(f"background task stopped: {type(e).__name__}")

    async def stop(self):
        for t in self.tasks:
            t.cancel()
        await self.server.stop()


def setup_logging(cfg, verbose):
    folder = cfg["data_dir"]
    os.makedirs(folder, exist_ok=True)
    handlers = [logging.handlers.RotatingFileHandler(os.path.join(folder, "hub.log"), maxBytes=1_000_000, backupCount=3,
                                                     encoding="utf-8")]
    # pythonw (the logon task) has no console, so sys.stderr is None there.
    if verbose or (sys.stderr is not None and sys.stderr.isatty()):
        handlers.append(logging.StreamHandler())
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", handlers=handlers)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m hub", description="Home hub: TV, lights, PS5, scenes, washer and the phone app.")
    ap.add_argument("--config", help="path to hub-config.json")
    ap.add_argument("--port", type=int)
    ap.add_argument("--signed-in-op", action="store_true",
                    help="read secrets from 1Password with your own sign-in instead of the keyring (testing on a Mac)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args(argv)
    cfg = config_mod.load(args.config, {"port": args.port} if args.port else None)
    setup_logging(cfg, args.verbose)
    log = logging.getLogger("hub")
    vault.configure(cfg, "op" if args.signed_in_op else "keyring")
    log.info(f"home hub starting, data in {cfg['data_dir']}, secrets in {'1Password' if args.signed_in_op else 'the keyring'}")
    hub = Hub(cfg)

    async def run():
        await hub.start()
        await asyncio.Event().wait()
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
    return 0
