# Luzes (Tuya, controle local)

Controla as 4 lâmpadas (192.168.0.24 a .27) direto pela rede de casa, sem passar pela nuvem da Tuya. O app Smart Life continua funcionando normalmente.

As chaves locais ficam só no 1Password, no item **Tuya Lamps**. Nada de chave em arquivo.

## 1. Parear (uma vez só)

1. No celular, abra o Smart Life: **Eu → Configurações (engrenagem) → Conta e segurança → Código do usuário** (em inglês: *Me → Settings → Account and Security → User Code*). Copie o código.
2. No terminal do Mac:

   ```
   /Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python /Users/rodrigocarneiro/personal/samsung-tv/luzes/pair_lights.py
   ```

3. Cole o User Code. Vai aparecer um QR code no terminal.
4. No Smart Life, aba **Início**, toque no ícone de scan (canto superior direito), leia o QR e confirme o login no celular.
5. O script lista as lâmpadas encontradas (nome, IP, versão) e grava tudo no 1Password (vai pedir Touch ID).

Se o terminal for pequeno e o QR sair cortado, aumente a janela ou diminua a fonte (Cmd -) antes de rodar.

Rodar de novo é seguro: atualiza o mesmo item no 1Password. Precisa rodar de novo se você remover e adicionar uma lâmpada no app (a chave muda) ou renomear as lâmpadas.

## 2. Usar

```
cd /Users/rodrigocarneiro/personal/samsung-tv/luzes
./luzes on                 # liga todas
./luzes off 2              # desliga a lâmpada 2
./luzes toggle sala        # alterna as que têm "sala" no nome
./luzes bright 40          # brilho 40% (0 desliga)
./luzes temp 0             # branco quente (100 = frio)
./luzes color ff8800       # cor em hex (sem o #, o zsh pode achar que é comentário)
./luzes color azul         # ou nome: vermelho, verde, azul, amarelo, laranja, roxo, rosa, ciano, branco
./luzes status             # estado de cada uma
./luzes status --json      # o mesmo em JSON (para o menu ou um app)
./luzes list               # números e nomes
```

Alvo: `all` (padrão), número (ordem do IP, 1 = .24) ou parte do nome.

Cada comando lê o 1Password uma vez (Touch ID na primeira vez da sessão do 1Password).

## Usar a partir de outro código

```python
import sys; sys.path.insert(0, "/Users/rodrigocarneiro/personal/samsung-tv/luzes")
import luzes
luzes.on("all")
luzes.set_brightness(30, "sala")
luzes.status()   # lista de dicts: name, ok, on, mode, brightness, temp, color, ip
```

## Se der erro

- **"Sem dados no 1Password"**: rode o pareamento (passo 1).
- **"sem resposta valida"**: a lâmpada está desligada no interruptor, ou a chave mudou. Teste no app; se no app funciona, rode o pareamento de novo.
- **IP mudou** (roteador trocou o IP): o script procura a lâmpada pelo id na rede e tenta de novo sozinho. Para fixar, reserve os IPs no roteador.

## Plano B: conta de desenvolvedor Tuya

Só se o login por QR não devolver as chaves:

1. Crie conta em https://iot.tuya.com, crie um Cloud Project com data center **Central Europe**, e em *Devices → Link App Account* leia o QR com o Smart Life.
2. Rode `/Users/rodrigocarneiro/personal/samsung-tv/.venv/bin/python -m tinytuya wizard` numa pasta temporária. Ele grava `devices.json`, `tuya-raw.json` e `snapshot.json` **com as chaves em texto puro**: copie para o 1Password e apague esses arquivos logo em seguida.
