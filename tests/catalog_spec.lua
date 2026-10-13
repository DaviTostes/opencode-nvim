-- Slash commands, subagent mentions and shell routing.
-- No server, no tokens. Run with: nvim -l tests/catalog_spec.lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

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

local plugin = require("opencode-nvim")
local panel = require("opencode-nvim.ui.panel")
local catalog = require("opencode-nvim.catalog")
local api = require("opencode-nvim.api")
local session = require("opencode-nvim.session")

plugin.setup({ server = { autostart = false } })

-- Pretend a session is attached so the catalogue and event filtering have a
-- location to work with (no HTTP).
session.current = {
  id = "ses_test",
  agent = "build",
  location = { directory = vim.uv.cwd() },
  tokens = {},
  cost = 0,
}

local COMMANDS = {
  { name = "review", description = "review changes" },
  { name = "init", description = "guided AGENTS.md setup" },
}
local AGENTS = {
  { id = "build", mode = "primary" },
  { id = "explore", mode = "subagent", description = "search the codebase" },
  { id = "general", mode = "subagent", description = "multi-step tasks" },
}

--- Populate the catalogue from fixtures (stubbing the HTTP layer).
local function warm_catalog()
  catalog.reset()
  local saved_ensure, saved_commands, saved_agents = api.ensure_location, api.commands, api.agents
  api.ensure_location = function(_, cb) if cb then cb(nil, {}) end end
  api.commands = function(_, cb) cb(nil, COMMANDS) end
  api.agents = function(_, cb) cb(nil, AGENTS) end
  catalog.commands(function() end)
  catalog.agents(function() end)
  api.ensure_location, api.commands, api.agents = saved_ensure, saved_commands, saved_agents
end

local function set_input(lines)
  local buf = panel.input_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  panel.maybe_collapse_paste()
  panel.state.input.target = nil
  panel.state.input.selection = nil
  return buf
end

