-- UI smoke tests: renders synthetic events into the panel and opens the
-- popups. No server, no tokens. Run with: make test
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local plugin = require("opencode-nvim")
local event = require("opencode-nvim.event")
local panel = require("opencode-nvim.ui.panel")
local diff = require("opencode-nvim.ui.diff")

plugin.setup({ server = { autostart = false } })

-- Pretend a session is attached so event filtering is exercised.
-- (Set the field directly: `set_current` would fetch the history over HTTP.)
require("opencode-nvim.session").current = {
  id = "ses_test",
  agent = "build",
  location = { directory = vim.uv.cwd() },
  tokens = {},
  cost = 0,
}

local failures = 0
local function report(name, ok, detail)
  if ok then
    io.write("ok   - " .. name .. "\n")
  else
    failures = failures + 1
    io.write("FAIL - " .. name .. "\n       " .. tostring(detail) .. "\n")
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  report(name, ok, err)
end

local function panel_text()
  local buf = panel.state.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function settle(ms)
  vim.wait(ms or 250, function() return false end, 20)
end

local function feed(kind, data, extra)
  local payload = vim.tbl_extend("force", { sessionID = "ses_test" }, data or {})
  event.emit(vim.tbl_extend("force", { type = kind, data = payload }, extra or {}))
end

--------------------------------------------------------------------------------

test("setup defines highlights and commands", function()
  assert(vim.fn.hlexists("OpencodeBorder") == 1)
  assert(vim.fn.exists(":Opencode") == 2, "comando :Opencode ausente")
  assert(vim.fn.exists(":OpencodeApprovalAgent") == 2)
end)

test("config exposes the approval agent name", function()
  local cfg = require("opencode-nvim.config")
  assert(cfg.get().approval.agent == "opencode-nvim", cfg.get().approval.agent)
end)

test("streams assistant text into the panel", function()
  feed("session.text.started")
  feed("session.text.delta", { delta = "olá " })
  feed("session.text.delta", { delta = "mundo" })
  feed("session.text.ended", { text = "olá mundo" })
  settle()
  local text = panel_text()
  assert(text:find("olá mundo", 1, true), text)
end)

test("repairs dropped deltas using text.ended", function()
  feed("session.text.started")
  feed("session.text.delta", { delta = "parcial" })
  feed("session.text.ended", { text = "texto completo do servidor" })
  settle()
  local text = panel_text()
  assert(text:find("texto completo do servidor", 1, true), text)
  assert(not text:find("parcial", 1, true), "bloco antigo não foi substituído:\n" .. text)
end)

test("renders tool calls with summary and status", function()
  feed("session.tool.input.started", { id = "call_1", name = "read" })
  feed("session.tool.input.ended", { id = "call_1", text = '{"filePath":"/tmp/exemplo.lua"}' })
  feed("session.tool.success", {
    id = "call_1",
    content = { { type = "text", text = "linha 1\nlinha 2" } },
  })
  settle()
  local text = panel_text()
  assert(text:find("read", 1, true), text)
  assert(text:find("/tmp/exemplo.lua", 1, true), text)
  assert(text:find("✓", 1, true), text)
  assert(text:find("linha 1", 1, true), text)
end)

test("renders a failed tool", function()
  feed("session.tool.input.started", { id = "call_2", name = "shell" })
  feed("session.tool.input.ended", { id = "call_2", text = '{"command":"rm -rf /"}' })
  feed("session.tool.failed", { id = "call_2", content = { { type = "text", text = "negado" } } })
  settle()
  local text = panel_text()
  assert(text:find("✗", 1, true), text)
  assert(text:find("negado", 1, true), text)
end)

test("ignores events from other sessions", function()
  local before = panel_text()
  feed("session.text.delta", { delta = "NÃO DEVE APARECER", sessionID = "ses_outra" })
  settle()
  assert(panel_text() == before, "evento de outra sessão vazou para o painel")
end)

test("ignores catalog events", function()
  local before = panel_text()
  event.emit({ type = "plugin.updated", data = { id = "x" } })
  event.emit({ type = "catalog.updated", data = {} })
  settle()
  assert(panel_text() == before, "evento de catálogo mexeu no painel")
end)

test("renders reasoning and errors", function()
  feed("session.reasoning.delta", { delta = "pensando..." })
  feed("session.reasoning.ended", {})
  feed("session.error", { message = "algo falhou" })
  settle()
  local text = panel_text()
  assert(text:find("pensando", 1, true), text)
  assert(text:find("algo falhou", 1, true), text)
end)

test("clears the panel", function()
  plugin.clear()
  settle()
  assert(panel_text() == "", "painel não foi limpo")
end)

test("renders history messages", function()
  panel.render_messages({
    { type = "user", text = "faz isso", time = { created = 1 } },
    {
      type = "assistant",
      time = { created = 2 },
      content = {
        { type = "text", text = "claro" },
        { type = "tool", name = "edit", state = { status = "completed", input = { filePath = "/tmp/h.lua" }, output = "ok" } },
      },
    },
  })
  settle()
  local text = panel_text()
  assert(text:find("faz isso", 1, true), text)
  assert(text:find("claro", 1, true), text)
  assert(text:find("/tmp/h.lua", 1, true), text)
end)

