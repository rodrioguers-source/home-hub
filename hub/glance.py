"""Weather (Open-Meteo) and Arsenal's next match (ESPN), both keyless public APIs (Glance.swift)."""
import asyncio
import datetime
import json
import time
import urllib.request

from .text import london

WEATHER_EVERY = 15 * 60
MATCH_EVERY = 60 * 60
LIVE_EVERY = 60
TEAM_ID = "359"
TEAM_SHORT = "ARS"


def fetch_blocking(url, timeout=10, limit=4_000_000):
    """(content type, bytes) for a 200 answer, else None."""
    req = urllib.request.Request(url, headers={"User-Agent": "HomeHub/1"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if r.status != 200:
                return None
            return r.headers.get("Content-Type") or "", r.read(limit + 1)
    except Exception:
        return None


async def fetch(url):
    return await asyncio.get_running_loop().run_in_executor(None, fetch_blocking, url)


def weather_text(code):
    if code == 0: return "Clear"
    if code == 1: return "Mostly clear"
    if code == 2: return "Partly cloudy"
    if code == 3: return "Overcast"
    if code in (45, 48): return "Fog"
    if 51 <= code <= 57: return "Drizzle"
    if 61 <= code <= 67: return "Rain"
    if 71 <= code <= 77: return "Snow"
    if 80 <= code <= 82: return "Showers"
    if code in (85, 86): return "Snow showers"
    if 95 <= code <= 99: return "Thunderstorm"
    return "Cloudy"


def weather_emoji(code, day):
    if code == 0: return "☀️" if day else "🌙"
    if code in (1, 2): return "⛅️" if day else "☁️"
    if code in (45, 48): return "🌫️"
    if 51 <= code <= 57: return "🌦️"
    if 61 <= code <= 67 or 80 <= code <= 82: return "🌧️"
    if 71 <= code <= 77 or code in (85, 86): return "🌨️"
    if 95 <= code <= 99: return "⛈️"
    return "☁️"


def parse_weather(data):
    d = json.loads(data)
    cur = d["current"]
    rain = None
    hourly = d.get("hourly") or {}
    times = hourly.get("time") or []
    i = next((n for n, t in enumerate(times) if t[:13] == cur["time"][:13]), None)
    if i is not None:
        vals = [v for v in (hourly.get("precipitation_probability") or [])[i:i + 3] if v is not None]
        rain = max(vals) if vals else None
    daily = d.get("daily") or {}
    hi = (daily.get("temperature_2m_max") or [None])[0]
    lo = (daily.get("temperature_2m_min") or [None])[0]
    return {"temp": cur["temperature_2m"], "code": cur["weather_code"], "is_day": cur["is_day"] == 1,
            "high": hi, "low": lo, "rain": rain}


class Weather:
    def __init__(self, cfg, settings):
        self.cfg, self.settings = cfg, settings
        self.now = None
        cached = settings.get("glance.weather")
        if cached:
            self.now = cached

    async def run(self):
        while True:
            await self.refresh()
            await asyncio.sleep(WEATHER_EVERY)

    async def refresh(self):
        url = (f"https://api.open-meteo.com/v1/forecast?latitude={self.cfg['latitude']}&longitude={self.cfg['longitude']}"
               "&current=temperature_2m,weather_code,is_day&hourly=precipitation_probability"
               "&daily=temperature_2m_max,temperature_2m_min&timezone=Europe%2FLondon&forecast_days=2")
        r = await fetch(url)
        if not r:
            return
        try:
            self.now = parse_weather(r[1])
        except (ValueError, KeyError, TypeError):
            return
        self.settings.set("glance.weather", self.now)

    def web_state(self):
        w = self.now
        if not w:
            return None
        parts = []
        if w.get("high") is not None and w.get("low") is not None:
            parts.append(f"{int(round(w['high']))}° / {int(round(w['low']))}°")
        if w.get("rain") is not None and w["rain"] >= 10:
            parts.append(f"☂ {w['rain']}%")
        return {"temp": int(round(w["temp"])), "summary": weather_text(w["code"]), "emoji": weather_emoji(w["code"], w["is_day"]),
                "range": " · ".join(parts), "place": self.cfg["place"]}


def _date(s):
    for fmt in ("%Y-%m-%dT%H:%M%z", "%Y-%m-%dT%H:%M:%S%z"):
        try:
            return datetime.datetime.strptime(s.replace("Z", "+0000"), fmt).timestamp()
        except ValueError:
            continue
    return None


def _score(sc):
    if isinstance(sc, str):
        return sc
    if isinstance(sc, dict):
        return sc.get("displayValue")
    return None


def parse_matches(data):
    out = []
    for e in json.loads(data).get("events") or []:
        comps = e.get("competitions") or []
        if not comps:
            continue
        c = comps[0]
        kickoff = _date(e.get("date") or "")
        teams = c.get("competitors") or []
        us = next((t for t in teams if (t.get("team") or {}).get("id") == TEAM_ID), None)
        them = next((t for t in teams if (t.get("team") or {}).get("id") != TEAM_ID), None)
        if kickoff is None or not us or not them:
            continue
        st = c.get("status") or {}
        kind = st.get("type") or {}
        if kind.get("state") == "in":
            clock = "HT" if kind.get("name") == "STATUS_HALFTIME" else (st.get("displayClock") or kind.get("shortDetail") or "")
            state = ("live", clock)
        elif kind.get("state") == "post":
            state = ("finished", None)
        else:
            state = ("upcoming", None)
        lg = e.get("league") or {}
        league = lg.get("shortName") or lg.get("abbreviation") or lg.get("name") or ""
        out.append({"kickoff": kickoff, "opponent": them["team"].get("shortDisplayName") or them["team"].get("displayName") or "TBC",
                    "home": us.get("homeAway") == "home", "neutral": bool(c.get("neutralSite")),
                    "competition": league.replace("UEFA ", ""), "state": state,
                    "ours": _score(us.get("score")), "theirs": _score(them.get("score"))})
    return out


def match_text(m, now=None):
    now = time.time() if now is None else now
    venue = "N" if m["neutral"] else ("H" if m["home"] else "A")
    fixture = f"v {m['opponent']} ({venue})"
    k = london(m["kickoff"])
    if k.date() == london(now).date():
        when = k.strftime("Today · %H:%M")
    else:
        when = f"{k.strftime('%a')} {k.day} {k.strftime('%b · %H:%M')}"
    short = {"Premier League": "PL", "Champions League": "UCL", "Carabao Cup": "EFL Cup", "English Carabao Cup": "EFL Cup"}.get(m["competition"], m["competition"])
    score = f"{TEAM_SHORT} {m['ours']}–{m['theirs']}" if m["ours"] is not None and m["theirs"] is not None else None
    kind = m["state"][0]
    headline = fixture if kind == "upcoming" else f"{score or TEAM_SHORT} {fixture}"
    detail = f"{when} · {short}" if kind == "upcoming" else (m["competition"] if kind == "live" else f"Full time · {m['competition']}")
    live = None
    if kind == "live":
        live = f"LIVE {m['state'][1]}" if m["state"][1] else "LIVE"
    return {"headline": headline, "detail": detail, "title": f"Arsenal {fixture} · {m['competition']} · {when} (UK time)", "live": live}


class Match:
    BASE = f"https://site.api.espn.com/apis/site/v2/sports/soccer/all/teams/{TEAM_ID}/schedule"

    def __init__(self):
        self.match = None

    def _in_window(self):
        m = self.match
        if not m:
            return False
        if m["state"][0] == "live":
            return True
        t = time.time() - m["kickoff"]
        return -600 < t < 3 * 3600

    async def run(self):
        last = 0
        while True:
            every = LIVE_EVERY if self._in_window() else MATCH_EVERY
            if time.time() - last >= every - 1:
                await self.refresh()
                last = time.time()
            await asyncio.sleep(LIVE_EVERY)

    async def refresh(self):
        r = await fetch(self.BASE + "?fixture=true")
        if not r:
            return
        try:
            fixtures = parse_matches(r[1])
        except (ValueError, KeyError, TypeError):
            return
        upcoming = sorted([m for m in fixtures if m["state"][0] != "finished"], key=lambda m: m["kickoff"])
        pick = next((m for m in upcoming if m["state"][0] == "live"), None)
        # A match that ended in the last 3 h drops off the fixture list, so show its result for a while.
        if pick is None:
            r = await fetch(self.BASE)
            try:
                results = parse_matches(r[1]) if r else []
            except (ValueError, KeyError, TypeError):
                results = []
            recent = [m for m in results if m["state"][0] == "finished" and time.time() - m["kickoff"] < 3 * 3600]
            pick = max(recent, key=lambda m: m["kickoff"]) if recent else None
        self.match = pick or (upcoming[0] if upcoming else None)

    def web_state(self):
        return match_text(self.match) if self.match else None
