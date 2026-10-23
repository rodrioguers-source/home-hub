# SmartThings: a TV pela nuvem da Samsung

Isto dá ao Mac acesso ao que a rede local não dá: picture mode, input atual, lista de inputs e launch de apps via `custom.launchapp`.

## Por que OAuth e não PAT

Desde 30 Dez 2024, PATs novos do SmartThings valem só 24h. Por isso usamos uma SmartApp OAuth-In:
você faz login uma vez, depois o módulo renova sozinho. O access token dura cerca de 24h e o refresh token cerca de 30 dias.
O refresh token é de uso único, então cada renovação grava o novo no 1Password.
Se ficar mais de cerca de 30 dias sem usar, é só rodar o script de novo.

Tudo fica só no item **"SmartThings OAuth"** do 1Password: client_id, client_secret, refresh_token,
access_token, access_expires_at, app_id e device_id. Nada vai para disco nem aparece na tela.

## Passo a passo (uma vez só)

1. Ligue a TV e confirme que ela aparece no app SmartThings do celular.
2. No Terminal:

   ```
   /Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python /Users/rodrigocarneiro/personal/samsung-tv/helper/smartthings_auth.py
   ```

3. O script faz isto:
   - instala o CLI se faltar (`brew install smartthingscommunity/smartthings/smartthings`);
   - faz login do CLI na sua conta Samsung (abre o navegador);
   - cria a SmartApp OAuth-In com scopes `r:devices:*`, `w:devices:*`, `x:devices:*` e redirect `https://httpbin.org/get`;
   - abre a página de autorização. Faça login, escolha a Location e clique Authorize;
   - o navegador cai no httpbin com um JSON. Copie tudo (Cmd+A, Cmd+C) e cole no Terminal. O texto não aparece na tela;
   - acha a TV e mostra as capabilities dela.

## Uso

```
PY=/Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python
ST=/Users/rodrigocarneiro/personal/samsung-tv/helper/smartthings.py
$PY $ST caps                 # capabilities presentes e ausentes
$PY $ST status --refresh     # power, input, picture mode, volume
$PY $ST inputs
$PY $ST input HDMI1
$PY $ST picture mode=Movie   # use um id da lista picture_modes do status
$PY $ST apps
$PY $ST launch <appId>
```

O app do menu bar fala com isto pelo `home_helper.py` (`st.status`, `st.inputs`, `st.set_input`, `st.picture`, `st.apps`, `st.launch`).

## Achar o app ID do Stremio

Nenhuma capability publicada da TV lista os apps instalados. Para descobrir o ID:

1. Abra o Stremio na TV com o controle.
2. Rode `$PY $ST apps` e veja `current.tv_channel_name` (em muitas TVs ele mostra o app em primeiro plano).
3. Confirme o ID pela rede local: `curl http://192.168.0.23:8001/api/v2/applications/<ID>`.

## Problemas conhecidos

- **"redirect_uri could not be validated" ou 403 na autorização**: confira se a data de nascimento da conta Samsung dá 18 anos ou mais, faça logout e login de novo. Use o redirect do httpbin; `localhost` costuma falhar.
- **Brilho, contraste, nitidez e cor**: não existe capability documentada para TV. `set_picture` só muda o picture mode e avisa o resto.
  Se a TV tiver `execute`, dá para testar `ocf-get`/`ocf-set` com um href capturado do app, mas isso é experimental.
- **"authorisation expired"**: rode `smartthings_auth.py` de novo e escolha reaproveitar o client.