test("opens the diff popup with patches", function()
  local ok, err = pcall(diff.patches, {
    title = "teste",
    patches = {
      { file = "src/a.lua", patch = "@@ -1 +1 @@\n-velho\n+novo", additions = 1, deletions = 1, status = "modified" },
    },
  })
  if not ok then return report("opens the diff popup with patches", false, err) end
  settle(80)
  local buf = vim.api.nvim_get_current_buf()
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(text:find("src/a.lua", 1, true), text)
  assert(text:find("+novo", 1, true), text)
  assert(vim.bo[buf].filetype == "diff", vim.bo[buf].filetype)
  diff.close()
end)

test("review popup offers revert", function()
  local reverted = false
  diff.review({
    patches = { { file = "b.lua", patch = "+x", additions = 1, deletions = 0, status = "modified" } },
    on_revert = function() reverted = true end,
  })
  settle(80)
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), "\n")
  assert(text:find("desfazer", 1, true), text)
  vim.api.nvim_feedkeys("r", "x", false)
  settle(80)
  assert(reverted, "a tecla r não chamou on_revert")
end)

test("opens the panel window and the prompt", function()
  local ok, err = pcall(plugin.open)
  if not ok then return report("opens the panel window and the prompt", false, err) end
  assert(panel.visible(), "janela do painel não abriu")
  assert(panel.state.input.win ~= nil, "janela do prompt não abriu")
  assert(vim.api.nvim_get_current_win() == panel.state.input.win, "o prompt não recebeu o foco")
  -- Obs: com `-l` (sem UI) o Neovim não entra em insert mode, então o modo não
  -- pode ser verificado aqui.
  plugin.close()
  settle(60)
  assert(not panel.visible(), "janela do painel não fechou")
end)

test("mostra 'pensando…' e troca pelo conteúdo", function()
  plugin.clear()
  settle()
  feed("session.execution.started")
  settle()
  local text = panel_text()
  assert(text:find("pensando", 1, true), "placeholder ausente:\n" .. text)

  feed("session.text.started")
  feed("session.text.delta", { delta = "pronto" })
  feed("session.text.ended", { text = "pronto" })
  settle()
  text = panel_text()
  assert(text:find("pronto", 1, true), text)
  assert(not text:find("pensando", 1, true), "placeholder não foi removido:\n" .. text)
end)

test("resolve_model cai para o modelo preferido do TUI", function()
  local session = require("opencode-nvim.session")
  local model = session.resolve_model(nil, {})
  local preferred = session.preferred_model()
  if preferred then
    assert(model and model.providerID == preferred.providerID and model.id == preferred.id,
      vim.inspect(model))
  else
    assert(model == nil, "sem preferido não deveria inventar modelo")
  end

  -- Modelo explícito desconhecido é descartado com motivo.
  local dropped, reason = session.resolve_model({ providerID = "x", id = "y" },
    { { providerID = "a", id = "b" } })
  assert(dropped == nil and reason ~= nil, vim.inspect({ dropped, reason }))

  -- E um conhecido é normalizado pelo catálogo.
  local known = session.resolve_model({ providerID = "a", id = "b" },
    { { providerID = "a", id = "b", variant = "v" } })
  assert(known and known.id == "b" and known.variant == "v", vim.inspect(known))
end)

test("prompt e painel ficam alinhados e sem sobreposição", function()
  plugin.open()
  local pwin, iwin = panel.state.win, panel.state.input.win
  assert(pwin and iwin, "janelas ausentes")
  local panel_conf = vim.api.nvim_win_get_config(pwin)
  local input_conf = vim.api.nvim_win_get_config(iwin)

  -- Both content areas must share the same left edge.
  local panel_left = panel_conf.col - panel_conf.width + 1
  assert(input_conf.col == panel_left,
    string.format("bordas esquerdas diferentes: painel=%d prompt=%d", panel_left, input_conf.col))

  -- The prompt sits below the panel (anchors: SE for the panel, SW for the
  -- prompt), with the borders not touching.
  local panel_outer_bottom = panel_conf.row + 1
  local input_outer_top = input_conf.row - 1
  assert(input_outer_top > panel_outer_bottom,
    string.format("prompt sobrepõe o painel: prompt_top=%d painel_bottom=%d", input_outer_top, panel_outer_bottom))
  plugin.close()
end)

test("submitting goes back to the code window", function()
  local target = panel.code_target()
  assert(target and target.win, "não achei uma janela de código")
  panel.open()
  assert(panel.state.input.win ~= nil)
  panel.close_input()
  panel.state.input.target = target
  panel.after_submit()
  assert(vim.api.nvim_get_current_win() == target.win, "o foco não voltou para o código")
  plugin.close()
end)

io.write(string.format("\n%d falha(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
