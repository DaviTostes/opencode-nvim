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
  command("Opencode", function() M.toggle() end, { desc = "alterna o painel do opencode" })
  command("OpencodeAsk", function(args)
    local prefill = args.args ~= "" and args.args or nil
    M.ask(prefill)
  end, { nargs = "*", desc = "pergunta ao opencode" })
  command("OpencodeNew", function() M.new_session() end, { desc = "nova sessão do opencode" })
  command("OpencodeAttach", function(args)
    session.attach(args.args, function(err)
      if err then fail("attach", err) end
    end)
  end, { nargs = 1, desc = "anexa uma sessão existente" })
  command("OpencodeSessions", function() M.select_session() end, { desc = "escolhe uma sessão" })
  command("OpencodeModels", function() M.select_model() end, { desc = "escolhe o modelo" })
  command("OpencodeAgents", function() M.select_agent() end, { desc = "escolhe o agente" })
  command("OpencodeInterrupt", function() M.interrupt() end, { desc = "interrompe a execução" })
  command("OpencodeUndo", function() M.undo() end, { desc = "desfaz o último turno" })
  command("OpencodeApproval", function() M.approval_status() end, { desc = "estado da aprovação no editor" })
  command("OpencodeApprovalAgent", function() M.setup_approval_agent() end, { desc = "cria o agente de aprovação no config do OpenCode" })
  command("OpencodeDiff", function() M.diff() end, { desc = "diff do último turno" })
  command("OpencodePermissions", function() permission.select() end, { desc = "permissões pendentes" })
  command("OpencodeEvents", function() M.events() end, { desc = "eventos recebidos do servidor" })
  command("OpencodeHealth", function() M.health() end, { desc = "checa a conexão com o opencode" })
  command("OpencodeLog", function(args)
    local level = util.trim(args.args)
    if level == "" then
      log.notify("log level = " .. cfg.get().log.level)
      return
    end
    cfg.get().log.level = level
    log.level = level
    log.notify("log level = " .. level)
  end, { nargs = "?", desc = "nível de log do opencode-nvim" })
end

function M.create_keymaps()
  local keys = cfg.get().keymaps or {}
  if keys.enabled == false then return end

  local function map(mode, lhs, rhs, desc)
    if type(lhs) ~= "string" or lhs == "" then return end
    vim.keymap.set(mode, lhs, rhs, { desc = "opencode: " .. desc, silent = true })
  end

  map({ "n", "x" }, keys.toggle, function() M.toggle() end, "alterna painel")
  map({ "n", "x" }, keys.ask, function()
    if vim.fn.mode():find("[vV\22]") then
      local first, last = vim.fn.line("v"), vim.fn.line(".")
      if first > last then first, last = last, first end
      local bufnr = vim.api.nvim_get_current_buf()
      M.ask(nil, { bufnr = bufnr, first = first, last = last })
    else
      M.ask()
    end
  end, "pergunta")
  map({ "n", "x" }, keys.ask_buffer, function() M.ask("@buffer ") end, "pergunta com o buffer")
  map("n", keys.sessions, function() M.select_session() end, "sessões")
  map("n", keys.models, function() M.select_model() end, "modelo")
  map("n", keys.agents, function() M.select_agent() end, "agente")
  map("n", keys.diff, function() M.diff() end, "diff do turno")
  map("n", keys.interrupt, function() M.interrupt() end, "interromper")
  map("n", keys.undo, function() M.undo() end, "desfazer turno")
  map({ "n", "x" }, keys.events, function() M.events() end, "eventos")
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
  log.debug("setup concluído")
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

function M.ask(prefill, selection)
  M._autosetup()
  panel.open({ prefill = prefill, selection = selection })
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

function M.diff()
  panel.show_diff()
end

function M.clear()
  panel.clear()
end

function M.new_session()
  session.new({}, function(err)
    if err then return fail("nova sessão", err) end
  end)
end

