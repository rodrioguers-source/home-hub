import datetime
import math
import time

try:
    from zoneinfo import ZoneInfo
    LONDON = ZoneInfo("Europe/London")
except Exception:
    LONDON = None


def format_duration(seconds):
    s = int(max(seconds, 0))
    if s < 60:
        return f"{s} s"
    m = s // 60
    if m < 60:
        return f"{m} min"
    return f"{m // 60} h {m % 60:02d} min"


def london(ts):
    if LONDON is not None:
        return datetime.datetime.fromtimestamp(ts, LONDON)
    return datetime.datetime.fromtimestamp(ts)


def clock(ts):
    return london(ts).strftime("%H:%M")


def parse_iso(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def ceil_minutes(seconds):
    return int(math.ceil(seconds / 60))


def now():
    return time.time()
