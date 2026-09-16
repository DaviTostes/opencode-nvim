-- End-to-end protocol check against the real OpenCode service.
--
-- Creates a throwaway session in a temp directory, sends one tiny prompt and
-- records every event the server emits (including the exact payload shapes).
--
--   make e2e                     -- só o streaming de texto
--   E2E_TOOLS=1 make e2e         -- também valida a aprovação de edição
--
-- Cost: one short prompt (plus one tool prompt with E2E_TOOLS=1).
local uv = vim.uv or vim.loop

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local api = require("opencode-nvim.api")
local discovery = require("opencode-nvim.discovery")
local event = require("opencode-nvim.event")
local util = require("opencode-nvim.util")

local dump_path = os.getenv("E2E_DUMP") or "/tmp/opencode/e2e-events.json"
local workdir = os.getenv("E2E_DIR") or vim.fs.joinpath(vim.fn.tempname())
local with_tools = os.getenv("E2E_TOOLS") == "1"
vim.fn.mkdir(workdir, "p")

io.write("diretório: " .. workdir .. "\n")
io.write("dump: " .. dump_path .. "\n\n")

local seen, samples, deltas = {}, {}, {}
local state = { finished = false, session_id = nil }
local text_session = nil

event.on_any(function(ev)
  local kind = ev.type
  if not seen[kind] then
    seen[kind] = 0
    samples[kind] = vim.deepcopy(ev)
  end
  seen[kind] = seen[kind] + 1

  local data = ev.data or {}
  local detail = util.pick_string(data, { "delta", "text", "command", "filePath", "message", "error" })
    or util.pick_string(data, { "id" })
    or ""
  if #detail > 70 then detail = detail:sub(1, 70) .. "..." end
  io.write(string.format("  ev %-32s %s\n", kind, detail:gsub("\n", " ")))

  if kind == "session.text.delta" then
    deltas[#deltas + 1] = util.pick_string(data, { "delta", "text", "content" }) or ""
  end
  -- A turn ends with execution.*; `session.idle` only shows up in some flows.
  if kind == "session.execution.succeeded" or kind == "session.execution.failed"
    or kind == "session.execution.interrupted" or kind == "session.idle" then
    local sid = util.pick_string(data, { "sessionID", "sessionId" })
    if not sid or sid == state.session_id then state.finished = true end
  end
end)

event.start() -- wire the SSE stream into the event bus

----------------------------------------------------------------------

local function wait(condition, timeout)
  return vim.wait(timeout or 20000, condition, 20)
end

local function step(name, fn, timeout)
  io.write("== " .. name .. "\n")
  local done, err = false, nil
  fn(function(e)
    err = e
    done = true
  end)
  if not wait(function() return done end, timeout) then
    io.write("   TIMEOUT\n")
    return nil
  end
  if err then
    local text = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
    io.write("   ERRO: " .. text .. "\n")
    return nil
  end
  return true
end

local function send_prompt(session_id, text)
  state.finished = false
  local ok = step("prompt: " .. text:sub(1, 50), function(cb)
    api.prompt(session_id, { text = text }, function(err)
      cb(err)
    end)
  end)
  if not ok then return false end
  io.write("   aguardando o fim do turno...\n")
  if not wait(function() return state.finished end, 120000) then
    io.write("   TIMEOUT esperando o fim do turno\n")
    return false
  end
  return true
end

local function last_assistant_text(session_id, cb)
  api.messages(session_id, { limit = 5, order = "desc" }, function(err, page)
    if err then return cb(err) end
    for _, message in ipairs((page and page.data) or {}) do
      if message.type == "assistant" then
        local parts = {}
        for _, item in ipairs(message.content or {}) do
          if item.type == "text" and item.text then parts[#parts + 1] = item.text end
        end
        return cb(nil, table.concat(parts, "\n"))
      end
    end
    cb(nil, nil)
  end)
end

local function describe_session(session_id, label)
  step(label .. ": inspecionar sessão", function(cb)
    api.get_session(session_id, function(err, info)
      if err then return cb(err) end
      io.write("   agent=" .. tostring(info.agent) .. " model=" .. vim.inspect(info.model) .. "\n")
      io.write("   permissions=" .. vim.inspect(info.permissions) .. "\n")
      cb(nil)
    end)
  end)
end

----------------------------------------------------------------------

local ok = step("descoberta + health", function(cb)
  discovery.resolve(function(err, server)
    if err then return cb(err) end
    discovery.probe(server, function(probe_err, info)
      if probe_err then return cb(probe_err) end
      io.write(string.format("   servidor %s versão %s pid %s\n", server.url, tostring(info.version), tostring(info.pid)))
      cb(nil)
    end)
  end)
end)
if not ok then os.exit(1) end

if not wait(function() return require("opencode-nvim.sse").connected() end, 10000) then
  io.write("não consegui conectar no stream de eventos\n")
  os.exit(1)
end
io.write("   stream conectado\n")

-- Session 1: text streaming with a read-only agent.
step("criar sessão de texto (agent=plan)", function(cb)
  api.create_session({
    location = { directory = workdir },
    agent = "plan",
    permissions = {
      { action = "*", resource = "*", effect = "allow" },
      { action = "edit", resource = "*", effect = "ask" },
      { action = "shell", resource = "*", effect = "ask" },
    },
    title = "opencode-nvim e2e (texto)",
  }, function(err, info)
    if err then return cb(err) end
    state.session_id = info.id
    text_session = info.id
    io.write("   " .. info.id .. " agent=" .. tostring(info.agent) .. "\n")
    cb(nil)
  end)
end)

describe_session(text_session, "sessão de texto")

deltas = {}
send_prompt(text_session, "Responda apenas com a palavra: ok. Não use ferramentas.")
io.write(string.format("\n   text deltas: %d, total %d bytes\n", #deltas, #table.concat(deltas)))
step("resposta final", function(cb)
  last_assistant_text(text_session, function(err, text)
    if err then return cb(err) end
    io.write("   " .. vim.inspect((text or ""):sub(1, 200)) .. "\n")
    cb(nil)
  end)
end)

-- Session 2 (optional): edit approval flow.
if with_tools then
  local tool_session = nil
  local asked = nil
  local stop = event.on("permission.asked", function(ev)
    asked = ev.data
  end)

  step("criar sessão de ferramentas (agent=build)", function(cb)
    api.create_session({
      location = { directory = workdir },
      agent = "build",
      permissions = {
        { action = "*", resource = "*", effect = "allow" },
        { action = "edit", resource = "*", effect = "ask" },
        { action = "shell", resource = "*", effect = "ask" },
      },
      title = "opencode-nvim e2e (ferramentas)",
    }, function(err, info)
      if err then return cb(err) end
      tool_session = info.id
      state.session_id = info.id
      io.write("   " .. info.id .. "\n")
      cb(nil)
    end)
  end)

  describe_session(tool_session, "sessão de ferramentas")

  state.finished = false
  step("pedir criação de arquivo", function(cb)
    api.prompt(tool_session, {
      text = "Crie um arquivo chamado e2e-hello.txt contendo exatamente: oi",
    }, function(err) cb(err) end)
  end)

  io.write("   aguardando permission.asked...\n")
  if wait(function() return asked ~= nil end, 120000) then
    io.write("   permission.asked: " .. vim.inspect(asked) .. "\n")
    local request = asked
    step("responder permitindo uma vez", function(cb)
      api.reply_permission(tool_session, request.id, "once", nil, function(err) cb(err) end)
    end)
    if wait(function() return state.finished end, 120000) then
      io.write("   turno concluído\n")
    else
      io.write("   TIMEOUT esperando o fim do turno depois da aprovação\n")
    end
    local file = vim.fs.joinpath(workdir, "e2e-hello.txt")
    io.write("   arquivo criado: " .. tostring(vim.fn.filereadable(file) == 1) .. "\n")
    if vim.fn.filereadable(file) == 1 then
      io.write("   conteúdo: " .. vim.inspect(vim.fn.readfile(file)) .. "\n")
    end
  else
    io.write("   nenhuma permissão pedida (o agente pode ter recusado ou editado sem pedir)\n")
  end

  stop()

  step("limpar sessão de ferramentas", function(cb)
    api.delete_session(tool_session, function() cb(nil) end)
  end)
end

-- Shapes for the history renderer.
step("shapes das mensagens", function(cb)
  api.messages(text_session, { limit = 6, order = "desc" }, function(err, page)
    if err then return cb(err) end
    io.write("   envelope: " .. vim.inspect(vim.tbl_keys(page or {})) .. "\n")
    for _, message in ipairs((page and page.data) or {}) do
      io.write(string.format("   - type=%s keys=%s\n", tostring(message.type), vim.inspect(vim.tbl_keys(message))))
      if message.type == "assistant" then
        for _, item in ipairs(message.content or {}) do
          io.write("       item=" .. vim.inspect(item):sub(1, 220) .. "\n")
        end
      elseif message.type == "user" then
        io.write("       text=" .. vim.inspect(message.text) .. "\n")
      end
    end
    cb(nil)
  end)
end)

local report = {
  workdir = workdir,
  session_id = text_session,
  counts = seen,
  samples = samples,
  text_deltas = deltas,
}
local fd = io.open(dump_path, "w")
if fd then
  fd:write(vim.json.encode(report))
  fd:close()
  io.write("\neventos por tipo:\n")
  local kinds = vim.tbl_keys(seen)
  table.sort(kinds)
  for _, kind in ipairs(kinds) do
    io.write(string.format("  %-40s %d\n", kind, seen[kind]))
  end
  io.write("\ndump: " .. dump_path .. "\n")
end

step("limpar sessão de texto", function(cb)
  api.delete_session(text_session, function() cb(nil) end)
end)

vim.fn.delete(workdir, "rf")
os.exit(0)
