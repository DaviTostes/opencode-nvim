-- Interactive flow: open the panel, type in the prompt, send, and watch the
-- reply land in the panel while the cursor stays in the code window.
--
-- Uses the real service. Costs one short prompt.
--
--   make e2e-panel
local uv = vim.uv or vim.loop

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.g.mapleader = " "

local plugin = require("opencode-nvim")
local event = require("opencode-nvim.event")
local panel = require("opencode-nvim.ui.panel")
local session = require("opencode-nvim.session")

local workdir = os.getenv("E2E_DIR") or vim.fs.joinpath(vim.fn.tempname())
vim.fn.mkdir(workdir, "p")
io.write("directory: " .. workdir .. "\n")

local failures = 0
local function report(name, ok, detail)
  if ok then
    io.write("ok   - " .. name .. "\n")
  else
    failures = failures + 1
    io.write("FAIL - " .. name .. "\n       " .. tostring(detail) .. "\n")
  end
end

local function wait(condition, timeout)
  return vim.wait(timeout or 20000, condition, 30)
end

--- The provider (not the plugin) can be unavailable: opencode-go's free tier
--- started rejecting the V2 beta with a version gate. Treat that as a skip so
--- the suite does not report a plugin bug when the account cannot run turns.
local provider_errors = {}
local function note_provider_error(text)
  for line in tostring(text):gmatch("[^\n]+") do
    if line:find("Error from provider", 1, true) or line:find("is required to use", 1, true)
      or line:find("Endpoint is unavailable", 1, true) then
      provider_errors[#provider_errors + 1] = vim.trim(line)
    end
  end
end

plugin.setup({ keymaps = { enabled = true }, agent = "plan" })
event.start()

local state = { finished = false, deltas = 0 }
event.on_any(function(ev)
  if not session.id() then return end
  local data = ev.data or {}
  local sid = data.sessionID
  if sid and sid ~= session.id() then return end
  if ev.type == "session.text.delta" then
    state.deltas = state.deltas + 1
  elseif ev.type == "session.execution.succeeded" or ev.type == "session.execution.failed"
    or ev.type == "session.execution.interrupted" then
    state.finished = true
  end
end)

if not wait(function() return require("opencode-nvim.sse").connected() end, 15000) then
  io.write("could not connect to the stream\n")
  os.exit(1)
end

-- A code buffer to come back to after sending.
vim.cmd("enew")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = 1", "-- real code" })
vim.bo.filetype = "lua"
local code_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(code_win, { 1, 0 })

-- 1. The keymap opens the panel + prompt.
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>ta", true, false, true), "x", false)
vim.wait(600, function() return false end, 50)

report("the keymap opened the panel", panel.visible(), "panel is not visible")
report("the prompt opened focused", panel.state.input.win ~= nil
  and vim.api.nvim_get_current_win() == panel.state.input.win,
  string.format("input.win=%s current=%s", tostring(panel.state.input.win), tostring(vim.api.nvim_get_current_win())))

-- The session is created on the first send; attach it to the test directory.
local attached = false
session.new({ directory = workdir }, function(err, info) attached = info ~= nil end)
wait(function() return attached end, 60000)
report("session created in the test directory", attached, "session.new failed")

-- 2. Type a prompt (simulating the user) and submit.
local buf = panel.state.input.buf
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Say only: bye" })
panel.submit()
wait(function() return not panel.state.input.win or panel.state.input.win == nil end, 2000)
vim.wait(200, function() return false end, 50)

local current = vim.api.nvim_get_current_win()
report("focus went back to the code after sending", current == code_win,
  string.format("win atual=%d code_win=%d", current, code_win))

report("the panel shows the prompt", (function()
  local text = table.concat(vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false), "\n")
  return text:find("Say only: bye", 1, true) ~= nil
end)(), table.concat(vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false), "\n"))

-- 3. Wait for the turn and check the streamed reply is in the panel.
--    (The upstream provider is flaky, so a failed turn is retried.)
local attempts = 0
while not state.finished and attempts < 3 do
  if not wait(function() return state.finished end, 120000) then
    io.write("   timeout on the turn\n")
    break
  end
  if state.deltas == 0 and attempts < 2 then
    attempts = attempts + 1
    io.write(string.format("   turn failed without text (attempt %d), retrying...\n", attempts))
    local panel_text = table.concat(vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false), "\n")
    for line in panel_text:gmatch("[^\n]+") do
      if line:find("⚠", 1, true) then
        io.write("     reason: " .. line .. "\n")
        note_provider_error(line)
      end
    end
    state.finished = false
    state.deltas = 0
    vim.api.nvim_buf_set_lines(panel.state.input.buf, 0, -1, false, { "Say only: bye" })
    panel.submit()
  else
    break
  end
end

report("the turn finished", state.finished, "timeout")

local text = table.concat(vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false), "\n")
io.write("--- panel ---\n" .. text:sub(1, 700) .. "\n--------------\n")
note_provider_error(text)

if state.deltas == 0 and #provider_errors > 0 then
  io.write("SKIP - streaming/answer: the provider refused the turn, not a plugin bug\n")
  io.write("       " .. provider_errors[1] .. "\n")
else
  report("received text deltas", state.deltas > 0, "no session.text.delta")
  local answered = false
for line in text:gmatch("[^\n]+") do
  -- skip the echoed user prompt (it starts with the "❯ " marker)
  if line:find("bye", 1, true) and not line:find("❯", 1, true) then answered = true end
end
report("the answer showed up in the panel", answered, text:sub(1, 300))
end

local cleaned = false
require("opencode-nvim.api").delete_session(session.id(), function() cleaned = true end)
wait(function() return cleaned end, 20000)
vim.fn.delete(workdir, "rf")

io.write(string.format("\n%d falha(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
