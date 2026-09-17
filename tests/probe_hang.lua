-- Probe: what does the server do during a turn that never answers?
-- Logs every event with the elapsed time. One tiny prompt.
--
--   nvim -l tests/probe_hang.lua [seconds]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local limit = tonumber(os.getenv("PROBE_SECONDS") or "150") or 150
local workdir = vim.fs.joinpath(vim.fn.tempname())
vim.fn.mkdir(workdir, "p")

local api = require("opencode-nvim.api")
local event = require("opencode-nvim.event")
local session = require("opencode-nvim.session")
local util = require("opencode-nvim.util")
local uv = vim.uv or vim.loop

local started = uv.now()
local function stamp()
  return string.format("%6.1fs", (uv.now() - started) / 1000)
end

local important = {
  "session.execution.started", "session.execution.succeeded", "session.execution.failed",
  "session.step.started", "session.step.ended", "session.step.failed",
  "session.text.started", "session.text.ended", "session.reasoning.started",
  "session.tool.input.started", "session.tool.called", "session.tool.success", "session.tool.failed",
  "session.error", "session.retry.scheduled", "session.idle", "session.usage.updated",
  "session.inbox.enqueued", "session.inbox.delivered", "server.connected",
}
local interesting = {}
for _, kind in ipairs(important) do interesting[kind] = true end

event.on_any(function(ev)
  local sid = util.pick_string(ev.data or {}, { "sessionID" })
  if sid and session.id() and sid ~= session.id() then return end -- another session
  local detail = ""
  if ev.type == "session.retry.scheduled" then
    detail = "attempt=" .. tostring(ev.data.attempt) .. " " .. tostring(util.deep_find(ev.data, { "message" }))
  elseif ev.type == "session.step.started" then
    detail = "agent=" .. tostring(ev.data.agent) .. " model=" .. vim.inspect(ev.data.model)
  elseif ev.type == "session.step.ended" then
    detail = string.format("finish=%s cost=%s", tostring(ev.data.finish), tostring(ev.data.cost))
  elseif ev.type == "session.usage.updated" then
    detail = string.format("tokens=%s", vim.inspect(ev.data.tokens))
  elseif ev.type == "session.execution.failed" then
    detail = vim.inspect(ev.data)
  end
  io.write(string.format("%s  %s  %s\n", stamp(), ev.type, detail))
end)

event.start()
vim.wait(10000, function() return require("opencode-nvim.sse").connected() end, 50)
io.write(string.format("%s  stream connected=%s\n", stamp(), tostring(require("opencode-nvim.sse").connected())))

local info
session.new({ directory = workdir }, function(_, created) info = created end)
vim.wait(60000, function() return info ~= nil end, 50)
if not info then io.write("could not create the session\n"); os.exit(1) end
io.write(string.format("%s  session %s agent=%s model=%s approval=%s\n", stamp(), info.id,
  tostring(info.agent), vim.inspect(info.model), tostring(info.approval)))

local sent = false
api.prompt(info.id, { text = "hey" }, function(err, inbox)
  sent = true
  io.write(string.format("%s  prompt -> err=%s inbox=%s\n", stamp(), vim.inspect(err), vim.inspect(inbox):sub(1, 160)))
end)
vim.wait(65000, function() return sent end, 50)
if not sent then io.write(string.format("%s  PROMPT NEVER RETURNED (client side)\n", stamp())) end

local done = false
event.on("session.execution.succeeded", function() done = true end)
event.on("session.execution.failed", function() done = true end)
if vim.wait(limit * 1000, function() return done end, 200) then
  io.write(string.format("%s  turn finished\n", stamp()))
else
  io.write(string.format("%s  STILL RUNNING after %ds\n", stamp(), limit))
  -- Ask the server what it thinks the session state is.
  local state_done = false
  api.get_session(info.id, function(err, fresh)
    state_done = true
    io.write(string.format("%s  GET session -> %s\n", stamp(),
      err and vim.inspect(err) or string.format("agent=%s model=%s cost=%s tokens=%s",
        tostring(fresh.agent), vim.inspect(fresh.model), tostring(fresh.cost), vim.inspect(fresh.tokens))))
  end)
  vim.wait(15000, function() return state_done end, 50)

  local msgs_done = false
  api.messages(info.id, { limit = 3, order = "desc" }, function(err, page)
    msgs_done = true
    if err then
      io.write(string.format("%s  GET messages -> %s\n", stamp(), vim.inspect(err)))
    else
      for _, message in ipairs(page.data or {}) do
        local text = ""
        if message.type == "assistant" then
          for _, item in ipairs(message.content or {}) do
            if item.type == "text" then text = text .. tostring(item.text) end
          end
        else
          text = tostring(message.text or "")
        end
        io.write(string.format("%s    msg type=%s finish=%s error=%s text=%q\n", stamp(),
          tostring(message.type), tostring(message.finish), vim.inspect(message.error), text:sub(1, 60)))
      end
    end
  end)
  vim.wait(15000, function() return msgs_done end, 50)

  io.write(string.format("%s  interrupting...\n", stamp()))
  local interrupted = false
  api.interrupt(info.id, function(err) interrupted = true; io.write(string.format("%s  interrupt -> %s\n", stamp(), vim.inspect(err))) end)
  vim.wait(20000, function() return interrupted end, 50)
  vim.wait(5000, function() return false end, 100)
end

local cleaned = false
api.delete_session(info.id, function() cleaned = true end)
vim.wait(20000, function() return cleaned end, 50)
vim.fn.delete(workdir, "rf")
os.exit(0)
