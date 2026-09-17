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
  assert(vim.fn.exists(":OpencodeDoctor") == 2, "the :OpencodeDoctor command is missing")
  -- Regression: setup() must attach the event bus to the stream, otherwise the
  -- stream parses events into the void and nothing ever renders.
  assert(require("opencode-nvim.sse").has_handler(), "the event bus is not attached to the SSE stream")
end)

test("config exposes the approval agent name", function()
  local cfg = require("opencode-nvim.config")
  assert(cfg.get().approval.agent == "opencode-nvim", cfg.get().approval.agent)
end)

test("streams assistant text into the panel", function()
  feed("session.text.started")
  feed("session.text.delta", { delta = "hello " })
  feed("session.text.delta", { delta = "world" })
  feed("session.text.ended", { text = "hello world" })
  settle()
  local text = panel_text()
  assert(text:find("hello world", 1, true), text)
end)

test("repairs dropped deltas using text.ended", function()
  feed("session.text.started")
  feed("session.text.delta", { delta = "partial" })
  feed("session.text.ended", { text = "full text from the server" })
  settle()
  local text = panel_text()
  assert(text:find("full text from the server", 1, true), text)
  assert(not text:find("partial", 1, true), "old block was not replaced:\n" .. text)
end)

test("renders tool calls with summary and status", function()
  feed("session.tool.input.started", { id = "call_1", name = "read" })
  feed("session.tool.input.ended", { id = "call_1", text = '{"filePath":"/tmp/exemplo.lua"}' })
  feed("session.tool.success", {
    id = "call_1",
    content = { { type = "text", text = "line 1\nline 2" } },
  })
  settle()
  local text = panel_text()
  assert(text:find("read", 1, true), text)
  assert(text:find("/tmp/exemplo.lua", 1, true), text)
  assert(text:find("✓", 1, true), text)
  assert(text:find("line 1", 1, true), text)
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
  feed("session.text.delta", { delta = "MUST NOT APPEAR", sessionID = "ses_other" })
  settle()
  assert(panel_text() == before, "event from another session leaked into the panel")

  -- and nothing at all when the plugin has no session yet (a TUI session in
  -- another terminal used to stream into this panel)
  local session = require("opencode-nvim.session")
  local saved = session.current
  session.current = nil
  local empty = panel_text()
  feed("session.text.delta", { delta = "TUI LEAK", sessionID = "ses_tui" })
  event.emit({ type = "session.text.delta", data = { delta = "TUI LEAK" } })
  settle()
  assert(panel_text() == empty, "an event leaked while there was no session")
  session.current = saved
end)

test("ignores catalog events", function()
  local before = panel_text()
  event.emit({ type = "plugin.updated", data = { id = "x" } })
  event.emit({ type = "catalog.updated", data = {} })
  settle()
  assert(panel_text() == before, "catalog event touched the panel")
end)

test("renders reasoning and errors", function()
  feed("session.reasoning.delta", { delta = "thinking..." })
  feed("session.reasoning.ended", {})
  feed("session.error", { message = "algo falhou" })
  settle()
  local text = panel_text()
  assert(text:find("thinking", 1, true), text)
  assert(text:find("algo falhou", 1, true), text)
end)

