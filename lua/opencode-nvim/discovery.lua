local http = require("opencode-nvim.http")
local log = require("opencode-nvim.log")
local cfg = require("opencode-nvim.config")

--- Finds (or starts) the OpenCode background service and exposes its address.
local M = {}

local cached = nil
local resolving = false
local waiters = {}

local function options()
  return cfg.get().server or {}
end

---@return string
function M.state_dir()
  local configured = options().state_dir
  if configured and configured ~= "" then return configured end
  local base = vim.env.XDG_STATE_HOME
  if not base or base == "" then
    base = vim.fs.joinpath(vim.env.HOME or "~", ".local", "state")
  end
  return vim.fs.joinpath(base, "opencode")
end

---@return string
function M.service_file()
  return vim.fs.joinpath(M.state_dir(), "service.json")
end

---@return table? service registration
function M.read_service()
  local path = M.service_file()
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then return nil end
  local data = require("opencode-nvim.util").decode(table.concat(lines, "\n"))
  if type(data) ~= "table" or type(data.url) ~= "string" then return nil end
  return data
end

---@return opencode.http.Server?
function M.server_from_service(service)
  if not service then return nil end
  local host, port, err = http.url_parts(service.url)
  if not host then
    log.debug("invalid service.url:", err)
    return nil
  end
  return {
    host = host,
    port = port,
    password = service.password or options().password,
    url = service.url,
    version = service.version,
    pid = service.pid,
  }
end

---@return opencode.http.Server?
function M.current()
  return cached
end

function M.reset()
  cached = nil
end

---@param pid? integer
---@return boolean
local function alive(pid)
  if not pid then return true end
  local ok, result = pcall(function() return (vim.uv or vim.loop).kill(pid, 0) end)
  return ok and result ~= nil
end

--- Probes the health endpoint of a resolved server.
---@param server opencode.http.Server
---@param cb fun(err: string?, info: table?)
function M.probe(server, cb, timeout)
  http.request(server, { method = "GET", path = "/api/health", timeout = timeout or 3000 },
    function(err, status, _, text)
      if err then return cb(err) end
      if status ~= 200 then return cb("health respondeu " .. tostring(status)) end
      local info = require("opencode-nvim.util").decode(text)
      if type(info) ~= "table" then return cb("health returned invalid json") end
      cb(nil, info)
    end)
end

local function flush(err, server)
  local pending = waiters
  waiters = {}
  for _, cb in ipairs(pending) do
    pcall(cb, err, server)
  end
end

local function adopt(server)
  cached = server
  flush(nil, server)
end

--- Runs the CLI once; the CLI starts the background service when needed.
local function autostart(cb)
  local command = options().command or "opencode2"
  if vim.fn.executable(command) ~= 1 then
    return cb(string.format("'%s' not found in PATH (adjust server.command)", command))
  end
  log.debug("starting/validating the service via", command)
  vim.system({ command, "api", "get", "/api/health" }, { text = true, timeout = 60000 }, function()
    -- The service writes its address to service.json while starting.
    local deadline = (vim.uv or vim.loop).now() + (options().start_timeout or 15000)
    -- Forward declaration: `attempt` below refers to `retry`, and a `local
    -- function` declared after its use would resolve to a (nil) global.
    local retry
    local function attempt()
      local server = M.server_from_service(M.read_service())
      if server then
        M.probe(server, function(err)
          if not err then
            log.debug("service ready at", server.url)
            return adopt(server)
          end
          retry()
        end, 1500)
      else
        retry()
      end
    end
    retry = function()
      if (vim.uv or vim.loop).now() > deadline then
        return cb("could not start the OpenCode service")
      end
      vim.defer_fn(attempt, 250)
    end
    attempt()
  end)
end

--- Resolves the service address, starting it when necessary.
---@param cb fun(err: string?, server: opencode.http.Server?)
function M.resolve(cb)
  if cached then return cb(nil, cached) end
  if resolving then
    waiters[#waiters + 1] = cb
    return
  end
  resolving = true
  waiters[#waiters + 1] = cb

  local function done(err, server)
    resolving = false
    if err then
      flush(err, nil)
    else
      adopt(server)
    end
  end

  local configured_url = options().url
  if configured_url and configured_url ~= "" then
    local host, port, err = http.url_parts(configured_url)
    if not host then return done(err) end
    local server = { host = host, port = port, password = options().password, url = configured_url }
    return M.probe(server, function(probe_err)
      if probe_err then return done("configured server.url did not respond: " .. probe_err) end
      done(nil, server)
    end)
  end

  local service = M.read_service()
  local server = M.server_from_service(service)
  if server then
    if not alive(service.pid) then
      log.debug("service.json points to a dead pid", service.pid)
      server = nil
    end
  end

  if server then
    return M.probe(server, function(probe_err)
      if not probe_err then return done(nil, server) end
      log.debug("health failed:", probe_err)
      if options().autostart == false then return done(probe_err) end
      autostart(done)
    end)
  end

  if options().autostart == false then
    return done("no OpenCode service found and autostart = false")
  end
  autostart(done)
end

--- Describe the resolved service for `:checkhealth` and `:OpencodeHealth`.
---@return table
function M.describe()
  local service = M.read_service()
  return {
    server = cached,
    service_file = M.service_file(),
    service_exists = service ~= nil,
    service_pid = service and service.pid or nil,
    pid_alive = service ~= nil and alive(service.pid) or false,
    command = options().command,
  }
end

return M
