"""Builds hub/web/index.html from the page in WebUI.swift, so the phone sees the same app from either host.

    python -m hub.sync_webui           regenerate
    python -m hub.sync_webui --check   exit 1 if index.html is out of date or its script doesn't parse
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(ROOT, "app", "Sources", "SamsungTV", "WebUI.swift")
OUT = os.path.join(ROOT, "hub", "web", "index.html")
JSC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"

SWAPS = [
    ("Can't reach the Mac. Is it awake, with the app open, on this Wi-Fi?",
     "Can't reach the home hub. Is the laptop on and running the hub, on this Wi-Fi?"),
    ("On your Mac, open the Samsung TV panel in the menu bar, click <b>···</b> and choose <b>Pair a phone…</b> Then enter the 6-digit code it shows.",
     "On the hub laptop, run <b>python -m hub.pair</b>, or on the Mac (with Use home hub on) choose <b>··· › Pair a phone…</b> Then enter the 6-digit code it shows."),
    ("toast(\"Couldn't reach the Mac.\")", "toast(\"Couldn't reach the home hub.\")"),
    ("$('#pairmsg').textContent = \"Couldn't reach the Mac.\"", "$('#pairmsg').textContent = \"Couldn't reach the home hub.\""),
    ("Only apps this Mac knows about appear.", "Only apps the hub knows about appear."),
    ("Use Retry in the Mac's Lights tab.", "The hub tries again every few minutes."),
    ("Set up PSN from the PS5 tab on the Mac to see what you're playing here.",
     "Send the PSN NPSSO from the Mac (hub.send_secrets) to see what you're playing here."),
    ("'. Notifications appear on the Mac.'", "'. Notifications appear on the hub laptop and on the Mac.'"),
    ("// MARK: PS5 backdrop, ported from the Mac panel: synthwave floor and drifting △ ○ ✕ □",
     "// PS5 backdrop: synthwave floor and drifting △ ○ ✕ □"),
]


def build_mac():
    """The page exactly as the Mac serves it, before any swaps."""
    with open(SWIFT, encoding="utf-8") as f:
        src = f.read()
    start = src.index('static let page = #"""\n') + len('static let page = #"""\n')
    end = src.index('\n"""#', start)
    return src[start:end] + "\n"


def build():
    page = build_mac()
    for old, new in SWAPS:
        if old not in page:
            raise SystemExit(f"WebUI.swift changed: couldn't find {old[:60]!r}. Update hub/sync_webui.py.")
        page = page.replace(old, new)
    return page


def scripts(page):
    return [m.group(1) for m in re.finditer(r"<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>", page, re.S)]


def js_errors(page, workdir=None):
    """Parses the page's inline scripts with macOS's jsc. None when jsc isn't there (not a Mac), else a list of errors."""
    if not os.path.exists(JSC):
        return None
    errors = []
    with tempfile.TemporaryDirectory(dir=workdir) as d:
        for i, code in enumerate(scripts(page)):
            path = os.path.join(d, f"script-{i}.js")
            with open(path, "w", encoding="utf-8") as f:
                f.write(code)
            r = subprocess.run([JSC, "-e", f"checkSyntax({path!r})"], capture_output=True, text=True, timeout=30)
            if r.returncode != 0:
                errors.append(f"script {i}: {(r.stdout + r.stderr).strip()[:300]}")
    return errors


def current():
    try:
        with open(OUT, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    page = build()
    if "--check" in argv:
        if current() != page:
            print("hub/web/index.html is out of date. Run: python -m hub.sync_webui")
            return 1
        errors = js_errors(page)
        if errors:
            print("The page's script doesn't parse:\n" + "\n".join(errors))
            return 1
        print("hub/web/index.html matches WebUI.swift" + (", and its script parses." if errors is not None else " (jsc not found, script not parsed)."))
        return 0
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(page)
    print(f"Wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
