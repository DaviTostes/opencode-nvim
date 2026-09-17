local api = require("opencode-nvim.api")
local cfg = require("opencode-nvim.config")
local context = require("opencode-nvim.context")
local event = require("opencode-nvim.event")
local log = require("opencode-nvim.log")
local session = require("opencode-nvim.session")
local util = require("opencode-nvim.util")
local Renderer = require("opencode-nvim.ui.render")

--- Floating conversation panel plus its prompt buffer.
---
--- The panel never takes focus when it opens: the cursor keeps living in the
--- code window while the answer streams beside it.
local M = {}

local THINKING_LINE = "▸ thinking…"
local THINKING_HEADER = "▸ thinking"
local GUTTER = "│ "

--- True while any flavour of insert mode is active.
local function inserting()
  return vim.fn.mode(1):find("^[iR]") ~= nil
end

--- Work that needs the panel window to be the current one.
---
--- Switching the current window from insert mode makes Neovim attribute the
--- insert mode to the buffer that became current ("the panel entered insert
--- mode") and the cursor goes with it. Measured with a real UI: `nvim_win_call`
--- emits that mode change, `vim.fn.win_execute()` does not switch the focus at
--- all. So: never `nvim_win_call` while inserting — queue it for InsertLeave.
local pending_window_commands = {}

local function flush_window_commands()
  if inserting() then return end
  local list = pending_window_commands
  pending_window_commands = {}
  for _, item in ipairs(list) do
    if vim.api.nvim_win_is_valid(item.win) then
      pcall(vim.fn.win_execute, item.win, item.command)
    end
  end
end

vim.api.nvim_create_autocmd("InsertLeave", {
  callback = function() vim.schedule(flush_window_commands) end,
})

---@param win integer
---@param command string Ex command to run in that window
local function when_not_inserting(win, command)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if not inserting() then
    return pcall(vim.fn.win_execute, win, command)
  end
  pending_window_commands[#pending_window_commands + 1] = { win = win, command = command }
end

local state = {
  buf = nil,
  win = nil,
  renderer = nil,
  status = "idle",
  follow = true, -- whether the view was at the end before the last draw
  model = nil,
  geom = nil,
  session_id = nil,
  thinking = false,
  reasoning_open = false,
  reasoning_text = nil,
  pending_tools = {},
  pending_order = {},
  stall_text = nil,
  running_since = nil,
  warned_slow = false,
  ticker = nil,
  input = {
    buf = nil,
    win = nil,
    target = nil,
    selection = nil,
    history = {},
    index = 0,
    draft = "",
  },
}

M.state = state

--- Collapses a finished reasoning block with a *manual* fold.
---
--- Folds are created once, when the block ends, instead of using `foldexpr`,
--- which runs on every redraw (a fragile place to evaluate Lua, and one that
--- cannot be exercised by the headless tests).
--- Going to the end means: put the cursor on the last line. It is a deliberate
--- jump, so it never fights the "is the view still at the end?" check.
function M.scroll_to_bottom()
  local win = state.win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return end
  local last = vim.api.nvim_buf_line_count(state.buf)
  -- Fast path: the cursor is on the last line and the view already shows it.
  -- Drawing a tool header or replacing a line calls this with no new line to
  -- reveal, and the `winrestview` below is an Ex command (the expensive part).
  local cursor = vim.api.nvim_win_get_cursor(win)
  if cursor[1] >= last and vim.fn.line("w$", win) >= last then return end
  -- Moving another window's cursor is invisible to the mode and works without
  -- focus, so this runs always: the panel keeps following while you type.
  pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
  -- Making the window show that line needs it to be current, which must not
  -- happen during insert mode (see `when_not_inserting`). `winrestview` is an
  -- Ex call, so unlike `normal!` it does not put that window in normal mode.
  when_not_inserting(win, string.format("call winrestview({'lnum': %d})", last))
end

--- True when the last line of the buffer is on screen, i.e. the user is
--- following the conversation and has not scrolled up.
---
--- `w$` is the last *displayed* buffer line, which is what matters: a closed
--- fold makes 30 buffer lines take a single screen row.
local function window_at_bottom()
  local win = state.win
  if not (win and vim.api.nvim_win_is_valid(win)) then return true end
  -- `line()` takes a window id, so this is a read that never switches windows
  -- (it runs on every draw: switching here was the whole bug).
  return vim.fn.line("w$", win) >= vim.fn.line("$", win)
end

--- Kept for callers that just want the view to catch up.
function M.scroll_soon()
  -- live check: a stale `follow` (from the previous draw) would drag the
  -- view back to the end after the user scrolled up
  if window_at_bottom() then M.scroll_to_bottom() end
end

local function fold_reasoning(renderer)
  if (cfg.get().ui.panel or {}).folds == false then return end
  local block = renderer:last_block()
  if block.kind ~= "dim" or not block.first or not block.last then return end
  if block.last <= block.first then return end
  local win = state.win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  -- Write the block out first: a pending debounced draw would rewrite those
  -- lines right after the fold and drop it.
  renderer:draw()
  local follow = window_at_bottom()
  -- `:fold` *closes*; creating one from a script is `zf` over a visual range.
  -- Done without switching the focus, and deferred while you are typing.
  when_not_inserting(win, string.format("normal! %dGV%dGzf | normal! zc", block.first, block.last))
  if follow then M.scroll_to_bottom() end
end

local function err_text(err)
  if type(err) == "table" then return err.message or vim.inspect(err) end
  return tostring(err)
end

--- Whether tool bodies are shown in the panel (`ui.panel.tool_output`).
---
--- An edit tool prints its patch as its body, so this is the switch that keeps
--- changes out of the conversation.
local function tool_output_enabled()
  return (cfg.get().ui.panel or {}).tool_output ~= false
end

local function panel_geometry()
  local ui = cfg.get().ui.panel or {}
  local columns, lines = vim.o.columns, vim.o.lines
  local width = math.floor(columns * (ui.width or 0.45))
  local height = math.floor(lines * (ui.height or 0.35))
  width = math.min(ui.max_width or 110, math.max(30, width))
  height = math.min(ui.max_height or 30, math.max(5, height))
  width = math.max(10, math.min(width, columns - 4))
  height = math.max(3, math.min(height, lines - 6))
  return width, height
end

--------------------------------------------------------------------------------
-- Panel window
--------------------------------------------------------------------------------

--- Panel title. Status first (it is what changes and what you glance at),
--- then agent/model, then the cheap-to-skip numbers.
function M.title()
  local parts = {}
  if state.status == "running" then
    local elapsed = state.running_since
      and math.floor(((vim.uv or vim.loop).now() - state.running_since) / 1000)
      or 0
    parts[#parts + 1] = elapsed > 0 and string.format("● %ds", elapsed) or "●"
  elseif state.status == "error" then
    parts[#parts + 1] = "!"
  end

  local info = session.info()
  if info then
    local model = state.model or (info.model and (info.model.id or info.model.modelID))
    if info.agent then parts[#parts + 1] = info.agent end
    if model then parts[#parts + 1] = model end
    local total, cost = session.tokens()
    if total > 0 then parts[#parts + 1] = string.format("%.1fk", total / 1000) end
    if cost and cost > 0 then parts[#parts + 1] = string.format("$%.4f", cost) end
  else
    parts[#parts + 1] = "no session"
  end

  if event.started() and not event.connected() then
    parts[#parts + 1] = "offline"
  end
  return table.concat(parts, " · ")
end

--- Takes back the "thinking" placeholder when real content shows up. When the
--- content *is* reasoning the placeholder becomes the block header instead, so
--- reasoning is always delimited from the answer.
local function clear_thinking(renderer, as_header)
  if not state.thinking then return end
  state.thinking = false
  if as_header then
    if renderer:replace_line(THINKING_LINE, THINKING_HEADER) then return end
    renderer:remove_line(THINKING_LINE)
  else
    renderer:remove_line(THINKING_LINE)
  end
end

--- Reasoning arrives interleaved with tool calls (the server emits
--- `tool.input.started` in the middle of a reasoning part), so a header is
--- ensured per reasoning run instead of relying on the placeholder alone.
local function ensure_reasoning_header(renderer)
  if state.reasoning_open then return end
  state.reasoning_open = true
  -- The placeholder of this turn becomes the header when it is still around.
  if not renderer:replace_line(THINKING_LINE, THINKING_HEADER) then
    renderer:note(THINKING_HEADER, "meta")
  end
end

--- Writes the accumulated reasoning of one part into the panel.
---
--- Inline (header + gutter) and only when the part is complete, so it never
--- interleaves with tool output and never flickers word by word.
local function flush_reasoning(renderer)
  local text = state.reasoning_text
  state.reasoning_text = nil
  if not text or text == "" then return end
  ensure_reasoning_header(renderer)
  renderer:finalize()
  renderer:stream("dim", text, GUTTER)
  renderer:finalize()
  state.reasoning_open = false
  fold_reasoning(renderer)
end

--- Tool headers are deferred until their arguments are complete, so the
--- reasoning around a tool call stays in a single block (and the header gets
--- the useful summary on the first render).
local function flush_tool(renderer, id, name, args)
  -- keep the order: reasoning written before the tool it surrounds
  flush_reasoning(renderer)
  local pending = state.pending_tools[id]
  state.pending_tools[id] = nil
  name = name or (pending and pending.name)
  args = args or (pending and pending.args)
  state.reasoning_open = false
  renderer:tool_begin(id, name)
  if args ~= nil then
    renderer:tool_called(id, name, args)
  end
end

--- Flushes every deferred tool, in the order they were announced.
---
--- `pairs` over the table itself rendered them in a different order from run to
--- run (several tools can be pending at the end of a turn).
local function flush_all_tools(renderer)
  local order = state.pending_order or {}
  state.pending_order = {}
  for _, id in ipairs(order) do
    if state.pending_tools[id] then flush_tool(renderer, id) end
  end
end

--- Takes back the stall warning once something finally arrives.
local function clear_stall(renderer)
  if not state.stall_text then return end
  local text = state.stall_text
  state.stall_text = nil
  renderer:remove_line(text)
end

--- Short summary of the last event that belongs to this session, so a stalled
--- turn can be told apart from a dead stream.
---
--- NOTE: defined before the ticker on purpose — a `local function` declared
--- after its use would resolve to a global and blow up at 30s.
local function last_event_summary()
  local history = event.history()
  local now = os.time()
  for index = #history, 1, -1 do
    local item = history[index]
    local sid = util.pick_string(item.data or {}, { "sessionID" })
    if sid == nil or sid == session.id() then
      local age
      if item.created then age = now - math.floor(item.created / 1000) end
      return string.format("%s%s", item.type, age and string.format(" (%ds ago)", age) or "")
    end
  end
  return "none"
end

function M.set_status(status)
  local now = (vim.uv or vim.loop).now()
  if status == "running" and state.status ~= "running" then
    state.running_since = now
    state.warned_slow = false
  elseif status ~= "running" then
    state.running_since = nil
  end
  state.status = status
  if status == "running" then M.start_ticker() else M.stop_ticker() end
  M.update_title()
end

--- Keeps the title counting while a turn runs, and warns once when the
--- provider is taking too long (otherwise a stalled turn looks like a no-op).
function M.tick()
  if state.status ~= "running" then return end
  M.update_title()
  local elapsed = state.running_since and ((vim.uv or vim.loop).now() - state.running_since) / 1000 or 0
  if elapsed > 30 and not state.warned_slow then
    state.warned_slow = true
    local text = string.format(
      "no response for %ds (last event: %s) — the provider may be slow; <C-c> interrupts, r resends, :OpencodeDoctor diagnoses",
      math.floor(elapsed), last_event_summary())
    state.stall_text = text
    M.renderer():note(text, "meta")
    M.scroll_soon()
  end
end

function M.start_ticker()
  if state.ticker then return end
  state.ticker = (vim.uv or vim.loop).new_timer()
  state.ticker:start(1000, 1000, vim.schedule_wrap(M.tick))
end

function M.stop_ticker()
  if not state.ticker then return end
  state.ticker:stop()
  state.ticker:close()
  state.ticker = nil
end


local function input_open()
  return state.input.win ~= nil and vim.api.nvim_win_is_valid(state.input.win)
end

--- Full float config for the panel.
---
--- When the prompt is open the panel is lifted so both stack in the corner
--- instead of overlapping.
local function panel_config()
  local width, height = panel_geometry()
  local lift = 0
  if input_open() then
    -- The prompt is `input_height` rows plus its two border rows; +2 puts the
    -- panel's bottom border right above the prompt's top border, with no hole in
    -- between.
    lift = M.input_height() + 2
  end
  return {
    relative = "editor",
    anchor = "SE",
    row = vim.o.lines - 2 - lift,
    col = vim.o.columns - 2,
    width = width,
    height = height,
    style = "minimal",
    border = (cfg.get().ui.panel or {}).border or "rounded",
    title = " " .. M.title() .. " ",
    title_pos = "left",
    footer = " i prompt · N new session · <C-c> interrupt · gd diff · r resend · q close ",
    footer_pos = "center",
    focusable = true,
    zindex = 50,
  }
end

function M.update_title()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  -- Change detection: this runs on every event of a running turn and
  -- `nvim_win_set_config` re-lays out the float every single time.
  local width, height = panel_geometry()
  local signature = table.concat({
    M.title(),
    tostring(width),
    tostring(height),
    tostring(input_open() and M.input_height() or 0),
    tostring(vim.o.columns),
    tostring(vim.o.lines),
  }, "|")
  if state.title_signature == signature then return end
  state.title_signature = signature
  pcall(vim.api.nvim_win_set_config, state.win, panel_config())
end

function M.set_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", function() M.close() end, vim.tbl_extend("force", opts, { desc = "close panel" }))
  vim.keymap.set("n", "<Esc>", function() M.close() end, vim.tbl_extend("force", opts, { desc = "close panel" }))
  local function open_prompt()
    -- from inside the panel the draft is kept on purpose
    M.open_input(nil, nil, false)
  end
  vim.keymap.set("n", "i", open_prompt, vim.tbl_extend("force", opts, { desc = "open prompt" }))
  vim.keymap.set("n", "a", open_prompt, vim.tbl_extend("force", opts, { desc = "open prompt" }))
  vim.keymap.set("n", "<CR>", open_prompt, vim.tbl_extend("force", opts, { desc = "open prompt" }))
  vim.keymap.set("n", "<C-c>", function() M.interrupt() end, vim.tbl_extend("force", opts, { desc = "interrupt" }))
  vim.keymap.set("n", "gd", function() M.show_diff() end, vim.tbl_extend("force", opts, { desc = "turn diff" }))
  vim.keymap.set("n", "r", function() M.retry() end, vim.tbl_extend("force", opts, { desc = "resend last prompt" }))
  vim.keymap.set("n", "N", function() M.new_session() end, vim.tbl_extend("force", opts, { desc = "new session" }))
  vim.keymap.set("n", "G", function()
    M.scroll_to_bottom()
  end, vim.tbl_extend("force", opts, { desc = "go to the end" }))
end

function M.ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, string.format("opencode-nvim://panel/%d", vim.fn.getpid()))
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  -- Display only: the renderer unlocks it while writing.
  vim.bo[buf].modifiable = false
  state.buf = buf
  state.renderer = Renderer.new(buf)
  -- Following the end is decided from the window view while drawing, never from
  -- a sticky flag: folding moves the cursor programmatically and used to switch
  -- the panel out of follow mode on its own.
  state.renderer.on_before_draw = function()
    state.follow = window_at_bottom()
  end
  state.renderer.on_after_draw = function()
    if state.follow then M.scroll_to_bottom() end
  end
  M.set_keymaps(buf)

  return buf
end

function M.renderer()
  if state.renderer and state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.renderer end
  M.ensure_buf()
  return state.renderer
end

function M.visible()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function ensure_win()
  local buf = M.ensure_buf()
  if M.visible() then return state.win end
  state.win = vim.api.nvim_open_win(buf, false, panel_config())
  vim.wo[state.win].wrap = true
  vim.wo[state.win].linebreak = true
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].foldcolumn = "0"
  vim.wo[state.win].winhighlight = "Normal:OpencodeNormal,FloatBorder:OpencodeBorder,FloatTitle:OpencodeTitle"
  state.title_signature = nil
  if (cfg.get().ui.panel or {}).folds ~= false then
    -- Manual folds: `fold_reasoning` creates one per reasoning block when the
    -- block ends (zo opens, zR opens all).
    vim.wo[state.win].foldmethod = "manual"
    vim.wo[state.win].foldlevel = 0
    vim.wo[state.win].foldenable = true
  end
  -- A freshly opened panel shows the end of the conversation.
  M.scroll_to_bottom()
  return state.win
end

--- Opens the panel. With `opts.input ~= false`, also opens the prompt.
---@param opts? { prefill?: string, selection?: table, input?: boolean, fresh?: boolean, focus?: boolean }
function M.open(opts)
  opts = opts or {}
  ensure_win()
  M.update_title()

  -- Opening the UI is a deliberate act, so it takes the cursor by default
  -- (`ui.focus_on_open = false` keeps it where it is). Automatic opens — the
  -- panel appearing because an answer is streaming — pass focus = false.
  local focus = opts.focus
  if focus == nil then
    focus = (cfg.get().ui or {}).focus_on_open ~= false
  end
  if focus then pcall(vim.api.nvim_set_current_win, state.win) end

  if opts.input ~= false then
    M.open_input(opts.prefill, opts.selection, opts.fresh ~= false)
  end
  return state.win
end

function M.close()
  M.close_input()
  if M.visible() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  state.title_signature = nil
end

--- Show or hide the panel. Showing it never moves the cursor and never opens
--- the prompt: type with `:OpencodeAsk` or the in-panel key.
function M.toggle()
  if M.visible() then return M.close() end
  M.open({ input = false })
end

function M.focus()
  if M.visible() then
    pcall(vim.api.nvim_set_current_win, state.win)
    vim.cmd("stopinsert")
  end
end

--- Window to return to (the code you were in before opening the panel).
function M.remember_code_win()
  local win = vim.api.nvim_get_current_win()
  if win ~= state.win and win ~= state.input.win and vim.api.nvim_win_is_valid(win) then
    state.code_win = win
  end
end

--- Focus that code window again.
function M.focus_code()
  local win = state.code_win
  if win and vim.api.nvim_win_is_valid(win) then
    return pcall(vim.api.nvim_set_current_win, win)
  end
  for _, candidate in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(candidate)
    if vim.api.nvim_win_get_config(candidate).relative == "" and buf ~= state.buf then
      return pcall(vim.api.nvim_set_current_win, candidate)
    end
  end
end

--- Switch the cursor between the plugin UI and your code.
function M.focus_toggle()
  local current = vim.api.nvim_get_current_win()
  if current == state.win or current == state.input.win then
    return M.focus_code()
  end
  return M.focus()
end

--------------------------------------------------------------------------------
-- Prompt input
--------------------------------------------------------------------------------

function M.input_buf()
  if state.input.buf and vim.api.nvim_buf_is_valid(state.input.buf) then return state.input.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, string.format("opencode-nvim://input/%d", vim.fn.getpid()))
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  state.input.buf = buf

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set({ "i", "n" }, "<CR>", function() M.submit() end, opts)
  vim.keymap.set({ "i", "n" }, "<C-j>", function() M.insert_newline() end, opts)
  vim.keymap.set({ "i", "n" }, "<Esc>", function() M.escape() end, opts)
  vim.keymap.set({ "i", "n" }, "<C-c>", function() M.interrupt() end, opts)
  -- <C-p>/<C-n> are completion keys in insert mode, so the prompt history uses
  -- <C-Up>/<C-Down> there and <C-p>/<C-n> only in normal mode.
  vim.keymap.set({ "i", "n" }, "<C-Up>", function() M.input_history(-1) end, opts)
  vim.keymap.set({ "i", "n" }, "<C-Down>", function() M.input_history(1) end, opts)
  vim.keymap.set("n", "<C-p>", function() M.input_history(-1) end, opts)
  vim.keymap.set("n", "<C-n>", function() M.input_history(1) end, opts)
  vim.bo[buf].omnifunc = "v:lua.opencode_nvim_omnifunc"

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = buf,
    callback = function() M.update_input_win() end,
  })

  return buf
end

--- Browse previously sent prompts: <C-p> goes back, <C-n> forward, and going
--- past the newest restores the draft.
---@param direction -1 older, 1 newer
function M.input_history(direction)
  local history = state.input.history
  local input = state.input
  if not (input.buf and vim.api.nvim_buf_is_valid(input.buf)) then return end
  if #history == 0 then return end

  if input.index == 0 and direction < 0 then
    input.draft = table.concat(vim.api.nvim_buf_get_lines(input.buf, 0, -1, false), "\n")
  end
  local index = math.max(0, math.min(#history, (input.index or 0) - direction))
  input.index = index

  local text = index == 0 and (input.draft or "") or history[#history - index + 1]
  vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, util.lines(text))
  local last = vim.api.nvim_buf_line_count(input.buf)
  local last_line = vim.api.nvim_buf_get_lines(input.buf, last - 1, last, false)[1] or ""
  if input.win and vim.api.nvim_win_is_valid(input.win) then
    pcall(vim.api.nvim_win_set_cursor, input.win, { last, #last_line })
  end
  M.update_input_win()
  vim.cmd("startinsert!")
end

--- Completion for `@` placeholders, files and buffers.
function M.complete(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local before = line:sub(1, col)
    local word = before:match("[%w@%./_%-]*$") or ""
    return col - #word
  end

  local items = {}
  for _, name in ipairs({ "this", "buffer", "buffers", "diagnostics", "diff" }) do
    local candidate = "@" .. name
    if candidate:sub(1, #base) == base then items[#items + 1] = candidate end
  end
  local ok, files = pcall(vim.fn.getcompletion, base, "file")
  if ok and type(files) == "table" then
    for _, file in ipairs(files) do
      items[#items + 1] = file
      if #items > 300 then break end
    end
  end
  return items
end

function M.input_height()
  local ui = cfg.get().ui.input or {}
  local buf = state.input.buf
  local count = 1
  if buf and vim.api.nvim_buf_is_valid(buf) then count = vim.api.nvim_buf_line_count(buf) end
  return math.max(1, math.min(ui.height or 4, count))
end

function M.update_input_win()
  if not (state.input.buf and vim.api.nvim_buf_is_valid(state.input.buf)) then return end
  local width = select(1, panel_geometry())
  local ui = cfg.get().ui.input or {}

  -- Same anchor, column and width as the panel: the two boxes line up by
  -- construction, whatever the border does to the anchor arithmetic.
  local config = {
    relative = "editor",
    anchor = "SE",
    row = vim.o.lines - 2,
    col = vim.o.columns - 2,
    width = width,
    height = M.input_height(),
    style = "minimal",
    border = ui.border or "rounded",
    title = " prompt · enter sends · esc closes ",
    title_pos = "left",
    zindex = 60,
  }

  -- The prompt is reconfigured from `TextChangedI` (every keystroke): only do
  -- the work when the geometry actually changed. The height follows the number
  -- of lines in the buffer, which is part of the signature.
  local signature = string.format("%d|%d|%d|%d|%s",
    width, config.height, vim.o.columns, vim.o.lines, ui.border or "rounded")

  if state.input.win and vim.api.nvim_win_is_valid(state.input.win) then
    if state.input.signature ~= signature then
      state.input.signature = signature
      pcall(vim.api.nvim_win_set_config, state.input.win, config)
    end
  else
    state.input.win = vim.api.nvim_open_win(state.input.buf, true, config)
    state.input.signature = signature
    vim.wo[state.input.win].wrap = true
    vim.wo[state.input.win].linebreak = true
    vim.wo[state.input.win].winhighlight = "Normal:OpencodeNormal,FloatBorder:OpencodeBorder,FloatTitle:OpencodeTitle"
  end

  -- The panel stacks above the prompt.
  M.update_title()
end

--- Window/buffer that provides context for the prompt.
function M.code_target()
  local current = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(current)
  if buf ~= state.buf and buf ~= state.input.buf then
    return { win = current, bufnr = buf, cursor = vim.api.nvim_win_get_cursor(current) }
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local win_buf = vim.api.nvim_win_get_buf(win)
    local conf = vim.api.nvim_win_get_config(win)
    if win_buf ~= state.buf and win_buf ~= state.input.buf and conf.relative == "" then
      return { win = win, bufnr = win_buf, cursor = vim.api.nvim_win_get_cursor(win) }
    end
  end
  return nil
end

---@param prefill? string
---@param selection? { bufnr: integer, first: integer, last: integer }
---@param fresh? boolean start from an empty prompt (commands do; the in-panel
--- key keeps the draft you were typing)
function M.open_input(prefill, selection, fresh)
  local target = M.code_target()
  state.input.target = target
  if target and target.win then state.code_win = target.win end
  -- Only an explicit selection counts (visual keymap or a ranged command):
  -- reusing the previous selection or the `'<`/`'>` marks made old selections
  -- leak into prompts that did not ask for one.
  state.input.selection = selection
  if fresh then
    state.input.index = 0
    state.input.draft = ""
  end

  local buf = M.input_buf()
  if prefill and prefill ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, util.lines(prefill))
  else
    local current = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if state.input.selection and (fresh or util.is_blank(current)) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "@this " })
    elseif fresh then
      -- A command always starts from an empty prompt: the draft of the previous
      -- one (e.g. the edit template) must not come back.
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    end
  end

  M.update_input_win()
  if state.input.win and vim.api.nvim_win_is_valid(state.input.win) then
    pcall(vim.api.nvim_set_current_win, state.input.win)
  end
  local last = vim.api.nvim_buf_line_count(buf)
  local last_line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
  pcall(vim.api.nvim_win_set_cursor, state.input.win, { last, #last_line })
  vim.cmd("startinsert!")
  M.update_title()
end

function M.insert_newline()
  local win = state.input.win
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local line = vim.api.nvim_buf_get_lines(state.input.buf, row - 1, row, false)[1] or ""
  vim.api.nvim_buf_set_lines(state.input.buf, row - 1, row, false, { line:sub(1, col), line:sub(col + 1) })
  pcall(vim.api.nvim_win_set_cursor, win, { row + 1, 0 })
  vim.cmd("startinsert!")
end

function M.close_input()
  local win = state.input.win
  local was_current = win ~= nil and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_get_current_win() == win
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  state.input.win = nil
  state.input.signature = nil
  -- Closing the window you were inserting in must not leave the insert mode
  -- behind in whatever window Neovim focuses next (that is how the cursor ended
  -- up typing in the panel).
  if was_current then
    pcall(vim.cmd, "stopinsert")
  end
end

function M.input_text()
  local buf = state.input.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return "" end
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

function M.submit()
  local text = M.input_text()
  if util.is_blank(text) then
    -- <CR> on an empty prompt does nothing: the prompt stays open and focused.
    -- (It used to behave like <Esc>, which closed the prompt right after you had
    -- sent something, since sending leaves the prompt empty.) `<Esc>` is the way
    -- out.
    return
  end

  local target = state.input.target
  local selection = state.input.selection

  -- keep a short history (used by <C-p>/<C-n>)
  local history = state.input.history
  if history[#history] ~= text then
    history[#history + 1] = text
    if #history > 50 then table.remove(history, 1) end
  end
  state.input.index = 0
  state.input.draft = ""

  if state.input.buf and vim.api.nvim_buf_is_valid(state.input.buf) then
    vim.api.nvim_buf_set_lines(state.input.buf, 0, -1, false, { "" })
  end

  -- `<CR>` is handled while insert mode is being processed, so closing the
  -- window here and reopening it afterwards made the cursor (and the insert
  -- state) land somewhere else. When the focus is meant to stay in the prompt,
  -- the window is left exactly where it is: only the text is cleared.
  local mode = (cfg.get().ui or {}).focus_after_submit or "input"
  if mode == "input" and state.input.win and vim.api.nvim_win_is_valid(state.input.win) then
    M.update_input_win()
    pcall(vim.api.nvim_win_set_cursor, state.input.win, { 1, 0 })
  else
    M.close_input()
  end

  M.send(text, { target = target, selection = selection })
  M.after_submit()
end

--- Where the cursor goes after sending: back to the code (default), to the
--- panel, or to a fresh prompt.
function M.after_submit()
  local mode = (cfg.get().ui or {}).focus_after_submit or "input"
  if mode == "input" then
    if state.input.win and vim.api.nvim_win_is_valid(state.input.win) then
      -- The prompt never lost the focus: just make sure it still has it.
      pcall(vim.api.nvim_set_current_win, state.input.win)
      if not vim.fn.mode():find("[iR]") then
        vim.cmd("startinsert!")
      end
      return
    end
    return M.open_input(nil, nil, true)
  end
  if mode == "panel" then
    return M.focus()
  end
  local target = state.input.target
  if target and target.win and vim.api.nvim_win_is_valid(target.win) then
    pcall(vim.api.nvim_set_current_win, target.win)
  end
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

---@param text string
---@param opts? { target?: table, selection?: table, delivery?: string, new_session?: boolean }
function M.send(text, opts)
  opts = opts or {}
  state.last_prompt = { text = text, opts = opts }
  local target = opts.target
  local expanded, files = context.expand(text, {
    bufnr = target and target.bufnr or nil,
    line = target and target.cursor and target.cursor[1] or nil,
    selection = opts.selection,
  })

  M.remember_code_win()
  M.ensure_buf()
  M.renderer():user(text)
  -- Streaming: show the panel, never take the cursor (focus_after_submit decides
  -- where it goes).
  M.open({ input = false, focus = false })
  M.set_status("running")
  state.thinking = true
  M.renderer():note(THINKING_LINE, "meta")
  M.scroll_to_bottom()

  session.prompt(expanded, {
    files = files,
    delivery = opts.delivery,
    new_session = opts.new_session,
  }, function(err)
    if err then
      clear_thinking(M.renderer())
      clear_stall(M.renderer())
      M.set_status("error")
      M.renderer():error(err_text(err))
    end
  end)
end

function M.interrupt()
  session.interrupt(function(err)
    if err then log.warn("interrupt: " .. err_text(err)) end
    M.set_status("idle")
  end)
end

--- Sends the last prompt again (provider hiccups are common).
function M.retry()
  if not state.last_prompt then
    return log.notify("nothing to resend yet")
  end
  if state.status == "running" then
    return log.notify("a turn is already running")
  end
  local prompt = state.last_prompt
  M.send(prompt.text, prompt.opts)
end

--- A fresh session, with an empty prompt ready to type.
function M.new_session()
  session.new({}, function(err)
    if err then
      return log.notify("new session: " .. util.err_text(err), vim.log.levels.ERROR)
    end
    M.clear()
    M.open({ input = true, fresh = true })
  end)
end

function M.show_diff()
  session.diff({ context = 3 }, function(err, patches, source)
    if err then return log.notify("diff: " .. err_text(err), vim.log.levels.WARN) end
    if type(patches) ~= "table" or #patches == 0 then
      return log.notify("no changes to show")
    end
    local title = source == "working" and "working tree changes" or "diff of the last turn"
    require("opencode-nvim.ui.diff").patches({ title = title, patches = patches })
  end)
end

--- After a turn that touched files, show what changed so it can be kept or
--- undone. Used when the session is not in pre-approval mode.
function M.review_turn()
  local approval = cfg.approval()
  if approval.review == false or approval.review == "off" then return end
  if session.approval_active() then return end

  session.diff({ context = 3 }, function(err, patches, source)
    if err or type(patches) ~= "table" or #patches == 0 then return end

    if approval.review == "notify" then
      local summary = {}
      for _, patch in ipairs(patches) do
        summary[#summary + 1] = string.format("%s (+%d -%d)", patch.file or "?", patch.additions or 0, patch.deletions or 0)
      end
      log.notify(string.format("%d file(s) changed: %s — :OpencodeDiff to review, :OpencodeUndo to undo",
        #patches, table.concat(summary, ", ")), vim.log.levels.INFO)
      return
    end

    require("opencode-nvim.ui.diff").review({
      title = source == "working" and "working tree changes" or "turn changes",
      patches = patches,
      on_revert = function()
        session.revert_last_turn(function(revert_err)
          if revert_err then
            log.notify("undo: " .. err_text(revert_err), vim.log.levels.ERROR)
          else
            log.notify("turn undone")
            M.renderer():note("turn undone (files restored)", "meta")
          end
        end)
      end,
    })
  end)
end

function M.clear()
  -- The per-turn bookkeeping has to go too: a stale `thinking` flag would
  -- swallow the next turn's placeholder and a stale tool would never render.
  state.input.index = 0
  state.input.draft = ""
  state.thinking = false
  state.reasoning_text = nil
  state.reasoning_open = false
  state.pending_tools = {}
  state.pending_order = {}
  state.stall_text = nil
  M.renderer():clear()
end

--- `<Esc>` inside the prompt: close the prompt and hand the focus to the panel,
--- where the keys (gd, r, N, q) work. `ui.escape_closes` changes that: "all"
--- closes the whole UI, "input" just closes the prompt.
function M.escape()
  local mode = (cfg.get().ui or {}).escape_closes or "panel"
  M.close_input()
  if mode == "all" then
    return M.close()
  end
  if mode == "panel" then
    return M.focus()
  end
end

--------------------------------------------------------------------------------
-- Session history
--------------------------------------------------------------------------------

local function message_text(message)
  local payload = message.payload or {}
  return util.pick_string(payload, { "text", "message", "prompt" })
    or util.pick_string(message, { "text" })
end

local function content_output(state_table)
  if type(state_table) ~= "table" then return nil end
  local output = state_table.output or state_table.result or state_table.content
  if type(output) == "string" then return output end
  if type(output) == "table" then
    local parts = {}
    for _, item in ipairs(output) do
      if type(item) == "table" and type(item.text) == "string" then parts[#parts + 1] = item.text end
    end
    if #parts > 0 then return table.concat(parts, "\n") end
  end
  return util.pick_string(state_table, { "error", "message" })
end

function M.render_messages(messages)
  local renderer = M.renderer()
  local index = 0
  for _, message in ipairs(messages) do
    if message.type == "user" then
      local text = message_text(message)
      if text then renderer:user(text) end
    elseif message.type == "assistant" then
      for _, item in ipairs(message.content or {}) do
        if type(item) == "table" and item.type == "text" then
          renderer:delta("text", item.text or "")
          renderer:finalize()
        elseif type(item) == "table" and item.type == "reasoning" then
          renderer:delta("dim", item.text or "")
          renderer:finalize()
        elseif type(item) == "table" and item.type == "tool" then
          index = index + 1
          local id = string.format("history-%d", index)
          local tool_state = item.state or {}
          renderer:tool_begin(id, item.name or item.tool)
          local args = tool_state.input or item.input
          if args then renderer:tool_called(id, item.name or item.tool, args) end
          local status = tool_state.status
          if status == "completed" or status == "error" or status == "failed" then
            local body = content_output(tool_state)
            if not tool_output_enabled() then body = nil end
            renderer:tool_end(id, status ~= "error" and status ~= "failed", body)
          end
        end
      end
      renderer:finalize()
    end
  end
  renderer:finalize()
  M.scroll_to_bottom()
end

function M.load_history()
  local id = session.id()
  if not id then return end
  local limit = cfg.get().session.history or 30
  if limit <= 0 then return end
  api.messages(id, { limit = limit, order = "desc" }, function(err, page)
    if err then return log.debug("history:", err_text(err)) end
    local messages = type(page) == "table" and page.data or {}
    if type(messages) ~= "table" or #messages == 0 then return end
    table.sort(messages, function(a, b)
      local at = (a.time and a.time.created) or 0
      local bt = (b.time and b.time.created) or 0
      return at < bt
    end)
    M.render_messages(messages)
  end)
end

function M.on_session(info)
  state.model = info.model and (info.model.id or info.model.modelID) or nil
  M.ensure_buf()
  M.update_title()

  -- `fresh` sessions were just created for the prompt being sent: there is no
  -- history to replay, and clearing here would wipe the user's own message.
  local fresh = info.fresh == true
  info.fresh = nil

  -- Re-rendering the same session would wipe text that is still streaming.
  if state.session_id == info.id then return end
  state.session_id = info.id
  if fresh then return end -- a fresh session has no history; keep what is on screen

  state.thinking = false
  state.reasoning_text = nil
  state.reasoning_open = false
  state.pending_tools = {}
  state.pending_order = {}
  state.stall_text = nil
  M.renderer():clear()
  M.load_history()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function event_text(data)
  return util.pick_string(data, { "delta", "text", "content", "value", "chunk" })
end

local function tool_id(data)
  return util.pick_string(data, { "id", "callID", "callId", "toolCallID", "toolID" })
end

local function tool_name(data)
  return util.pick_string(data, { "name", "tool", "toolName" })
end

local function tool_output(data)
  local content = data.content
  if type(content) == "table" then
    local parts = {}
    for _, item in ipairs(content) do
      if type(item) == "table" and type(item.text) == "string" then parts[#parts + 1] = item.text end
    end
    if #parts > 0 then return table.concat(parts, "\n") end
  end
  return util.pick_string(data, { "output", "text", "result", "error", "message" })
end

--- Body of a tool result, honouring `ui.panel.tool_output`.
local function tool_body(data)
  if not tool_output_enabled() then return nil end
  return tool_output(data)
end

--- Only events of the session the panel is showing are rendered.
---
--- This used to accept everything while there was no session yet, which meant a
--- TUI session running in another terminal streamed its text into this panel.
local function belongs_here(data)
  local current = session.id()
  if not current then return false end
  local sid = util.pick_string(data, { "sessionID", "sessionId" })
  if not sid then return false end
  if sid == current then return true end
  local parent = util.pick_string(data, { "parentID", "parentSessionID", "parentId" })
  return parent ~= nil and parent == current
end

--- Event types the panel renders. Anything else is ignored early so catalog
--- events (`plugin.updated`, `catalog.updated`, ...) cost nothing.
local HANDLED = {
  ["opencode.session.changed"] = true,
  ["opencode.form.created"] = true,
  ["opencode.form.replied"] = true,
  ["server.connected"] = true,
  ["session.text.started"] = true,
  ["session.text.delta"] = true,
  ["session.text.ended"] = true,
  ["session.reasoning.started"] = true,
  ["session.reasoning.delta"] = true,
  ["session.reasoning.ended"] = true,
  ["session.tool.input.started"] = true,
  ["session.tool.input.delta"] = true,
  ["session.tool.input.ended"] = true,
  ["session.tool.called"] = true,
  ["session.tool.success"] = true,
  ["session.tool.failed"] = true,
  ["session.execution.started"] = true,
  ["session.execution.succeeded"] = true,
  ["session.execution.interrupted"] = true,
  ["session.execution.failed"] = true,
  ["session.error"] = true,
  ["session.retry.scheduled"] = true,
  ["session.compaction.started"] = true,
  ["session.compaction.failed"] = true,
  ["session.idle"] = true,
  ["session.usage.updated"] = true,
  ["session.updated"] = true,
  ["session.model.selected"] = true,
  ["session.agent.selected"] = true,
}

function M.on_event(ev)
  local data = ev.data or {}
  local kind = ev.type

  if not HANDLED[kind] then return end
  if kind == "opencode.session.changed" then
    return M.on_session(data)
  end
  if kind == "opencode.form.created" then
    local renderer = M.renderer()
    renderer:note(string.format("? %s", tostring(data.title or "question")), "note")
    for _, field in ipairs(data.fields or {}) do
      local question = field.description or field.title
      if question then renderer:note("  " .. question, "note") end
    end
    M.scroll_soon()
    return
  end
  if kind == "opencode.form.replied" then
    local parts = {}
    for key, value in pairs(data.answer or {}) do
      parts[#parts + 1] = string.format("%s=%s", key, type(value) == "table" and table.concat(value, ", ") or tostring(value))
    end
    M.renderer():note("  answered " .. table.concat(parts, " "), "meta")
    M.scroll_soon()
    return
  end
  -- `server.connected` carries no session: it only refreshes the title.
  if kind == "server.connected" then
    return M.update_title()
  end
  if not belongs_here(data) then return end

  local renderer = M.renderer()

  if kind == "session.text.started" then
    flush_reasoning(renderer)
    flush_all_tools(renderer)
    clear_thinking(renderer)
    clear_stall(renderer)
    state.reasoning_open = false
    renderer:finalize()
    M.set_status("running")
  elseif kind == "session.text.delta" then
    clear_thinking(renderer)
    state.reasoning_open = false
    renderer:stream("text", event_text(data) or "")
  elseif kind == "session.text.ended" then
    renderer:text_finished(util.pick_string(data, { "text" }))
  elseif kind == "session.reasoning.started" then
    clear_stall(renderer)
    state.reasoning_text = ""
    renderer:finalize()
  elseif kind == "session.reasoning.delta" then
    -- Accumulated, not streamed: rendering every delta split the reasoning into
    -- fragments around tool calls (the tail of a fragment even looked like a
    -- header). It is written once, inline, when the part ends.
    state.reasoning_text = (state.reasoning_text or "") .. (event_text(data) or "")
  elseif kind == "session.reasoning.ended" then
    flush_reasoning(renderer)
  elseif kind == "session.tool.input.started" then
    -- Deferred: rendering now would split the reasoning around the call.
    clear_stall(renderer)
    local id = tool_id(data) or "tool"
    if not state.pending_tools[id] then
      state.pending_order[#state.pending_order + 1] = id
    end
    state.pending_tools[id] = { name = tool_name(data), args = "" }
  elseif kind == "session.tool.input.delta" then
    local pending = state.pending_tools[tool_id(data) or "tool"]
    if pending then pending.args = (pending.args or "") .. (event_text(data) or "") end
  elseif kind == "session.tool.input.ended" then
    -- The complete JSON arguments arrive here; treat them as the source of truth.
    flush_tool(renderer, tool_id(data) or "tool", tool_name(data),
      util.pick_string(data, { "text" }))
  elseif kind == "session.tool.called" then
    flush_tool(renderer, tool_id(data) or "tool", tool_name(data), data.args or data.input)
  elseif kind == "session.tool.success" then
    local id = tool_id(data) or "tool"
    if state.pending_tools[id] then flush_tool(renderer, id) end
    renderer:tool_end(id, true, tool_body(data))
  elseif kind == "session.tool.failed" then
    local id = tool_id(data) or "tool"
    if state.pending_tools[id] then flush_tool(renderer, id) end
    renderer:tool_end(id, false, tool_body(data))
  elseif kind == "session.execution.started" then
    M.set_status("running")
    if not state.thinking then
      state.thinking = true
      renderer:note(THINKING_LINE, "meta")
    end
  elseif kind == "session.execution.succeeded" or kind == "session.execution.interrupted" then
    flush_reasoning(renderer)
    flush_all_tools(renderer)
    clear_thinking(renderer)
    clear_stall(renderer)
    state.reasoning_open = false
    state.pending_tools = {}
    renderer:finalize()
    M.set_status("idle")
    M.update_title()
    vim.defer_fn(M.review_turn, 150)
  elseif kind == "session.execution.failed" then
    flush_reasoning(renderer)
    flush_all_tools(renderer)
    clear_thinking(renderer)
    clear_stall(renderer)
    state.reasoning_open = false
    state.pending_tools = {}
    M.set_status("error")
    local message = util.deep_find(data, { "message" })
    if message then
      renderer:error(tostring(message))
    else
      renderer:error("execution failed")
      -- The reason lives in the assistant message, not in the event.
      if session.id() then
        api.messages(session.id(), { limit = 5, order = "desc" }, function(err, page)
          if err then return end
          for _, msg in ipairs((type(page) == "table" and page.data) or {}) do
            if msg.type == "assistant" then
              local reason = util.deep_find(msg.error, { "message", "type" })
              if not reason and msg.finish == "error" then reason = msg.rawFinish end
              if reason then
                renderer:error(tostring(reason))
                -- An unknown agent is accepted at creation but fails here.
                if tostring(reason):find("Agent not found", 1, true) then
                  session.reset_agents()
                end
              end
              return
            end
          end
        end)
      end
    end
  elseif kind == "session.error" then
    renderer:error(util.pick_string(data, { "message", "error", "text" }) or "session error")
  elseif kind == "session.retry.scheduled" then
    local attempt = data.attempt and string.format(" (attempt %d)", data.attempt) or ""
    local reason = util.deep_find(data, { "message", "error" })
    renderer:note("retry scheduled" .. attempt .. (reason and (": " .. tostring(reason)) or ""), "meta")
  elseif kind == "session.compaction.started" then
    renderer:note("compacting context…", "meta")
  elseif kind == "session.compaction.failed" then
    renderer:error("context compaction failed")
  elseif kind == "session.idle" then
    M.set_status("idle")
    renderer:finalize()
    M.update_title()
  elseif kind == "session.usage.updated" or kind == "session.updated"
    or kind == "session.model.selected" or kind == "session.agent.selected" then
    -- Only the title changed: nothing was appended, so there is no view to
    -- follow (this branch runs several times per second while a turn streams).
    M.update_title()
    return
  end

  M.scroll_soon()
end

return M
