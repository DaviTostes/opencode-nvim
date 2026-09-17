-- Probe: the agent asks a question (the `question` tool -> a "form").
-- Dumps the form events and the API shapes, replies once, and reports whether
-- the turn completes. One small prompt.
--
--   nvim -l tests/probe_form.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local workdir = vim.fs.joinpath(vim.fn.tempname())
vim.fn.mkdir(workdir, "p")

local api = require("opencode-nvim.api")
local event = require("opencode-nvim.event")
local session = require("opencode-nvim.session")
local util = require("opencode-nvim.util")

local state = { finished = false, form = nil, replied = false }

event.on_any(function(ev)
  local sid = util.pick_string(ev.data or {}, { "sessionID" })
  if not session.id() then return end
  if sid and sid ~= session.id() then return end

  if ev.type:find("form", 1, true) or ev.type:find("question", 1, true) then
    io.write(string.format("EV %-28s %s\n", ev.type, vim.json.encode(ev.data or {}):sub(1, 700) .. "\n"))
  end
  if ev.type == "form.created" or ev.type == "session.form.created" or ev.type == "session.form.create" then
    state.form = ev.data
  end
  if ev.type == "session.execution.succeeded" or ev.type == "session.execution.failed" then
    state.finished = true
  end
end)

event.start()
vim.wait(10000, function() return require("opencode-nvim.sse").connected() end, 50)

vim.api.nvim_set_current_dir(workdir)
local info
session.new({ directory = workdir }, function(_, created) info = created end)
assert(vim.wait(60000, function() return info ~= nil end, 50), "no session")
io.write(string.format("session=%s agent=%s model=%s\n", info.id, tostring(info.agent), vim.inspect(info.model)))

-- Ask the agent to use the question tool.
api.prompt(info.id, {
  text = "Use the question tool to ask me which language I prefer. Two options: Lua and Python.",
}, function(err) io.write("prompt -> " .. vim.inspect(err) .. "\n") end)

-- Wait for a form (or the turn to end).
local deadline = (vim.uv or vim.loop).now() + 120000
while not state.form and not state.finished and (vim.uv or vim.loop).now() < deadline do
  vim.wait(200, function() return false end, 50)
end

if not state.form then
  io.write(string.format("no form arrived (finished=%s)\n", tostring(state.finished)))
else
  io.write("--- form payload ---\n" .. vim.json.encode(state.form) .. "\n")

  -- what does the API say about pending forms?
  local forms_done = false
  api.raw({ method = "GET", path = "/api/session/" .. info.id .. "/form" }, function(err, decoded)
    forms_done = true
    io.write("GET /form -> " .. (err and vim.inspect(err) or vim.json.encode(decoded):sub(1, 700)) .. "\n")
  end)
  vim.wait(15000, function() return forms_done end, 50)

  -- Reply with the first option of the first field (guessing the shape).
  local form = state.form.form or state.form
  local id = form.id or form.formID
  local fields = form.fields or {}
  local first = fields[1] or {}
  local options = first.options or {}
  local answer = {}
  if #options > 0 then
    answer[first.key] = options[1].value
  else
    answer[first.key] = "Lua"
  end
  io.write("reply: " .. vim.inspect({ id = id, answer = answer }) .. "\n")
  if id then
    api.raw({
      method = "POST",
      path = "/api/session/" .. info.id .. "/form/" .. id .. "/reply",
      body = { answer = answer },
      timeout = 15000,
    }, function(err, decoded, status)
      state.replied = true
      io.write("reply -> status=" .. tostring(status) .. " err=" .. vim.inspect(err) ..
        " body=" .. tostring(decoded and vim.json.encode(decoded):sub(1, 300)) .. "\n")
    end)
    vim.wait(15000, function() return state.replied end, 50)
  end
end

vim.wait(60000, function() return state.finished end, 200)
io.write(string.format("finished=%s\n", tostring(state.finished)))
local msgs_done = false
api.messages(info.id, { limit = 2, order = "desc" }, function(err, page)
  msgs_done = true
  for _, message in ipairs(err and {} or page.data or {}) do
    if message.type == "assistant" then
      local text = {}
      for _, item in ipairs(message.content or {}) do
        if item.type == "text" then text[#text + 1] = item.text end
      end
      io.write(string.format("assistant finish=%s error=%s text=%q\n", tostring(message.finish),
        vim.inspect(message.error), table.concat(text, " "):sub(1, 200)))
      break
    end
  end
end)
vim.wait(15000, function() return msgs_done end, 50)

local cleaned = false
api.delete_session(info.id, function() cleaned = true end)
vim.wait(20000, function() return cleaned end, 50)
vim.fn.delete(workdir, "rf")
os.exit(0)
