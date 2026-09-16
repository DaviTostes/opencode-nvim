# opencode-nvim

Usa o [OpenCode](https://opencode.ai) de dentro do Neovim **sem tirar o código
de vista**.

Em vez de abrir um terminal com o TUI (que toma a tela inteira), o painel é um
float ancorado no canto inferior direito que **não rouba o foco**: a resposta
chega em streaming enquanto você continua lendo e editando o arquivo. Quando a
IA quer mexer num arquivo, o diff aparece num popup dentro do Neovim e você
aprova com `<CR>` — antes de qualquer coisa ser gravada.

- Streaming de texto, raciocínio e ferramentas no painel
- Aprovação de edições com diff no editor (nada é escrito sem você ver)
- Buffers alterados pela IA recarregam sozinhos, preservando o cursor
- Contexto do editor: `@this`, `@buffer`, `@buffers`, `@diagnostics`, `@diff`
- Sessões compartilhadas com o `opencode2` (abra no TUI e continue no Neovim)
- **Zero dependências obrigatórias** — só o que já vem no Neovim

## Requisitos

- Neovim **0.11+** (usa `vim.uv`, `vim.json`, `vim.base64`, `vim.fs`)
- OpenCode **V2** (`opencode2`) no `PATH`

O plugin fala com o serviço HTTP do OpenCode (o mesmo de fundo que o TUI usa) e
sobe um automaticamente se não houver nenhum. O cliente HTTP/SSE é Lua puro
sobre `vim.uv` — sem `curl`, sem `plenary`.

## Instalação

Com `vim.pack`:

```lua
vim.pack.add({ { src = "https://github.com/<voce>/opencode-nvim" } })
require("opencode-nvim").setup({})
```

Desenvolvimento local (aponta para este diretório):

```lua
vim.opt.rtp:prepend("/home/toast/toaster")
require("opencode-nvim").setup({})
```

Sem chamar `setup()`, o plugin se configura sozinho no `VimEnter`.

## Uso

| Keymap | Ação |
| --- | --- |
| `<leader>tt` | abre/fecha o painel e foca o prompt |
| `<leader>ta` | pergunta (com seleção visual, usa como `@this`) |
| `<leader>tA` | pergunta com o buffer inteiro |
| `<leader>ts` | escolhe sessão |
| `<leader>tm` | escolhe modelo |
| `<leader>tg` | escolhe agente |
| `<leader>td` | diff do último turno |
| `<leader>tx` | interrompe |
| `<leader>tu` | desfaz o último turno |

No painel: `i`/`a`/`<CR>` abre o prompt, `q`/`<Esc>` fecha, `<C-c>` interrompe,
`gd` mostra o diff, `G` volta para o fim.
No prompt: `<CR>` envia, `<C-j>` nova linha, `<C-x><C-o>` completa arquivos e
placeholders, `<Esc>` fecha.
No popup de diff/permissão: `<CR>` permite uma vez, `a` permite sempre, `n`
rejeita (com mensagem opcional), `<Esc>` decide depois.

Comandos:

```
:Opencode               abre/fecha o painel
:OpencodeAsk [texto]    abre o prompt já preenchido
:OpencodeNew            sessão nova no diretório atual
:OpencodeAttach {id}    anexa uma sessão existente (inclusive do TUI)
:OpencodeSessions       escolhe sessão
:OpencodeModels         escolhe modelo
:OpencodeAgents         escolhe agente
:OpencodeInterrupt      interrompe a execução
:OpencodeUndo           desfaz o último turno
:OpencodeDiff           diff do último turno
:OpencodeApproval       estado da aprovação no editor
:OpencodeApprovalAgent  cria o agente de aprovação no config do OpenCode
:OpencodePermissions    decide permissões deixadas para depois
:OpencodeEvents         eventos recebidos do servidor (debug)
:OpencodeHealth         checagem ao vivo da conexão
:OpencodeLog [nível]    nível de log (debug/info/warn/error)
```

## Aprovação de edições

O plugin tenta o modo mais seguro primeiro e degrada com elegância:

1. **Pré-aprovação (o ideal).** Se existir um agente cujas regras pedem
   aprovação para `edit` (ou `shell`), as edições **pausam** e o diff da
   proposta aparece no Neovim; só depois do seu `<CR>` o arquivo é gravado.
   O plugin detecta esse agente automaticamente e, se não existir, o comando
   `:OpencodeApprovalAgent` cria um (`opencode-nvim`) no config do OpenCode:

   ```jsonc
   {
     "agents": {
       "opencode-nvim": {
         "description": "OpenCode dentro do Neovim: pede aprovação antes de editar e rodar shell",
         "mode": "primary",
         "permissions": [
           { "action": "edit", "resource": "*", "effect": "ask" },
           { "action": "shell", "resource": "*", "effect": "ask" }
         ]
       }
     }
   }
   ```

   Depois rode `opencode2 service restart`. Para conferir: `:OpencodeApproval`.

2. **Revisão depois do turno (padrão sem config).** O turno roda, e ao terminar
   o plugin mostra o diff num popup: `<CR>` mantém, `r` **desfaz o turno**
   (restaura os arquivos) e `<Esc>` fecha. `:OpencodeUndo` faz o mesmo.
   Para só avisar em vez de abrir popup: `approval = { review = "notify" }`;
   para desligar: `approval = { review = false }`.

O `u` do Neovim continua funcionando normalmente nos buffers.

## Configuração

```lua
require("opencode-nvim").setup({
  server = { command = "opencode2", autostart = true },
  agent = "build",                       -- agente padrão
  approval = {
    review = "popup",                    -- "popup" | "notify" | false
    agent = "opencode-nvim",             -- agente de pré-aprovação
    auto_detect = true,                  -- usa qualquer agente que peça aprovação
  },
  reload = { enabled = true, set_autoread = true },
  context = { auto = true, max_bytes = 200 * 1024 },
  ui = {
    panel = { width = 0.45, height = 0.35, max_width = 110, max_height = 30 },
    focus_after_submit = "code",         -- volta pro código depois de enviar
  },
})
```

Todas as opções, comandos, eventos e a API Lua estão em
[`doc/opencode-nvim.txt`](doc/opencode-nvim.txt) (`:help opencode-nvim`).

## Contexto do editor

| Marcador | Vira |
| --- | --- |
| `@this` | linha atual, ou a seleção visual se o prompt veio dela |
| `@buffer` | arquivo atual (buffer não salvo vai como anexo) |
| `@buffers` | arquivos abertos |
| `@diagnostics` | diagnósticos do buffer/intervalo |
| `@diff` | `git diff` do diretório da sessão |

## Como funciona

```
Neovim (Lua)                            OpenCode V2
  │  1. descobre o serviço                 │
  │     ~/.local/state/opencode/service.json
  │  2. GET /api/health      (basic auth)  │
  │───────────────────────────────────────>│
  │  3. GET /api/location + /api/agent     │  (agents são por location)
  │  4. POST /api/session                  │
  │───────────────────────────────────────>│
  │  5. GET /api/event  (SSE)              │
  │<───────────────────────────────────────│
  │     session.text.delta   → painel      │
  │     session.tool.*       → painel      │
  │     permission.asked     → popup       │
  │     file.edited          → checktime   │
  │     session.execution.*  → fim do turno│
```

`mini.pick` (pickers), `mini.icons` e `mini.diff` são usados **se** estiverem
disponíveis; nada é obrigatório.

## Detalhes do Beta V2 (o que o plugin contorna)

Enquanto a API V2 está em beta, alguns comportamentos divergem do OpenAPI
publicado. Estes foram verificados contra `0.0.0-beta-19271` e estão tratados no
código:

| Observação | Contorno no plugin |
| --- | --- |
| `permissions` enviado em `POST /api/session` é ignorado (não é persistido nem aplicado) | aprovação via **agente** (`agents.<id>.permissions`) |
| `POST .../permission/{id}/reply` espera `{"reply": "once"}` e não `{"decision": ...}` | manda `reply` e cai para `decision` se levar 400 |
| `GET /api/agent` é escopado por location e só fica completo depois que a location é carregada | `GET /api/location` antes, com retry pelo agente esperado |
| `GET /api/session/{id}/diff` não está roteado (404 vazio) | fallback `GET /api/vcs/diff?mode=working` |
| Num turno normal **não** chega `session.idle` | o fim do turno é `session.execution.succeeded/failed/interrupted` |
| `session.text.ended` traz o texto completo da parte | o renderer conserta deltas perdidos com ele |
| Snapshots (diff do turno e restauração de arquivos no revert) usam **git** | o plugin faz fallback pro working tree e avisa quando não é repo |

## Testes

```sh
make test           # HTTP + SSE + UI com servidor falso (sem gastar tokens)
make e2e            # protocolo real: streaming de texto (1 prompt mínimo)
make e2e-approval   # fluxo de aprovação real, com popup e revert (1 prompt)
make probe          # sonda config/agents/permissions (sem gastar tokens)
make lint           # checagem de sintaxe de todos os .lua
```

## Status

Beta, escrito contra a API V2 (experimental). Se algo do servidor mudar,
`:OpencodeEvents` mostra exatamente o que chegou e
`log = { level = "debug", file = "/tmp/opencode-nvim.log" }` grava tudo.

## Licença

MIT
