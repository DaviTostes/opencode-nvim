-- Real-UI smoke test (driven by tests/ui_smoke.sh inside tmux).
--
-- Guards the "never move the focus or the insert mode while I am in the flow"
-- behaviour, which cannot be tested headlessly: without a UI Neovim does not
-- redraw and insert mode is not entered.
--
-- It logs one line per observation. The shell asserts:
--   * no `i@panel`/`R@panel` mode change (insert mode leaking into the panel)
--   * the prompt keeps the window and the focus through the whole flow
--   * the panel follows the stream
--   * a final `DONE` line (so a crashed check cannot pass silently)
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local logfile = os.getenv("UI_SMOKE_LOG") or "/tmp/opencode/ui_smoke.log"
local function log(message)
  local fd = io.open(logfile, "a")
  if not fd then return end
  fd:write(message .. "\n")
  fd:close()
end

local plugin = require("opencode-nvim")
local config = require("opencode-nvim.config")
-- Keep whatever the user's config set (that is the point when running with
-- UI_SMOKE_USER_CONFIG=1); only make the run offline and keymap-free.
local options = config.get()
options.server = { command = "opencode2", autostart = false, url = "http://127.0.0.1:9" }
options.keymaps.enabled = false
plugin.setup(options)
local event = require("opencode-nvim.event")
local panel = require("opencode-nvim.ui.panel")
local session = require("opencode-nvim.session")

local mode_changes = {}

local function where()
  local current = vim.api.nvim_get_current_win()
  if current == panel.state.input.win then return "input" end
  if current == panel.state.win then return "panel" end
  -- anything else that is a float is one of the dialogs (diff/permission/form)
  if vim.api.nvim_win_get_config(current).relative ~= "" then return "popup" end
  return "code"
end

