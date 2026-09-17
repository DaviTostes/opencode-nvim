-- Questions (forms) tests. Run with: nvim -l tests/form_spec.lua
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

local function settle(ms)
  vim.wait(ms or 200, function() return false end, 20)
end

-- stub the API before anything else uses it
local api = require("opencode-nvim.api")
local replies = {}
api.reply_form = function(id, form_id, answer, cb)
  replies[#replies + 1] = { session = id, form = form_id, answer = answer }
  if cb then cb(nil) end
end

local plugin = require("opencode-nvim")
local event = require("opencode-nvim.event")
local form = require("opencode-nvim.form")
local session = require("opencode-nvim.session")

plugin.setup({ server = { autostart = false }, approval = { review = false } })
session.current = {
  id = "ses_test",
  agent = "build",
  approval = false,
  tokens = {},
  cost = 0,
  location = { directory = vim.uv.cwd() },
}

local FORM = {
  id = "frm_1",
  sessionID = "ses_test",
  title = "Questions",
  metadata = { kind = "question" },
  fields = {
    {
      key = "q0",
      type = "string",
      title = "Language preference",
      description = "Which language do you prefer?",
      custom = true,
      options = {
        { value = "Lua", label = "Lua", description = "Use Lua for the task." },
        { value = "Python", label = "Python" },
      },
    },
  },
}

local function popup_text()
  local buf = vim.api.nvim_get_current_buf()
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), buf
end

test("field helpers", function()
  local choice = FORM.fields[1]
  assert(form.is_choice(choice), "an option field should be a choice")
  assert(not form.is_choice({ key = "x", type = "string" }), "a plain string is not a choice")
  local options = form.options_of(choice)
  assert(#options == 2 and options[1].value == "Lua" and options[1].label == "Lua", vim.inspect(options))
  assert(form.answer_value(choice, { options[1] }) == "Lua", "single choice value")
  local multi = { key = "m", type = "multiselect", options = choice.options }
  local list = form.answer_value(multi, { options[1], options[2] })
  assert(type(list) == "table" and #list == 2 and list[2] == "Python", vim.inspect(list))
  local lines = form.field_lines(choice)
  assert(lines[1] == "Language preference" and lines[2] == "Which language do you prefer?", vim.inspect(lines))
end)

test("a question opens a popup with the options", function()
  replies = {}
  event.emit({ type = "form.created", data = { form = FORM } })
  settle()
  local text, buf = popup_text()
  assert(text:find("Which language do you prefer?", 1, true), text)
  assert(text:find("[1] Lua", 1, true), text)
  assert(text:find("[2] Python", 1, true), text)
  assert(text:find("Use Lua for the task.", 1, true), text)
  assert(vim.bo[buf].filetype ~= "diff", "the question popup should not be a diff view")

  -- the panel also records the question in the transcript
  local panel = require("opencode-nvim.ui.panel")
  local panel_text = table.concat(vim.api.nvim_buf_get_lines(panel.state.buf, 0, -1, false), "\n")
  assert(panel_text:find("? Questions", 1, true), panel_text)
  assert(panel_text:find("Which language do you prefer?", 1, true), panel_text)
end)

test("picking an option answers the form", function()
  vim.api.nvim_feedkeys("1", "x", false)
  settle()
  assert(#replies == 1, "expected one reply, got " .. #replies)
  assert(replies[1].form == "frm_1", vim.inspect(replies[1]))
  assert(replies[1].answer.q0 == "Lua", vim.inspect(replies[1].answer))
  assert(#form.pending() == 0, "the form is still pending")
end)

test("a question left open is dropped when the turn ends", function()
  event.emit({ type = "form.created", data = { form = FORM } })
  settle()
  assert(#form.pending() == 1, "the form should be pending")
  event.emit({ type = "session.execution.succeeded", data = { sessionID = "ses_test" } })
  settle()
  assert(#form.pending() == 0, "a stale question should be dropped")
end)

test("questions from another session are ignored", function()
  local other = vim.deepcopy(FORM)
  other.id = "frm_other"
  other.sessionID = "ses_other"
  event.emit({ type = "form.created", data = { form = other } })
  settle()
  assert(#form.pending() == 0, "a question from another session leaked in")
end)

test("the :OpencodeQuestion command exists", function()
  assert(vim.fn.exists(":OpencodeQuestion") == 2, "missing :OpencodeQuestion")
end)

io.write(string.format("\n%d falha(s)\n", failures))
os.exit(failures == 0 and 0 or 1)
