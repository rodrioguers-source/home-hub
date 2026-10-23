"""Controle local das lampadas Tuya (sem nuvem).

CLI:  luzes.py on|off|toggle|status [alvo] [--json]
      luzes.py bright <0-100> [alvo]
      luzes.py temp <0-100> [alvo]      (0 = quente, 100 = frio)
      luzes.py color <hex|nome> [alvo]
alvo: all (padrao), numero 1-4, ou nome (parcial, sem diferenciar maiusculas)

Modulo: import luzes; luzes.on("sala"); luzes.status() -> lista de dicts
"""
import json
import os
import sys
import unicodedata
import warnings
from concurrent.futures import ThreadPoolExecutor

warnings.filterwarnings("ignore")

import tinytuya

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "helper"))
import secret_store  # noqa: E402

OP_ITEM = "Tuya Lamps"
DEFAULT_VERSION = 3.5

COLORS = {
    "vermelho": "ff0000", "verde": "00ff00", "azul": "0000ff", "amarelo": "ffb000",
    "laranja": "ff5000", "roxo": "8000ff", "rosa": "ff2080", "ciano": "00ffff",
    "branco": "ffffff",
}

_devices = None


class LuzesError(Exception):
    pass


def _norm(s):
    return unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower().strip()


def devices():
    """Lista de lampadas guardada no 1Password, lida uma vez por processo."""
    global _devices
    if _devices is not None:
        return _devices
    raw = os.environ.get("TUYA_LAMPS_JSON")
    if not raw:
        try:
            raw = secret_store.get_field(OP_ITEM)
        except secret_store.SecretError:
            raw = None
        if not raw:
            raise LuzesError(f"Sem dados no 1Password ('{OP_ITEM}'). Rode primeiro pair_lights.py")
    _devices = json.loads(raw)["devices"]
    return _devices


def resolve(target="all"):
    devs = devices()
    t = _norm(str(target or "all"))
    if t in ("all", "todas", "todos", "tudo"):
        return list(devs)
    if t.isdigit():
        i = int(t)
        if 1 <= i <= len(devs):
            return [devs[i - 1]]
        raise LuzesError(f"Nao existe lampada {i} (tenho {len(devs)})")
    exact = [d for d in devs if _norm(d["name"]) == t]
    if exact:
        return exact
    partial = [d for d in devs if t in _norm(d["name"])]
    if partial:
        return partial
    raise LuzesError(f"Nenhuma lampada chamada '{target}'. Disponiveis: {', '.join(d['name'] for d in devs)}")


def _bulb(d, ip=None):
    b = tinytuya.BulbDevice(
        d["id"], ip or d["ip"], d["local_key"], version=d.get("version") or DEFAULT_VERSION,
        connection_timeout=3, connection_retry_limit=1, connection_retry_delay=1,
    )
    b.set_socketTimeout(3)
    return b


def _run(d, fn):
    """Executa fn(bulb) numa lampada; se o IP mudou (DHCP), redescobre pelo id e tenta de novo."""
    try:
        res = fn(_bulb(d))
        if isinstance(res, dict) and "Error" in res:
            raise LuzesError(res["Error"])
        return res
    except Exception as first:
        found = tinytuya.find_device(dev_id=d["id"])
        if not found or not found.get("ip") or found["ip"] == d["ip"]:
            raise LuzesError(str(first))
        d["ip"] = found["ip"]
        res = fn(_bulb(d))
        if isinstance(res, dict) and "Error" in res:
            raise LuzesError(res["Error"])
        return res


def _each(target, fn):
    targets = resolve(target)

    def one(d):
        try:
            return {"name": d["name"], "ok": True, "result": _run(d, fn)}
        except Exception as e:
            msg = str(e)
            if "not configured" in msg:
                msg = "sem resposta valida (lampada offline/desligada na parede, ou chave mudou: rode pair_lights.py)"
            return {"name": d["name"], "ok": False, "error": msg}

    with ThreadPoolExecutor(max_workers=len(targets)) as pool:
        return list(pool.map(one, targets))


def on(target="all"):
    return _each(target, lambda b: b.turn_on())


def off(target="all"):
    return _each(target, lambda b: b.turn_off())


