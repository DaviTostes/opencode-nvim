# opencode-nvim

Drive OpenCode from Neovim. The panel floats bottom-right and **does not steal
focus**: answers stream while you keep editing.

- Streaming text, reasoning and tool calls
- Edits via a diff you approve in Neovim
- Changed buffers reload on their own, keeping the cursor
- Prompts carry editor context (file, cursor, selection, diagnostics)
- Sessions shared with the `opencode2` TUI
- No dependencies, **no keymaps**: everything is a command

## Requirements

- Neovim 0.11+
- OpenCode V2 (`opencode2`) in `PATH`

## Install

```lua
vim.pack.add({ { src = "https://github.com/<you>/opencode-nvim" } })
require("opencode-nvim").setup({})
```

Local development: `vim.opt.rtp:prepend("/home/toast/opencode-nvim")`.

## Quick start

```
:Opencode          open the panel and the prompt
type, then <CR>    send
<Esc>              close the prompt and the panel
```

That is the whole loop. No keymaps are installed by default; if you want them,
list exactly the ones you want (mapping happens when `setup()` runs, so
`vim.g.mapleader` must be set first):

```lua
vim.g.mapleader = " " -- before setup()
require("opencode-nvim").setup({
  keymaps = {
    enabled = true,
    toggle = "<leader>tt", ask = "<leader>ta", ask_buffer = "<leader>tA",
    edit = "<leader>ti", actions = "<leader>tc", diff = "<leader>td",
    interrupt = "<leader>tx", undo = "<leader>tu",
    sessions = "<leader>ts", models = "<leader>tm", agents = "<leader>tg",
    events = "<leader>te",
  },
})
```

## Commands

| Command | What it does |
| --- | --- |
| `:Opencode` | open/close the panel |
| `:OpencodeClose` | close the panel |
| `:OpencodeAsk [text]` | ask; with a range it sends the selection |
| `:OpencodeEdit` | ask for a change in the selection (or file) |
| `:OpencodeActions` | pick a ready-made action |
| `:OpencodeResend` | send the last prompt again |
| `:OpencodeInterrupt` | interrupt the running turn |
| `:OpencodeUndo` | undo the last turn and restore the files |
| `:OpencodeDiff` | diff of the last turn (or of the working tree) |
| `:OpencodeClear` | clear the panel |
| `:OpencodeNew` | new session in this directory |
| `:OpencodeAttach {id}` | attach an existing session |
| `:OpencodeSessions` | pick a session |
| `:OpencodeModels` / `:OpencodeAgents` | pick the model / agent |
| `:OpencodeApproval` | in-editor approval status |
| `:OpencodeApprovalAgent` | create the approval agent in the OpenCode config |
| `:OpencodePermissions` | decide permissions you left for later |
| `:OpencodeDoctor` | diagnose a turn that never answers |
| `:OpencodeHealth` / `:OpencodeEvents` / `:OpencodeLog` | connection, event log, log level |

`:OpencodeAsk` and `:OpencodeEdit` accept a range, so from visual mode just hit
`:` and they show up as `:'<,'>OpencodeAsk`.

## Tips

- **Ask about what you are looking at.** Select the code and run
  `:'<,'>OpencodeAsk`, or call `:OpencodeAsk` with the cursor on a line. The
  prompt automatically gets `[editor context] file=... cursor=...` plus the
  selected code, the filetype, `modified=true` and the diagnostics count — so
  "is this right?" works without naming anything.
- **Make it write code.** `:'<,'>OpencodeEdit` then describe the change
  ("accept a callback"). The agent proposes, you see the diff, `<CR>` approves,
  the file is written and the buffer reloads keeping your cursor. `u` still
  undoes the buffer if you change your mind.
- **One pick instead of typing.** `:OpencodeActions` has explain this code,
  find bugs here, write tests, refactor this, document this, explain this file,
  review my changes, commit message. It pre-fills the prompt so you can edit it
  before sending.
- **Review a turn.** `:OpencodeDiff` opens the diff; `u` inside that popup
  undoes the whole turn (files restored), `<CR>` keeps it.
- **A turn that never answers.** The panel counts the elapsed time and warns at
  30s showing the last event of that session. `<C-c>` interrupts, `r` in the
  panel (or `:OpencodeResend`) sends again, and `:OpencodeDoctor` prints the
  server, the stream, the session state, the last events and the last nvim
  error (`:messages` has the full history).
- **Pick a good model.** The plugin uses the model you last used in the TUI. The
  server default can be a free-tier model that refuses to run; pin one with
  `model = { providerID = "...", id = "..." }` or pick it live with
  `:OpencodeModels`.
- **Reasoning is folded.** Each reasoning run shows a `▸ thinking` header with
  the block folded right below it; `zo` opens one, `zR` opens all. Answers are
  never buried in thinking.
- **Share with the TUI.** `:OpencodeSessions` (or `:OpencodeAttach ses_...`)
  attaches to any session, including one already running in the terminal.
- **In the panel:** `i`/`a`/`<CR>` prompt · `q`/`<Esc>` close · `<C-c>`
  interrupt · `gd` diff · `r` resend · `G` go to the end.
- **In the popups:** `<CR>`/`y` allow once · `A` allow always · `x` reject ·
  `<Esc>`/`q` later. They are normal buffers — `j`/`k`, `<C-d>`, `/` and `gg`
  work, and the keys are listed in the footer.
- **Undo needs git.** Turn diffs and file restores use OpenCode snapshots, which
  use git; outside a repository the diff falls back to the working tree.

## Context markers (optional)

`@this`, `@buffer`, `@buffers`, `@diagnostics`, `@diff` expand to code, files,
buffers, diagnostics and `git diff`. You rarely need them: `context.auto`
already prepends the header and the selection. Typing one skips the automatic
part.

## Configuration

```lua
require("opencode-nvim").setup({
  agent = "build",                        -- default agent
  model = nil,                            -- nil = the last model used in the TUI
  approval = {
    review = "popup",                     -- "popup" | "notify" | false
    agent = "opencode-nvim",              -- agent whose rules ask for approval
    auto_detect = true,                   -- use any agent that asks
  },
  reload = { enabled = true },            -- reload buffers the AI changes
  context = { auto = true },              -- prepend the editor context
  ui = {
    panel = { width = 0.42, height = 0.32, max_width = 100, max_height = 22 },
    focus_after_submit = "input",         -- "code" | "panel" | "input"
    escape_closes = "all",                -- <Esc> closes prompt + panel
  },
})
```

Everything (options, commands, events, Lua API, the V2 beta workarounds) is in
[`doc/opencode-nvim.txt`](doc/opencode-nvim.txt): `:help opencode-nvim`.

## Tests

```sh
make test           # HTTP + SSE + UI + discovery against a fake server (no tokens)
make e2e            # real protocol: text streaming (one tiny prompt)
make e2e-panel      # real interactive flow through the panel (one prompt)
make e2e-approval   # real approval flow: permission popup + revert (one prompt)
make probe          # config/agents/permissions probe (no tokens)
make probe-hang     # what the server does during a turn that never answers
make lint           # syntax check of every .lua file
```

## License

MIT