function M.select_session()
  session.list(function(err, sessions)
    if err then return fail("sessões", err) end
    local items, map = { "+ nova sessão" }, {}
    for _, info in ipairs(sessions or {}) do
      local title = (info.title or "(sem título)"):gsub("%s+", " ")
      if #title > 60 then title = title:sub(1, 57) .. "..." end
      local label = string.format("%s  %s  [%s]", info.id, title, info.agent or "?")
      items[#items + 1] = label
      map[label] = info
    end
    picker.pick(items, { name = "sessões do opencode" }, function(choice)
      if not choice then return end
      if choice == "+ nova sessão" then return M.new_session() end
      local info = map[choice]
      if not info then return end
      session.attach(info.id, function(attach_err)
        if attach_err then fail("attach", attach_err) end
      end)
    end)
  end)
end

local function collect_models(node, out, provider, depth)
  depth = depth or 0
  if depth > 4 or type(node) ~= "table" then return out end

  local id = node.id or node.modelID
  local model_provider = node.providerID or node.provider or provider
  if type(id) == "string" and type(model_provider) == "string" then
    out[#out + 1] = {
      id = id,
      providerID = model_provider,
      variant = node.variant,
      name = node.name,
    }
    return out
  end

  if type(node.models) == "table" then
    return collect_models(node.models, out, node.id or node.providerID or provider, depth + 1)
  end
  for key, value in pairs(node) do
    if type(value) == "table" then
      collect_models(value, out, type(key) == "string" and key or provider, depth + 1)
    end
  end
  return out
end

function M.select_model()
  local info = session.info()
  if not info then return log.notify("nenhuma sessão ativa") end
  local directory = info.location and info.location.directory or nil
  api.models(directory, function(err, catalog)
    if err then return fail("modelos", err) end
    local seen, items, map = {}, {}, {}
    for _, model in ipairs(collect_models(catalog, {})) do
      local label = string.format("%s/%s", model.providerID, model.id)
      if not seen[label] then
        seen[label] = true
        local suffix = model.variant and (" · " .. model.variant) or ""
        items[#items + 1] = label .. suffix
        map[label .. suffix] = model
      end
    end
    table.sort(items)
    if #items == 0 then return log.notify("nenhum modelo disponível") end
    picker.pick(items, { name = "modelos" }, function(choice)
      if not choice then return end
      local model = map[choice]
      api.set_model(session.id(), model, function(set_err)
        if set_err then return fail("trocar modelo", set_err) end
        log.notify("modelo: " .. choice)
      end)
    end)
  end)
end

function M.select_agent()
  if not session.id() then return log.notify("nenhuma sessão ativa") end
  api.agents(function(err, agents)
    if err then return fail("agentes", err) end
    local items, map = {}, {}
    for _, agent in ipairs(agents or {}) do
      if type(agent) == "table" then
        local id = agent.id or agent.name
        local mode = agent.mode or agent.type
        if id and mode ~= "subagent" and mode ~= "hidden" then
          local label = id .. (agent.description and ("  " .. agent.description) or "")
          if #label > 80 then label = label:sub(1, 77) .. "..." end
          items[#items + 1] = label
          map[label] = id
        end
      end
    end
    if #items == 0 then return log.notify("nenhum agente disponível") end
    picker.pick(items, { name = "agentes" }, function(choice)
      if not choice then return end
      api.set_agent(session.id(), map[choice], function(set_err)
        if set_err then return fail("trocar agente", set_err) end
        log.notify("agente: " .. map[choice])
      end)
    end)
  end)
end

function M.undo()
  if not session.id() then return log.notify("nenhuma sessão ativa") end
  session.revert_last_turn(function(err)
    if err then return fail("undo", err) end
    log.notify("último turno desfeito")
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
    description = "OpenCode dentro do Neovim: pede aprovação antes de editar arquivos e rodar shell",
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
    log.notify("não consegui editar " .. path .. " (tem comentários?); copie o trecho da janela", vim.log.levels.WARN)
    return
  end

  config = config or {}
  config.agents = config.agents or {}
  config.agents[name] = approval_agent_definition()

  local ok, err = pcall(vim.fn.writefile, vim.split(pretty_json(config), "\n"), path)
  if not ok then return fail("escrever " .. path, err) end
  session.reset_agents()
  log.notify(string.format(
    "agente '%s' gravado em %s — rode `opencode2 service restart` e abra uma sessão nova", name, path))
end

--- Shows which agents pause for approval.
function M.approval_status()
  session.agents(function(err, agents)
    local approval = cfg.get().approval or {}
    local configured = approval.agent or "opencode-nvim"
    local lines = { "Aprovação no editor (diff antes de gravar)", "" }

    if err then
      lines[#lines + 1] = "não consegui listar os agentes: " .. err_text(err)
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
    if #lines == 2 then lines[#lines + 1] = "  (nenhum agente pede aprovação)" end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("agente de aprovação configurado: %s (%s)", configured, found and "encontrado" or "não existe")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Sem um agente de aprovação o plugin revisa o turno depois:"
    lines[#lines + 1] = "  :OpencodeDiff  mostra as mudanças"
    lines[#lines + 1] = "  :OpencodeUndo  desfaz o turno"
    lines[#lines + 1] = ""
    lines[#lines + 1] = ":OpencodeApprovalAgent  cria o agente no config do OpenCode"

    require("opencode-nvim.ui.diff").text({ title = "opencode · aprovação", lines = lines })
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
  if #lines == 0 then lines = { "(nenhum evento recebido ainda)" } end
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
    "arquivo de serviço: " .. info.service_file,
    "serviço registrado: " .. tostring(info.service_exists) .. "  (pid vivo: " .. tostring(info.pid_alive) .. ")",
    "comando: " .. tostring(info.command),
    "stream de eventos: " .. event.status(),
    "sessão atual: " .. tostring(session.id() or "(nenhuma)"),
    "permissões pendentes: " .. tostring(#permission.pending()),
    "autoread: " .. tostring(vim.o.autoread),
    "",
  }
  api.health(function(err, health, server)
    if err then
      lines[#lines + 1] = "conexão: FALHOU — " .. err_text(err)
    else
      lines[#lines + 1] = "conexão: ok — " .. tostring(server and server.url or "?")
      local ok, encoded = pcall(vim.inspect, health)
      lines[#lines + 1] = "servidor: " .. (ok and encoded or "?")
    end
    local current = session.info()
    if current then
      lines[#lines + 1] = string.format("sessão: %s  agente=%s  modelo=%s",
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

function M.complete(findstart, base)
  return panel.complete(findstart, base)
end

return M
