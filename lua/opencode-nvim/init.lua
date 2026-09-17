local api = require("opencode-nvim.api")
local cfg = require("opencode-nvim.config")
local discovery = require("opencode-nvim.discovery")
local event = require("opencode-nvim.event")
local log = require("opencode-nvim.log")
local panel = require("opencode-nvim.ui.panel")
local permission = require("opencode-nvim.permission")
local picker = require("opencode-nvim.ui.picker")
local reload = require("opencode-nvim.reload")
local session = require("opencode-nvim.session")
local util = require("opencode-nvim.util")

--- Public entry point.
local M = {}

M._setup_done = false

local function err_text(err)
  if type(err) == "table" then return err.message or vim.inspect(err) end
  return tostring(err)
end

local function fail(prefix, err)
  log.notify(prefix .. ": " .. err_text(err), vim.log.levels.ERROR)
end

function M.define_highlights()
  local definitions = {
    OpencodeNormal = { link = "NormalFloat" },
    OpencodeBorder = { link = "FloatBorder" },
    OpencodeTitle = { link = "Title" },
    OpencodeUser = { link = "Title" },
    OpencodeDim = { link = "Comment" },
    OpencodeTool = { link = "Function" },
    OpencodeToolOk = { link = "DiagnosticOk" },
    OpencodeToolFail = { link = "DiagnosticError" },
    OpencodeError = { link = "DiagnosticError" },
    OpencodeNote = { link = "Special" },
    OpencodeMeta = { link = "Comment" },
  }
  for name, spec in pairs(definitions) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

function M.wire()
  if M._wired then return end
  M._wired = true
  event.on_any(function(ev)
    panel.on_event(ev)
    permission.on_event(ev)
    reload.on_event(ev)
    session.on_event(ev)
  end)

  -- Attach the bus to the SSE stream. This is what turns the stream into
  -- rendered text, tool lines, permission popups and buffer reloads.
  event.start()
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function command(name, fn, opts)
  opts = opts or {}
  opts.desc = opts.desc or "opencode-nvim"
  vim.api.nvim_create_user_command(name, fn, opts)
end

function M.create_commands()
  command("Opencode", function() M.toggle() end, { desc = "toggle the opencode panel" })
  command("OpencodeAsk", function(args)
    local prefill = args.args ~= "" and args.args or nil
    M.ask(prefill, M.range_from_args(args), { fresh = true })
  end, { nargs = "*", range = true, desc = "ask opencode (range: uses the selection)" })
  command("OpencodeNew", function() M.new_session() end, { desc = "new opencode session" })
  command("OpencodeAttach", function(args)
    session.attach(args.args, function(err)
      if err then return fail("attach", err) end
      panel.open({ input = false })
    end)
  end, { nargs = 1, desc = "attach an existing session" })
  command("OpencodeSessions", function() M.select_session() end, { desc = "pick a session" })
  command("OpencodeModels", function() M.select_model() end, { desc = "pick the model" })
  command("OpencodeAgents", function() M.select_agent() end, { desc = "pick the agent" })
  command("OpencodeInterrupt", function() M.interrupt() end, { desc = "interrupt the running turn" })
  command("OpencodeUndo", function() M.undo() end, { desc = "undo the last turn" })
  command("OpencodeApproval", function() M.approval_status() end, { desc = "in-editor approval status" })
  command("OpencodeApprovalAgent", function() M.setup_approval_agent() end, { desc = "create the approval agent in the OpenCode config" })
  command("OpencodeDiff", function() M.diff() end, { desc = "diff of the last turn" })
  command("OpencodeActions", function() M.choose_action() end, { desc = "pick a ready-made action" })
  command("OpencodeEdit", function(args)
    M.edit_this(M.range_from_args(args))
  end, { range = true, desc = "ask for a change in the selection (or file)" })
  command("OpencodePermissions", function() permission.select() end, { desc = "pending permissions" })
  command("OpencodeEvents", function() M.events() end, { desc = "events received from the server" })
  command("OpencodeHealth", function() M.health() end, { desc = "check the connection to opencode" })
  command("OpencodeClose", function() M.close() end, { desc = "close the panel" })
  command("OpencodeResend", function() M.resend() end, { desc = "send the last prompt again" })
  command("OpencodeClear", function() M.clear() end, { desc = "clear the panel" })
  command("OpencodeDoctor", function() M.doctor() end, { desc = "diagnose a turn that never answers" })
  command("OpencodeLog", function(args)
    local level = util.trim(args.args)
    if level == "" then
      log.notify("log level = " .. cfg.get().log.level)
      return
    end
    cfg.get().log.level = level
    log.level = level
    log.notify("log level = " .. level)
  end, { nargs = "?", desc = "opencode-nvim log level" })
