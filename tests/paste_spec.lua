-- Paste summary tests (like the TUI `prompt.paste = "compact"`).
-- Run with: nvim -l tests/paste_spec.lua
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
local cfg = require("opencode-nvim.config")

plugin.setup({ server = { autostart = false } })
require("opencode-nvim.session").current = {
  id = "ses_test",
  agent = "build",
  location = { directory = vim.uv.cwd() },
  tokens = {},
  cost = 0,
}

local function set_input(lines)
  local buf = panel.input_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- the TextChanged autocmd already ran synchronously; a second call is a no-op
  panel.maybe_collapse_paste()
  return buf
end

local function insert_input(row, lines)
  local buf = panel.input_buf()
  vim.api.nvim_buf_set_lines(buf, row, row, false, lines)
  panel.maybe_collapse_paste()
  return buf
end

local function input_lines()
  return vim.api.nvim_buf_get_lines(panel.input_buf(), 0, -1, false)
end

local function paste_count()
  local marks = panel.state.input.paste_marks or {}
  local count = 0
  for _ in pairs(marks) do count = count + 1 end
  return count
end

local function reset_input()
  panel.clear_pastes()
  vim.api.nvim_buf_set_lines(panel.input_buf(), 0, -1, false, { "" })
  panel.state.input.prev_text = ""
end

test("the marker uses the TUI format", function()
  assert(panel.paste_placeholder(5) == "[Pasted ~5 lines]")
  assert(panel.paste_placeholder(1) == "[Pasted ~1 lines]")
end)

