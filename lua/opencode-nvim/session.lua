local api = require("opencode-nvim.api")
local cfg = require("opencode-nvim.config")
local discovery = require("opencode-nvim.discovery")
local event = require("opencode-nvim.event")
local log = require("opencode-nvim.log")
local sse = require("opencode-nvim.sse")
local util = require("opencode-nvim.util")

--- Current OpenCode session plus the orchestration around it.
local M = {}

---@type table?
M.current = nil

function M.id()
  return M.current and M.current.id or nil
end

function M.info()
  return M.current
end

--- Directory a new session belongs to (repository root by default).
---@return string
function M.directory()
  local configured = cfg.get().session and cfg.get().session.directory
  if configured and configured ~= "" then return configured end
  return util.root((vim.uv or vim.loop).cwd())
end

function M.relpath(path)
  local dir = (M.current and M.current.location and M.current.location.directory) or M.directory()
  return util.relative(path, dir)
end

function M.set_current(info)
  if type(info) ~= "table" or not info.id then return end
  M.current = info
  vim.api.nvim_exec_autocmds("User", { pattern = "OpencodeSessionChanged", data = info })
  event.emit({ type = "opencode.session.changed", data = info })
end

-- Agent lists are scoped per location: a project config only shows up after
-- that location is loaded (which happens when a session is created there).
local agents_cache = {}

function M.reset_agents()
  agents_cache = {}
end

local function cached_agents(directory)
  return agents_cache[directory]
end

local function agent_id(item)
  if type(item) == "table" then return item.id or item.name end
  return item
end

local function find_agent(agents, id)
  for _, item in ipairs(agents or {}) do
    if agent_id(item) == id then return item end
  end
  return nil
end

--- Agent list of a directory.
---
--- The list is only reliable once the location is loaded *and* its project
--- config has been read, so `wait_for` (an agent id) makes this retry until
--- that agent shows up.
local function agents_for(directory, cb, wait_for)
  local cached = agents_cache[directory]
  if cached and (not wait_for or find_agent(cached, wait_for)) then
    return cb(nil, cached)
  end

  local attempts = wait_for and 5 or 1

  local function attempt(index)
    api.ensure_location(directory, function()
      api.agents(directory, function(err, agents)
        if err or type(agents) ~= "table" then
          if index < attempts then
            return vim.defer_fn(function() attempt(index + 1) end, 250)
          end
          return cb(err, cached)
        end
        if #agents > #(cached or {}) then agents_cache[directory] = agents end
        if wait_for and not find_agent(agents, wait_for) and index < attempts then
          return vim.defer_fn(function() attempt(index + 1) end, 250)
        end
        cb(nil, agents)
      end)
    end)
  end

  attempt(1)
end

--- Agents of the current session directory (or the default one).
---@param cb fun(err: any, agents: table?)
function M.agents(cb)
  agents_for(M.current and M.current.location and M.current.location.directory or M.directory(), cb)
end

local function agent_asks_for_edit(item)
  local permissions = type(item) == "table" and item.permissions or {}
  for _, rule in ipairs(permissions or {}) do
    if rule.action == "edit" and rule.effect == "ask" then return true end
  end
  return false
end

--- Picks the agent for a new session.
---
--- Order of preference: an explicit agent, the configured approval agent, any
--- primary agent whose rules ask before editing, then the configured default.
---@return string|nil agent
function M.pick_agent(agents, explicit)
  if explicit then return explicit end
  local approval = cfg.approval()

  if approval.agent and find_agent(agents, approval.agent) then
    return approval.agent
  end

  if approval.auto_detect ~= false then
    local fallback
    for _, item in ipairs(agents or {}) do
      local mode = type(item) == "table" and item.mode or nil
      if mode == nil or mode == "primary" or mode == "all" then
        if agent_asks_for_edit(item) then
          local id = agent_id(item)
          if id == cfg.get().agent then return id end
          fallback = fallback or id
        end
      end
    end
    if fallback then return fallback end
  end

  local default = cfg.get().agent
  if default and find_agent(agents, default) then return default end
  return nil
end

