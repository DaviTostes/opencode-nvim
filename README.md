# opencode-nvim

Use [OpenCode](https://opencode.ai) from inside Neovim **without losing sight of
your code**.

The panel is a float in the bottom right corner that **does not steal focus**:
the answer streams in while you keep reading and editing. When the AI wants to
touch a file the diff appears in a popup and you approve it with `<CR>` — before
anything is written.

- Text, reasoning and tool calls streaming in the panel
- Edit approval with the diff inside the editor (nothing is written unseen)
- Buffers changed by the AI reload on their own, keeping the cursor
- Editor context: `@this`, `@buffer`, `@buffers`, `@diagnostics`, `@diff`
- Sessions shared with `opencode2` (start it in the TUI, continue in Neovim)
- **No required dependencies** — only what ships with Neovim

## Requirements

- Neovim **0.11+** (`vim.uv`, `vim.json`, `vim.base64`, `vim.fs`)
- OpenCode **V2** (`opencode2`) in `PATH`

The plugin talks to the OpenCode HTTP service (the background service the TUI
uses) and starts one if none is running. The HTTP/SSE client is pure Lua on
`vim.uv` — no `curl`, no `plenary`.

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

Without `setup()` the plugin configures itself with the defaults on `VimEnter`.

## Daily use

Four flows cover almost everything:

| I want to... | Do this |
| --- | --- |
| ask about the code in front of me | select it (or not) and `<leader>ta`, type, `<CR>` |
| run a common action | `<leader>tc` and pick: explain this code, find bugs here, write tests, refactor this, document this, explain this file, review my changes, commit message |
| ask for an **edit** | select the code and `<leader>ti`, describe the change, then approve the diff with `<CR>` |
| review what the AI did | `gd` in the panel (or `:OpencodeDiff`); `r` in that popup undoes the turn |

You don't have to type `@this`: with `context.auto = true` (default) every
prompt carries a header — `[editor context] file=... cursor=...`, the selected
code, the filetype, `modified=true` and the diagnostics count — so "look at this
file" works on the file you're looking at. A placeholder (`@this`, `@diff`, ...)
skips the automatic part.

A typical edit loop: `<leader>ti` on the function, "make it accept a callback",
`<CR>`, then approve the diff with `<CR>`. The buffer reloads keeping your
cursor, and `u` still undoes it.

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
| `<leader>tu` | undo the last turn (`u` in the review popup too) |
| `<leader>tc` | pick a ready-made action |
| `<leader>ti` | edit this (selection or file) with an instruction |

In the panel: `i`/`a`/`<CR>` opens the prompt, `q`/`<Esc>` closes it, `<C-c>`
interrupts, `gd` shows the diff, `r` resends the last prompt, `G` jumps to the
end. While a turn runs the panel shows `▸ thinking…` and the title counts the
elapsed time (`● 12s`).

How the panel reads:

```
❯ your message

▸ thinking (12 lines, zo opens)      <- reasoning, folded by default
▸ read /path/to/file ✓               <- tool call and its status
the answer text                      <- plain text, no gutter
```

Only reasoning is folded; `zo` opens one block, `zR` all. Reasoning is guttered
(`│ `) so it stays distinguishable when expanded. After sending, the prompt
stays open for the next message (`ui.focus_after_submit = "input"`; `"code"`
jumps back to your code, `"panel"` lands in the panel).

In the prompt: `<CR>` sends, `<C-j>` newline, `<C-x><C-o>` completes files and
placeholders, `<Esc>` closes the prompt **and** the panel (`ui.escape_closes =
"input"` keeps the panel open). `:Opencode` / `<leader>tt` toggles the whole UI.

In the diff/permission popup: `<CR>` (or `y`) allows once, `A` allows always,
`x` rejects (with an optional message), `<Esc>`/`q` decides later. In the turn
review popup: `<CR>` keeps the changes, `u` undoes the turn.

These popups are ordinary buffers: `j`/`k`, `<C-d>`/`<C-u>`, `/`, `gg`/`G` and
yanking all work (the actions deliberately avoid those keys), and the available
keys are always visible in the float footer.

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

By default the plugin uses **the model you last used in the TUI**
(`~/.local/state/opencode/model.json`). The server default is often a free tier
model that refuses to run — on `opencode-go`, `opencode/union-alpha` answers
`OpenCode 1.17.0 or newer is required to use the free tier`, which makes the
first prompt silently do nothing.

To pin a model:

```lua
model = { providerID = "opencode-go", id = "deepseek-v4.1-flash" }
```

Switch in a live session with `<leader>tm`. A configured model missing from the
project catalogue is dropped with a warning instead of breaking the session.

## Edit approval

The plugin tries the safest mode first and degrades gracefully:

1. **Pre-approval (the good one).** With an agent that asks for approval on
   `edit` (or `shell`), edits **pause** and the diff shows up in Neovim; the
   file is written only after your `<CR>`. The plugin detects such an agent, and
   if there is none `:OpencodeApprovalAgent` creates one (`opencode-nvim`) in
   the OpenCode config:

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

   Then `opencode2 service restart`. Check with `:OpencodeApproval`.

2. **Review after the turn (no config needed).** When the turn finishes the
   plugin shows the diff in a popup: `<CR>` keeps it, `r` **undoes the turn**
   (restores the files), `<Esc>` closes. `:OpencodeUndo` does the same from
   outside the popup. Warn only with `approval = { review = "notify" }`, or
   disable with `approval = { review = false }`.

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

All options, commands, events and the Lua API are documented in
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

`mini.pick` (pickers), `mini.icons` and `mini.diff` are used **if** installed;
nothing is required.

## Beta V2 notes (what the plugin works around)

The beta V2 API differs from the published OpenAPI. These were verified against
`0.0.0-beta-19271` and handled in the code:

| Observation | Workaround in the plugin |
| --- | --- |
| `permissions` in `POST /api/session` is ignored | approval through an **agent** (`agents.<id>.permissions`) |
| `POST .../permission/{id}/reply` wants `{"reply": "once"}`, not `{"decision": ...}` | sends `reply`, falls back to `decision` on a 400 |
| `GET /api/agent` is location-scoped, incomplete until the location loads | calls `GET /api/location` first and retries until the agent shows up |
| `GET /api/session/{id}/diff` is unrouted (empty 404) | falls back to `GET /api/vcs/diff?mode=working` |
| A normal turn **does not** emit `session.idle` | end of turn is `session.execution.succeeded/failed/interrupted` |
| `session.text.ended` carries the full part text | the renderer repairs dropped deltas with it |
| Snapshots (turn diff, restore on revert) rely on **git** | falls back to the working tree diff and warns outside a repo |
| The `opencode-go` provider is flaky and returns misleading errors ("OpenCode 1.17.0 or newer is required to use the free tier", "Endpoint is unavailable") | the real reason shows in the panel and `r` resends the last prompt |
| A request can hang for minutes with no event | the panel shows the elapsed time, warns at 30s with the last event, and `:OpencodeDoctor` prints the whole state |

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

Beta, written against the (experimental) V2 API. When the server changes,
`:OpencodeEvents` shows exactly what arrived and
`log = { level = "debug", file = "/tmp/opencode-nvim.log" }` records everything.

## License

MIT
