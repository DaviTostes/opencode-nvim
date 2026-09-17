-- End-to-end approval flow: real server, real agent, real diff popup.
--
-- Uses a *project* config in a temp directory so nothing global is touched.
-- Costs one short agent turn.
--
--   make e2e-approval
local uv = vim.uv or vim.loop

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local plugin = require("opencode-nvim")
local event = require("opencode-nvim.event")
local panel = require("opencode-nvim.ui.panel")
local permission = require("opencode-nvim.permission")
local session = require("opencode-nvim.session")

local workdir = os.getenv("E2E_DIR") or vim.fs.joinpath(vim.fn.tempname())
vim.fn.mkdir(workdir, "p")

local AGENT = "opencode-nvim"
local TARGET = "e2e-hello.txt"

-- Project config: declares an agent that asks before editing and running shell.
-- A git repository is created too: OpenCode's turn snapshots (the diff of a
-- turn and restoring files on revert) rely on git.
local function git(...)
  vim.fn.system({ "git", "-C", workdir, "-c", "user.email=e2e@test", "-c", "user.name=e2e", ... })
end
git("init", "-q")
vim.fn.writefile({ "seeded", }, vim.fs.joinpath(workdir, "README.md"))
git("add", "-A")
git("commit", "-q", "-m", "seed")

vim.fn.writefile({
  "{",
  '  "agents": {',
  '    "' .. AGENT .. '": {',
  '      "description": "approval test",',
  '      "mode": "primary",',
  '      "permissions": [',
  '        { "action": "*", "resource": "*", "effect": "allow" },',
  '        { "action": "edit", "resource": "*", "effect": "ask" },',
  '        { "action": "shell", "resource": "*", "effect": "ask" }',
  "      ]",
  "    }",
  "  }",
  "}",
}, vim.fs.joinpath(workdir, "opencode.json"))

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

