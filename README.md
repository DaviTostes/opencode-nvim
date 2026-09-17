# opencode-nvim

Drive OpenCode from Neovim. The panel floats bottom-right and stays out of the
way: answers stream while you keep editing.

## Requirements

Neovim 0.11+ and OpenCode V2 (`opencode2`) in `PATH`.

## Install

```lua
vim.pack.add({ { src = "https://github.com/<you>/opencode-nvim" } })
require("opencode-nvim").setup({})
```

Local development: `vim.opt.rtp:prepend("/home/toast/opencode-nvim")`.

## Quick start

```
:Opencode          show/hide the panel
:OpencodeAsk       open the prompt and type
<CR>               send
<Esc>              leave
```

Opening the panel takes the cursor, so its keys (`gd` diff, `r` resend, `zo`
unfold, `q` close) work right away. Sending leaves the cleared prompt open and
streaming never pulls you in; `:OpencodeFocus` switches between the panel and
your code. `:OpencodeAsk` and `:OpencodeEdit` accept a range, so from visual
mode `:'<,'>OpencodeAsk` works. No keymaps are installed by default; set
`vim.g.mapleader` before `setup()` and see `:help opencode-nvim` for the
`keymaps` options.

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

## Tips

- **Ask about what you are looking at.** Select code and run `:'<,'>OpencodeAsk`,
  or call it with the cursor on a line: the prompt gets `[editor context]
  file=... cursor=...` plus the selection, filetype, `modified=true` and the
  diagnostics count.
- **Make it write code.** `:'<,'>OpencodeEdit` then describe the change; `<CR>`
  approves the diff, the file is written and the buffer reloads keeping your
  cursor (`u` undoes the buffer). `:OpencodeActions` offers ready-made prompts
  (explain, find bugs, write tests, refactor, document, commit message).
- **Review a turn.** A turn that touches files only notifies you without
  stealing focus; `:OpencodeDiff` opens the diff, where `u` undoes the whole turn
  and `<CR>` keeps it. `approval = { review = "popup" }` restores the popup.
- **A turn that never answers.** The panel warns at 30s; `<C-c>` interrupts, `r`
  resends, and `:OpencodeDoctor` prints the server, stream, session state, last
  events and last nvim error.
- **Models and reasoning.** The plugin uses the model you last used in the TUI;
  pin one with `model = { providerID = "...", id = "..." }` or pick live with
  `:OpencodeModels`. Reasoning is folded under a `▸ thinking` header (`zo`/`zR`).
- **Panel and popup keys.** Panel: `i`/`a`/`<CR>` prompt · `q`/`<Esc>` close ·
  `<C-c>` interrupt · `gd` diff · `r` resend · `G` go to the end (scroll up to
  stop following the stream). Popups: `<CR>`/`y` allow once · `A` allow always ·
  `x` reject · `<Esc>`/`q` later.
- **Undo needs git.** Turn diffs and file restores use OpenCode snapshots (git);
  outside a repository the diff falls back to the working tree.

`@this`, `@buffer`, `@buffers`, `@diagnostics` and `@diff` are optional context
markers; `context.auto` already prepends the header and selection.

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

Options, keymaps, events and the Lua API are in
[`doc/opencode-nvim.txt`](doc/opencode-nvim.txt): `:help opencode-nvim`.

## Tests

`make test` and `make lint` run offline; the `make e2e*`, `make ui-smoke` and
`make probe*` targets use the real protocol. See the `Makefile`.

## License

MIT
