# opencode-nvim

Use [OpenCode](https://opencode.ai) from inside Neovim **without losing sight of
your code**.

Instead of opening a terminal with the TUI (which takes over the screen), the
panel is a float anchored to the bottom right corner that **does not steal
focus**: the answer streams in while you keep reading and editing the file. When
the AI wants to touch a file, the diff shows up in a popup inside Neovim and you
approve it with `<CR>` — before anything is written.

- Text, reasoning and tool calls streaming in the panel
- Edit approval with the diff inside the editor (nothing is written unseen)
- Buffers changed by the AI reload on their own, keeping the cursor
- Editor context: `@this`, `@buffer`, `@buffers`, `@diagnostics`, `@diff`
- Sessions shared with `opencode2` (start it in the TUI, continue in Neovim)
- **No required dependencies** — only what ships with Neovim

## Requirements

- Neovim **0.11+** (uses `vim.uv`, `vim.json`, `vim.base64`, `vim.fs`)
- OpenCode **V2** (`opencode2`) in `PATH`

The plugin talks to the OpenCode HTTP service (the same background service the
TUI uses) and starts one if none is running. The HTTP/SSE client is pure Lua on
top of `vim.uv` — no `curl`, no `plenary`.

## Install

With `vim.pack`:

```lua
vim.pack.add({ { src = "https://github.com/<you>/opencode-nvim" } })
require("opencode-nvim").setup({})
```

Local development (points at this directory):

```lua
vim.opt.rtp:prepend("/home/toast/opencode-nvim")
require("opencode-nvim").setup({})
```

If `setup()` is never called the plugin configures itself with the defaults on
`VimEnter`.

## Daily use

Four flows cover almost everything:

| I want to... | Do this |
| --- | --- |
| ask about the code in front of me | select it (or not) and `<leader>ta`, type, `<CR>` |
| run a common action | `<leader>tc` and pick: explain this code, find bugs here, write tests, refactor this, document this, explain this file, review my changes, commit message |
| ask for an **edit** | select the code and `<leader>ti`, describe the change, then approve the diff with `<CR>` |
| review what the AI did | `gd` in the panel (or `:OpencodeDiff`); `r` in that popup undoes the turn |

You do **not** have to type `@this`: with `context.auto = true` (default) every
prompt carries a compact header — `[editor context] file=... cursor=...` plus
the selected code, the filetype, `modified=true` and the diagnostics count — so
"look at this file" or "is this right?" work with the file you are looking at.
Typing a placeholder (`@this`, `@diff`, ...) instead skips the automatic part.

A typical edit loop: put the cursor on the function, `<leader>ti`, type "make it
accept a callback", `<CR>`, the diff popup appears, `<CR>` approves, the buffer
reloads keeping your cursor, and `u` still undoes it if you change your mind.

## Usage

| Keymap | Action |
| --- | --- |
| `<leader>tt` | open/close the panel and focus the prompt |
| `<leader>ta` | ask (with a visual selection it is used as `@this`) |
| `<leader>tA` | ask with the whole buffer |
| `<leader>ts` | pick a session |
| `<leader>tm` | pick a model |
| `<leader>tg` | pick an agent |
| `<leader>td` | diff of the last turn |
| `<leader>tx` | interrupt |
| `<leader>tu` | undo the last turn |
| `<leader>tc` | pick a ready-made action |
| `<leader>ti` | edit this (selection or file) with an instruction |

In the panel: `i`/`a`/`<CR>` opens the prompt, `q`/`<Esc>` closes it, `<C-c>`
interrupts, `gd` shows the diff, `r` resends the last prompt (handy when the
provider hiccups), `G` goes to the end. While a turn runs the panel shows
`▸ thinking…` and the title counts the elapsed time (`● 12s`).

How the panel reads:

```
❯ your message

▸ thinking (12 lines, zo opens)      <- reasoning, folded by default
▸ read /path/to/file ✓               <- tool call and its status
the answer text                      <- plain text, no gutter
```

Only reasoning is folded (and only collapsed); `zo` opens one block, `zR` opens
them all. Reasoning is also guttered (`│ `) so it stays distinguishable when
expanded, and each new turn is separated by a blank line. After sending, the
prompt stays open for the next message (`ui.focus_after_submit = "input"`;
use `"code"` to jump back to your code, `"panel"` to land in the panel).

In the prompt: `<CR>` sends, `<C-j>` newline, `<C-x><C-o>` completes files and
placeholders, `<Esc>` closes.

In the diff/permission popup: `<CR>` allows once, `a` allows always, `n` rejects
(with an optional message), `<Esc>` decides later.

Commands:

```
:Opencode               open/close the panel
:OpencodeAsk [text]     open the prompt pre-filled
:OpencodeNew            new session in the current directory
:OpencodeAttach {id}    attach an existing session (including a TUI one)
:OpencodeSessions       pick a session
:OpencodeModels         pick the model
:OpencodeAgents         pick the agent
:OpencodeInterrupt      interrupt the running turn
:OpencodeUndo           undo the last turn
:OpencodeDiff           diff of the last turn
:OpencodeActions        pick a ready-made action
:OpencodeEdit           ask for a change in the selection
:OpencodeApproval       in-editor approval status
:OpencodeApprovalAgent  create the approval agent in the OpenCode config
:OpencodePermissions    decide permissions left for later
:OpencodeEvents         events received from the server (debug)
:OpencodeHealth         live connection check
:OpencodeDoctor         diagnose a turn that never answers
:OpencodeLog [level]    log level (debug/info/warn/error)
```

## Model

By default the plugin uses **the same model you last used in the TUI** (it reads
`~/.local/state/opencode/model.json`). That is not just convenience: the server
default model can be a free tier model that refuses to run — on `opencode-go`
the default `opencode/union-alpha` answers
`OpenCode 1.17.0 or newer is required to use the free tier`, which was the cause
of a first prompt silently doing nothing.

To pin a model:

```lua
model = { providerID = "opencode-go", id = "deepseek-v4.1-flash" }
```

Switching in a live session: `<leader>tm`. A configured model that does not
exist in the project catalogue is dropped with a warning instead of breaking the
session.

## Edit approval

The plugin tries the safest mode first and degrades gracefully:

1. **Pre-approval (the good one).** When an agent whose rules ask for approval on
   `edit` (or `shell`) exists, edits **pause** and the proposed diff shows up in
   Neovim; the file is written only after your `<CR>`. The plugin detects such an
   agent automatically, and if there is none `:OpencodeApprovalAgent` creates one
   (`opencode-nvim`) in the OpenCode config:

   ```jsonc
   {
     "agents": {
       "opencode-nvim": {
         "description": "OpenCode inside Neovim: asks for approval before editing files and running shell",
         "mode": "primary",
         "permissions": [
           { "action": "edit", "resource": "*", "effect": "ask" },
           { "action": "shell", "resource": "*", "effect": "ask" }
         ]
       }
     }
   }
   ```

   Then run `opencode2 service restart`. To check: `:OpencodeApproval`.

2. **Review after the turn (works with no config).** The turn runs and, when it
   finishes, the plugin shows the diff in a popup: `<CR>` keeps it, `r` **undoes
   the turn** (restores the files), `<Esc>` closes it. `:OpencodeUndo` does the
   same from outside the popup. To only warn instead of opening a popup:
   `approval = { review = "notify" }`; to disable it: `approval = { review = false }`.

Neovim's own `u` keeps working on the buffers.

## Configuration

```lua
require("opencode-nvim").setup({
  server = { command = "opencode2", autostart = true },
  agent = "build",                       -- default agent
  approval = {
    review = "popup",                    -- "popup" | "notify" | false
    agent = "opencode-nvim",             -- pre-approval agent
    auto_detect = true,                  -- use any agent that asks for approval
  },
  reload = { enabled = true, set_autoread = true },
  context = { auto = true, max_bytes = 200 * 1024 },
  ui = {
    panel = { width = 0.42, height = 0.32, max_width = 100, max_height = 22, folds = true },
    focus_after_submit = "input",        -- "code" | "panel" | "input"
  },
})
```

Every option, command, event and the Lua API are documented in
[`doc/opencode-nvim.txt`](doc/opencode-nvim.txt) (`:help opencode-nvim`).

## Editor context

| Marker | Expands to |
| --- | --- |
| `@this` | current line, or the visual selection if the prompt came from one |
| `@buffer` | current file (an unsaved buffer is sent as an attachment) |
| `@buffers` | open buffers |
| `@diagnostics` | diagnostics of the buffer/range |
| `@diff` | `git diff` of the session directory |

## How it works

```
Neovim (Lua)                             OpenCode V2
  │  1. discover the service               │
  │     ~/.local/state/opencode/service.json
  │  2. GET /api/health     (basic auth)   │
  │───────────────────────────────────────>│
  │  3. GET /api/location + /api/agent     │  (agents are per location)
  │  4. POST /api/session                  │
  │───────────────────────────────────────>│
  │  5. GET /api/event  (SSE)              │
  │<───────────────────────────────────────│
  │     session.text.delta   → panel       │
  │     session.tool.*       → panel       │
  │     permission.asked     → popup       │
  │     file.edited          → checktime   │
  │     session.execution.*  → end of turn │
```

`mini.pick` (pickers), `mini.icons` and `mini.diff` are used **if** they are
installed; nothing is required.

## Beta V2 notes (what the plugin works around)

While the V2 API is in beta some behaviour differs from the published OpenAPI.
These were verified against `0.0.0-beta-19271` and are handled in the code:

| Observation | Workaround in the plugin |
| --- | --- |
| `permissions` sent to `POST /api/session` is ignored (not stored, not enforced) | approval through an **agent** (`agents.<id>.permissions`) |
| `POST .../permission/{id}/reply` expects `{"reply": "once"}`, not `{"decision": ...}` | sends `reply` and falls back to `decision` on a 400 |
| `GET /api/agent` is location-scoped and only complete after the location is loaded | calls `GET /api/location` first and retries until the expected agent shows up |
| `GET /api/session/{id}/diff` is not routed (empty 404) | falls back to `GET /api/vcs/diff?mode=working` |
| A normal turn **does not** emit `session.idle` | end of turn is `session.execution.succeeded/failed/interrupted` |
| `session.text.ended` carries the full part text | the renderer repairs dropped deltas with it |
| Snapshots (turn diff and file restore on revert) rely on **git** | falls back to the working tree diff and warns outside a repo |
| The `opencode-go` provider is flaky and sometimes returns misleading errors ("OpenCode 1.17.0 or newer is required to use the free tier", "Endpoint is unavailable") | the real reason shows in the panel and `r` resends the last prompt |
| A provider request can hang without any event for minutes | the panel shows the elapsed time, warns at 30s with the last event of the session, and `:OpencodeDoctor` prints the whole state |

## Tests

```sh
make test           # HTTP + SSE + UI against a fake server (no tokens spent)
make e2e            # real protocol: text streaming (one tiny prompt)
make e2e-approval   # real approval flow, with popup and revert (one prompt)
make e2e-panel      # full interactive flow through the panel (one prompt)
make probe          # config/agents/permissions probe (no tokens spent)
make probe-hang     # what the server does during a turn that never answers
make lint           # syntax check of every .lua file
```

## Status

Beta, written against the (experimental) V2 API. If something changes on the
server side, `:OpencodeEvents` shows exactly what arrived and
`log = { level = "debug", file = "/tmp/opencode-nvim.log" }` records everything.

## License

MIT
