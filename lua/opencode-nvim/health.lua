local M = {}

function M.check()
  vim.health.start("opencode-nvim")

  local ok, discovery = pcall(require, "opencode-nvim.discovery")
  if not ok then
    vim.health.error("could not load the discovery module")
    return
  end

  local info = discovery.describe()

  if info.service_exists then
    vim.health.ok("service registration found: " .. info.service_file)
  else
    vim.health.warn("no service registration in " .. info.service_file .. " (the plugin can start one)")
  end

  if info.service_exists and not info.pid_alive then
    vim.health.warn("the registered pid (" .. tostring(info.service_pid) .. ") is not alive; a new service will be started")
  end

  if vim.fn.executable(info.command or "opencode2") == 1 then
    vim.health.ok("command found: " .. tostring(info.command))
  else
    vim.health.error("'" .. tostring(info.command) .. "' is not in PATH (adjust server.command)")
  end

  local server = discovery.current()
  if server then
    vim.health.ok("server resolved: " .. tostring(server.url))
  else
    vim.health.info("server not resolved yet — use :OpencodeHealth for a live check")
  end

  if vim.o.autoread then
    vim.health.ok("'autoread' is on (buffers reload by themselves)")
  else
    vim.health.warn("'autoread' is off — AI edits will not reload buffers automatically")
  end

  local ok_event, event = pcall(require, "opencode-nvim.event")
  if ok_event then
    vim.health.info("event stream: " .. event.status())
  end

  local ok_session, session = pcall(require, "opencode-nvim.session")
  if ok_session then
    local current = session.info()
    if current then
      vim.health.ok("current session: " .. current.id)
    else
      vim.health.info("no active session")
    end
  end

  local ok_cfg, cfg = pcall(require, "opencode-nvim.config")
  if ok_cfg then
    local ruleset = cfg.permission_ruleset()
    if ruleset == nil then
      vim.health.warn("permissions = false: no in-editor approval")
    else
      local asks = {}
      for _, rule in ipairs(ruleset) do
        if rule.effect == "ask" then asks[#asks + 1] = rule.action end
      end
      vim.health.ok("in-editor approval for: " .. (#asks > 0 and table.concat(asks, ", ") or "no actions"))
    end
  end
end

return M
