"""Configuração única do SmartThings para a TV. Rode no Terminal e siga os passos.

    /Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python /Users/rodrigocarneiro/personal/samsung-tv/helper/smartthings_auth.py
        [--item "SmartThings OAuth Mac"] [--owner mac|hub]

Sem --item usa "SmartThings OAuth". Com --item "SmartThings OAuth Mac" o Mac ganha a própria autorização,
separada da do home hub, e passa a usá-la sozinho. Nada secreto é impresso nem gravado em disco:
client secret e tokens vão direto (por stdin) para o item escolhido do 1Password.
"""
import argparse
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smartthings as st  # noqa: E402

CLI_CANDIDATES = ["/opt/homebrew/bin/smartthings", "/usr/local/bin/smartthings"]
BREW_FORMULA = "smartthingscommunity/smartthings/smartthings"


def ask(msg, default=True):
    suffix = " [S/n] " if default else " [s/N] "
    ans = input(msg + suffix).strip().lower()
    return default if not ans else ans in ("s", "sim", "y", "yes")


def step(n, title):
    print(f"\n== Passo {n}: {title}")


def find_cli():
    return shutil.which("smartthings") or next((p for p in CLI_CANDIDATES if os.access(p, os.X_OK)), None)


def ensure_cli():
    cli = find_cli()
    if cli:
        print(f"SmartThings CLI encontrado: {cli}")
        return cli
    print("O SmartThings CLI não está instalado.")
    brew = shutil.which("brew") or "/opt/homebrew/bin/brew"
    if not ask(f"Instalar agora com 'brew install {BREW_FORMULA}'?"):
        sys.exit("Instale o CLI e rode este script de novo.")
    if subprocess.run([brew, "install", BREW_FORMULA]).returncode != 0:
        sys.exit("A instalação falhou. Veja a mensagem do brew acima.")
    cli = find_cli()
    if not cli:
        sys.exit("Instalou, mas não achei o comando 'smartthings' no PATH. Abra um Terminal novo e tente de novo.")
    return cli


