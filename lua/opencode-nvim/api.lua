local http = require("opencode-nvim.http")
local discovery = require("opencode-nvim.discovery")
local util = require("opencode-nvim.util")
local log = require("opencode-nvim.log")

--- Typed access to the OpenCode V2 HTTP API.
---
--- Every function follows the `cb(err, data)` convention and unwraps the
--- `{ data = ... }` envelope used by the server.
local M = {}

local function request(opts, cb, retried)
  discovery.resolve(function(resolve_err, server)
    if resolve_err then return cb(resolve_err) end
    local function done(err, status, decoded, text)
      if err and not retried then
        discovery.reset()
        return request(opts, cb, true)
      end
      if err then return cb(err) end
      if status == 401 then
        return cb(string.format("unauthorized (401) — check the password in %s", discovery.service_file()))
      end
      if status < 200 or status >= 300 then
        local message = text
        if type(decoded) == "table" then
          message = decoded.message or decoded.error or vim.inspect(decoded)
        end
        return cb({ code = status, message = message })
      end
      cb(nil, decoded, status)
    end

    http.request(server, {
      method = opts.method or "GET",
      path = opts.path,
      body = opts.body,
      accept = opts.accept,
      timeout = opts.timeout,
    }, function(err, status, _, text)
      local decoded = util.decode(text)
      done(err, status, decoded, text)
    end)
  end)
end

--- Like `request`, but only returns `body.data`.
local function data(opts, cb)
  request(opts, function(err, decoded)
    if err then return cb(err) end
    if type(decoded) == "table" and decoded.data ~= nil then
      return cb(nil, decoded.data, decoded)
    end
    cb(nil, decoded, decoded)
  end)
end

function M.raw(opts, cb)
  request(opts, cb)
end

--------------------------------------------------------------------------------
-- Server / project
--------------------------------------------------------------------------------

---@param cb fun(err: any, info: table?)
function M.health(cb)
  discovery.resolve(function(err, server)
    if err then return cb(err) end
    discovery.probe(server, function(probe_err, info)
      cb(probe_err, info, server)
    end)
  end)
end

function M.server(cb)
  discovery.resolve(function(err, server)
    if err then return cb(err) end
    cb(nil, server)
  end)
end

--------------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------------

---@param params? table `limit`, `order`, `search`, `parentID`, `directory`, `project`
function M.list_sessions(params, cb)
  data({ method = "GET", path = "/api/session" .. util.query(params) }, cb)
end

---@param body table `title`, `agent`, `model`, `location`, `permissions`, `metadata`
function M.create_session(body, cb)
  data({ method = "POST", path = "/api/session", body = body, timeout = 60000 }, cb)
end

function M.get_session(id, cb)
  data({ method = "GET", path = "/api/session/" .. id }, cb)
end

function M.delete_session(id, cb)
  data({ method = "DELETE", path = "/api/session/" .. id }, cb)
end

---@param body { text: string, files?: table[], delivery?: string, resume?: boolean }
function M.prompt(id, body, cb)
  data({ method = "POST", path = "/api/session/" .. id .. "/prompt", body = body, timeout = 60000 }, cb)
end

--- Full message page (keeps the `cursor` field).
function M.messages(id, params, cb)
  request({ method = "GET", path = "/api/session/" .. id .. "/message" .. util.query(params) }, cb)
end

function M.interrupt(id, cb)
  data({ method = "POST", path = "/api/session/" .. id .. "/interrupt", body = {}, timeout = 15000 }, cb)
end

---@param params? { from?: string, to?: string, context?: integer|string }
function M.session_diff(id, params, cb)
  data({ method = "GET", path = "/api/session/" .. id .. "/diff" .. util.query(params) }, cb)
end

function M.set_agent(id, agent, cb)
  data({ method = "POST", path = "/api/session/" .. id .. "/agent", body = { agent = agent } }, cb)
end

function M.set_model(id, model, cb)
  data({ method = "POST", path = "/api/session/" .. id .. "/model", body = { model = model } }, cb)
end

function M.revert_stage(id, body, cb)
  data({ method = "POST", path = "/api/session/" .. id .. "/revert/stage", body = body or {} }, cb)
end

function M.revert_commit(id, body, cb)
  data({ method = "POST", path = "/api/session/" .. id .. "/revert/commit", body = body or {} }, cb)
end

function M.revert_clear(id, cb)
  data({ method = "DELETE", path = "/api/session/" .. id .. "/revert" }, cb)
end

--------------------------------------------------------------------------------
-- Permissions
--------------------------------------------------------------------------------

function M.permissions(id, cb)
  data({ method = "GET", path = "/api/session/" .. id .. "/permission" }, cb)
end

function M.pending_permissions(cb)
  data({ method = "GET", path = "/api/permission/request" }, cb)
end