end

function M.create_keymaps()
  local keys = cfg.get().keymaps or {}
  if keys.enabled ~= true then return end

  local function map(mode, lhs, rhs, desc)
    if type(lhs) ~= "string" or lhs == "" then return end
    vim.keymap.set(mode, lhs, rhs, { desc = "opencode: " .. desc, silent = true })
  end

  map({ "n", "x" }, keys.toggle, function() M.toggle() end, "toggle the panel")
  local function in_visual()
    return vim.fn.mode():find("[vV\22]") ~= nil
  end

  map({ "n", "x" }, keys.ask, function()
    M.ask(nil, in_visual() and M.selection_range() or nil)
  end, "ask")
  map({ "n", "x" }, keys.ask_buffer, function() M.ask("@buffer ") end, "ask with the buffer")
  map({ "n", "x" }, keys.edit, function()
    M.edit_this(in_visual() and M.selection_range() or nil)
  end, "edit this")
  map({ "n", "x" }, keys.actions, function() M.choose_action() end, "pick an action")
  map("n", keys.sessions, function() M.select_session() end, "sessions")
  map("n", keys.models, function() M.select_model() end, "model")
  map("n", keys.agents, function() M.select_agent() end, "agent")
  map("n", keys.diff, function() M.diff() end, "diff of the last turn")
  map("n", keys.interrupt, function() M.interrupt() end, "interrupt")
  map("n", keys.undo, function() M.undo() end, "undo the last turn")
  map({ "n", "x" }, keys.events, function() M.events() end, "events")
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

---@param opts? table
function M.setup(opts)
  local options = cfg.setup(opts)
  if options.reload.set_autoread and not vim.o.autoread then
    vim.o.autoread = true
  end

  _G.opencode_nvim_omnifunc = function(findstart, base)
    return panel.complete(findstart == true and 1 or findstart, base)
  end

  M.define_highlights()
  M.create_commands()
  M.create_keymaps()
  M.wire()
  M._setup_done = true
  log.debug("setup done")
  return M
end

function M._autosetup()
  if M._setup_done then return end
  M.setup({})
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

function M.toggle()
  M._autosetup()
  panel.toggle()
end

function M.open(opts)
  M._autosetup()
  return panel.open(opts)
end

function M.close()
  panel.close()
end

---@param prefill? string
---@param selection? { bufnr: integer, first: integer, last: integer }
---@param opts? { fresh?: boolean }
function M.ask(prefill, selection, opts)
  M._autosetup()
  opts = opts or {}
  panel.open({ prefill = prefill, selection = selection, fresh = opts.fresh })
end

--- Selection opened by a `:Opencode...` command used with a range (from visual
--- mode). Returns nil when the command was used without a range.
--- Range of the current visual selection (used by keymaps in visual mode).
---@return { bufnr: integer, first: integer, last: integer }?
function M.selection_range()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if first == 0 or last == 0 then return nil end
  if first > last then first, last = last, first end
  return { bufnr = vim.api.nvim_get_current_buf(), first = first, last = last }
end

---@param args table command args from nvim_create_user_command
---@return { bufnr: integer, first: integer, last: integer }?
function M.range_from_args(args)
  if not args or not args.range or args.range == 0 then return nil end
  return { bufnr = vim.api.nvim_get_current_buf(), first = args.line1, last = args.line2 }
end

---@param text string
---@param opts? { delivery?: string, new_session?: boolean }
function M.prompt(text, opts)
  M._autosetup()
  panel.send(text, opts or {})
end

function M.interrupt()
  session.interrupt()
end

--- Send the last prompt again (the provider hiccups often).
function M.resend()
  M._autosetup()
  panel.retry()
end

function M.diff()
  panel.show_diff()
