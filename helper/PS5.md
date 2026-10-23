# PS5: ligar e pôr em repouso pelo Mac

Usa o protocolo do Remote Play via `pyremoteplay` 0.7.6 (instalado no `.venv` junto com `pyee<12`, porque o pyee 12+ quebra o import).

- **Status**: pacote de descoberta UDP 9302 (200 = ligado, 620 = repouso). Só leitura, não precisa de pareamento.
- **Ligar**: pacote DDP `WAKEUP` com a credencial do registro.
- **Repouso**: abre uma sessão Remote Play curta, manda o comando de standby e fecha. O PS5 pode mostrar por um instante o aviso de Remote Play conectado.

O registro (RegistKey, RP-Key e o ID do console) fica só no item **"PS5 Remote Play"** do 1Password, campo `credential`. Nada vai para disco, argv ou tela.

## Parear (uma vez só)

1. Ligue o PS5 de verdade (não em repouso).
2. No PS5: Configurações › Sistema › Reprodução Remota › ative **Ativar Reprodução Remota**.
3. Para ligar pelo Mac depois: Configurações › Sistema › Economia de energia › Recursos disponíveis no Modo de Repouso › **Manter conectado à internet** e **Permitir ligar o PS5 pela rede**.
4. No Terminal:

   ```
   /Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python /Users/rodrigocarneiro/personal/samsung-tv/helper/ps5_pair.py
   ```

5. O script pega o account ID da PSN pelo item "PSN NPSSO" se ele existir. Se não, oferece o login da Sony no navegador (cola a URL da página `redirect`, sem eco) ou digitar o ID.
6. Quando ele pedir, abra no PS5 Reprodução Remota › **Vincular dispositivo** e digite o PIN de 8 dígitos (não aparece na tela).

## Uso

```
PY=/Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python
C=/Users/rodrigocarneiro/personal/samsung-tv/helper/ps5_control.py
$PY $C status
$PY $C wake          # espera até 40 s o PS5 responder 200; --no-wait só manda
$PY $C standby
```

O app do menu bar chama `ps5.wake {wait}` e `ps5.standby` pelo `home_helper.py`.
IP diferente: `PS5_HOST=192.168.0.x`.

## Problemas conhecidos

- **"Device not in Register Mode"**: a tela Vincular dispositivo não estava aberta ou o PIN expirou. Abra de novo e rode o script.
- **Registro falha com 403 ou similar**: PIN errado, ou a conta PSN não é a que está logada no PS5.
- **NPSSO expirado**: o script cai para o login da Sony. Para o NPSSO, pegue um novo e atualize "PSN NPSSO".
- **`wake_timeout`**: confira os itens do passo 3 e se o PS5 está em repouso (luz laranja), não desligado. Desligado de verdade não acorda pela rede.
- **`session_failed` no standby**: o registro deixou de valer (resetou o PS5, removeu o dispositivo, trocou de conta). Pareie de novo; o script oferece substituir o item.
- **`standby_timeout`**: alguns jogos ou downloads seguram o repouso. Tente pelo controle.
- **Status sempre `unreachable`**: o PS5 responde para a porta local 9303. Se outra coisa estiver presa nela, a biblioteca usa uma porta aleatória e a resposta pode não chegar; feche o que estiver usando a 9303.
