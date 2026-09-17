-- Probe: the review popup that opens after a turn that changed files.
-- Presses movement keys and records every error. One small prompt.
--
--   nvim -l tests/probe_review_popup.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local workdir = vim.fs.joinpath(vim.fn.tempname())
vim.fn.mkdir(workdir, "p")
local function git(...)
  vim.fn.system({ "git", "-C", workdir, "-c", "user.email=e2e@test", "-c", "user.name=e2e", ... })
end
git("init", "-q")

local target = vim.fs.joinpath(workdir, "hello.lua")
local lines = {}
for index = 1, 30 do lines[index] = string.format("local value_%d = %d", index, index) end
vim.fn.writefile(lines, target)
git("add", "-A")
git("commit", "-q", "-m", "seed")

local plugin = require("opencode-nvim")
local event = require("opencode-nvim.event")
local panel = require("opencode-nvim.ui.panel")
local session = require("opencode-nvim.session")
local util = require("opencode-nvim.util")

plugin.setup({
  keymaps = { enabled = false },
  agent = "build",
  approval = { auto_detect = false }, -- no approval gate: the edit happens
})

local state = { finished = false }
event.on_any(function(ev)
  local sid = util.pick_string(ev.data or {}, { "sessionID" })
  if not session.id() then return end
  if sid and sid ~= session.id() then return end
  if ev.type == "session.execution.succeeded" or ev.type == "session.execution.failed" then
    state.finished = true
  end
end)

vim.api.nvim_set_current_dir(workdir)
require("opencode-nvim").open({ input = false })

local info
session.new({ directory = workdir }, function(_, created) info = created end)
assert(vim.wait(60000, function() return info ~= nil end, 50), "no session")

local sent = false
plugin.prompt("Add a comment line '-- note' as the first line of hello.lua. Use the edit tool.")
vim.wait(3000, function() return false end, 100)

io.write("waiting for the turn...\n")
assert(vim.wait(180000, function() return state.finished end, 200), "turn never finished")
vim.wait(1500, function() return false end, 100) -- let review_turn fire

local win = vim.api.nvim_get_current_win()
local conf = vim.api.nvim_win_get_config(win)
io.write(string.format("current win=%d float=%s buftype=%s filetype=%s\n", win,
  tostring(conf.relative ~= ""), vim.bo.buftype, vim.bo.filetype))
io.write(string.format("foldmethod=%s foldenable=%s foldlevel=%s modifiable=%s\n",
  vim.wo.foldmethod, tostring(vim.wo.foldenable), tostring(vim.wo.foldlevel), tostring(vim.bo.modifiable)))
io.write(string.format("title=%s footer=%s\n", vim.inspect(conf.title), vim.inspect(conf.footer)))
io.write("buffer:\n")
for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  io.write(string.format("%3d| %s\n", index, line))
end

local function press(keys, label)
  vim.v.errmsg = ""
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(150, function() return false end, 30)
  local cursor = vim.api.nvim_win_get_cursor(0)
  io.write(string.format("%-10s -> row=%d col=%d errmsg=%s\n", label, cursor[1], cursor[2],
    vim.inspect(vim.v.errmsg)))
end

io.write("--- keys ---\n")
press("j", "j")
press("j", "j")
press("k", "k")
press("G", "G")
press("gg", "gg")
press("]", "]")
press("<C-d>", "<C-d>")
press("/local", "/local")
press("n", "n")
press("y", "y")
press("u", "u") -- mapped: undoes the turn
vim.wait(800, function() return false end, 100)
io.write(string.format("file restored: %s\n", vim.inspect(vim.fn.readfile(target):sub(1, 2))))
io.write("--- messages ---\n")
local ok, out = pcall(vim.api.nvim_exec2, "messages", { output = true })
io.write((ok and out.output or tostring(out)):sub(-1500) .. "\n")

local cleaned = false
require("opencode-nvim.api").delete_session(info.id, function() cleaned = true end)
vim.wait(20000, function() return cleaned end, 50)
vim.fn.delete(workdir, "rf")
os.exit(0)