--- True when the current session pauses edits for in-editor approval.
function M.approval_active()
  return M.current ~= nil and M.current.approval == true
end

--------------------------------------------------------------------------------
-- Models
--------------------------------------------------------------------------------

local models_cache = {}

--- Flattens the model catalogue into `{ providerID, id, variant, name }` entries.
---@param node any
---@return table[]
function M.flatten_models(node)
  local out, seen = {}, {}
  local function walk(value, provider, depth)
    if depth > 4 or type(value) ~= "table" then return end
    local id = value.id or value.modelID
    local model_provider = value.providerID or value.provider or provider
    if type(id) == "string" and type(model_provider) == "string" then
      local key = model_provider .. "/" .. id .. "/" .. tostring(value.variant or "")
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = {
          id = id,
          providerID = model_provider,
          variant = value.variant,
          name = value.name,
        }
      end
      return
    end
    if type(value.models) == "table" then
      return walk(value.models, value.id or value.providerID or provider, depth + 1)
    end
    for key, item in pairs(value) do
      if type(item) == "table" then
        walk(item, type(key) == "string" and key or provider, depth + 1)
      end
    end
  end
  walk(node, nil, 0)
  return out
end

--- Model catalogue of a directory (cached).
---@param cb fun(err: any, models: table[]?)
function M.models_for(directory, cb)
  if models_cache[directory] then return cb(nil, models_cache[directory]) end
  api.models(directory, function(err, catalog)
    if err then return cb(err, nil) end
    local models = M.flatten_models(catalog)
    if #models > 0 then models_cache[directory] = models end
    cb(nil, models)
  end)
end

--- The model the user last used (same state file the TUI keeps).
---
--- Without this the server falls back to its default model, which for
--- `opencode-go` accounts can be a free tier model that refuses to run.
---@return table? Model.Ref
function M.preferred_model()
  local path = vim.fs.joinpath(discovery.state_dir(), "model.json")
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines == 0 then return nil end
  local data = util.decode(table.concat(lines, "\n"))
  local recent = type(data) == "table" and data.recent or nil
  if type(recent) ~= "table" then return nil end
  for _, item in ipairs(recent) do
    local provider = item.providerID or item.provider
    local id = item.modelID or item.id
    if type(provider) == "string" and type(id) == "string" then
      return { providerID = provider, id = id, variant = item.variant }
    end
  end
  return nil
end