end

function M.clear()
  panel.clear()
end

function M.new_session()
  session.new({}, function(err)
    if err then return fail("new session", err) end
    -- Show it, without taking the cursor away from the code.
    panel.open({ input = false })
  end)
end

--- Ready-made instructions, so daily actions are one pick away.
M.actions = {
  { label = "explain this code", prompt = "@this\n\nExplain what this code does, briefly." },
  { label = "find bugs here", prompt = "@this\n\nFind bugs, edge cases or risky assumptions in the code above." },
  { label = "write tests", prompt = "@this\n\nWrite tests for the code above." },
  { label = "refactor this", prompt = "@this\n\nRefactor the code above for clarity, keeping the behaviour identical." },
  { label = "document this", prompt = "@this\n\nAdd comments/documentation to the code above." },
  { label = "explain this file", prompt = "@buffer\n\nExplain what this file does and how it fits the project." },
  { label = "review my changes", prompt = "@diff\n\nReview the changes above and point out problems." },
  { label = "commit message", prompt = "@diff\n\nSuggest a commit message for the changes above." },
}

--- Pick a ready-made action and pre-fill the prompt with it.
function M.choose_action()
  M._autosetup()
  local labels = {}
  for _, action in ipairs(M.actions) do labels[#labels + 1] = action.label end
  picker.pick(labels, { name = "opencode actions" }, function(choice)
    if not choice then return end
    for _, action in ipairs(M.actions) do
      if action.label == choice then
        return M.ask(action.prompt .. "\n", nil, { fresh = true })
      end
    end
  end)
end

--- Ask for a change in the code you are looking at. Goes through the normal
--- approval flow, so nothing is written before you see the diff.
function M.edit_this(selection)
  M._autosetup()
  M.ask("@this\n\nEdit the code above as follows: ", selection, { fresh = true })
end

function M.select_session()
  session.list(function(err, sessions)
    if err then return fail("sessions", err) end
    local items, map = { "+ new session" }, {}
    for _, info in ipairs(sessions or {}) do
      local title = (info.title or "(untitled)"):gsub("%s+", " ")
      if #title > 60 then title = title:sub(1, 57) .. "..." end
      local label = string.format("%s  %s  [%s]", info.id, title, info.agent or "?")
      items[#items + 1] = label
      map[label] = info
    end
    picker.pick(items, { name = "opencode sessions" }, function(choice)
      if not choice then return end
      if choice == "+ new session" then return M.new_session() end
      local info = map[choice]
      if not info then return end
      session.attach(info.id, function(attach_err)
        if attach_err then return fail("attach", attach_err) end
        panel.open({ input = false })
      end)
    end)
  end)
end

--- Label for a model entry, marking the one the session is using.
---@param model { providerID: string, id: string, variant?: string }
---@param current? { providerID: string, id: string }
---@return string
function M.model_label(model, current)
  local label = string.format("%s/%s", model.providerID, model.id)
  if model.variant then label = label .. " · " .. model.variant end
  if current and current.id == model.id and current.providerID == model.providerID then
    label = "● " .. label
  end
  return label
end

function M.select_model()
  local info = session.info()
  if not info then return log.notify("no active session") end
  local directory = info.location and info.location.directory or nil
  session.models_for(directory, function(err, models)
    if err then return fail("models", err) end
    local items, map = {}, {}
    for _, model in ipairs(models or {}) do
      local label = M.model_label(model, info.model)
      if not map[label] then
        items[#items + 1] = label
        map[label] = model
      end
    end
    table.sort(items)
    if #items == 0 then return log.notify("no model available") end
    picker.pick(items, { name = "models (● = current)" }, function(choice)
      if not choice then return end
      local model = map[choice]
      api.set_model(session.id(), model, function(set_err)
        if set_err then return fail("switch model", set_err) end
        -- show it straight away, the event completes the picture later
        if session.info() then session.info().model = model end
        log.notify("model: " .. choice)
      end)
    end)
  end)
end

--- Label for an agent entry, marking the one the session is using.
---@param agent table
---@param current? string
---@return string?
function M.agent_label(agent, current)
  local id = agent.id or agent.name
  local mode = agent.mode or agent.type
  if not id or mode == "subagent" or mode == "hidden" then return nil end
  local label = id .. (agent.description and ("  " .. agent.description) or "")
  if #label > 80 then label = label:sub(1, 77) .. "..." end
  if current and current == id then label = "● " .. label end
  return label
end

function M.select_agent()
  local info = session.info()
  if not info then return log.notify("no active session") end
  api.agents(function(err, agents)
    if err then return fail("agents", err) end
    local items, map = {}, {}
    for _, agent in ipairs(agents or {}) do
      if type(agent) == "table" then
        local label = M.agent_label(agent, info.agent)
        if label and not map[label] then
          items[#items + 1] = label
          map[label] = agent.id or agent.name
        end
      end
    end
    if #items == 0 then return log.notify("no agent available") end
    picker.pick(items, { name = "agents (● = current)" }, function(choice)
      if not choice then return end
      api.set_agent(session.id(), map[choice], function(set_err)
        if set_err then return fail("switch agent", set_err) end
        if session.info() then session.info().agent = map[choice] end
        log.notify("agent: " .. map[choice])
      end)
    end)
  end)
end

function M.undo()
  if not session.id() then return log.notify("no active session") end
  session.revert_last_turn(function(err)
    if err then return fail("undo", err) end
    log.notify("last turn undone")
  end)
end

--- Path of the global OpenCode config, preferring an existing file.
function M.global_config_path()
  local base = vim.env.XDG_CONFIG_HOME
  if not base or base == "" then
    base = vim.fs.joinpath(vim.env.HOME or "~", ".config")
  end
  local dir = vim.fs.joinpath(base, "opencode")
  for _, name in ipairs({ "opencode.json", "opencode.jsonc" }) do
    local path = vim.fs.joinpath(dir, name)
    if vim.fn.filereadable(path) == 1 then return path end
  end
  return vim.fs.joinpath(dir, "opencode.json")
end

local function approval_agent_definition()
  local approval = cfg.get().approval or {}
  return {
    description = "OpenCode inside Neovim: asks for approval before editing files and running shell",
    mode = "primary",
    permissions = approval.permissions or {
      { action = "edit", resource = "*", effect = "ask" },
      { action = "shell", resource = "*", effect = "ask" },
    },
  }
end

--- Minimal pretty printer (sorted keys, 2 spaces) for writing config files.
local function pretty_json(value, indent)
  indent = indent or ""
  local kind = type(value)
  if kind ~= "table" then
    if kind == "string" then return vim.json.encode(value) end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    return "null"
  end
  if vim.islist(value) then
    if #value == 0 then return "[]" end
    local parts = {}
    for _, item in ipairs(value) do
      parts[#parts + 1] = indent .. "  " .. pretty_json(item, indent .. "  ")
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
  end
  local keys = vim.tbl_keys(value)
  table.sort(keys)
  if #keys == 0 then return "{}" end
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = string.format("%s  %s: %s", indent, vim.json.encode(key), pretty_json(value[key], indent .. "  "))
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

M.pretty_json = pretty_json

--- Writes an approval agent into the OpenCode config (real pre-approval).
function M.setup_approval_agent()
  local path = M.global_config_path()
  local text = vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path), "\n") or ""
  local config = util.decode(text)
  local name = (cfg.get().approval or {}).agent or "opencode-nvim"

  if text ~= "" and config == nil then
    require("opencode-nvim.ui.diff").text({
      title = "cole no seu config do OpenCode",
      lines = vim.split(pretty_json({ agents = { [name] = approval_agent_definition() } }), "\n"),
      filetype = "json",
      width = 0.8,
      height = 0.5,
    })
    log.notify("could not edit " .. path .. " (comments in the file?); copy the snippet from the window", vim.log.levels.WARN)
    return
  end

  config = config or {}
  config.agents = config.agents or {}
  config.agents[name] = approval_agent_definition()

  local ok, err = pcall(vim.fn.writefile, vim.split(pretty_json(config), "\n"), path)
  if not ok then return fail("escrever " .. path, err) end
  session.reset_agents()
  log.notify(string.format(
    "agent '%s' written to %s — run `opencode2 service restart` and open a new session", name, path))
end

--- Shows which agents pause for approval.
function M.approval_status()
  session.agents(function(err, agents)
    local approval = cfg.get().approval or {}
    local configured = approval.agent or "opencode-nvim"
    local lines = { "In-editor approval (diff before writing)", "" }

    if err then
      lines[#lines + 1] = "could not list agents: " .. err_text(err)
    end

    local found = false
    for _, item in ipairs(agents or {}) do
      local id = item.id or item.name
      local asks = {}
      for _, rule in ipairs(item.permissions or {}) do
        if rule.effect == "ask" and (rule.action == "edit" or rule.action == "shell" or rule.action == "*") then
          asks[#asks + 1] = rule.action
        end
      end
      if #asks > 0 then
        lines[#lines + 1] = string.format("  %-16s mode=%-8s ask: %s", tostring(id), tostring(item.mode), table.concat(asks, ", "))
        if id == configured then found = true end
      end
    end
    if #lines == 2 then lines[#lines + 1] = "  (no agent asks for approval)" end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("approval agent configured: %s (%s)", configured, found and "found" or "missing")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Without an approval agent the plugin reviews the turn afterwards:"
    lines[#lines + 1] = "  :OpencodeDiff  shows the changes"
    lines[#lines + 1] = "  :OpencodeUndo  undoes the turn"
    lines[#lines + 1] = ""
    lines[#lines + 1] = ":OpencodeApprovalAgent  creates the agent in the OpenCode config"

    require("opencode-nvim.ui.diff").text({ title = "opencode · approval", lines = lines })
  end)
end

function M.events()
  local history = event.history()
  local lines = {}
  local start = math.max(1, #history - 200)
  for index = start, #history do
    local item = history[index]
    local ok, payload = pcall(vim.json.encode, item.data or {})
    if not ok then payload = "?" end
    if #payload > 500 then payload = payload:sub(1, 500) .. "..." end
    lines[#lines + 1] = string.format("%s  %s", item.type, payload)
  end
  if #lines == 0 then lines = { "(no events received yet)" } end
  require("opencode-nvim.ui.diff").text({
    title = "opencode · eventos",
    lines = lines,
    filetype = "json",
    width = 0.9,
    height = 0.8,
  })
end

function M.health()
  local info = discovery.describe()
  local lines = {
    "service file: " .. info.service_file,
    "service registered: " .. tostring(info.service_exists) .. "  (pid alive: " .. tostring(info.pid_alive) .. ")",
    "comando: " .. tostring(info.command),
    "stream de eventos: " .. event.status(),
    "current session: " .. tostring(session.id() or "(none)"),
    "pending permissions: " .. tostring(#permission.pending()),
    "autoread: " .. tostring(vim.o.autoread),
    "",
  }
  api.health(function(err, health, server)
    if err then
      lines[#lines + 1] = "connection: FAILED — " .. err_text(err)
    else
      lines[#lines + 1] = "connection: ok — " .. tostring(server and server.url or "?")
      local ok, encoded = pcall(vim.inspect, health)
      lines[#lines + 1] = "server: " .. (ok and encoded or "?")
    end
    local current = session.info()
    if current then
      lines[#lines + 1] = string.format("session: %s  agent=%s  model=%s",
        current.id, tostring(current.agent), tostring(current.model and (current.model.id or current.model.modelID)))
    end
    require("opencode-nvim.ui.diff").text({ title = "opencode · health", lines = lines })
  end)
end

function M.status()
  return {
    session = session.info(),
    server = discovery.current(),
    stream = event.status(),
    connected = event.connected(),
    panel = panel.visible(),
    permissions = #permission.pending(),
  }
end

function M.statusline()
  return session.statusline()
end

--- Compact one-line token summary.
local function tokens_summary(tokens)
  tokens = tokens or {}
  local cache = tokens.cache or {}
  return string.format("in=%d out=%d reasoning=%d cache_read=%d cache_write=%d",
    tokens.input or 0, tokens.output or 0, tokens.reasoning or 0, cache.read or 0, cache.write or 0)
end

--- Live diagnosis for a turn that never answers: is the server reachable, is
--- the stream alive, what did the session actually do, what was the last event?
function M.doctor()
  local lines = { "opencode-nvim doctor", "" }
  local pending, shown = 0, false

  local function show()
    if shown then return end
    shown = true
    require("opencode-nvim.ui.diff").text({
      title = "opencode · doctor",
      lines = lines,
      width = 0.9,
      height = 0.8,
    })
  end

  local function finish()
    pending = pending - 1
    if pending <= 0 then show() end
  end

  local function job(fn)
    pending = pending + 1
    fn(function(line)
      if line then lines[#lines + 1] = line end
      finish()
    end)
  end

  local info = session.info()
  local directory = info and info.location and info.location.directory

  job(function(cb)
    api.health(function(err, health, server)
      if err then return cb("server: UNREACHABLE — " .. err_text(err)) end
      cb(string.format("server: %s  version=%s  pid=%s", tostring(server.url),
        tostring(health.version), tostring(health.pid)))
    end)
  end)

  job(function(cb)
    local sse = require("opencode-nvim.sse")
    cb(string.format("event stream: %s  connected=%s  handler=%s", sse.status(),
      tostring(sse.connected()), tostring(sse.has_handler())))
  end)

  job(function(cb)
    if not info then return cb("session: none yet") end
    local model = info.model and string.format("%s/%s", info.model.providerID, info.model.id) or "?"
    cb(string.format("session: %s  agent=%s  model=%s  approval=%s  dir=%s",
      info.id, tostring(info.agent), model, tostring(info.approval), tostring(directory)))
  end)

  job(function(cb)
    if not info then return cb(nil) end
    api.get_session(info.id, function(err, fresh)
      if err then return cb("session GET: " .. err_text(err)) end
      local updated = fresh.time and fresh.time.updated
      cb(string.format("session state: cost=%s  %s%s", tostring(fresh.cost),
        tokens_summary(fresh.tokens),
        updated and ("  updated " .. os.date("%H:%M:%S", math.floor(updated / 1000))) or ""))
    end)
  end)

  job(function(cb)
    if not info then return cb(nil) end
    api.messages(info.id, { limit = 3, order = "desc" }, function(err, page)
      if err then return cb("messages: " .. err_text(err)) end
      local out = {}
      for index, message in ipairs(page.data or {}) do
        if index > 3 then break end
        local detail = tostring(message.type)
        if message.type == "assistant" then
          detail = detail .. string.format("  finish=%s", tostring(message.finish))
          local reason = util.deep_find(message.error, { "message", "type" })
          if reason then detail = detail .. "  error=" .. tostring(reason) end
        end
        out[#out + 1] = string.format("  %s  (created %s)", detail,
          os.date("%H:%M:%S", math.floor((message.time and message.time.created or 0) / 1000)))
      end
      cb("last messages:\n" .. (#out > 0 and table.concat(out, "\n") or "  (none)"))
    end)
  end)

  job(function(cb)
    cb(string.format("pending permissions: %d", #permission.pending()))
  end)

  job(function(cb)
    -- Whatever nvim complained about last is usually the thing to fix.
    cb("last nvim error: " .. (vim.v.errmsg ~= "" and vim.v.errmsg or "(none)"))
  end)

  job(function(cb)
    local history = event.history()
    local now = os.time()
    local out = {}
    for index = #history, 1, -1 do
      local item = history[index]
      local sid = util.pick_string(item.data or {}, { "sessionID" })
      if not info or not sid or sid == info.id then
        local age = item.created and (now - math.floor(item.created / 1000)) or nil
        out[#out + 1] = string.format("  %-34s %s", item.type, age and (age .. "s ago") or "?")
        if #out >= 8 then break end
      end
    end
    cb("last events for this session:\n" .. (#out > 0 and table.concat(out, "\n")
      or "  (none — the stream may be pointing at another session/server)"))
  end)

  job(function(cb)
    local approval = cfg.get().approval or {}
    cb(string.format("config: agent=%s  approval.agent=%s  review=%s  autoread=%s",
      tostring(cfg.get().agent), tostring(approval.agent), tostring(approval.review), tostring(vim.o.autoread)))
  end)

  -- Never leave the user without an answer, even if a probe hangs.
  vim.defer_fn(function()
    if shown then return end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "(some checks did not answer in time)"
    show()
  end, 8000)
end

function M.complete(findstart, base)
  return panel.complete(findstart, base)
end

return M