local state = { finished = false, approvals = 0, asked = {} }
event.on_any(function(ev)
  local data = ev.data or {}
  -- Only events of the session under test (the service is shared with the TUI
  -- and with any other session running right now).
  local sid = data.sessionID
  if not session.id() then return end
  if sid and sid ~= session.id() then return end
  if ev.type == "permission.asked" then
    state.asked[#state.asked + 1] = data
    io.write(string.format("   permission.asked: action=%s resources=%s\n",
      tostring(data.action), vim.inspect(data.resources)))
    io.write("   full request: " .. vim.json.encode(data):sub(1, 900) .. "\n")
  elseif ev.type == "session.execution.succeeded" or ev.type == "session.execution.failed"
    or ev.type == "session.execution.interrupted" then
    state.finished = true
  elseif ev.type == "session.tool.success" then
    io.write("   tool.success: " .. tostring(data.id) .. "\n")
  elseif ev.type == "session.text.delta" then
    local delta = data.delta or ""
    io.write(delta)
  end
end)

plugin.setup({ keymaps = { enabled = false }, agent = AGENT })

-- Instrument the reply so any failure is visible (and the raw status/body).
local api = require("opencode-nvim.api")
local original_reply = api.reply_permission
api.reply_permission = function(id, request_id, decision, message, cb)
  io.write(string.format("   reply -> session=%s request=%s decision=%s\n", id, request_id, decision))
  return original_reply(id, request_id, decision, message, function(err, decoded, status)
    io.write(string.format("   reply <- status=%s err=%s body=%s\n",
      tostring(status), vim.inspect(err), vim.inspect(decoded):sub(1, 200)))
    if cb then cb(err) end
  end)
end

if not wait(function() return require("opencode-nvim.sse").connected() end, 15000) then
  io.write("could not connect to the event stream\n")
  os.exit(1)
end

-- Attach the plugin to the test directory and check agent detection.
local info = nil
session.new({ directory = workdir }, function(err, created) info = created end)
if not wait(function() return info ~= nil end, 90000) then
  io.write("could not create the session\n")
  os.exit(1)
end

report("detects the agent that asks for approval", info.agent == AGENT and info.approval == true,
  string.format("agent=%s approval=%s", tostring(info.agent), tostring(info.approval)))

panel.open({ input = false })

-- Send the prompt through the plugin (context expansion included).
state.finished = false
plugin.prompt("Create a file named " .. TARGET .. " containing exactly: oi")

-- Approve every popup that shows up (diff or shell) until the turn ends.
-- Only feed <CR> when a popup is actually focused, so the keystroke cannot
-- land in the panel's prompt by accident.
local function popup_focused()
  local win = vim.api.nvim_get_current_win()
  local conf = vim.api.nvim_win_get_config(win)
  if conf.relative == "" then return false end
  local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  return ft == "diff" or ft == ""
end

local deadline = uv.now() + 180000
local dumped_popup = false
while not state.finished and uv.now() < deadline do
  if #permission.pending() > 0 and popup_focused() then
    if not dumped_popup then
      dumped_popup = true
      local win = vim.api.nvim_get_current_win()
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
      io.write("   permission popup:\n    " .. table.concat(lines, "\n    "):sub(1, 700) .. "\n")
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    state.approvals = state.approvals + 1
  end
  vim.wait(200, function() return false end, 50)
end

report("the turn finished", state.finished, "timeout waiting for the turn to finish")
report("asked for permission before writing", #state.asked > 0,
  "no permission asked (did the agent ignore the rules?)")
report("approved through the popup", state.approvals > 0, "no approval was sent")

local target = vim.fs.joinpath(workdir, TARGET)
local exists = vim.fn.filereadable(target) == 1
report("file created after approval", exists, "file does not exist: " .. target)
if exists then
  io.write("   content: " .. vim.inspect(vim.fn.readfile(target)) .. "\n")
end

-- The review popup must stay out of the way when pre-approval is active.
report("no review popup in approval mode", session.approval_active(), "approval_active() is false")

-- The turn diff is what the review popup shows; make sure it has content.
local diff_patches, diff_source, diff_done = nil, nil, false
session.diff({ context = 3 }, function(err, patches, source)
  diff_patches, diff_source, diff_done = patches, source, true
  if err then io.write("   diff ERROR: " .. vim.inspect(err) .. "\n") end
end)
wait(function() return diff_done end, 20000)
report("the turn diff has content", type(diff_patches) == "table" and #diff_patches > 0,
  vim.inspect(diff_patches))
if type(diff_patches) == "table" and #diff_patches > 0 then
  io.write(string.format("   source=%s  %s (+%d -%d) status=%s\n", tostring(diff_source),
    tostring(diff_patches[1].file), diff_patches[1].additions or 0,
    diff_patches[1].deletions or 0, tostring(diff_patches[1].status)))
  io.write("   patch:\n" .. tostring(diff_patches[1].patch):sub(1, 400) .. "\n")
end
if type(diff_patches) == "table" and #diff_patches > 0 then
  io.write(string.format("   %s (+%d -%d) status=%s\n", tostring(diff_patches[1].file),
    diff_patches[1].additions or 0, diff_patches[1].deletions or 0, tostring(diff_patches[1].status)))
end

-- Undo the turn: the created file should be restored (removed).
local reverted, revert_err = false, nil
session.revert_last_turn(function(err)
  revert_err = err
  reverted = true
end)
wait(function() return reverted end, 30000)
report("undo worked", reverted and revert_err == nil, tostring(revert_err))
vim.wait(600, function() return false end, 50)
local still_there = vim.fn.filereadable(target) == 1
report("undo removed the created file", not still_there,
  "the file is still on disk after the revert")

-- Clean up.
local deleted = false
require("opencode-nvim.api").delete_session(session.id(), function() deleted = true end)
wait(function() return deleted end, 20000)
vim.fn.delete(workdir, "rf")

io.write(string.format("\n%d failure(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
