"""Pareia o Mac com o PS5 via Remote Play (uma vez só) e guarda o registro no 1Password.

    /Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python /Users/rodrigocarneiro/personal/samsung-tv/helper/ps5_pair.py

Precisa: PS5 ligado (não em repouso), Remote Play ativo e a tela
Configurações › Sistema › Reprodução Remota › Vincular dispositivo aberta com o PIN.
O PIN e as chaves não aparecem na tela e só vão para o item "PS5 Remote Play".
"""
import base64
import getpass
import json
import sys

import ps5_control as ps5

PSN_OP_ITEM = "PSN NPSSO"


def _op(args, stdin=None):
    title = PSN_OP_ITEM if PSN_OP_ITEM in args else ps5.OP_ITEM
    return ps5.op_cli.run(args, title=title, input=stdin, timeout=180)


def _not_found(stderr):
    err = stderr.lower()
    return "isn't an item" in err or "not found" in err or "no item" in err or "isn't a field" in err


def ask(prompt, default=""):
    try:
        value = input(prompt).strip()
    except EOFError:
        value = ""
    return value or default


def account_id_from_npsso():
    r = _op(["item", "get", PSN_OP_ITEM, "--fields", "credential", "--reveal", "--format", "json"])
    if r.returncode != 0:
        if not _not_found(r.stderr):
            print(f"Não consegui ler '{PSN_OP_ITEM}' do 1Password.")
        return None, None
    try:
        npsso = json.loads(r.stdout).get("value", "").strip()
    except ValueError:
        npsso = ""
    if not npsso:
        return None, None
    ps5._secrets.add(npsso)
    try:
        from psnawp_api import PSNAWP
        me = PSNAWP(npsso).me()
        return str(me.account_id), me.online_id
    except Exception as e:
        print(f"PSN recusou o NPSSO ({type(e).__name__}); provavelmente expirou.")
        return None, None


def account_id_from_sony_login():
    from pyremoteplay import oauth
    print("\nAbra este link no navegador e faça login na conta PSN do PS5:\n")
    print(oauth.get_login_url())
    print("\nDepois do login o navegador vai para uma página 'redirect' (pode ficar em branco).")
    print("Copie a URL inteira da barra de endereço e cole aqui. O texto não aparece na tela.")
    url = getpass.getpass("URL: ").strip()
    try:
        account = oauth.get_user_account(url)
    except Exception as e:
        print(f"Falhou ao trocar o código com a Sony ({type(e).__name__}).")
        return None, None
    if not account or not account.get("user_id"):
        print("A Sony não devolveu a conta. Confira se colou a URL completa e tente de novo.")
        return None, None
    return str(account["user_id"]), account.get("online_id")


def account_id_manual():
    print("\nDigite o account ID numérico da PSN (ex.: 1234567890123456789).")
    value = ask("Account ID: ")
    return (value, None) if value.isdigit() else (None, None)


def to_rp_id(account_id):
    return base64.b64encode(int(account_id).to_bytes(8, "little")).decode()


def get_account():
    account_id, online_id = account_id_from_npsso()
    if account_id:
        print(f"Conta PSN pelo NPSSO: {online_id}")
        return account_id
    print("\nSem NPSSO utilizável. Como pegar o account ID?")
    print("  1) Login da Sony no navegador (recomendado)")
    print("  2) Digitar o account ID")
    choice = ask("Escolha [1]: ", "1")
    account_id, online_id = account_id_from_sony_login() if choice == "1" else account_id_manual()
    if account_id and online_id:
        print(f"Conta PSN: {online_id}")
    return account_id


def ask_pin():
    for _ in range(3):
        pin = getpass.getpass("PIN de 8 dígitos (não aparece na tela): ").replace(" ", "").strip()
        if len(pin) == 8 and pin.isdigit():
            return pin
        print("O PIN tem 8 dígitos, só números.")
    return None


