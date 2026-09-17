-- Probe: the first message of a session through the real plugin path.
-- Dumps every event and the resulting panel buffer.
--
--   nvim -l tests/probe_first_message.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local workdir = vim.fs.joinpath(vim.fn.tempname())
vim.fn.mkdir(workdir, "p")
vim.fn.writefile({ "local hello = 1", "print(hello)" }, vim.fs.joinpath(workdir, "sample.lua"))

local plugin = require("opencode-nvim")
local event = require("opencode-nvim.event")
local panel = require("opencode-nvim.ui.panel")
local session = require("opencode-nvim.session")
local util = require("opencode-nvim.util")

plugin.setup({ keymaps = { enabled = false }, agent = "plan" })

local state = { finished = false }
event.on_any(function(ev)
  local sid = util.pick_string(ev.data or {}, { "sessionID" })
  if not session.id() then return end
  if sid and sid ~= session.id() then return end
  if ev.type:match("^session%.text%.delta$") or ev.type:match("^session%.reasoning%.delta$") then
    return -- too noisy, the buffer dump shows the result
  end
  io.write(string.format("ev %-34s %s\n", ev.type,
    util.pick_string(ev.data or {}, { "name", "id", "filePath", "command" }) or ""))
  if ev.type == "session.execution.succeeded" or ev.type == "session.execution.failed" then
    state.finished = true
  end
end)

vim.api.nvim_set_current_dir(workdir)
local info
session.new({ directory = workdir }, function(_, created) info = created end)
assert(vim.wait(60000, function() return info ~= nil end, 50), "no session")

io.write(string.format("session=%s model=%s approval=%s\n", info.id, vim.inspect(info.model), tostring(info.approval)))

-- Exactly what the user does: open the panel and send the first message.
local original_send = panel.send
panel.send("look at this file", {})
io.write(string.format("thinking flag after send: %s\n", tostring(panel.state.thinking)))

assert(vim.wait(120000, function() return state.finished end, 100), "turn never finished")
vim.wait(500, function() return false end, 50)

io.write("\n--- panel buffer ---\n")
for index, line in ipairs(vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false)) do
  io.write(string.format("%3d| %s\n", index, line))
end
io.write("--- end ---\n")
io.write(string.format("thinking=%s reasoning_open=%s\n", tostring(panel.state.thinking),
  tostring(panel.state.reasoning_open)))

local cleaned = false
require("opencode-nvim.api").delete_session(info.id, function() cleaned = true end)
vim.wait(20000, function() return cleaned end, 50)
vim.fn.delete(workdir, "rf")
os.exit(0)