local function panel_text()
  local buf = panel.state.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function words(items)
  local out = {}
  for _, item in ipairs(items) do out[#out + 1] = item.word end
  return out
end

--------------------------------------------------------------------------------

test("the catalogue lists commands and subagents", function()
  warm_catalog()
  local command_words = words(catalog.command_items("/"))
  assert(vim.tbl_contains(command_words, "/review"), vim.inspect(command_words))
  assert(vim.tbl_contains(command_words, "/init"), vim.inspect(command_words))

  local agent_words = words(catalog.agent_items("@"))
  assert(vim.tbl_contains(agent_words, "@explore"), vim.inspect(agent_words))
  assert(vim.tbl_contains(agent_words, "@general"), vim.inspect(agent_words))
  assert(not vim.tbl_contains(agent_words, "@build"), "primary agents are not mentionable")

  assert(catalog.find_command("review").name == "review")
  assert(catalog.find_agent("explore").id == "explore")
  assert(catalog.find_command("nope") == nil)
  assert(catalog.find_agent("nope") == nil)
end)

test("completing / and @ uses the catalogue", function()
  warm_catalog()
  local slash = words(panel.complete(0, "/re"))
  assert(vim.tbl_contains(slash, "/review"), vim.inspect(slash))
  assert(not vim.tbl_contains(slash, "/init"), vim.inspect(slash))

  local mentions = words(panel.complete(0, "@ex"))
  assert(vim.tbl_contains(mentions, "@explore"), vim.inspect(mentions))

  -- the placeholders are untouched (their own completion still has five items)
  assert(#panel.placeholder_items("@") == 5, vim.inspect(panel.placeholder_items("@")))
end)

test("agent mentions attach only known subagents", function()
  warm_catalog()
  local agents = panel.mentioned_agents("@explore find the parser")
  assert(#agents == 1 and agents[1].name == "explore", vim.inspect(agents))
  assert(#panel.mentioned_agents("mail user@explore.com") == 0, "a mid-token @ became a mention")
  assert(#panel.mentioned_agents("@build do it") == 0, "a primary agent was attached")
  assert(#panel.mentioned_agents("@nope hi") == 0)
  assert(#panel.mentioned_agents("@explore and @explore again") == 1, "duplicate mentions were not folded")
end)

test("submitting a known /command runs it", function()
  warm_catalog()
  local saved = session.command
  local sent
  session.command = function(name, text, opts, cb)
    sent = { name = name, text = text, opts = opts }
    if cb then cb(nil) end
  end
  local ok, err = pcall(function()
    set_input({ "/review src/api.lua" })
    panel.submit()
    assert(sent and sent.name == "review", vim.inspect(sent))
    assert(sent.text:find("src/api.lua", 1, true), vim.inspect(sent.text))
  end)
  session.command = saved
  assert(ok, err)
  plugin.close()
end)

test("submitting !cmd runs a shell command", function()
  local saved = session.shell
  local sent
  session.shell = function(command, opts, cb)
    sent = { command = command, opts = opts }
    if cb then cb(nil) end
  end
  local ok, err = pcall(function()
    set_input({ "!ls -la" })
    panel.submit()
    assert(sent and sent.command == "ls -la", vim.inspect(sent))
  end)
  session.shell = saved
  assert(ok, err)
  plugin.close()
end)

test("an unknown /name is an ordinary prompt", function()
  warm_catalog()
  local saved = session.prompt
  local sent
  session.prompt = function(text, opts, cb)
    sent = { text = text, opts = opts }
    if cb then cb(nil) end
  end
  local ok, err = pcall(function()
    set_input({ "/nope hello" })
    panel.submit()
    assert(sent and sent.text:find("/nope hello", 1, true), vim.inspect(sent))
  end)
  session.prompt = saved
  assert(ok, err)
  plugin.close()
end)

test("@mention rides along as an agents attachment", function()
  warm_catalog()
  local saved = session.prompt
  local sent
  session.prompt = function(text, opts, cb)
    sent = { text = text, opts = opts }
    if cb then cb(nil) end
  end
  local ok, err = pcall(function()
    set_input({ "@explore find the entry point" })
    panel.submit()
    assert(sent and sent.opts.agents and #sent.opts.agents == 1, vim.inspect(sent))
    assert(sent.opts.agents[1].name == "explore", vim.inspect(sent.opts.agents))
  end)
  session.prompt = saved
  assert(ok, err)
  plugin.close()
end)

test("session.command posts the name, args and agents", function()
  local sse = require("opencode-nvim.sse")
  local current = session.current
  local saved_ensure, saved_run, saved_connected = session.ensure, api.run_command, sse.connected
  session.ensure = function(_, cb) cb(nil, current) end
  sse.connected = function() return true end
  local body
  api.run_command = function(_, b, cb)
    body = b
    cb(nil)
  end
  local ok, err = pcall(function()
    session.command("review", "src/api.lua", { agents = { { name = "explore" } } }, function() end)
    assert(body and body.name == "review" and body.text == "src/api.lua", vim.inspect(body))
    assert(body.agents and body.agents[1].name == "explore", vim.inspect(body))
  end)
  session.ensure, api.run_command, sse.connected = saved_ensure, saved_run, saved_connected
  assert(ok, err)
end)

test("session.prompt carries the agents attachment", function()
  local sse = require("opencode-nvim.sse")
  local current = session.current
  local saved_ensure, saved_prompt, saved_connected = session.ensure, api.prompt, sse.connected
  session.ensure = function(_, cb) cb(nil, current) end
  sse.connected = function() return true end
  local body
  api.prompt = function(_, b, cb)
    body = b
    cb(nil)
  end
  local ok, err = pcall(function()
    session.prompt("hi", { agents = { { name = "explore" } } }, function() end)
    assert(body and body.agents and body.agents[1].name == "explore", vim.inspect(body))
  end)
  session.ensure, api.prompt, sse.connected = saved_ensure, saved_prompt, saved_connected
  assert(ok, err)
end)

test("session.shell posts the command to the session", function()
  local current = session.current
  local saved_ensure, saved_shell = session.ensure, api.shell_command
  session.ensure = function(_, cb) cb(nil, current) end
  local got
  api.shell_command = function(id, command, cb)
    got = { id = id, command = command }
    cb(nil)
  end
  local ok, err = pcall(function()
    session.shell("ls -la", {}, function() end)
    assert(got and got.id == "ses_test" and got.command == "ls -la", vim.inspect(got))
  end)
  session.ensure, api.shell_command = saved_ensure, saved_shell
  assert(ok, err)
end)

test("context.expand auto = false leaves command arguments alone", function()
  local context = require("opencode-nvim.context")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "/tmp/opencode/catalog-ctx.lua")
  vim.api.nvim_set_current_buf(buf)
  local with_auto = context.expand("websearch", { bufnr = buf, auto = true })
  assert(with_auto:find("[editor context]", 1, true), with_auto)
  local without = context.expand("websearch", { bufnr = buf, auto = false })
  assert(without == "websearch", vim.inspect(without))
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end)

test("shell events render the command and its output", function()
  panel.clear()
  panel.on_event({
    type = "session.shell.started",
    data = { sessionID = "ses_test", shell = { command = "echo hi" } },
  })
  panel.on_event({
    type = "session.shell.ended",
    data = {
      sessionID = "ses_test",
      shell = { command = "echo hi", exit = 0 },
      output = { output = "hi\n" },
    },
  })
  panel.renderer():draw()
  local text = panel_text()
  assert(text:find("$ echo hi", 1, true), text)
  assert(text:find("hi", 1, true), text)
  assert(text:find("exit 0", 1, true), text)
  assert(panel.state.status == "idle", tostring(panel.state.status))
end)

test("a shell event from another session is ignored", function()
  panel.clear()
  panel.on_event({
    type = "session.shell.ended",
    data = {
      sessionID = "ses_other",
      shell = { command = "echo nope", exit = 1 },
      output = { output = "nope\n" },
    },
  })
  panel.renderer():draw()
  assert(not panel_text():find("echo nope", 1, true), panel_text())
end)

io.write(string.format("\n%d failure(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
