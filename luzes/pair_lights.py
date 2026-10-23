"""Pareia as lampadas Tuya via login QR do Smart Life e guarda as chaves no 1Password.

Uso: .venv/bin/python luzes/pair_lights.py
"""
import json
import subprocess
import sys
import time
import warnings

warnings.filterwarnings("ignore")

import qrcode
from tinytuya import scanner
from tuya_sharing import LoginControl, Manager

# Same public client the Home Assistant Tuya integration uses (homeassistant/components/tuya/const.py).
TUYA_CLIENT_ID = "HA_3y9q4ak7g4ephrvke"
TUYA_SCHEMA = "haauthorize"
OP_ITEM = "Tuya Lamps"
EXPECTED_IPS = ["192.168.0.24", "192.168.0.25", "192.168.0.26", "192.168.0.27"]
LOGIN_TIMEOUT = 180


def ask_user_code():
    print("No app Smart Life: Eu -> Configuracoes -> Conta e seguranca -> Codigo do usuario")
    print("(em ingles: Me -> Settings -> Account and Security -> User Code)\n")
    code = input("Cole o User Code: ").strip()
    if not code:
        sys.exit("Sem User Code, nada a fazer.")
    return code


def qr_login(user_code):
    login = LoginControl()
    resp = login.qr_code(TUYA_CLIENT_ID, TUYA_SCHEMA, user_code)
    if not resp.get("success"):
        sys.exit(f"A Tuya recusou o User Code: {resp.get('msg', resp)}")
    qr_token = resp["result"]["qrcode"]

    qr = qrcode.QRCode(border=1)
    qr.add_data(f"tuyaSmart--qrLogin?token={qr_token}")
    qr.print_ascii(invert=True)
    print("\nNo Smart Life, toque no icone de scan (canto superior direito da aba Inicio),")
    print("leia o QR acima e confirme o login no celular. Esperando...")

    deadline = time.time() + LOGIN_TIMEOUT
    while time.time() < deadline:
        ok, info = login.login_result(qr_token, TUYA_CLIENT_ID, user_code)
        if ok:
            return info
        time.sleep(2)
    sys.exit("O QR expirou sem confirmacao. Rode o script de novo.")


def fetch_cloud_devices(user_code, info):
    token_info = {k: info[k] for k in ("t", "uid", "expire_time", "access_token", "refresh_token")}
    manager = Manager(TUYA_CLIENT_ID, user_code, info["terminal_id"], info["endpoint"], token_info)
    manager.update_device_cache()
    devices = list(manager.device_map.values())
    # Expires only this script's session token; it does not unbind devices or rotate local keys.
    try:
        manager.user_repository.unload(info["terminal_id"])
    except Exception:
        pass
    return devices


def discover_local(ids):
    # verbose=False is what keeps tinytuya from writing snapshot.json; tuyadevices=[] skips devices.json.
    found = scanner.devices(
        verbose=False, scantime=15, color=False, poll=False,
        tuyadevices=[], byID=True, wantids=ids,
    )
    return {dev_id: {"ip": d.get("ip"), "version": d.get("version")} for dev_id, d in found.items()}


def build_record(devices, local):
    out = []
    for d in devices:
        key = getattr(d, "local_key", "")
        if not key:
            continue
        loc = local.get(d.id, {})
        out.append({
            "id": d.id,
            "name": d.name,
            "local_key": key,
            "ip": loc.get("ip"),
            "version": float(loc["version"]) if loc.get("version") else None,
            "category": getattr(d, "category", None),
            "product_id": getattr(d, "product_id", None),
            "product_name": getattr(d, "product_name", None),
            "dp_codes": sorted((getattr(d, "status", {}) or {}).keys()),
        })
    out.sort(key=lambda x: tuple(int(p) for p in x["ip"].split(".")) if x["ip"] else (999,))
    return out


def save_to_1password(record):
    payload = json.dumps({"devices": record}, ensure_ascii=False)
    template = json.dumps({
        "title": OP_ITEM,
        "category": "API_CREDENTIAL",
        "fields": [{"id": "credential", "type": "CONCEALED", "label": "credential", "value": payload}],
    })
    exists = subprocess.run(
        ["op", "item", "get", OP_ITEM, "--format", "json"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0
    cmd = ["op", "item", "edit", OP_ITEM] if exists else ["op", "item", "create"]
    # Secrets go via stdin so they never land on disk, in argv (ps) or on the terminal.
    result = subprocess.run(cmd, input=template, text=True, capture_output=True)
    if result.returncode != 0:
        sys.exit(f"Falhou ao gravar no 1Password:\n{result.stderr}")
    return exists


def main():
    user_code = ask_user_code()
    info = qr_login(user_code)
    print("Login OK. Buscando dispositivos na nuvem...")
    devices = fetch_cloud_devices(user_code, info)
    if not devices:
        sys.exit("A conta nao devolveu nenhum dispositivo.")

    print(f"{len(devices)} dispositivo(s) na conta. Procurando na rede local (15s)...")
    local = discover_local([d.id for d in devices])
    record = build_record(devices, local)
    if not record:
        sys.exit("Nenhum dispositivo veio com local_key. Ver README, plano B (tinytuya wizard).")

    print()
    for i, r in enumerate(record, 1):
        print(f"  {i}. {r['name']:<24} {r['ip'] or '(nao achado na rede)':<15} v{r['version'] or '?'}  {r['id']}")
    missing = [ip for ip in EXPECTED_IPS if ip not in {r["ip"] for r in record}]
    if missing:
        print(f"\nAtencao: nenhuma lampada da conta respondeu em {', '.join(missing)}.")

    updated = save_to_1password(record)
    print(f"\n{'Atualizado' if updated else 'Criado'} o item '{OP_ITEM}' no 1Password. Nenhuma chave foi gravada em disco.")


if __name__ == "__main__":
    main()