test("clears the panel", function()
  plugin.clear()
  settle()
  assert(panel_text() == "", "panel was not cleared")
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

test("review popup offers revert and shows its keys", function()
  local reverted = false
  diff.review({
    patches = { { file = "b.lua", patch = "+x", additions = 1, deletions = 0, status = "modified" } },
    on_revert = function() reverted = true end,
  })
  settle(80)
  local win = vim.api.nvim_get_current_win()
  -- get_config reports the footer as a list of lines of chunks
  local footer = vim.api.nvim_win_get_config(win).footer or {}
  local footer_text = ""
  for _, line in ipairs(footer) do
    footer_text = footer_text .. (type(line) == "table" and table.concat(line) or tostring(line))
  end
  assert(footer_text:find("undo the turn", 1, true), "footer missing: " .. vim.inspect(footer))

  vim.api.nvim_feedkeys("u", "x", false)
  settle(80)
  assert(reverted, "the u key did not call on_revert")
end)

test("permission popup leaves navigation and search keys alone", function()
  local choice, chosen = "unset", false
  diff.patches({
    title = "approve",
    patches = { { file = "c.lua", patch = "+x", additions = 1, deletions = 0, status = "modified" } },
    on_choice = function(value) choice, chosen = value, true end,
  })
  settle(80)
  local buf = vim.api.nvim_get_current_buf()

  -- navigation and search must not be shadowed by popup actions
  for _, key in ipairs({ "n", "a", "r", "j", "k", "g", "G", "/", "d" }) do
    local map = vim.fn.maparg(key, "n", false, true)
    assert(type(map) ~= "table" or map.buffer ~= 1 or vim.tbl_isempty(map),
      string.format("%q is bound in the approval popup (%s)", key, vim.inspect(map)))
  end

  -- <Esc> means "decide later", not a bare close (it used to be overridden)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  settle(80)
  assert(chosen, "<Esc> did not call the decision callback")
  assert(choice == nil, "expected 'decide later', got " .. vim.inspect(choice))
  assert(not vim.api.nvim_buf_is_valid(buf), "the popup did not close")

  -- y allows once
  choice, chosen = "unset", false
  diff.patches({
    title = "approve",
    patches = { { file = "d.lua", patch = "+x", additions = 1, deletions = 0, status = "modified" } },
    on_choice = function(value) choice, chosen = value, true end,
  })
  settle(80)
  vim.api.nvim_feedkeys("y", "x", false)
  settle(80)
  assert(chosen and choice == "once", vim.inspect({ chosen, choice }))
end)

test("opens the panel window and the prompt", function()
  local ok, err = pcall(plugin.open)
  if not ok then return report("opens the panel window and the prompt", false, err) end
  assert(panel.visible(), "panel window did not open")
  assert(panel.state.input.win ~= nil, "prompt window did not open")
  assert(vim.api.nvim_get_current_win() == panel.state.input.win, "the prompt did not get focus")
  -- Note: with `-l` (no UI) Neovim does not enter insert mode, so the mode
  -- cannot be checked here.
  plugin.close()
  settle(60)
  assert(not panel.visible(), "panel window did not close")
end)

test("shows 'thinking…' and swaps it for content", function()
  plugin.clear()
  settle()
  feed("session.execution.started")
  settle()
  local text = panel_text()
  assert(text:find("thinking", 1, true), "placeholder missing:\n" .. text)

  feed("session.text.started")
  feed("session.text.delta", { delta = "pronto" })
  feed("session.text.ended", { text = "pronto" })
  settle()
  text = panel_text()
  assert(text:find("pronto", 1, true), text)
  assert(not text:find("thinking", 1, true), "placeholder was not removed:\n" .. text)
end)

test("resolve_model falls back to the TUI preferred model", function()
  local session = require("opencode-nvim.session")
  local model = session.resolve_model(nil, {})
  local preferred = session.preferred_model()
  if preferred then
    assert(model and model.providerID == preferred.providerID and model.id == preferred.id,
      vim.inspect(model))
  else
    assert(model == nil, "without a preferred model it must not invent one")
  end

  -- An unknown explicit model is dropped with a reason.
  local dropped, reason = session.resolve_model({ providerID = "x", id = "y" },
    { { providerID = "a", id = "b" } })
  assert(dropped == nil and reason ~= nil, vim.inspect({ dropped, reason }))

  -- A known one is normalized through the catalogue.
  local known = session.resolve_model({ providerID = "a", id = "b" },
    { { providerID = "a", id = "b", variant = "v" } })
  assert(known and known.id == "b" and known.variant == "v", vim.inspect(known))
end)

test("context.auto tells the model what 'this' means", function()
  local cfg = require("opencode-nvim.config")
  local context = require("opencode-nvim.context")

  -- a named buffer with a filetype and a cursor
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(vim.uv.cwd(), "exemplo.lua"))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = 1", "local y = 2", "print(x + y)" })
  vim.bo[buf].filetype = "lua"

  local text = context.expand("look at this", { bufnr = buf, line = 2 })
  assert(text:find("[editor context]", 1, true), text)
  assert(text:find("file=exemplo.lua", 1, true), text)
  assert(text:find("lang=lua", 1, true), text)
  assert(text:find("cursor=2", 1, true), text)
  assert(text:find("look at this", 1, true), text)

  -- with a selection the code itself goes along
  local selected = context.expand("what about this?", {
    bufnr = buf,
    selection = { bufnr = buf, first = 1, last = 2 },
  })
  assert(selected:find("selection=1-2", 1, true), selected)
  assert(selected:find("local x = 1", 1, true), selected)

  -- an explicit placeholder wins over the automatic header
  local explicit = context.expand("@this", { bufnr = buf, line = 1 })
  assert(not explicit:find("[editor context]", 1, true), explicit)
  assert(explicit:find("local x = 1", 1, true), explicit)

  -- and it can be turned off
  cfg.get().context.auto = false
  local plain = context.expand("look at this", { bufnr = buf, line = 2 })
  assert(not plain:find("[editor context]", 1, true), plain)
  cfg.get().context.auto = true
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("actions are one pick away", function()
  assert(vim.fn.exists(":OpencodeActions") == 2)
  assert(vim.fn.exists(":OpencodeEdit") == 2)
  assert(type(plugin.actions) == "table" and #plugin.actions >= 5, vim.inspect(plugin.actions))
  local labels = {}
  for _, action in ipairs(plugin.actions) do
    labels[action.label] = true
    assert(type(action.prompt) == "string" and action.prompt ~= "", vim.inspect(action))
  end
  assert(labels["review my changes"] and labels["write tests"], vim.inspect(labels))
end)

test("reasoning gets a header, a gutter and a fold", function()
  plugin.open({ input = false }) -- folds need a window
  plugin.clear()
  settle()
  feed("session.execution.started") -- "▸ thinking…" placeholder
  settle()
  feed("session.reasoning.started")
  feed("session.reasoning.delta", { delta = "let me think" })
  feed("session.reasoning.delta", { delta = "\nabout this" })
  feed("session.reasoning.ended")
  settle()

  local text = panel_text()
  assert(text:find("▸ thinking", 1, true), "no reasoning header:\n" .. text)
  assert(text:find("│ let me think", 1, true), "reasoning is not guttered:\n" .. text)
  assert(text:find("│ about this", 1, true), "second reasoning line lost the gutter:\n" .. text)
  assert(not text:find("▸ thinking…", 1, true), "the placeholder was not replaced:\n" .. text)

  local buf = panel.state.buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first_gutter
  for index, line in ipairs(lines) do
    if line:sub(1, #"│ ") == "│ " and not first_gutter then first_gutter = index end
  end
  assert(first_gutter, "no guttered line found")

  -- the reasoning block is collapsed with a manual fold (no foldexpr, which
  -- would run on every redraw)
  assert(vim.wo[panel.state.win].foldmethod == "manual",
    "expected manual folds, got " .. vim.wo[panel.state.win].foldmethod)
  if vim.wo[panel.state.win].foldenable then
    local closed = vim.api.nvim_win_call(panel.state.win, function()
      return vim.fn.foldclosed(first_gutter)
    end)
    assert(closed ~= -1, "the reasoning block is not folded closed")
  end
  plugin.close()
end)

test("a new turn is separated and keeps the prompt visible", function()
  plugin.clear()
  settle()
  feed("session.text.started")
  feed("session.text.delta", { delta = "first answer" })
  feed("session.text.ended", { text = "first answer" })
  settle()

  panel.send("second question", {})
  settle()
  local lines = vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  assert(text:find("❯ second question", 1, true), text)
  -- a blank line separates the turns
  local blank_before = false
  for index, line in ipairs(lines) do
    if line:find("❯ second question", 1, true) and index > 1 and lines[index - 1] == "" then
      blank_before = true
    end
  end
  assert(blank_before, "there is no blank line before the new turn:\n" .. text)
end)

test("the stall warning names the last event of the session", function()
  plugin.clear()
  settle()
  feed("session.execution.started") -- a turn started and never produced content
  settle()

  -- Pretend 31s went by (calling tick() directly: no need to wait).
  panel.state.status = "running"
  panel.state.running_since = (vim.uv or vim.loop).now() - 31000
  panel.state.warned_slow = false
  panel.tick()
  settle()

  local text = panel_text()
  assert(text:find("no response for", 1, true), "no stall warning:\n" .. text)
  assert(text:find("last event:", 1, true), "the warning does not name the last event:\n" .. text)

  -- And it is taken back as soon as content arrives.
  feed("session.text.started")
  feed("session.text.delta", { delta = "late answer" })
  feed("session.text.ended", { text = "late answer" })
  settle()
  text = panel_text()
  assert(not text:find("no response for", 1, true), "the stall warning was not removed:\n" .. text)
  assert(text:find("late answer", 1, true), text)
end)

test("reasoning around a tool call stays in one block", function()
  plugin.clear()
  settle()
  feed("session.execution.started")
  feed("session.reasoning.started")
  feed("session.reasoning.delta", { delta = "The user says" })
  -- the server interleaves the tool call *inside* the reasoning part
  feed("session.tool.input.started", { id = "c1", name = "read" })
  feed("session.reasoning.ended")
  feed("session.tool.input.ended", { id = "c1", text = '{"filePath":"/tmp/a.lua"}' })
  feed("session.tool.called", { id = "c1", input = { filePath = "/tmp/a.lua" } })
  feed("session.tool.success", { id = "c1", content = { { type = "text", text = "ok" } } })
  settle()

  local lines = vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  local headers = 0
  for _, line in ipairs(lines) do
    if line == "▸ thinking" then headers = headers + 1 end
  end
  assert(headers == 1, "expected a single reasoning header:\n" .. text)

  local reasoning_at, tool_at
  for index, line in ipairs(lines) do
    if line:find("│ The user says", 1, true) then reasoning_at = index end
    if line:find("▸ read /tmp/a.lua", 1, true) then tool_at = index end
  end
  assert(reasoning_at and tool_at and reasoning_at < tool_at,
    "reasoning and tool are out of order:\n" .. text)
  assert(not text:find("▸ The", 1, true), "the reasoning fragment leaked as a header:\n" .. text)
end)

test("the panel advertises its keys", function()
  plugin.open({ input = false })
  local footer = vim.api.nvim_win_get_config(panel.state.win).footer or {}
  local text = ""
  for _, line in ipairs(footer) do
    text = text .. (type(line) == "table" and table.concat(line) or tostring(line))
  end
  assert(text:find("prompt", 1, true) and text:find("close", 1, true),
    "the panel footer does not list the keys: " .. vim.inspect(footer))
  plugin.close()
end)

test("a fresh session does not wipe the panel", function()
  local session = require("opencode-nvim.session")
  local saved_current, saved_sid = session.current, panel.state.session_id

  plugin.clear()
  settle()
  feed("session.execution.started") -- renders the "▸ thinking…" placeholder

  local fresh = { id = "ses_fresh", location = { directory = vim.uv.cwd() }, fresh = true }
  panel.state.session_id = nil
  session.current = fresh
  event.emit({ type = "opencode.session.changed", data = fresh })
  settle()

  local text = panel_text()
  assert(text:find("thinking", 1, true), "the prompt was wiped when the session was created:\n" .. text)
  assert(session.current.fresh == nil, "the fresh flag should be consumed")

  -- and only ONE placeholder: resetting the flag without clearing the line used
  -- to add a second one (the first message showed two "▸ thinking…")
  local placeholders = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false)) do
    if line:find("▸ thinking…", 1, true) then placeholders = placeholders + 1 end
  end
  assert(placeholders == 1, string.format("expected one placeholder, found %d:\n%s", placeholders, text))

  session.current, panel.state.session_id = saved_current, saved_sid
end)

test("prompt and panel are aligned and do not overlap", function()
  plugin.open()
  local pwin, iwin = panel.state.win, panel.state.input.win
  assert(pwin and iwin, "janelas ausentes")
  local panel_conf = vim.api.nvim_win_get_config(pwin)
  local input_conf = vim.api.nvim_win_get_config(iwin)

  -- Same anchor, column and width: alignment guaranteed by construction
  -- (the C side computes the border the same way for both).
  assert(panel_conf.anchor == "SE" and input_conf.anchor == "SE",
    string.format("different anchors: panel=%s prompt=%s", tostring(panel_conf.anchor), tostring(input_conf.anchor)))
  assert(panel_conf.col == input_conf.col,
    string.format("different columns: panel=%s prompt=%s", tostring(panel_conf.col), tostring(input_conf.col)))
  assert(panel_conf.width == input_conf.width,
    string.format("different widths: panel=%s prompt=%s", tostring(panel_conf.width), tostring(input_conf.width)))

  -- The panel ends above the prompt under either border convention.
  local panel_outer_bottom = panel_conf.row + 1
  local input_outer_top = input_conf.row - input_conf.height - 2
  assert(panel_outer_bottom < input_outer_top,
    string.format("prompt overlaps the panel: panel_bottom=%d prompt_top=%d", panel_outer_bottom, input_outer_top))
  plugin.close()
end)

test("no keymaps are created unless asked for", function()
  local before = #vim.api.nvim_get_keymap("n")
  plugin.setup({}) -- defaults: no keymaps
  assert(#vim.api.nvim_get_keymap("n") == before,
    "setup() created keymaps by default")

  -- and only the requested ones when enabled
  plugin.setup({ keymaps = { enabled = true, toggle = "<F9>" } })
  -- NOTE: maparg wants the key notation ("<F9>"), not the raw termcodes
  local function mapping(key)
    return vim.fn.maparg(key, "n", false, true)
  end
  local found = mapping("<F9>")
  assert(type(found) == "table" and found.desc ~= nil, "the requested keymap was not created")
  assert(vim.tbl_isempty(mapping("<F8>")), "an unrequested keymap was created")

  -- every action is reachable as a command
  for _, name in ipairs({
    "Opencode", "OpencodeClose", "OpencodeAsk", "OpencodeEdit", "OpencodeActions",
    "OpencodeNew", "OpencodeAttach", "OpencodeSessions", "OpencodeModels", "OpencodeAgents",
    "OpencodeInterrupt", "OpencodeResend", "OpencodeUndo", "OpencodeDiff", "OpencodeClear",
    "OpencodeApproval", "OpencodeApprovalAgent", "OpencodePermissions",
    "OpencodeEvents", "OpencodeDoctor", "OpencodeHealth", "OpencodeLog",
  }) do
    assert(vim.fn.exists(":" .. name) == 2, "missing command :" .. name)
  end

  -- a range (visual mode) is understood by the commands that take one
  local range_info = vim.api.nvim_get_commands({}).OpencodeAsk
  assert(range_info and range_info.range ~= nil and range_info.range ~= "",
    "OpencodeAsk does not accept a range: " .. vim.inspect(range_info and range_info.range))
  plugin.setup({})
end)

test("a command starts with an empty prompt", function()
  -- OpencodeEdit pre-fills its template
  vim.cmd("OpencodeEdit")
  settle()
  local text = table.concat(vim.api.nvim_buf_get_lines(panel.state.input.buf, 0, -1, false), "\n")
  assert(text:find("Edit the code above", 1, true), text)
  panel.close_input()

  -- OpencodeAsk must not inherit that draft
  vim.cmd("OpencodeAsk")
  settle()
  text = table.concat(vim.api.nvim_buf_get_lines(panel.state.input.buf, 0, -1, false), "\n")
  assert(text == "", "the draft leaked into :OpencodeAsk: " .. vim.inspect(text))
  plugin.close()

  -- nor must :Opencode
  vim.cmd("Opencode")
  settle()
  text = table.concat(vim.api.nvim_buf_get_lines(panel.state.input.buf, 0, -1, false), "\n")
  assert(text == "", "the draft leaked into :Opencode: " .. vim.inspect(text))

  -- the in-panel key keeps the draft on purpose
  vim.api.nvim_buf_set_lines(panel.state.input.buf, 0, -1, false, { "meu rascunho" })
  panel.close_input()
  panel.open_input(nil, nil, false)
  settle()
  text = table.concat(vim.api.nvim_buf_get_lines(panel.state.input.buf, 0, -1, false), "\n")
  assert(text:find("rascunho", 1, true), "the in-panel key should keep the draft: " .. vim.inspect(text))
  plugin.close()
end)

test("a ranged command sends the selection", function()
  local work = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(work, vim.fs.joinpath(vim.uv.cwd(), "range.lua"))
  vim.api.nvim_buf_set_lines(work, 0, -1, false, { "line one", "line two" })
  vim.api.nvim_set_current_buf(work)
  vim.api.nvim_buf_set_mark(work, "<", 1, 1, {})
  vim.api.nvim_buf_set_mark(work, ">", 2, 1, {})

  vim.cmd("'<,'>OpencodeAsk hello")
  settle()
  assert(panel.state.input.win ~= nil, "the prompt did not open")
  local text = table.concat(vim.api.nvim_buf_get_lines(panel.state.input.buf, 0, -1, false), "\n")
  assert(text:find("hello", 1, true), "the argument was lost: " .. text)
  local selection = panel.state.input.selection
  assert(selection and selection.first == 1 and selection.last == 2,
    "the range was not passed: " .. vim.inspect(selection))

  -- without a range there is no selection
  panel.close_input()
  vim.cmd("OpencodeAsk no-range")
  settle()
  assert(panel.state.input.selection == nil,
    "a selection appeared without a range: " .. vim.inspect(panel.state.input.selection))

  plugin.close()
  vim.api.nvim_buf_delete(work, { force = true })
end)

test("<Esc> in the prompt leaves the whole UI", function()
  local cfg = require("opencode-nvim.config")

  plugin.open()
  assert(panel.visible() and panel.state.input.win ~= nil, "the UI did not open")
  panel.escape()
  settle()
  assert(panel.state.input.win == nil, "the prompt is still open")
  assert(not panel.visible(), "the panel is still open")

  -- "<Esc> only closes the prompt" stays available
  cfg.get().ui.escape_closes = "input"
  plugin.open()
  panel.escape()
  settle()
  assert(panel.state.input.win == nil, "the prompt is still open")
  assert(panel.visible(), "the panel should have stayed open")

  cfg.get().ui.escape_closes = "all"
  plugin.close()
end)

test("clear() resets the per-turn state", function()
  -- a stale "thinking" flag used to swallow the next turn's placeholder
  panel.state.thinking = true
  panel.state.reasoning_open = true
  panel.state.pending_tools = { stale = { name = "read" } }
  plugin.clear()
  assert(panel.state.thinking == false, "thinking flag survived clear()")
  assert(panel.state.reasoning_open == false, "reasoning flag survived clear()")
  assert(next(panel.state.pending_tools) == nil, "pending tools survived clear()")
end)

test("focus_after_submit honours the configured mode", function()
  local cfg = require("opencode-nvim.config")
  local target = panel.code_target()
  assert(target and target.win, "no code window found")

  cfg.get().ui.focus_after_submit = "code"
  panel.open()
  assert(panel.state.input.win ~= nil)
  panel.close_input()
  panel.state.input.target = target
  panel.after_submit()
  assert(vim.api.nvim_get_current_win() == target.win, "focus did not return to the code")

  cfg.get().ui.focus_after_submit = "input"
  panel.after_submit()
  assert(panel.state.input.win ~= nil, "the prompt was not reopened")
  assert(vim.api.nvim_get_current_win() == panel.state.input.win, "the prompt did not get focus")

  cfg.get().ui.focus_after_submit = "code"
  plugin.close()
end)

io.write(string.format("\n%d falha(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