---@param decision "once"|"always"|"reject"
---
--- The OpenAPI documents the body key as `decision`, but the running server
--- expects `reply` (verified against this beta). Send `reply` and fall back to
--- `decision` if the server complains, so either version works.
function M.reply_permission(id, request_id, decision, message, cb)
  local path = "/api/session/" .. id .. "/permission/" .. request_id .. "/reply"

  local function send(key, allow_fallback)
    local body = { [key] = decision }
    if message and message ~= "" then body.message = message end
    request({ method = "POST", path = path, body = body, timeout = 15000 },
      function(err, decoded, status)
        if err and allow_fallback and type(err) == "table" and err.code == 400 then
          log.debug("permission reply with the key '" .. key .. "' was rejected; trying the other one")
          return send(key == "reply" and "decision" or "reply", false)
        end
        if cb then cb(err, decoded, status) end
      end)
  end

  send("reply", true)
end

--------------------------------------------------------------------------------
-- Forms (the `question` tool asks through these)
--------------------------------------------------------------------------------

function M.session_forms(id, cb)
  data({ method = "GET", path = "/api/session/" .. id .. "/form" }, cb)
end

function M.pending_forms(cb)
  data({ method = "GET", path = "/api/form/request" }, cb)
end

---@param answer table<string, string|number|boolean|string[]>
function M.reply_form(id, form_id, answer, cb)
  data({
    method = "POST",
    path = "/api/session/" .. id .. "/form/" .. form_id .. "/reply",
    body = { answer = answer },
    timeout = 15000,
  }, function(err, decoded)
    if cb then cb(err, decoded) end
  end)
end

function M.cancel_form(id, form_id, cb)
  data({
    method = "POST",
    path = "/api/session/" .. id .. "/form/" .. form_id .. "/cancel",
    timeout = 15000,
  }, function(err, decoded)
    if cb then cb(err, decoded) end
  end)
end

--------------------------------------------------------------------------------
-- Catalogues
--------------------------------------------------------------------------------

---@param directory? string location whose config should be consulted
function M.agents(directory, cb)
  local path = "/api/agent"
  if directory then
    path = path .. "?location%5Bdirectory%5D=" .. vim.uri_encode(directory)
  end
  data({ method = "GET", path = path }, cb)
end

--- Registers/loads a location.
---
--- The agent list of a directory is only populated after its location has been
--- loaded, which this endpoint does as a side effect.
---@param directory string
function M.ensure_location(directory, cb)
  data({ method = "GET", path = "/api/location?location%5Bdirectory%5D=" .. vim.uri_encode(directory) },
    function(err, info)
      if cb then cb(err, info) end
    end)
end

---@param directory? string location whose config should be consulted
function M.models(directory, cb)
  local path = "/api/model"
  if directory then
    path = path .. "?location%5Bdirectory%5D=" .. vim.uri_encode(directory)
  end
  data({ method = "GET", path = path }, cb)
end

function M.default_model(cb)
  data({ method = "GET", path = "/api/model/default" }, cb)
end

function M.fs_find(params, cb)
  data({ method = "GET", path = "/api/fs/find" .. util.query(params) }, cb)
end

---@param mode "working"|"branch"|"committed"
---@param directory? string
function M.vcs_diff(mode, directory, cb)
  local path = "/api/vcs/diff" .. util.query({ mode = mode or "working" })
  if directory then
    path = path .. "&location%5Bdirectory%5D=" .. vim.uri_encode(directory)
  end
  data({ method = "GET", path = path }, cb)
end

function M.vcs_status(cb)
  data({ method = "GET", path = "/api/vcs/status" }, cb)
end

function M.location(cb)
  data({ method = "GET", path = "/api/location" }, cb)
end

function M.commands(cb)
  data({ method = "GET", path = "/api/command" }, cb)
end

function M.run_command(id, body, cb)
  data({ method = "POST", path = "/api/session/" .. id .. "/command", body = body, timeout = 60000 }, cb)
end

---@param options? table
---@param cb? fun(err: any, agent: table?)
function M.ensure(cb, options)
  options = options or {}
  local agent = options.agent
  discovery.resolve(function(err, server)
    if err then return cb(err) end
    local function create()
      M.create_session({
        location = { directory = options.directory },
        agent = agent,
        model = options.model,
        permissions = options.permissions,
        title = options.title,
      }, cb)
    end

    if not agent then return create() end
    -- Only pass an agent the server knows about, otherwise session creation
    -- fails with a confusing error.
    M.agents(function(agents_err, agents)
      if agents_err or type(agents) ~= "table" then
        log.debug("could not list agents:", agents_err)
        return create()
      end
      local known = false
      for _, item in ipairs(agents) do
        local id = type(item) == "table" and (item.id or item.name) or nil
        if id == agent then
          known = true
          break
        end
      end
      if not known then
        log.warn(string.format("agent '%s' does not exist; using the default", agent))
        agent = nil
      end
      create()
    end)
  end)
end

return M
