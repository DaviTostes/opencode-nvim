-- Real-UI smoke test (driven by tests/ui_smoke.sh inside tmux).
--
-- Guards the "never lose focus / never enter insert mode somewhere else"
-- behaviour, which cannot be tested headlessly: without a UI Neovim does not
-- redraw and insert mode is not entered.
vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local logfile = os.getenv("UI_SMOKE_LOG") or "/tmp/opencode/ui_smoke.log"
local function log(message)
  local fd = io.open(logfile, "a")
  fd:write(message .. "\n")
  fd:close()
end

local plugin = require("opencode-nvim")
plugin.setup({ server = { autostart = false, url = "http://127.0.0.1:9" }, keymaps = { enabled = false } })
local panel = require("opencode-nvim.ui.panel")

local mode_changes = {}
vim.api.nvim_create_autocmd("ModeChanged", {
  callback = function()
    local win = vim.api.nvim_get_current_win()
    local which = "code"
    if win == panel.state.input.win then which = "input" elseif win == panel.state.win then which = "panel" end
    mode_changes[#mode_changes + 1] = string.format("%s@%s", vim.fn.mode(1), which)
  end,
})

local function check(label, expected_window)
  local current = vim.api.nvim_get_current_win()
  local which = "code"
  if current == panel.state.input.win then which = "input" elseif current == panel.state.win then which = "panel" end

  -- Only *insert* mode leaking into the panel is a bug: it is what made the
  -- cursor and the insert state land in the wrong buffer. A transient "n@panel"
  -- from running a :normal command in that window is harmless.
  local bad = {}
  for _, change in ipairs(mode_changes) do
    if change:find("^i@panel") or change:find("^R@panel") then bad[#bad + 1] = change end
  end
  mode_changes = {}

  local win = panel.state.win
  local shows_end = true
  if win and vim.api.nvim_win_is_valid(win) then
    shows_end = vim.fn.line("w$", win) >= vim.fn.line("$", win)
  end

  local ok = which == expected_window and #bad == 0 and shows_end
  log(string.format("%s %-22s window=%s expected=%s mode=%s panel_mode_changes=%s panel_shows_end=%s",
    ok and "PASS" or "FAIL", label, which, expected_window, vim.fn.mode(1),
    (#bad > 0 and table.concat(bad, ",") or "none"), tostring(shows_end)))
  return ok
end

--- Run from insert mode with <C-o>:lua _G.ui_check()
_G.ui_check = function()
  -- 1. the panel must follow new content without touching the focus or the mode
  local renderer = panel.renderer()
  for i = 1, 80 do
    renderer:note(string.format("line %d", i))
  end
  panel.scroll_to_bottom()
  vim.wait(200, function() return false end, 50)
  check("scroll-while-inserting", "input")

  -- 2. sending must keep the prompt window, the focus and the mode
  local input = panel.state.input
  local before = input.win
  vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "hello from the smoke test" })
  panel.submit()
  vim.wait(200, function() return false end, 50)
  local check_ok = check("after-submit", "input")
  -- leave something for the real <CR> the shell sends next
  vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, { "real submit" })
  if input.win ~= before then
    log("FAIL prompt-window-recreated before=" .. tostring(before) .. " after=" .. tostring(input.win))
  else
    log("PASS prompt-window-kept " .. tostring(before))
  end
  log(check_ok and "DONE" or "DONE-WITH-FAILURES")
end

-- Diagnostic: log the state around every public panel call, and every WinEnter.
vim.api.nvim_create_autocmd("WinEnter", {
  callback = function()
    local win = vim.api.nvim_get_current_win()
    local which = "code"
    if win == panel.state.input.win then which = "input" elseif win == panel.state.win then which = "panel" end
    log(string.format("WINENTER   window=%s mode=%s", which, vim.fn.mode(1)))
  end,
})

local function where()
  local current = vim.api.nvim_get_current_win()
  if current == panel.state.input.win then return "input" end
  if current == panel.state.win then return "panel" end
  return "code"
end

for _, name in ipairs({ "open", "send", "after_submit", "scroll_to_bottom", "update_title", "submit",
                        "close_input", "open_input", "focus", "focus_code", "clear", "set_status",
                        "new_session", "retry", "escape" }) do
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

-- Observable state, so the shell can see what happened after a real <CR>.
local ticks = 0
local timer = (vim.uv or vim.loop).new_timer()
timer:start(500, 500, vim.schedule_wrap(function()
  ticks = ticks + 1
  local current = vim.api.nvim_get_current_win()
  local which = "code"
  if current == panel.state.input.win then which = "input" elseif current == panel.state.win then which = "panel" end
  log(string.format("STATE tick=%d window=%s mode=%s", ticks, which, vim.fn.mode(1)))
end))

log("READY")
