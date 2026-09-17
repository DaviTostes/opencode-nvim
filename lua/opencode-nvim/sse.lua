local uv = vim.uv or vim.loop
local http = require("opencode-nvim.http")
local discovery = require("opencode-nvim.discovery")
local log = require("opencode-nvim.log")

--- Server-Sent Events stream for `/api/event`.
local M = {}

local state = {
  handle = nil,
  generation = 0,
  connected = false,
  status = "off",
  backoff = 500,
  timer = nil,
  waiters = {},
}

local MAX_BACKOFF = 10000

function M.status()
  return state.status
end

--- True once the stream was started at least once (used to avoid showing
--- "offline" before the first request).
function M.started()
  return state.ever_started == true
end

function M.connected()
  return state.connected
end

local function flush_waiters(err)
  local pending = state.waiters
  state.waiters = {}
  for _, cb in ipairs(pending) do
    pcall(cb, err)
  end
end

--- Calls `cb` once the stream is delivering events (or after `timeout`).
---@param cb fun(err: string?)
function M.ensure(cb)
  if state.connected then return cb(nil) end
  state.waiters[#state.waiters + 1] = cb
  M.start()
  local tries = 0
  local function wait()
    if state.connected then return end
    tries = tries + 1
    if tries > 40 then
      return flush_waiters("timeout esperando o stream de eventos")
    end
    vim.defer_fn(wait, 250)
  end
  vim.defer_fn(wait, 250)
end

local function parse_frame(frame, emit)
  local payload = {}
  for line in frame:gmatch("[^\r\n]+") do
    if line:sub(1, 1) ~= ":" then
      local value = line:match("^data:%s?(.*)$")
      if value then payload[#payload + 1] = value end
    end
  end
  if #payload == 0 then return end

  local ok, event = pcall(vim.json.decode, table.concat(payload, "\n"))
  if not ok or type(event) ~= "table" then
    log.debug("evento inválido:", table.concat(payload, "\n"))
    return
  end
  emit(event)
end

--- Exposed for tests.
M.parse_frame = parse_frame

local function schedule_retry(delay)
  if state.timer then
    state.timer:stop()
    state.timer:close()
  end
  state.timer = uv.new_timer()
  state.timer:start(delay, 0, vim.schedule_wrap(function()
    M.start()
  end))
end

function M.stop()
  state.generation = state.generation + 1
  if state.handle then
    pcall(state.handle.close)
    state.handle = nil
  end
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  state.connected = false
  state.status = "off"
  flush_waiters("stream encerrado")
end

---@param opts? { on_event?: fun(event: table) }
function M.start(opts)
  opts = opts or {}
  if state.on_event then opts.on_event = opts.on_event or state.on_event end
  state.on_event = opts.on_event

  state.generation = state.generation + 1
  local generation = state.generation
  state.status = "connecting"
  state.ever_started = true

  if state.handle then
    pcall(state.handle.close)
    state.handle = nil
  end

  discovery.resolve(function(err, server)
    if generation ~= state.generation then return end
    if err then
      state.status = "error"
      log.debug("sse: resolve falhou:", err)
      return schedule_retry(state.backoff)
    end

    local buffer = ""
    local function emit(event)
      if generation ~= state.generation then return end
      if event.type == "server.connected" and not state.connected then
        state.connected = true
        state.status = "connected"
        state.backoff = 500
        flush_waiters(nil)
      end
      local callback = state.on_event
      if callback then
        vim.schedule(function()
          if generation ~= state.generation then return end
          pcall(callback, event)
        end)
      end
    end

    state.handle = http.stream(server, "/api/event", {
      on_chunk = function(chunk)
        buffer = buffer .. chunk
        while true do
          local index, skip = buffer:find("\r\n\r\n", 1, true), 4
          local lf = buffer:find("\n\n", 1, true)
          if lf and (not index or lf < index) then
            index, skip = lf, 2
          end
          if not index then break end
          local frame = buffer:sub(1, index - 1)
          buffer = buffer:sub(index + skip)
          parse_frame(frame, emit)
        end
      end,
      on_end = function(end_err, status)
        if generation ~= state.generation then return end
        state.connected = false
        state.status = end_err and "error" or "off"
        state.handle = nil
        if end_err then
          log.debug("sse encerrou:", end_err, "status", status)
        else
          log.debug("sse encerrou: conexão fechada pelo servidor")
        end
        local delay = state.backoff
        state.backoff = math.min(state.backoff * 2, MAX_BACKOFF)
        schedule_retry(delay)
      end,
    })
  end)
end

return M
