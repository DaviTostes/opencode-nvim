local api = require("opencode-nvim.api")
local log = require("opencode-nvim.log")

--- Catalogue of OpenCode slash commands and agents, cached per location.
---
--- The completion menu needs the lists synchronously (Neovim's omnifunc cannot
--- wait for HTTP), so a fetch fills a cache and later calls are pure reads. The
--- lists are scoped by location: a project's `.opencode/commands` and agents only
--- show up once that location has been loaded.
local M = {}

local commands_cache = {}
local agents_cache = {}
-- In-flight fetches, keyed by directory: a burst of completion calls must not
-- fire the same request several times over. Late callbacks are queued here.
local commands_pending = {}
local agents_pending = {}

--- Forget everything (a project config or service restarted).
function M.reset()
  commands_cache = {}
  agents_cache = {}
  commands_pending = {}
  agents_pending = {}
end

--- Directory the catalogues belong to: the current session's, or the default.
---@return string
function M.directory()
  local session = require("opencode-nvim.session")
  local info = session.info()
  if info and info.location and info.location.directory then return info.location.directory end
  return session.directory()
end

--- Fetch `request` once per directory, handing the result to every caller that
--- asked while it was in flight.
---@param cache table<string, table[]>
---@param pending table<string, function[]>
---@param directory string
---@param accept fun(list: table[]): boolean whether the list is worth caching
---@param request fun(cb: fun(err: any, list: table[]?))
---@param cb fun(err: any, list: table[]?)
local function fetch(cache, pending, directory, accept, request, cb)
  if cache[directory] then return cb(nil, cache[directory]) end
  local waiting = pending[directory]
  if waiting then
    waiting[#waiting + 1] = cb
    return
  end
  waiting = { cb }
  pending[directory] = waiting
  request(function(err, list)
    local result = cache[directory]
    if not err and type(list) == "table" then
      if accept(list) then cache[directory] = list end
      result = list
    end
    pending[directory] = nil
    for _, queued in ipairs(waiting) do queued(err, result) end
  end)
end

--- Custom commands of the current location.
---@param cb fun(err: any, commands: table[]?)
function M.commands(cb)
  local directory = M.directory()
  fetch(commands_cache, commands_pending, directory, function() return true end, function(done)
    -- A location's config (and so its commands) is only read after it is loaded.
    api.ensure_location(directory, function()
      api.commands(directory, function(err, list)
        if err or type(list) ~= "table" then log.debug("commands:", tostring(err)) end
        done(err, list)
      end)
    end)
  end, cb)
end

--- Every agent of the current location (primary and subagent).
---@param cb fun(err: any, agents: table[]?)
function M.agents(cb)
  local directory = M.directory()
  -- An empty list usually means the location has not been populated yet: do not
  -- cache it, so a later call can pick the agents up.
  fetch(agents_cache, agents_pending, directory, function(list) return #list > 0 end, function(done)
    api.ensure_location(directory, function()
      api.agents(directory, function(err, list)
        if err or type(list) ~= "table" then log.debug("agents:", tostring(err)) end
        done(err, list)
      end)
    end)
  end, cb)
end

--- Cached command list (empty when nothing has been fetched yet).
---@return table[]
function M.command_list()
  return commands_cache[M.directory()] or {}
end

--- Cached agent list (empty when nothing has been fetched yet).
---@return table[]
function M.agent_list()
  return agents_cache[M.directory()] or {}
end

--- Command info by name (without the leading `/`), or nil.
---@param name string
---@return table?
function M.find_command(name)
  for _, command in ipairs(M.command_list()) do
    if type(command) == "table" and command.name == name then return command end
  end
  return nil
end

--- Agent info by id, or nil.
---@param id string
---@return table?
function M.find_agent(id)
  for _, agent in ipairs(M.agent_list()) do
    if type(agent) == "table" and (agent.id or agent.name) == id then return agent end
  end
  return nil
end

--- Only agents a prompt can attach: subagents (and agents that are both).
---@param agent table
---@return boolean
local function is_mentionable(agent)
  local mode = agent.mode or agent.type
  if agent.hidden then return false end
  return mode == "subagent" or mode == "all"
end

--- Completion items for slash commands matching `prefix` (which includes the
--- leading `/`).
---@param prefix string
---@return table[]
function M.command_items(prefix)
  local items = {}
  for _, command in ipairs(M.command_list()) do
    if type(command) == "table" and type(command.name) == "string" then
      local word = "/" .. command.name
      if word:sub(1, #prefix) == prefix then
        items[#items + 1] = { word = word, menu = command.description or "command", kind = "k" }
      end
    end
  end
  return items
end

--- Completion items for agent mentions matching `prefix` (which includes the
--- leading `@`).
---@param prefix string
---@return table[]
function M.agent_items(prefix)
  local items = {}
  for _, agent in ipairs(M.agent_list()) do
    local id = type(agent) == "table" and (agent.id or agent.name) or nil
    if id and is_mentionable(agent) then
      local word = "@" .. id
      if word:sub(1, #prefix) == prefix then
        items[#items + 1] = { word = word, menu = agent.description or "subagent", kind = "k" }
      end
    end
  end
  return items
end

--- Fetch both catalogues in the background (called when a session attaches so a
--- menu is ready by the time the user types `/` or `@`).
function M.warm()
  M.commands(function() end)
  M.agents(function() end)
end

return M