--- Resolves the model for a new session: explicit config wins, then the last
--- model used in the TUI, then the server default.
---@return table? model
---@return string? reason why a candidate was dropped
function M.resolve_model(explicit, catalog)
  -- NOTE: build the list by appending, never `{ nil, nil, preferred }`:
  -- `ipairs` stops at the first nil and the candidates would be skipped.
  local candidates = {}
  if explicit ~= nil then candidates[#candidates + 1] = explicit end
  if cfg.get().model ~= nil then candidates[#candidates + 1] = cfg.get().model end
  local preferred = M.preferred_model()
  if preferred ~= nil then candidates[#candidates + 1] = preferred end

  for _, candidate in ipairs(candidates) do
    if type(candidate) == "table" and candidate.providerID and candidate.id then
      if not catalog or #catalog == 0 then return candidate end
      for _, known in ipairs(catalog) do
        if known.id == candidate.id and known.providerID == candidate.providerID then
          return { providerID = known.providerID, id = known.id, variant = candidate.variant or known.variant }
        end
      end
      return nil, string.format("%s/%s is not available", candidate.providerID, candidate.id)
    end
  end
  return nil
end

local function create_session(directory, agent, model, opts, retry, cb)
  log.debug("creating session in", directory, "agent", tostring(agent),
    "model", model and (model.providerID .. "/" .. model.id) or "server default")
  api.create_session({
    location = { directory = directory },
    agent = agent,
    model = model,
    permissions = cfg.permission_ruleset(),
    title = opts.title,
  }, function(err, info)
    if err then
      if agent and not retry then
        -- A per-project agent may not exist for this directory yet.
        log.debug("agent", agent, "rejected:", vim.inspect(err))
        return create_session(directory, nil, model, opts, true, cb)
      end
      return cb(err)
    end
    -- Transient flag: a brand new session has no history, so the panel must not
    -- wipe the prompt that is being sent right now.
    info.fresh = true
    cb(nil, info)
  end)
end

--- Once the location is loaded its config (and so its agents) is known, so the
--- agent can be re-checked and switched to an approval agent when one exists.
local function finalize_agent(info, cb)
  local directory = info.location and info.location.directory or M.directory()
  local approval = cfg.approval()

  -- `approval = false`: never enable the approval gate, even if the session's
  -- agent asks for it (the user opted out of the whole flow).
  if not cfg.approval_enabled() then
    info.approval = false
    M.set_current(info)
    return cb(nil, info)
  end

  -- Wait for whichever agent tells us the location's config has been read.
  local wait_for = info.agent or approval.agent or cfg.get().agent

  agents_for(directory, function(_, agents)
    local current = find_agent(agents, info.agent)
    if current and agent_asks_for_edit(current) then
      info.approval = true
      M.set_current(info)
      return cb(nil, info)
    end

    local better = M.pick_agent(agents)
    local candidate = better and find_agent(agents, better)
    if candidate and better ~= info.agent and agent_asks_for_edit(candidate) then
      return api.set_agent(info.id, better, function(switch_err, updated)
        if switch_err then
          log.debug("could not enable the approval agent:", vim.inspect(switch_err))
          info.approval = false
          M.set_current(info)
          return cb(nil, info)
        end
        info = updated or info
        info.agent = better
        info.approval = true
        M.set_current(info)
        cb(nil, info)
      end)
    end

    info.approval = false
    M.set_current(info)
    cb(nil, info)
  end, wait_for)
end

---@param opts? { directory?: string, agent?: string, model?: table, title?: string, force?: boolean }
---@param cb fun(err: any, info: table?)
function M.ensure(opts, cb)
  opts = opts or {}
  -- An active session wins over the current working directory: prompts must
  -- never silently create a second session somewhere else.
  local directory = opts.directory
    or (M.current and M.current.location and M.current.location.directory)
    or M.directory()
  if M.current and not opts.force and M.current.location and M.current.location.directory == directory then
    return cb(nil, M.current)
  end

  local approval = cfg.approval()
  local agent = opts.agent or M.pick_agent(cached_agents(directory))
  -- NOTE: never *speculate* the approval agent name here. The server accepts an
  -- unknown agent at creation time and only fails when the turn runs
  -- ("Agent not found"). `finalize_agent` switches the session to it once the
  -- location is loaded and we know it exists.
  if not agent and approval.agent and find_agent(cached_agents(directory), approval.agent) then
    agent = approval.agent
  end

  -- A session creation that never answers used to leave the panel "running"
  -- forever. Every path below goes through `finish`, and a watchdog reports a
  -- clear error instead of hanging.
  local finished = false
  local timer = (vim.uv or vim.loop).new_timer()
  local function finish(err, info)
    if finished then return end
    finished = true
    timer:stop()
    timer:close()
    cb(err, info)
  end
  timer:start(25000, 0, function()
    vim.schedule(function()
      finish("timed out creating the session — check the service with :OpencodeDoctor")
    end)
  end)

  api.ensure_location(directory, function()
    M.models_for(directory, function(_, catalog)
      local model, dropped = M.resolve_model(opts.model, catalog)
      if dropped then
        log.warn(dropped .. " — falling back to the server default model")
      end
      create_session(directory, agent, model, opts, false, function(err, info)
        if err then return finish(err) end
        finalize_agent(info, finish)
      end)
    end)
  end)
end

---@param id string
function M.attach(id, cb)
  api.get_session(id, function(err, info)
    if err then return cb(err) end
    M.set_current(info)
    M.start_stream()
    -- Seed the context-window counter (the session GET does not carry it).
    M.refresh_context()
    -- Detect whether this session's agent pauses edits for approval.
    local directory = info.location and info.location.directory or M.directory()
    agents_for(directory, function(_, agents)
      local item = find_agent(agents, info.agent)
      info.approval = cfg.approval_enabled() and item ~= nil and agent_asks_for_edit(item) or false
      M.set_current(info)
      cb(nil, info)
    end, info.agent)
  end)
end

function M.new(opts, cb)
  opts = vim.tbl_extend("force", { force = true }, opts or {})
  M.ensure(opts, cb)
end

function M.refresh(cb)
  if not M.current then return cb and cb(nil, nil) end
  api.get_session(M.current.id, function(err, info)
    if not err and info then
      info.approval = M.current.approval
      -- The context usage is not part of the session GET; keep what the last
      -- `session.step.ended` (or `refresh_context`) measured.
      info.context_tokens = M.current.context_tokens
      M.current = info
      -- the panel picks up new tokens/cost/title without replaying history
      -- (on_session ignores a change for the same session)
      event.emit({ type = "opencode.session.changed", data = info })
    end
    if cb then cb(err, info) end
  end)
end

--- Undo the last turn: revert the session to the newest user message.
---@param cb? fun(err: any)
function M.revert_last_turn(cb)
  local id = M.id()
  if not id then
    if cb then cb("no active session") end
    return
  end
  api.messages(id, { limit = 20, order = "desc" }, function(err, page)
    if err then
      if cb then cb(err) end
      return
    end
    for _, message in ipairs((type(page) == "table" and page.data) or {}) do
      if message.type == "user" then
        -- `files = true` restores the working tree as well, not just messages.
        local body = { messageID = message.id, files = true }
        api.revert_stage(id, body, function(stage_err)
          if stage_err then
            if cb then cb(stage_err) end
            return
          end
          api.revert_commit(id, {}, function(commit_err)
            if commit_err then
              if cb then cb(commit_err) end
              return
            end
            require("opencode-nvim.reload").reload_all()
            M.refresh()
            M.refresh_context()
            if cb then cb(nil) end
          end)
        end)
        return
      end
    end
    if cb then cb("no turn to undo") end
  end)
end

function M.start_stream()
  -- `event.start` attaches the bus to the stream; a bare `sse.start` would
  -- connect and drop every event.
  event.start()
end

--- Send a prompt to the current session, creating one when needed.
---@param text string
---@param opts? { files?: table[], delivery?: string, new_session?: boolean, on_session?: fun(info: table) }
function M.prompt(text, opts, cb)
  opts = opts or {}
  M.ensure({ force = opts.new_session }, function(err, info)
    if err then
      if cb then cb(err) end
      return
    end
    if opts.on_session then pcall(opts.on_session, info) end

    local function send()
      local body = { text = text }
      if opts.files and #opts.files > 0 then body.files = opts.files end
      if opts.delivery then body.delivery = opts.delivery end
      api.prompt(info.id, body, function(prompt_err, inbox)
        if cb then cb(prompt_err, inbox, info) end
      end)
    end

    -- Connect the event stream first so no delta is missed.
    if sse.connected() then return send() end
    sse.ensure(function(stream_err)
      if stream_err then log.warn("event stream: " .. tostring(stream_err)) end
      send()
    end)
  end)
end

function M.interrupt(cb)
  if not M.current then return cb and cb(nil) end
  api.interrupt(M.current.id, cb or function() end)
end

--- Diff of the current turn. `source` is "turn" when it came from the session
--- snapshots and "working" when it is the repository's working tree.
function M.diff(opts, cb)
  local current = M.current
  if not current then return cb("no active session", nil) end
  opts = opts or {}
  local directory = current.location and current.location.directory

  api.session_diff(current.id, {
    context = opts.context == nil and 3 or opts.context,
    from = opts.from,
  }, function(err, patches)
    if not err and type(patches) == "table" and #patches > 0 then
      return cb(nil, patches, "turn")
    end
    api.vcs_diff("working", directory, function(vcs_err, vcs_patches)
      if vcs_err then return cb(err or vcs_err, nil, "turn") end
      cb(nil, vcs_patches or {}, "working")
    end)
  end)
end

function M.list(cb)
  local directory = M.directory()
  api.list_sessions({ directory = directory, limit = 50, parentID = "null" }, function(err, sessions)
    if err then return cb(err) end
    cb(nil, sessions or {})
  end)
end

--- Cumulative session usage (every turn, cache reads included) and cost.
function M.tokens()
  local current = M.current
  if not current or not current.tokens then return 0, 0 end
  local tokens = current.tokens
  local total = (tokens.input or 0) + (tokens.output or 0)
  local cache = tokens.cache or {}
  total = total + (cache.read or 0) + (cache.write or 0)
  return total, current.cost or 0
end

--- Tokens of one request's prompt: what actually occupies the context window.
---
--- `input` is only the uncached part; the cache reads/writes are the rest of the
--- same prompt, not a second copy of it.
local function prompt_tokens(tokens)
  if type(tokens) ~= "table" then return nil end
  local cache = tokens.cache or {}
  local total = (tokens.input or 0) + (cache.read or 0) + (cache.write or 0)
  if total <= 0 then return nil end
  return total
end

--- Context-window usage of the current session: the size of the last request's
--- prompt.
---
--- Deliberately *not* the session's cumulative `tokens`: that is a running sum
--- of every turn (cache reads included), so the same context is counted once
--- per turn and a 100k context shows up as millions.
function M.context_tokens()
  local current = M.current
  return current and current.context_tokens or 0
end

--- Fill in the context-window usage from the server's active context. The
--- `session.step.ended` event keeps it current while a turn streams; this is
--- what seeds it when attaching an existing session (or after a revert).
function M.refresh_context(cb)
  local current = M.current
  if not current then return cb and cb(nil) end
  api.session_context(current.id, function(err, messages)
    if err then
      log.debug("context:", vim.inspect(err))
      return cb and cb(err)
    end
    -- The session may have been replaced while the request was in flight.
    if current ~= M.current then return cb and cb(nil) end
    for index = #(messages or {}), 1, -1 do
      local used = prompt_tokens(messages[index].tokens)
      if used then
        current.context_tokens = used
        event.emit({ type = "opencode.session.context", data = current })
        break
      end
    end
    if cb then cb(nil) end
  end)
end

--- Short string for the statusline.
function M.statusline()
  if not M.current then return "" end
  local _, cost = M.tokens()
  local used = M.context_tokens()
  local parts = { "opencode" }
  local model = M.current.model and (M.current.model.id or M.current.model.modelID)
  if model then parts[#parts + 1] = model end
  if used > 0 then
    parts[#parts + 1] = string.format("%.1fk tok", used / 1000)
  end
  if cost > 0 then
    parts[#parts + 1] = string.format("$%.4f", cost)
  end
  return table.concat(parts, " ")
end

function M.on_event(ev)
  local info = ev.data or {}
  local sid = info.sessionID or info.sessionId or info.id
  local current = M.current
  local kind = ev.type

  if kind == "session.usage.updated" or kind == "session.updated" then
    if current and sid == current.id then
      if info.tokens then current.tokens = info.tokens end
      if info.cost ~= nil then current.cost = info.cost end
      if info.model then current.model = info.model end
      if info.agent then current.agent = info.agent end
      if info.title then current.title = info.title end
    end
  elseif kind == "session.step.ended" then
    -- Each step reports the prompt it sent: its size is the current context
    -- window usage (unlike `session.usage.updated`, which is cumulative).
    if current and sid == current.id then
      local used = prompt_tokens(info.tokens)
      if used then
        current.context_tokens = used
        event.emit({ type = "opencode.session.context", data = current })
      end
    end
  elseif kind == "session.execution.succeeded" or kind == "session.execution.failed"
    or kind == "session.execution.interrupted" or kind == "session.idle" then
    if not current or sid == nil or sid == current.id then M.refresh() end
  elseif kind == "session.model.selected" then
    if current and sid == current.id and info.model then current.model = info.model end
  elseif kind == "session.agent.selected" then
    if current and sid == current.id and info.agent then current.agent = info.agent end
  end
end

function M.reset()
  M.current = nil
end

return M