def create_app(cli, item):
    print("Primeiro o CLI precisa entrar na sua conta Samsung. Se abrir o navegador, faça login lá.")
    if subprocess.run([cli, "locations"]).returncode != 0:
        sys.exit("O login do CLI falhou. Rode 'smartthings locations' sozinho para ver o erro.")

    definition = {
        "appName": f"rodrigo-mac-tv-{uuid.uuid4().hex[:12]}",
        "displayName": "Rodrigo Mac TV" if item == st.OP_ITEM else f"Rodrigo Mac TV ({item})"[:75],
        "description": "Controle da TV pela barra de menus do Mac",
        "appType": "API_ONLY",
        "classifications": ["CONNECTED_SERVICE"],
        "singleInstance": True,
        "principalType": "LOCATION",
        "apiOnly": {},
        "oauth": {"clientName": "Rodrigo Mac TV", "scope": st.SCOPES, "redirectUris": [st.REDIRECT_URI]},
    }
    tmp = tempfile.mkdtemp(prefix="st-app-")
    path = os.path.join(tmp, "app.json")
    try:
        with open(path, "w") as fh:
            json.dump(definition, fh)
        print("Criando a SmartApp OAuth-In (o client secret vai direto para o 1Password, não aparece aqui)...")
        # stdout carries the one-time client secret, so it's captured and never echoed.
        r = subprocess.run([cli, "apps:create", "-i", path, "-j"], stdout=subprocess.PIPE, text=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    data = None
    if r.returncode == 0:
        try:
            data = json.loads(r.stdout[r.stdout.index("{"):])
        except ValueError:
            data = None
    if not data or not data.get("oauthClientId") or not data.get("oauthClientSecret"):
        print("\nNão consegui criar o app automaticamente.")
        print("Plano B: rode 'smartthings apps:create' em outro Terminal e responda:")
        print(f"  OAuth-In App, nome qualquer, scopes {', '.join(st.SCOPES)}, redirect URI {st.REDIRECT_URI}")
        print("No fim ele mostra OAuth Client Id e Client Secret UMA vez. Cole aqui (não aparece na tela):")
        client_id = getpass.getpass("OAuth Client Id: ").strip()
        client_secret = getpass.getpass("OAuth Client Secret: ").strip()
        app_id = ""
    else:
        client_id, client_secret = data["oauthClientId"], data["oauthClientSecret"]
        app_id = (data.get("app") or {}).get("appId", "")
    if not client_id or not client_secret:
        sys.exit("Faltou client id ou secret.")
    st.op_save_fields({"client_id": client_id, "client_secret": client_secret, "app_id": app_id}, item)
    print(f"Client id e secret guardados no 1Password em '{item}'.")
    return client_id, client_secret


def extract_code(text):
    text = text.strip()
    m = re.search(r'"code"\s*:\s*"([^"]+)"', text) or re.search(r"[?&]code=([^&\s]+)", text)
    return m.group(1) if m else text


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Autoriza o SmartThings e guarda os tokens num item do 1Password.")
    p.add_argument("--item", default=st.OP_ITEM, help=f'título do item (padrão "{st.OP_ITEM}"; para o Mac: "{st.MAC_ITEM}")')
    p.add_argument("--owner", choices=("mac", "hub"), default="mac", help="quem renova este token (padrão mac)")
    a = p.parse_args(argv)
    a.item = a.item.strip()
    if not a.item:
        p.error("--item não pode ser vazio")
    return a


def pick_client(cli, item):
    existing = st.item_fields(st.op_get_item(item))
    if existing.get("client_id") and existing.get("client_secret") and ask(f"Já existe um client OAuth em '{item}'. Reaproveitar?"):
        return existing["client_id"], existing["client_secret"]
    if item != st.OP_ITEM:
        shared = st.item_fields(st.op_get_item(st.OP_ITEM))
        if shared.get("client_id") and shared.get("client_secret"):
            print(f"'{st.OP_ITEM}' já tem uma SmartApp (a que o home hub usa).")
            print("Uma SmartApp separada para este item é o mais seguro: autorizar uma não mexe nos tokens da outra.")
            if not ask("Criar uma SmartApp separada?"):
                print("Reaproveitando a SmartApp existente. Depois de autorizar, confira se o SmartThings do hub continua a funcionar.")
                st.op_save_fields({"client_id": shared["client_id"], "client_secret": shared["client_secret"],
                                   "app_id": shared.get("app_id", "")}, item)
                return shared["client_id"], shared["client_secret"]
    return create_app(cli, item)


def main(argv=None):
    args = parse_args(argv)
    item = args.item
    # Every read and write below, including the status check at the end, goes to this item.
    os.environ["HOME_ST_ITEM"] = item
    print("Configuração do SmartThings para a TV da sala")
    print(f"Item do 1Password: '{item}' (renovado por: {args.owner})")
    print("Os PATs novos do SmartThings expiram em 24h, então usamos OAuth: login uma vez, depois renova sozinho.")

    step(1, "SmartThings CLI")
    cli = ensure_cli()

    step(2, "SmartApp OAuth-In")
    client_id, client_secret = pick_client(cli, item)

    step(3, "Autorizar no navegador")
    print("Vou abrir a página de login da Samsung. Faça login, escolha a sua Location (casa) e clique Authorize.")
    print(f"No fim o navegador cai em {st.REDIRECT_URI} com um JSON. Copie a página inteira (ou só o \"code\").")
    input("Enter para abrir o navegador...")
    subprocess.run(["open", st.authorize_url(client_id)])
    raw = getpass.getpass("Cole aqui o JSON, a URL ou o code (não aparece na tela): ")
    code = extract_code(raw)
    if not code:
        sys.exit("Não achei o code. Rode de novo a partir do passo 3.")
    data = st.token_request(client_id, client_secret, {"grant_type": "authorization_code", "code": code,
                                                        "redirect_uri": st.REDIRECT_URI})
    st.op_save_fields(dict(st.tokens_to_fields(data), **{st.OWNER_FIELD: args.owner}), item)
    print(f"Tokens guardados no 1Password em '{item}'. Escopos concedidos: {data.get('scope', '?')}")

    step(4, "Achar a TV")
    st.client.retry()
    tvs = [d for d in st.devices() if st.is_tv(d)]
    if not tvs:
        sys.exit("Nenhuma TV nesta Location. Confira se a TV aparece no app SmartThings e se escolheu a Location certa.")
    tv = tvs[0]
    if len(tvs) > 1:
        for i, d in enumerate(tvs, 1):
            print(f"  {i}. {d['label']} ({d.get('manufacturer') or '?'})")
        tv = tvs[int(input("Qual é a TV da sala? ").strip() or 1) - 1]
    st.op_save_fields({"device_id": tv["deviceId"]}, item)
    st.client.fields["device_id"] = tv["deviceId"]
    print(f"TV: {tv['label']}")

    report = st.capability_report()
    print("\nCapabilities da TV:")
    for c in report["all"]:
        print(f"  {c}")
    print("\nUsadas por este módulo e presentes:", ", ".join(report["present"]) or "nenhuma")
    print("Usadas por este módulo e ausentes:", ", ".join(report["missing"]) or "nenhuma")

    try:
        s = st.status(refresh=True)
        print(f"\nAgora: power={s['power']} input={s['input_source']} picture_mode={s['picture_mode']}")
        if s["picture_modes"]:
            print("Picture modes:", ", ".join(m["id"] for m in s["picture_modes"]))
        if s["picture_adjustments"]:
            print("Ajustes de imagem no status:", ", ".join(s["picture_adjustments"]))
        ins = st.inputs()
        print("Inputs:", ", ".join(f"{i['id']} ({i['name']})" for i in ins["inputs"]) or "nenhum listado")
    except st.SmartThingsError as e:
        print(f"\nStatus falhou (a TV está ligada?): {st.scrub(e)}")

    print("\nPronto. Teste com:\n  /Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python "
          "/Users/rodrigocarneiro/personal/samsung-tv/helper/smartthings.py status")


if __name__ == "__main__":
    try:
        main()
    except st.SmartThingsError as e:
        sys.exit(f"\nErro: {st.scrub(e)}")
    except KeyboardInterrupt:
        sys.exit("\nCancelado.")
