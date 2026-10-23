import json
import os
import subprocess
import sys
import warnings

warnings.filterwarnings("ignore")

from samsungtvws import SamsungTVWS
from wakeonlan import send_magic_packet

TV_IP = "192.168.0.23"
TV_MAC = "28:07:08:A8:9D:06"
OP_ITEM = "Samsung TV"
REMOTE_NAME = "Rodrigo Mac"

APPS = {
    "netflix": "3201907018807",
    "youtube": "111299001912",
    "prime": "3201910019365",
    "disney": "3201901017640",
    "spotify": "3201606009684",
    "apple": "3201807016597",
}

KEYS = {
    "up": "KEY_VOLUP",
    "down": "KEY_VOLDOWN",
    "mute": "KEY_MUTE",
    "home": "KEY_HOME",
    "back": "KEY_RETURN",
    "ok": "KEY_ENTER",
    "source": "KEY_SOURCE",
    "hdmi": "KEY_HDMI",
    "left": "KEY_LEFT",
    "right": "KEY_RIGHT",
    "play": "KEY_PLAY",
    "pause": "KEY_PAUSE",
}


def read_token():
    token = os.environ.get("SAMSUNG_TV_TOKEN")
    if token:
        return token
    result = subprocess.run(
        ["op", "item", "get", OP_ITEM, "--fields", "credential", "--reveal"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit("Sem token. Rode primeiro: tv pair")
    return result.stdout.strip()


def connect(token=None):
    return SamsungTVWS(host=TV_IP, port=8002, token=token, name=REMOTE_NAME, timeout=10)


def pair():
    print("Olhe para a TV e aceite o pedido de permissao...")
    tv = connect()
    tv.open()
    if not tv.token:
        sys.exit("A TV nao devolveu token. Foi recusado ou expirou, tente de novo.")
    # The token goes straight to 1Password via stdin so it never hits disk or the terminal.
    template = json.dumps({
        "title": OP_ITEM,
        "category": "API_CREDENTIAL",
        "fields": [{"id": "credential", "type": "CONCEALED", "label": "credential", "value": tv.token}],
    })
    result = subprocess.run(["op", "item", "create"], input=template, text=True, capture_output=True)
    tv.close()
    if result.returncode != 0:
        sys.exit(f"Pareou, mas falhou ao gravar no 1Password:\n{result.stderr}")
    print(f"Pareado. Token guardado no 1Password como '{OP_ITEM}'.")


def main():
    if len(sys.argv) < 2:
        sys.exit(
            "uso: tv pair | status | on | off | vol up|down|mute [n] | key <nome> | "
            "app <nome> | apps\n"
            f"teclas: {', '.join(KEYS)}\napps: {', '.join(APPS)}"
        )

    cmd, args = sys.argv[1], sys.argv[2:]

    if cmd == "pair":
        return pair()
    if cmd == "on":
        send_magic_packet(TV_MAC)
        return print("Wake-on-LAN enviado.")
    if cmd == "apps":
        # app_list() over the WebSocket never answers on this model, so probe the REST API per app.
        tv = connect()
        for name, app_id in APPS.items():
            try:
                print(f"{name:<10} {tv.rest_app_status(app_id)['name']}")
            except Exception:
                print(f"{name:<10} (nao instalado)")
        return
    if cmd == "status":
        info = connect().rest_device_info()["device"]
        return print(f"{info['modelName']}: {info['PowerState']}")

    tv = connect(read_token())

    if cmd == "off":
        tv.send_key("KEY_POWER")
    elif cmd == "vol":
        key = KEYS[args[0]]
        times = int(args[1]) if len(args) > 1 else 1
        for _ in range(times):
            tv.send_key(key)
    elif cmd == "key":
        tv.send_key(KEYS.get(args[0], args[0]))
    elif cmd == "app":
        tv.run_app(APPS.get(args[0], args[0]))
    else:
        sys.exit(f"Comando desconhecido: {cmd}")

    tv.close()


if __name__ == "__main__":
    main()
