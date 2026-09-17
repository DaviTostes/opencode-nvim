# opencode-nvim

Drive OpenCode from Neovim. The panel floats bottom-right and never steals
focus: answers stream while you keep editing.

- Streaming text, reasoning and tool calls
- Edits through a diff you approve in Neovim
- Changed buffers reload on their own, keeping the cursor
- Prompts carry editor context (file, cursor, selection, diagnostics)
- Sessions shared with the `opencode2` TUI
- No dependencies, no default keymaps: everything is a command

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
:Opencode          show/hide the panel and focus it
:OpencodeAsk       open the prompt and type
<CR>               send
<Esc>              leave
```

The panel takes the cursor when it opens, so its keys (`gd` diff, `r` resend,
`zo` unfold, `q` close) work right away; `ui.focus_on_open = false` leaves your
cursor in the code instead. Nothing automatic moves it: streaming never pulls
you in, and after sending you stay in the prompt (`ui.focus_after_submit =
"input"`: it is never closed on submit, only cleared). `<Esc>` closes the prompt
and hands the focus to the panel, where `q` closes the UI; `:OpencodeFocus`
switches between the panel and your code. The prompt only opens on purpose
(`:OpencodeAsk`, `:OpencodeEdit`, `:OpencodeActions`, or `i` in the panel) and
starts empty (`i` keeps your draft). `<C-Up>`/`<C-Down>` walks the history.

No keymaps are installed by default; list the ones you want (`vim.g.mapleader`
must be set before `setup()`):

```lua
vim.g.mapleader = " " -- before setup()
require("opencode-nvim").setup()
```

## Commands

| Command | What it does |
| --- | --- |
| `:Opencode` | show/hide the panel (focuses it) |
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
| `:OpencodeQuestion` | show the question waiting for an answer |
| `:OpencodeFocus` | switch the cursor between the panel and your code |
| `:OpencodeDoctor` | diagnose a turn that never answers |
| `:OpencodeHealth` / `:OpencodeEvents` / `:OpencodeLog` | connection, event log, log level |

`:OpencodeAsk` and `:OpencodeEdit` accept a range, so from visual mode just hit
`:` and they show up as `:'<,'>OpencodeAsk`.

## Tips

- **Ask about what you are looking at.** Select code and run `:'<,'>OpencodeAsk`,
  or call `:OpencodeAsk` with the cursor on a line. The prompt gets
  `[editor context] file=... cursor=...` plus the selection, filetype,
  `modified=true` and the diagnostics count, so "is this right?" just works.
- **Make it write code.** `:'<,'>OpencodeEdit` then describe the change. The
  agent proposes, you see the diff, `<CR>` approves, the file is written and the
  buffer reloads keeping your cursor; `u` still undoes the buffer.
- **One pick instead of typing.** `:OpencodeActions` offers explain this code,
  find bugs here, write tests, refactor this, document this, explain this file,
  review my changes, commit message. It pre-fills the prompt for editing.
- **Review a turn.** A turn that touches files just notifies you
  (`2 file(s) changed ...`) without stealing focus. `:OpencodeDiff` opens the
  diff when you want it; `u` there undoes the whole turn, `<CR>` keeps it. Prefer
  the old always-popup behaviour? `approval = { review = "popup" }`.
- **You control the focus.** Opening the panel puts the cursor in it; sending
  leaves you in your code; streaming never pulls you in. The only automatic
  focus grab is a permission request, because the turn is paused on your answer.
- **A turn that never answers.** The panel warns at 30s showing the last event.
  `<C-c>` interrupts, `r` (or `:OpencodeResend`) sends again, and
  `:OpencodeDoctor` prints the server, stream, session state, last events and
  last nvim error (`:messages` has the full history).
- **Pick a good model.** The plugin uses the model you last used in the TUI. Pin
  one with `model = { providerID = "...", id = "..." }` or pick it live with
  `:OpencodeModels` (the active choice is marked `●`, same for `:OpencodeAgents`).
- **Reasoning is folded.** Each run shows a `▸ thinking` header with the block
  folded below; `zo` opens one, `zR` opens all.
- **Share with the TUI.** `:OpencodeSessions` (or `:OpencodeAttach ses_...`)
  attaches to any session, including one running in the terminal, and only
  renders the session it is attached to.
- **In the panel:** `i`/`a`/`<CR>` prompt · `q`/`<Esc>` close · `<C-c>` interrupt ·
  `gd` diff · `r` resend · `G` go to the end. The footer lists them too.
- **The panel follows the stream**, focused or not. Scroll up to read and it
  stops following; `G` brings it back.
- **In the popups:** `<CR>`/`y` allow once · `A` allow always · `x` reject ·
  `<Esc>`/`q` later. They are normal buffers, and the footer lists the keys.
- **Undo needs git.** Turn diffs and file restores use OpenCode snapshots
  (git); outside a repository the diff falls back to the working tree.

## Context markers (optional)

`@this`, `@buffer`, `@buffers`, `@diagnostics`, `@diff` expand to code, files,
buffers, diagnostics and `git diff`. You rarely need them: `context.auto` already
prepends the header and the selection. Typing one skips the automatic part.

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

Everything else (options, commands, events, Lua API, V2 beta workarounds) is in
[`doc/opencode-nvim.txt`](doc/opencode-nvim.txt): `:help opencode-nvim`.

## Tests

```sh
make test           # HTTP + SSE + UI + discovery against a fake server (no tokens)
make e2e            # real protocol: text streaming (one tiny prompt)
make e2e-panel      # real interactive flow through the panel (one prompt)
make e2e-approval   # real approval flow: permission popup + revert (one prompt)
make e2e-form       # real question flow: the agent asks, the popup answers
make ui-smoke       # real UI in tmux: focus and insert mode are never lost
make probe          # config/agents/permissions probe (no tokens)
make probe-hang     # what the server does during a turn that never answers
make lint           # syntax check of every .lua file
```

## License

MIT