vim.api.nvim_create_autocmd("ModeChanged", {
  callback = function()
    mode_changes[#mode_changes + 1] = string.format("%s@%s", vim.fn.mode(1), where())
  end,
})

vim.api.nvim_create_autocmd("WinEnter", {
  callback = function()
    log(string.format("WINENTER   window=%s mode=%s", where(), vim.fn.mode(1)))
  end,
})

-- Diagnostic: the state around every public panel call.
for _, name in ipairs({ "open", "send", "after_submit", "scroll_to_bottom", "update_title", "submit",
  "close_input", "open_input", "focus", "focus_code", "clear", "set_status", "new_session",
  "retry", "escape" }) do
  local original = panel[name]
  if type(original) == "function" then
    panel[name] = function(...)
      log(string.format("CALL  %-16s before=%s mode=%s", name, where(), vim.fn.mode(1)))
      local result = original(...)
      log(string.format("DONE  %-16s after =%s mode=%s", name, where(), vim.fn.mode(1)))
      return result
    end
  end
end

--- Check the current situation: focus where it should be, no insert mode in the
--- panel, and the panel showing the end of the conversation.
local function check(label, expected_window)
  local which = where()
  local leaks = {}
  for _, change in ipairs(mode_changes) do
    if change:find("^i@panel") or change:find("^R@panel") then leaks[#leaks + 1] = change end
  end
  mode_changes = {}

  local win = panel.state.win
  local shows_end = not (win and vim.api.nvim_win_is_valid(win))
    or vim.fn.line("w$", win) >= vim.fn.line("$", win)

  local ok = which == expected_window and #leaks == 0 and shows_end
  log(string.format("%s %-24s window=%s expected=%s mode=%s panel_insert_leaks=%s panel_shows_end=%s",
    ok and "PASS" or "FAIL", label, which, expected_window, vim.fn.mode(1),
    (#leaks > 0 and table.concat(leaks, ",") or "none"), tostring(shows_end)))
  return ok
end

--- Run from insert mode with <C-o>:lua _G.ui_check()
_G.ui_check = function()
  local ok, err = pcall(function()
    -- offline: an attached session, so events belong to it and nothing hits the net
    session.current = {
      id = "ses_smoke",
      agent = "build",
      approval = false,
      tokens = {},
      cost = 0,
      location = { directory = vim.uv.cwd() },
    }

    local function emit(kind, data)
      event.emit({ type = kind, data = vim.tbl_extend("force", { sessionID = "ses_smoke" }, data or {}) })
      vim.wait(120, function() return false end, 30)
      log(string.format("PROBE %-26s window=%s mode=%s", kind, where(), vim.fn.mode(1)))
    end

    -- 1. content written while typing must not touch the focus or the mode
    local renderer = panel.renderer()
    for i = 1, 80 do
      renderer:note(string.format("line %d", i))
    end
    panel.scroll_to_bottom()
    vim.wait(200, function() return false end, 50)
    check("scroll-while-inserting", "input")

    -- 2. every kind of streaming event must leave the focus alone
    emit("session.text.started")
    emit("session.text.delta", { delta = "hello " })
    emit("session.reasoning.started")
    emit("session.reasoning.delta", { delta = "thinking about it" })
    emit("session.reasoning.ended")
    emit("session.tool.input.started", { id = "c1", name = "read" })
    emit("session.tool.input.ended", { id = "c1", text = '{"filePath":"/tmp/a.lua"}' })
    emit("session.tool.called", { id = "c1", input = { filePath = "/tmp/a.lua" } })
    emit("session.tool.success", { id = "c1", content = { { type = "text", text = "ok" } } })
    emit("session.usage.updated", { cost = 0.01, tokens = { input = 1, output = 2 } })
    emit("session.updated", { title = "renamed" })
    emit("session.model.selected", { model = { providerID = "p", id = "m" } })
    emit("session.execution.succeeded")
    emit("file.edited", { file = "/tmp/a.lua" })
    check("streaming-events", "input")

    -- 3. sending keeps the prompt window, the focus and the mode
    local input = panel.state.input
    local before = input.win
    vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "hello from the smoke test" })
    panel.submit()
    vim.wait(200, function() return false end, 50)
    check("after-submit", "input")
    log(string.format("%s prompt-window-kept %s", input.win == before and "PASS" or "FAIL", tostring(before)))

    -- leave something for the real <CR> the shell sends next
    vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "real submit" })
  end)

  if not ok then
    log("FAIL ui_check errored: " .. tostring(err))
    log("DONE-WITH-FAILURES")
    return
  end
  log("DONE")
end

-- A question raised by the agent *while you are typing*: the dialog must open
-- in normal mode (its keys are digits/<CR>/o) and answering must give the prompt
-- back with its insert mode.
local QUESTION = {
  id = "frm_smoke",
  sessionID = "ses_smoke",
  title = "Questions",
  metadata = { kind = "question" },
  fields = {
    { key = "q0", type = "string", title = "Pick one",
      options = { { value = "Lua", label = "Lua" }, { value = "Python", label = "Python" } } },
  },
}

_G.ui_raise_question = function()
  log(string.format("PROBE %-26s window=%s mode=%s", "before-question", where(), vim.fn.mode(1)))
  event.emit({ type = "form.created", data = { form = QUESTION } })
  vim.defer_fn(function()
    local mode = vim.fn.mode(1)
    check("question-dialog", "popup")
    log(string.format("%s dialog-mode %s (n expected)", mode:find("^n") and "PASS" or "FAIL", mode))
  end, 400)
  vim.defer_fn(function()
    check("after-answering", "input")
    log(string.format("%s answered-mode %s (insert expected)", vim.fn.mode(1):find("^[iR]") and "PASS" or "FAIL", vim.fn.mode(1)))
    log("DONE-QUESTION")
  end, 3000)
end

-- Observable state, so the shell can see what happened after a real <CR>.
local ticks = 0
local timer = (vim.uv or vim.loop).new_timer()
timer:start(500, 500, vim.schedule_wrap(function()
  ticks = ticks + 1
  log(string.format("STATE tick=%d window=%s mode=%s", ticks, where(), vim.fn.mode(1)))
end))

-- arm the question for a moment when the shell will have the prompt open
session.current = {
  id = "ses_smoke",
  agent = "build",
  approval = false,
  tokens = {},
  cost = 0,
  location = { directory = vim.uv.cwd() },
}
vim.defer_fn(function() pcall(_G.ui_raise_question) end, 4500)

log("READY")
