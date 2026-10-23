"""The same helper methods the Mac app calls over stdin, run in-process on worker threads."""
import asyncio
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

from . import vault


class Failure(Exception):
    def __init__(self, message, code=None):
        super().__init__(message)
        self.code = code


def is_auth_failure(code):
    return bool(code) and (code.startswith("st_") or code.startswith("op_") or code in ("reauth_needed", "token_failed"))


class Helper:
    def __init__(self, cfg):
        self.cfg = cfg
        self.pool = ThreadPoolExecutor(max_workers=6, thread_name_prefix="helper")
        self._hh = None

    def _module(self):
        if self._hh is None:
            import home_helper
            home_helper.PSN_OP_ITEM = self.cfg.item("psn")
            import luzes
            luzes.OP_ITEM = self.cfg.item("lights")
            import smartthings
            smartthings.OP_ITEM = self.cfg.item("smartthings")
            self._hh = home_helper
        return self._hh

    def _call(self, method, params):
        hh = self._module()
        try:
            if method == "lights.list":
                return hh.lights.list()
            if method.startswith("lights."):
                return hh.lights.call(method.split(".", 1)[1], params)
            if method == "psn.summary":
                return hh.psn.summary(force=bool(params.get("force")))
            if method.startswith("st."):
                return hh.st_call(method.split(".", 1)[1], params)
            if method == "retry":
                what = params.get("what", "all")
                if what in ("lights", "all"):
                    hh.lights.retry()
                if what in ("psn", "all"):
                    hh.psn.retry()
                return {"lights": hh.lights.state, "psn": hh.psn.state}
        except hh.HelperError as e:
            raise Failure(hh._scrub(e), e.code)
        except Exception as e:
            raise Failure(hh._scrub(e))
        raise Failure(f"Unknown method {method}")

    async def call(self, method, params=None, timeout=150):
        loop = asyncio.get_running_loop()
        fut = loop.run_in_executor(self.pool, self._call, method, dict(params or {}))
        try:
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError:
            raise Failure("The helper didn't answer in time.", "timeout")

    async def ps5(self, action, creds, host=None):
        """Standby needs a Remote Play session, which runs as its own process; its credential goes on stdin."""
        script = os.path.join(vault.HELPER, "ps5_control.py")
        args = [sys.executable, script, action, "--creds-stdin"] + (["--no-wait"] if action == "wake" else [])

        def run():
            env = dict(os.environ)
            env["PS5_HOST"] = host or self.cfg["ps5_host"]
            return subprocess.run(args, input=creds + "\n", capture_output=True, text=True, timeout=120, env=env)

        try:
            proc = await asyncio.get_running_loop().run_in_executor(self.pool, run)
        except subprocess.TimeoutExpired:
            raise Failure("The PS5 didn't answer in time.", "session_timeout")
        try:
            out = json.loads(proc.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            raise Failure("The PS5 control script gave no answer.", "standby_failed")
        if not out.get("ok"):
            raise Failure(out.get("error") or "PS5 command failed.", out.get("code"))
        return out.get("result")