def toggle(target="all"):
    # Toggling as a group (any on -> all off) avoids leaving a mixed on/off set.
    current = status(target)
    any_on = any(s.get("on") for s in current if s["ok"])
    return off(target) if any_on else on(target)


def set_brightness(pct, target="all"):
    pct = int(pct)
    if not 0 <= pct <= 100:
        raise LuzesError("Brilho vai de 0 a 100")
    if pct == 0:
        return off(target)
    return _each(target, lambda b: b.set_brightness_percentage(pct))


def set_temp(pct, target="all"):
    pct = int(pct)
    if not 0 <= pct <= 100:
        raise LuzesError("Temperatura vai de 0 (quente) a 100 (frio)")
    return _each(target, lambda b: b.set_colourtemp_percentage(pct))


def parse_color(value):
    h = COLORS.get(_norm(value), value).lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    try:
        if len(h) != 6:
            raise ValueError
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    except ValueError:
        raise LuzesError(f"Cor invalida: '{value}'. Use hex (#ff8800) ou: {', '.join(COLORS)}")


def set_color(value, target="all"):
    r, g, b_ = parse_color(value)
    return _each(target, lambda b: b.set_colour(r, g, b_))


def _read_state(b):
    st = b.state()
    if "Error" in st:
        return st
    out = {"on": bool(st.get("switch")), "mode": st.get("mode")}
    if b.bulb_has_capability("brightness"):
        out["brightness"] = round(b.get_brightness_percentage(state=st))
    if b.bulb_has_capability("colourtemp"):
        out["temp"] = round(b.get_colourtemp_percentage(state=st))
    if out["mode"] == "colour" and b.bulb_has_capability("colour"):
        r, g, bl = b.colour_rgb(state=st)
        out["color"] = "#%02x%02x%02x" % (int(r), int(g), int(bl))
    return out


def status(target="all"):
    rows = _each(target, _read_state)
    for row, d in zip(rows, resolve(target)):
        row["ip"] = d["ip"]
        if row["ok"]:
            row.update(row.pop("result"))
    return rows


def _print_results(rows):
    for r in rows:
        print(f"{r['name']:<24} {'ok' if r['ok'] else 'ERRO: ' + r['error']}")


def _print_status(rows):
    for r in rows:
        if not r["ok"]:
            print(f"{r['name']:<24} ERRO: {r['error']}")
            continue
        parts = ["ligada" if r["on"] else "desligada"]
        if r.get("mode") == "colour" and r.get("color"):
            parts.append(f"cor {r['color']}")
        else:
            if "brightness" in r:
                parts.append(f"brilho {r['brightness']}%")
            if "temp" in r:
                parts.append(f"temp {r['temp']}%")
        print(f"{r['name']:<24} {', '.join(parts)}")


USAGE = __doc__.split("Modulo:")[0].strip()


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in args
    args = [a for a in args if a != "--json"]
    if not args:
        sys.exit(USAGE)

    cmd, rest = args[0], args[1:]
    try:
        if cmd in ("on", "off", "toggle", "status"):
            target = " ".join(rest) or "all"
            rows = {"on": on, "off": off, "toggle": toggle, "status": status}[cmd](target)
        elif cmd in ("bright", "temp", "color"):
            if not rest:
                sys.exit(USAGE)
            target = " ".join(rest[1:]) or "all"
            fn = {"bright": set_brightness, "temp": set_temp, "color": set_color}[cmd]
            rows = fn(rest[0], target)
        elif cmd == "list":
            rows = [{"n": i, "name": d["name"], "ip": d["ip"], "id": d["id"]} for i, d in enumerate(devices(), 1)]
            if as_json:
                return print(json.dumps(rows, ensure_ascii=False))
            for r in rows:
                print(f"{r['n']}. {r['name']:<24} {r['ip']}")
            return
        else:
            sys.exit(f"Comando desconhecido: {cmd}\n\n{USAGE}")
    except LuzesError as e:
        sys.exit(str(e))

    if as_json:
        print(json.dumps(rows, ensure_ascii=False, default=str))
    elif cmd == "status":
        _print_status(rows)
    else:
        _print_results(rows)
    if not all(r["ok"] for r in rows):
        sys.exit(1)


if __name__ == "__main__":
    main()
