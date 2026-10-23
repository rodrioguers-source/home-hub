"""The PWA icon from WebUI.swift, drawn without image libraries: Samsung-blue square with a TV outline."""
import math
import struct
import zlib


def _png(size, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def _rgb(h):
    return ((h >> 16) & 255, (h >> 8) & 255, h & 255)


def _mix(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def _rounded_box(px, py, cx, cy, hw, hh, r):
    qx, qy = abs(px - cx) - hw + r, abs(py - cy) - hh + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def _segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def icon(size):
    s = float(size)
    stops = [(0.0, _rgb(0x3D5BFF)), (0.55, _rgb(0x1428A0)), (1.0, _rgb(0x070C3A))]
    glow = _rgb(0x5B78FF)
    white = (255, 255, 255)
    cx, cy, hw, hh, r = 0.5 * s, 0.44 * s, 0.31 * s, 0.2 * s, 0.05 * s
    lw = 0.025 * s
    rows = []
    for y in range(size):
        row = []
        py = y + 0.5
        for x in range(size):
            px = x + 0.5
            t = (px + py) / (2 * s)
            if t <= stops[1][0]:
                c = _mix(stops[0][1], stops[1][1], t / stops[1][0])
            else:
                c = _mix(stops[1][1], stops[2][1], (t - stops[1][0]) / (1 - stops[1][0]))
            g = math.hypot(px - 0.5 * s, py - 0.45 * s) / (0.45 * s)
            if g < 1:
                c = _mix(c, glow, 0.55 * (1 - g))
            d = _rounded_box(px, py, cx, cy, hw, hh, r)
            if d < 0:
                fill = 0.28 - 0.22 * (py - (cy - hh)) / (2 * hh)
                c = _mix(c, white, max(0.0, min(fill, 1.0)))
            stroke = abs(d) - lw
            stroke = min(stroke, _segment(px, py, 0.5 * s, 0.66 * s, 0.5 * s, 0.73 * s) - lw,
                         _segment(px, py, 0.37 * s, 0.75 * s, 0.63 * s, 0.75 * s) - lw)
            a = max(0.0, min(1.0, 0.5 - stroke))
            if a > 0:
                c = _mix(c, white, a)
            row.extend(int(round(v)) for v in c)
        rows.append(row)
    return _png(size, rows)