test("a short paste stays as typed", function()
  reset_input()
  set_input({ "hello" })
  insert_input(1, { "second" })
  local lines = input_lines()
  assert(#lines == 2, vim.inspect(lines))
  assert(lines[1] == "hello" and lines[2] == "second", vim.inspect(lines))
  assert(panel.input_text() == "hello\nsecond", vim.inspect(panel.input_text()))
  assert(paste_count() == 0, "a short paste was collapsed")
end)

test("a paste of several lines collapses into a marker", function()
  reset_input()
  set_input({ "ask:" })
  insert_input(1, { "l1", "l2", "l3", "l4", "l5" })
  local lines = input_lines()
  assert(#lines == 2, vim.inspect(lines))
  assert(lines[1] == "ask:" and lines[2] == "[Pasted ~5 lines]", vim.inspect(lines))
  assert(paste_count() == 1, "expected one collapsed paste")
  -- the prompt reads back the complete text
  assert(panel.input_text() == "ask:\nl1\nl2\nl3\nl4\nl5", vim.inspect(panel.input_text()))
end)

test("a long single line collapses by character count", function()
  reset_input()
  set_input({ "fix:" })
  local long = string.rep("x", 200)
  insert_input(1, { long })
  local lines = input_lines()
  assert(#lines == 2, vim.inspect(lines))
  assert(lines[1] == "fix:" and lines[2] == "[Pasted ~1 lines]", vim.inspect(lines))
  assert(panel.input_text() == "fix:\n" .. long, vim.inspect(panel.input_text()))
end)

test("paste = full keeps the pasted text as is", function()
  local saved = cfg.get().ui.input.paste
  cfg.get().ui.input.paste = "full"
  local ok, err = pcall(function()
    reset_input()
    set_input({ "ask:" })
    insert_input(1, { "l1", "l2", "l3", "l4", "l5" })
    local lines = input_lines()
    assert(#lines == 6, vim.inspect(lines))
    assert(paste_count() == 0, "a paste was collapsed with paste = full")
    assert(panel.input_text() == "ask:\nl1\nl2\nl3\nl4\nl5", vim.inspect(panel.input_text()))
  end)
  cfg.get().ui.input.paste = saved
  assert(ok, err)
end)

test("typing never collapses, even past the thresholds", function()
  reset_input()
  -- one line per change, like real typing: nothing is ever a bulk insertion
  set_input({ "l1" })
  insert_input(1, { "l2" })
  insert_input(2, { "l3" })
  insert_input(3, { "l4" })
  insert_input(4, { "l5" })
  insert_input(5, { "l6" })
  local lines = input_lines()
  assert(#lines == 6, vim.inspect(lines))
  assert(paste_count() == 0, "typing line by line was collapsed")
end)

test("each marker expands to its own paste after a deletion", function()
  reset_input()
  -- pasting into the empty prompt replaces its single empty line
  set_input({ "a1", "a2", "a3" })
  local first = input_lines()
  assert(#first == 1 and first[1] == "[Pasted ~3 lines]", vim.inspect(first))
  -- keep typing after the marker, then paste again
  insert_input(1, { "mid" })
  insert_input(2, { "b1", "b2", "b3" })
  local lines = input_lines()
  assert(#lines == 3, vim.inspect(lines))
  assert(panel.input_text() == "a1\na2\na3\nmid\nb1\nb2\nb3", vim.inspect(panel.input_text()))
  -- deleting the first marker forgets the first paste, not the second
  local buf = panel.input_buf()
  local marker_end = lines[1]:find("]", 1, true)
  assert(marker_end, "no marker to delete: " .. vim.inspect(lines))
  vim.api.nvim_buf_set_text(buf, 0, 0, 0, marker_end, { "" })
  panel.maybe_collapse_paste()
  assert(panel.input_text() == "\nmid\nb1\nb2\nb3", vim.inspect(panel.input_text()))
end)

test("a hand-typed marker is left alone", function()
  reset_input()
  -- typed in two steps (below the thresholds), so no collapse happens
  set_input({ "[Pasted" })
  insert_input(0, { "" })
  local buf = panel.input_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "[Pasted ~3 lines]?" })
  panel.maybe_collapse_paste()
  assert(panel.input_text() == "[Pasted ~3 lines]?", vim.inspect(panel.input_text()))
end)

test("multibyte pastes collapse and expand exactly", function()
  reset_input()
  set_input({ "olhe:" })
  insert_input(1, { "olá 🌍", "linha dois ✔", "第三行" })
  local lines = input_lines()
  assert(#lines == 2, vim.inspect(lines))
  assert(lines[1] == "olhe:" and lines[2] == "[Pasted ~3 lines]", vim.inspect(lines))
  assert(panel.input_text() == "olhe:\nolá 🌍\nlinha dois ✔\n第三行", vim.inspect(panel.input_text()))
end)

test("submitting sends the expanded prompt and forgets the pastes", function()
  local session = require("opencode-nvim.session")
  local saved_prompt = session.prompt
  local sent
  session.prompt = function(text, opts, cb)
    sent = { text = text, opts = opts }
    if cb then cb(nil) end
  end
  local ok, err = pcall(function()
    reset_input()
    set_input({ "please fix" })
    insert_input(1, { "e1", "e2", "e3" })
    assert(paste_count() == 1, "the paste did not collapse")
    panel.submit()
    assert(sent, "nothing was sent")
    assert(sent.text:find("e1\ne2\ne3", 1, true), vim.inspect(sent.text))
    assert(panel.input_text() == "", vim.inspect(panel.input_text()))
    assert(paste_count() == 0, "the pastes survived submit")
  end)
  session.prompt = saved_prompt
  assert(ok, err)
  plugin.close()
end)

test("<BS> after a marker deletes the whole marker", function()
  reset_input()
  set_input({ "ask:" })
  insert_input(1, { "l1", "l2", "l3" })
  assert(paste_count() == 1, "the paste did not collapse")
  panel.update_input_win()
  local win = panel.state.input.win
  assert(win and vim.api.nvim_win_is_valid(win), "the prompt window did not open")
  local lines = input_lines()
  assert(#lines == 2 and lines[2] == "[Pasted ~3 lines]", vim.inspect(lines))
  -- keep typing after the marker: <BS> right after it deletes it as one unit
  local buf = panel.input_buf()
  vim.api.nvim_buf_set_text(buf, 1, #lines[2], 1, #lines[2], { "!" })
  panel.maybe_collapse_paste()
  vim.api.nvim_win_set_cursor(win, { 2, #lines[2] })
  assert(panel.paste_backspace() == true, "the marker was not deleted as one unit")
  assert(panel.input_text() == "ask:\n!", vim.inspect(panel.input_text()))
  assert(paste_count() == 0, "the paste survived <BS>")
  -- without a marker <BS> is not handled (the key keeps its meaning)
  vim.api.nvim_win_set_cursor(win, { 1, #"ask:" })
  assert(panel.paste_backspace() == false, "<BS> was swallowed without a marker")
  plugin.close()
end)

test("only insert-mode changes collapse, not undo/redo", function()
  -- Regression: the collapse ran on both TextChangedI and TextChanged. A
  -- normal-mode bulk edit (undo/redo) then looked like a paste; worse, `u`
  -- after a collapse undid the collapse and the next diff collapsed it again,
  -- so undo appeared to do nothing.
  reset_input()
  -- a normal-mode bulk insertion: must not collapse
  vim.api.nvim_buf_set_lines(panel.input_buf(), 0, -1, false, { "ask:" })
  panel.state.input.prev_text = "ask:"
  vim.api.nvim_buf_set_lines(panel.input_buf(), 0, -1, false, { "ask:", "l1", "l2", "l3" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = panel.input_buf() })
  local lines = input_lines()
  assert(#lines == 4, "a normal-mode edit was collapsed: " .. vim.inspect(lines))
  assert(paste_count() == 0, "a normal-mode edit created a paste marker")

  -- the same insertion in insert mode collapses
  vim.api.nvim_buf_set_lines(panel.input_buf(), 0, -1, false, { "ask:" })
  panel.state.input.prev_text = "ask:"
  vim.api.nvim_buf_set_lines(panel.input_buf(), 0, -1, false, { "ask:", "l1", "l2", "l3" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = panel.input_buf() })
  lines = input_lines()
  assert(#lines == 2 and lines[2] == "[Pasted ~3 lines]",
    "an insert-mode paste was not collapsed: " .. vim.inspect(lines))
  reset_input()
end)

test("recalling history does not collapse the next keystroke", function()
  -- Regression: `input_history` changes the buffer through the API, which does
  -- not fire TextChangedI, so `prev_text` stayed at the pre-recall draft and the
  -- next keystroke read the whole recalled entry as a paste.
  reset_input()
  local input = panel.state.input
  input.history = { "line one\nline two\nline three\nline four" }
  input.index = 0
  input.draft = ""
  set_input({ "hi" })
  panel.input_history(-1)
  assert(paste_count() == 0, "the recall itself collapsed the entry")
  assert(input.prev_text == "line one\nline two\nline three\nline four",
    "the baseline was not refreshed: " .. vim.inspect(input.prev_text))

  local buf = panel.input_buf()
  local lines = input_lines()
  local last = #lines
  vim.api.nvim_buf_set_text(buf, last - 1, #lines[last], last - 1, #lines[last], { "x" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
  lines = input_lines()
  assert(#lines == 4 and lines[4] == "line fourx", "the recalled entry was collapsed: " .. vim.inspect(lines))
  assert(paste_count() == 0, "the recalled entry became a paste")
  reset_input()
end)

test("the first paste after sending still collapses", function()
  -- Regression: submit clears the prompt and the baseline together, so the
  -- baseline was nil and the first paste into the fresh prompt was stored as
  -- the baseline instead of being collapsed.
  local session = require("opencode-nvim.session")
  local saved_prompt = session.prompt
  session.prompt = function(_, _, cb) if cb then cb(nil) end end
  local ok, err = pcall(function()
    reset_input()
    set_input({ "one" })
    panel.submit()
    assert(panel.state.input.prev_text == "", "the post-send baseline is not empty")
    vim.api.nvim_buf_set_lines(panel.input_buf(), 0, -1, false, { "p1", "p2", "p3" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = panel.input_buf() })
    local lines = input_lines()
    assert(#lines == 1 and lines[1] == "[Pasted ~3 lines]", vim.inspect(lines))
  end)
  session.prompt = saved_prompt
  reset_input()
  assert(ok, err)
end)

test("clear() keeps a pending collapsed paste expandable", function()
  -- Regression: `M.clear()` dropped the paste markers while leaving the
  -- `[Pasted …]` text in the (untouched) prompt, so the next send would have
  -- sent the marker literally.
  reset_input()
  set_input({ "keep:" })
  insert_input(1, { "a1", "a2", "a3" })
  assert(paste_count() == 1, "the paste did not collapse")
  panel.clear()
  assert(panel.input_text() == "keep:\na1\na2\na3",
    "clear() orphaned the paste marker: " .. vim.inspect(panel.input_text()))
  reset_input()
end)

test("a placeholder inside a pasted block is sent literally", function()
  -- Regression: the paste was expanded before `context.expand`, so a pasted
  -- `@this` was expanded with editor context instead of being sent verbatim.
  local cfg = require("opencode-nvim.config")
  local session = require("opencode-nvim.session")
  local saved_prompt, saved_auto = session.prompt, cfg.get().context.auto
  cfg.get().context.auto = false
  local sent
  session.prompt = function(text, opts, cb)
    sent = { text = text, opts = opts }
    if cb then cb(nil) end
  end
  local ok, err = pcall(function()
    reset_input()
    set_input({ "look:" })
    insert_input(1, { "@this is literal", "line two", "line three" })
    assert(paste_count() == 1, "the paste did not collapse")
    panel.submit()
    assert(sent, "nothing was sent")
    assert(sent.text == "look:\n@this is literal\nline two\nline three",
      "the pasted @this was expanded or the paste was lost: " .. vim.inspect(sent.text))
  end)
  session.prompt, cfg.get().context.auto = saved_prompt, saved_auto
  reset_input()
  assert(ok, err)
end)

io.write(string.format("\n%d failure(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