def save_to_1password(creds):
    payload = json.dumps(creds, separators=(",", ":"))
    ps5._secrets.add(payload)
    fields = [
        {"id": "credential", "label": "credential", "type": "CONCEALED", "value": payload},
        {"id": "host", "label": "host", "type": "STRING", "value": creds["host"]},
        {"id": "host_name", "label": "host_name", "type": "STRING", "value": creds.get("host_name") or ""},
    ]
    existing = _op(["item", "get", ps5.OP_ITEM, "--format", "json"])
    if existing.returncode == 0:
        item = json.loads(existing.stdout)
        by_label = {f.get("label"): f for f in item.setdefault("fields", [])}
        for f in fields:
            if f["label"] in by_label:
                by_label[f["label"]].update(type=f["type"], value=f["value"])
            else:
                item["fields"].append(f)
        r = _op(["item", "edit", item["id"]], stdin=json.dumps(item))
    else:
        template = {"title": ps5.OP_ITEM, "category": "API_CREDENTIAL", "fields": fields}
        r = _op(["item", "create"], stdin=json.dumps(template))
    if r.returncode != 0:
        last = r.stderr.strip().splitlines()[-1] if r.stderr.strip() else ""
        raise ps5.PS5Error(f"Não consegui gravar no 1Password: {ps5.scrub(last)}", "op_write_failed")


def main():
    from pyremoteplay.register import register
    from pyremoteplay.util import add_regist_data

    host = ps5.PS5_HOST
    print(f"Pareamento Remote Play com o PS5 em {host}\n")

    existing = _op(["item", "get", ps5.OP_ITEM, "--format", "json"])
    if existing.returncode == 0:
        if ask(f"Já existe '{ps5.OP_ITEM}' no 1Password. Substituir? [s/N]: ").lower() not in ("s", "sim", "y"):
            return 0

    status = ps5._raw_status(host)
    if not status:
        print("O PS5 não respondeu na rede. Confira se está ligado e se o IP é esse (PS5_HOST=... para mudar).")
        return 1
    if status.get("status-code") != ps5.STATUS_ON:
        print("O PS5 está em repouso. Ligue ele de verdade (botão PS no controle) e rode de novo.")
        return 1
    print(f"Achei {status.get('host-name')} ({status.get('host-type')}), ligado.")

    account_id = get_account()
    if not account_id:
        print("Sem account ID não dá para parear.")
        return 1

    print("\nNo PS5: Configurações › Sistema › Reprodução Remota › Vincular dispositivo.")
    print("Deixe a tela do PIN aberta (ele vale uns minutos).")
    pin = ask_pin()
    if not pin:
        return 1

    print("Registrando...")
    try:
        info = register(host, to_rp_id(account_id), pin, timeout=6.0)
    except OSError as e:
        ps5._log.lines.append(f"{type(e).__name__}")
        info = {}
    pin = None
    if not info:
        hint = " ".join(ps5._log.lines[-2:])
        print("O registro falhou.", hint)
        if "Register Mode" in hint:
            print("A tela 'Vincular dispositivo' não estava aberta, ou o PIN expirou.")
        else:
            print("Causas comuns: PIN errado ou expirado, ou a conta não é a que está logada no PS5.")
        return 1

    profile = {"hosts": {}}
    add_regist_data(profile, status, info)
    data = profile["hosts"][status["host-id"]]["data"]
    creds = {
        "host": host,
        "host_id": status["host-id"],
        "host_type": status.get("host-type", "PS5"),
        "host_name": status.get("host-name"),
        "RegistKey": data["RegistKey"],
        "RP-Key": data["RP-Key"],
    }
    ps5._remember(creds)
    info.clear()
    data.clear()

    save_to_1password(creds)
    creds.clear()
    print(f"Registro guardado no 1Password em '{ps5.OP_ITEM}'.")

    ps5.reset()
    ps5.load_creds()
    print("Conferi a leitura do 1Password: ok.")
    print("\nPronto. Teste com:")
    print("  /Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python "
          "/Users/rodrigocarneiro/personal/samsung-tv/helper/ps5_control.py standby   (e depois wake)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nCancelado.")
        sys.exit(130)
    except ps5.PS5Error as e:
        print(ps5.scrub(e))
        sys.exit(1)
