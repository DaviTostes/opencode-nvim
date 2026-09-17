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

Optional: [mini.pick] for the session/model/agent pickers, which otherwise fall
back to `vim.ui.select`.

## Install

```lua
vim.pack.add({ { src = "https://github.com/<you>/opencode-nvim" } })
require("opencode-nvim").setup({})
```

Local development: `vim.opt.rtp:prepend("/home/toast/opencode-nvim")`.

## Quick start

```
:Opencode          show/hide the panel and focus it
:OpencodeAsk       open the prompt and type
<CR>               send (you stay in the prompt)
<Esc>              close the prompt, focus the panel
```

Opening the panel takes the cursor, so its keys (`gd` diff, `r` resend, `zo`
unfold, `q` close) work right away; `ui.focus_on_open = false` keeps your cursor
in the code instead. Nothing *automatic* ever moves it, and after sending you
stay where `ui.focus_after_submit` points (`code` by default). The prompt always
starts empty; `<C-Up>`/`<C-Down>` walks the history.

No keymaps are installed by default. To add some (set `vim.g.mapleader` before
`setup()`):

```lua
vim.g.mapleader = " "
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
| `:Opencode` | show/hide the panel (focuses it) |
| `:OpencodeClose` | close the panel |
| `:OpencodeFocus` | switch the cursor between the panel and your code |
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

- **Ask about what you are looking at.** Select code and run
  `:'<,'>OpencodeAsk`, or `:OpencodeAsk` with the cursor on a line. The prompt
  gets `[editor context] file=... cursor=...` plus the selected code, filetype,
  `modified=true` and the diagnostics count.
- **Make it write code.** `:'<,'>OpencodeEdit` then describe the change; `<CR>`
  approves the diff, the file is written and the buffer reloads keeping your
  cursor. `u` still undoes the buffer.
- **One pick instead of typing.** `:OpencodeActions` pre-fills the prompt with
  explain this code, find bugs here, write tests, refactor this, document this,
  explain this file, review my changes, commit message.
- **Review a turn.** Changed files just show a notification. `:OpencodeDiff`
  opens the diff when you want it: `u` undoes the turn (files restored), `<CR>`
  keeps it. `approval = { review = "popup" }` restores the old always-popup
  behaviour.
- **You control the focus.** Opening the panel takes the cursor (you asked for
  it) and after sending you stay in the prompt, ready for the next message
  (`ui.focus_after_submit = "input"`). `<Esc>` closes the prompt and hands the
  focus to the panel, where `q` closes the UI. `:OpencodeFocus` switches between
  the panel and your code at any time — floats are ordinary windows, so
  `nvim_set_current_win` or `:wincmd w` work too, but this is the round trip.
  Streaming never pulls you in, and the only automatic focus grab is a permission
  request, since the turn is paused.
- **A turn that never answers.** The panel counts elapsed time and warns at 30s
  with the last event. `<C-c>` interrupts, `r` (or `:OpencodeResend`) resends,
  `:OpencodeDoctor` prints the server, stream, session state and last errors.
- **Pick a good model.** Uses the model you last used in the TUI; pin one with
  `model = { providerID = "...", id = "..." }` or pick live with
  `:OpencodeModels` (the one in use is marked `●`).
- **Reasoning is folded.** Each run shows a `▸ thinking` header with the block
  folded below it; `zo` opens one, `zR` opens all.
- **Share with the TUI.** `:OpencodeSessions` (or `:OpencodeAttach ses_...`)
  attaches to any session, including one already running in the terminal.
- **In the panel:** `i`/`a`/`<CR>` prompt · `N` new session · `q`/`<Esc>` close ·
  `<C-c>` interrupt · `gd` diff · `r` resend · `G` go to the end — all listed in
  the footer.
- **The panel follows the stream** while you keep editing. Scroll up to stop
  following; `G` brings it back to the end.
- **In the popups:** `<CR>`/`y` allow once · `A` allow always · `x` reject ·
  `<Esc>`/`q` later. They are normal buffers, so motions and `/` work.
- **Undo needs git.** Turn diffs and file restores use OpenCode snapshots, which
  use git; outside a repository the diff falls back to the working tree.

## Context markers (optional)

`@this`, `@buffer`, `@buffers`, `@diagnostics`, `@diff` expand to code, files,
buffers, diagnostics and `git diff`. You rarely need them: `context.auto`
already prepends the header and the selection; typing one skips the automatic
part.

## Configuration

```lua
require("opencode-nvim").setup({
  agent = "build",                        -- default agent
  model = nil,                            -- nil = the last model used in the TUI
  approval = {
    review = "notify",                    -- "notify" | "popup" | false
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
