-- End-to-end: the agent asks a question (the `question` tool) and the plugin
-- answers it through its own popup. One small prompt.
--
--   make e2e-form
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local workdir = vim.fs.joinpath(vim.fn.tempname())
vim.fn.mkdir(workdir, "p")

local plugin = require("opencode-nvim")
local event = require("opencode-nvim.event")
local session = require("opencode-nvim.session")
local util = require("opencode-nvim.util")

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
  return vim.wait(timeout or 20000, condition, 50)
end

plugin.setup({ keymaps = { enabled = false }, agent = "build" })

local state = { finished = false, form = nil }
event.on_any(function(ev)
  local sid = util.pick_string(ev.data or {}, { "sessionID" })
  if not session.id() then return end
  if sid and sid ~= session.id() then return end
  if ev.type == "form.created" then
    state.form = (ev.data and ev.data.form) or ev.data
    io.write("   form: " .. vim.inspect(state.form and state.form.title) .. "\n")
  elseif ev.type == "session.execution.succeeded" or ev.type == "session.execution.failed" then
    state.finished = true
  end
end)

vim.api.nvim_set_current_dir(workdir)
local info
session.new({ directory = workdir }, function(_, created) info = created end)
if not wait(function() return info ~= nil end, 60000) then
  io.write("could not create the session\n")
  os.exit(1)
end

plugin.prompt("Use the question tool to ask me which language I prefer. Two options: Lua and Python.")

-- The plugin must open the question popup by itself.
if not wait(function() return state.form ~= nil end, 120000) then
  io.write("no question arrived (the agent may have answered without asking)\n")
  local cleaned = false
  require("opencode-nvim.api").delete_session(info.id, function() cleaned = true end)
  wait(function() return cleaned end, 20000)
  vim.fn.delete(workdir, "rf")
  os.exit(0)
end

wait(function()
  local win = vim.api.nvim_get_current_win()
  return vim.api.nvim_win_get_config(win).relative ~= "" and vim.bo.filetype ~= "diff"
end, 10000)

local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
io.write("   popup:\n    " .. text:gsub("\n", "\n    ") .. "\n")
report("the question shows up in a popup", text:find("Python", 1, true) ~= nil, text)

-- Answer with the first option.
vim.api.nvim_feedkeys("1", "x", false)
wait(function() return state.finished end, 120000)
report("the turn finished after answering", state.finished, "timeout waiting for the turn")

local answered_done = false
require("opencode-nvim.api").messages(info.id, { limit = 2, order = "desc" }, function(err, page)
  answered_done = true
  for _, message in ipairs(err and {} or page.data or {}) do
    if message.type == "assistant" then
      local parts = {}
      for _, item in ipairs(message.content or {}) do
        if item.type == "text" then parts[#parts + 1] = item.text end
      end
      local answer_text = table.concat(parts, " ")
      io.write("   final: " .. answer_text:sub(1, 160) .. "\n")
      report("the model used the answer", answer_text:lower():find("lua", 1, true) ~= nil, answer_text:sub(1, 160))
      return
    end
  end
end)
wait(function() return answered_done end, 20000)

local cleaned = false
require("opencode-nvim.api").delete_session(info.id, function() cleaned = true end)
wait(function() return cleaned end, 20000)
vim.fn.delete(workdir, "rf")

io.write(string.format("\n%d falha(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
