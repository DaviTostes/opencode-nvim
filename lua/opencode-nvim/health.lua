local M = {}

function M.check()
  vim.health.start("opencode-nvim")

  local ok, discovery = pcall(require, "opencode-nvim.discovery")
  if not ok then
    vim.health.error("não consegui carregar o módulo de descoberta")
    return
  end

  local info = discovery.describe()

  if info.service_exists then
    vim.health.ok("registro do serviço encontrado: " .. info.service_file)
  else
    vim.health.warn("nenhum registro de serviço em " .. info.service_file .. " (o plugin pode subir um)")
  end

  if info.service_exists and not info.pid_alive then
    vim.health.warn("o pid registrado (" .. tostring(info.service_pid) .. ") não está vivo; um novo serviço será iniciado")
  end

  if vim.fn.executable(info.command or "opencode2") == 1 then
    vim.health.ok("comando encontrado: " .. tostring(info.command))
  else
    vim.health.error("'" .. tostring(info.command) .. "' não está no PATH (ajuste server.command)")
  end

  local server = discovery.current()
  if server then
    vim.health.ok("servidor resolvido: " .. tostring(server.url))
  else
    vim.health.info("servidor ainda não resolvido — use :OpencodeHealth para uma checagem ao vivo")
  end

  if vim.o.autoread then
    vim.health.ok("'autoread' ligado (buffers recarregam sozinhos)")
  else
    vim.health.warn("'autoread' desligado — edições da IA não vão recarregar os buffers automaticamente")
  end

  local ok_event, event = pcall(require, "opencode-nvim.event")
  if ok_event then
    vim.health.info("stream de eventos: " .. event.status())
  end

  local ok_session, session = pcall(require, "opencode-nvim.session")
  if ok_session then
    local current = session.info()
    if current then
      vim.health.ok("sessão atual: " .. current.id)
    else
      vim.health.info("nenhuma sessão ativa")
    end
  end

  local ok_cfg, cfg = pcall(require, "opencode-nvim.config")
  if ok_cfg then
    local ruleset = cfg.permission_ruleset()
    if ruleset == nil then
      vim.health.warn("permissions = false: nenhuma aprovação no editor")
    else
      local asks = {}
      for _, rule in ipairs(ruleset) do
        if rule.effect == "ask" then asks[#asks + 1] = rule.action end
      end
      vim.health.ok("aprovação no editor para: " .. (#asks > 0 and table.concat(asks, ", ") or "nenhuma ação"))
    end
  end
end

return M
