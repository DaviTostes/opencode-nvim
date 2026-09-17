# opencode-nvim

Drive OpenCode from Neovim. The panel floats bottom-right and streams answers
while you keep editing.

## Requirements

Neovim 0.11+ and OpenCode V2 (`opencode2`) in `PATH`.

## Install

```lua
vim.pack.add({ { src = "https://github.com/<you>/opencode-nvim" } })
require("opencode-nvim").setup({})
```

Local dev: `vim.opt.rtp:prepend("/home/toast/opencode-nvim")`.

## Quick start

```
:Opencode      show/hide the panel
:OpencodeAsk   open the prompt and type
<CR> send      <Esc> leave
```

The panel takes the cursor, so its keys (`gd` diff, `r` resend, `zo` unfold,
`q` close) work right away and streaming never pulls you away;
`:OpencodeFocus` switches between panel and code. `:OpencodeAsk` and
`:OpencodeEdit` accept a range. No keymaps by default — set `vim.g.mapleader`
before `setup()`.

## Commands

| Command | What it does |
| --- | --- |
| `:Opencode` / `:OpencodeClose` | show/hide (focuses) · close the panel |
| `:OpencodeAsk [text]` / `:OpencodeEdit` | ask · change the selection or file |
| `:OpencodeActions` | pick a ready-made action |
| `:OpencodeResend` / `:OpencodeInterrupt` / `:OpencodeUndo` | resend · interrupt · undo the last turn |
| `:OpencodeDiff` / `:OpencodeClear` | diff of the last turn · clear the panel |
| `:OpencodeNew` / `:OpencodeAttach {id}` / `:OpencodeSessions` | new · attach · pick a session |
| `:OpencodeModels` / `:OpencodeAgents` | pick the model / agent |
| `:OpencodeApproval` / `:OpencodeApprovalAgent` / `:OpencodePermissions` | approval status · create the approval agent · decide pending permissions |
| `:OpencodeQuestion` | show the waiting question (digit picks, `o` types, `<Esc>` later) |
| `:OpencodeFocus` / `:OpencodeDoctor` | move the cursor · diagnose a stuck turn |
| `:OpencodeHealth` / `:OpencodeEvents` / `:OpencodeLog` | connection · event log · log level |

## Behavior

- **Context.** `:'<,'>OpencodeAsk`, or asking on a line, sends the file, cursor,
  selection, filetype, `modified` flag and diagnostic count. `@this`,
  `@buffer`, `@buffers`, `@diagnostics`, `@diff` are optional markers.
- **Edits.** `:'<,'>OpencodeEdit` describes a change; `<CR>` approves the diff,
  writes the file and reloads the buffer keeping your cursor (`u` undoes).
  `:OpencodeActions` offers explain, find bugs, tests, refactor, docs, commit.
- **Review.** File-only turns notify without stealing focus; `:OpencodeDiff`
  opens the diff (`u` undoes the turn, `<CR>` keeps it), or set
  `approval = { review = "popup" }`. Undo needs git; otherwise the diff falls
  back to the working tree.
- **Stuck turn.** The panel warns at 30s; `<C-c>` interrupts, `r` resends, and
  `:OpencodeDoctor` prints the server, stream, session, last events and error.
- **Models.** Uses your last TUI model; pin it with
  `model = { providerID = "...", id = "..." }` or pick with `:OpencodeModels`.
  Reasoning is written when the part finishes (no flicker, no fragments) and
  folds under `▸ thinking` (`zo`/`zR`).
- **Keys.** Panel: `i`/`a`/`<CR>` prompt · `q`/`<Esc>` close · `<C-c>` interrupt ·
  `gd` diff · `r` resend · `G` end (scroll up to stop following). Popups:
  `<CR>`/`y` allow once · `A` always · `x` reject · `<Esc>`/`q` later.

## Configuration

```lua
require("opencode-nvim").setup({
  agent = "build",                        -- default agent
  model = nil,                            -- nil = the last model used in the TUI
  approval = {
    review = "notify",                    -- "notify" | "popup" | false
    -- approval = false,                  -- no review and no pre-approval dialog at all
    agent = "opencode-nvim",              -- agent whose rules ask for approval
    auto_detect = true,                   -- use any agent that asks
  },
  reload = { enabled = true },            -- reload buffers the AI changes
  context = { auto = true },              -- prepend the editor context
  ui = {
    panel = { width = 0.42, height = 0.32, max_width = 100, max_height = 22 },
    focus_on_open = true,                 -- opening the panel focuses it
    focus_after_submit = "input",         -- "input" | "code" | "panel"
    escape_closes = "panel",              -- <Esc>: "panel" | "all" | "input"
    panel = { tool_output = true },       -- false: no tool bodies (no diffs in the panel)
  },
})
```

Options, keymaps, events and the Lua API are in
[`doc/opencode-nvim.txt`](doc/opencode-nvim.txt): `:help opencode-nvim`.

## Tests

`make test` and `make lint` run offline; `make e2e*`, `make ui-smoke` and
`make probe*` use the real protocol. See the `Makefile`.

## License

MIT
