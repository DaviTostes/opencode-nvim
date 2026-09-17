local sse = require("opencode-nvim.sse")
local log = require("opencode-nvim.log")
local util = require("opencode-nvim.util")

--- In-process event bus fed by the SSE stream. Every event is also dispatched
--- as a `User` autocmd: `OpencodeEvent:{type}` and `OpencodeEvent`.
local M = {}

local listeners = {}
local any_listeners = {}
local history = {}
local HISTORY_MAX = 200

function M.on(event_type, fn)
  listeners[event_type] = listeners[event_type] or {}
  local bucket = listeners[event_type]
  bucket[#bucket + 1] = fn
  return function()
    for index, item in ipairs(bucket) do
      if item == fn then
        table.remove(bucket, index)
        return
      end
    end
  end
end

function M.on_any(fn)
  any_listeners[#any_listeners + 1] = fn
  return function()
    for index, item in ipairs(any_listeners) do
      if item == fn then
        table.remove(any_listeners, index)
        return
      end
    end
  end
end

--- Recent events, newest last (for `:OpencodeEvents`).
function M.history()
  return history
end

local reported = {}

--- Runs a handler without letting a UI bug kill the event bus, but always
--- surfaces the error once (silently swallowing them hides real bugs).
local function safe(fn, event)
  local ok, err = pcall(fn, event)
  if ok then return end
  local message = tostring(err)
  if reported[message] then return end
  reported[message] = true
  log.error(string.format("handler for '%s' failed: %s", tostring(event.type), message))
end

local function dispatch(event)
  for _, fn in ipairs(listeners[event.type] or {}) do
    safe(fn, event)
  end
  for _, fn in ipairs(any_listeners) do
    safe(fn, event)
  end
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "OpencodeEvent:" .. event.type, data = event })
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "OpencodeEvent", data = event })
end

--- Emit a locally generated event (same pipeline as server events).
function M.emit(event)
  dispatch(event)
end

function M.emit_server(event)
  if #history >= HISTORY_MAX then table.remove(history, 1) end
  history[#history + 1] = event
  if log.level == "debug" then
    log.debug("event", event.type, util.pick_string(event.data, { "sessionID" }) or "")
  end
  dispatch(event)
end

function M.start()
  sse.start({ on_event = M.emit_server })
end

function M.connected()
  return sse.connected()
end

--- True once the stream was started at least once.
function M.started()
  return sse.started()
end

function M.status()
  return sse.status()
end

return M
