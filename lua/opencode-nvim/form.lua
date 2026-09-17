local api = require("opencode-nvim.api")
local event = require("opencode-nvim.event")
local log = require("opencode-nvim.log")
local picker = require("opencode-nvim.ui.picker")
local session = require("opencode-nvim.session")
local ui = require("opencode-nvim.ui.diff")
local util = require("opencode-nvim.util")

--- Answers the questions the agent asks.
---
--- The `question` tool does not print anything: it creates a *form* and the turn
--- waits for a reply (that is why a question used to look like nothing at all).
--- This module turns those forms into popups and posts the answer back.
local M = {}

local queue = {}
local active = nil

--------------------------------------------------------------------------------
-- Field helpers (pure, so they are easy to test)
--------------------------------------------------------------------------------

---@return { label: string, description?: string, value: any }[]
function M.options_of(field)
  local out = {}
  for _, option in ipairs(field.options or {}) do
    out[#out + 1] = {
      label = tostring(option.label or option.value or "?"),
      description = option.description,
      value = option.value ~= nil and option.value or option.label,
    }
  end
  return out
end

--- True when the field can be answered by picking one of its options.
---@return boolean
function M.is_choice(field)
  return (field.type == "string" or field.type == "multiselect") and #(field.options or {}) > 0
end

--- Text shown for a field: its title and description.
---@return string[]
function M.field_lines(field)
  local lines = {}
  if field.title and field.title ~= "" then lines[#lines + 1] = field.title end
  if field.description and field.description ~= "" then lines[#lines + 1] = field.description end
  if #lines == 0 then lines[#lines + 1] = tostring(field.key or "?") end
  return lines
end

--- Value to send for a picked option (multiselect expects a list).
---@return any
function M.answer_value(field, picked)
  if field.type == "multiselect" then
    local values = {}
    for _, option in ipairs(picked or {}) do
      values[#values + 1] = option.value
    end
    return values
  end
  local first = (picked or {})[1]
  return first and (first.value ~= nil and first.value or first.label) or nil
end

--------------------------------------------------------------------------------
-- Replying
--------------------------------------------------------------------------------

local function finish(form, err)
  active = nil
  if err then log.notify("could not answer the question: " .. util.err_text(err), vim.log.levels.ERROR) end
  M.next()
end

local function send(form, answers)
  event.emit({ type = "opencode.form.replied", data = { answer = answers, id = form.id } })
  api.reply_form(session.id(), form.id, answers, function(err)
    if err then
      log.error("failed to reply to the form: " .. util.err_text(err))
    end
  end)
  finish(form)
end

--------------------------------------------------------------------------------
-- Showing
--------------------------------------------------------------------------------

--- One popup per field, in order.
local function ask_field(form, fields, index, answers)
  local field = fields[index]
  if not field then
    return send(form, answers)
  end

  local function answered(value)
    if value ~= nil then answers[field.key] = value end
    if value == nil and field.required then
      log.notify(string.format("'%s' is required", tostring(field.title or field.key)))
      return ask_field(form, fields, index, answers)
    end
    ask_field(form, fields, index + 1, answers)
  end

  local title = form.title or "question"
  if (form.metadata or {}).kind == "question" then title = "question" end

  if M.is_choice(field) then
    local options = M.options_of(field)
    return ui.choose({
      title = title,
      body = M.field_lines(field),
      options = options,
      on_choice = function(picked)
        answered(picked and M.answer_value(field, { options[picked] }) or nil)
      end,
      on_other = field.custom and function()
        vim.ui.input({ prompt = (field.title or field.key) .. ": " }, function(text)
          answered(text)
        end)
      end,
    })
  elseif field.type == "boolean" then
    return ui.choose({
      title = title,
      body = M.field_lines(field),
      options = { { label = "yes", value = true }, { label = "no", value = false } },
      on_choice = function(picked)
        answered(picked and (picked == 1))
      end,
    })
  elseif field.type == "external" then
    return ui.choose({
      title = title,
      body = M.field_lines(field) .. { "", "Open: " .. tostring(field.url) },
      options = { { label = "done", value = true } },
      on_choice = function() answered(nil) end,
    })
  end

  -- Free text / numbers: one input, with the default offered.
  local prompt = (field.title or field.key) .. ": "
  return vim.ui.input({ prompt = prompt, default = field.default and tostring(field.default) or nil }, function(text)
    if text == nil then return answered(nil) end
    if field.type == "number" or field.type == "integer" then
      local number = tonumber(text)
      if not number then
        log.notify("that is not a number")
        return ask_field(form, fields, index, answers)
      end
      return answered(field.type == "integer" and math.floor(number) or number)
    end
    answered(text)
  end)
end

function M.show(form)
  local fields = form.fields or {}
  if #fields == 0 then
    return finish(form)
  end
  ask_field(form, fields, 1, {})
end

function M.next()
  if active or #queue == 0 then return end
  local form = table.remove(queue, 1)
  active = form
  event.emit({ type = "opencode.form.created", data = form })
  M.show(form)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function M.on_event(ev)
  if ev.type == "form.created" or ev.type == "session.form.created" or ev.type == "session.form.create" then
    local form = (ev.data and ev.data.form) or ev.data
    if type(form) ~= "table" or not form.id then return end
    local current = session.id()
    if not current or (form.sessionID and form.sessionID ~= current) then
      log.debug("ignoring a form from another session", tostring(form.sessionID))
      return
    end
    if active and active.id == form.id then return end
    for _, queued in ipairs(queue) do
      if queued.id == form.id then return end
    end
    queue[#queue + 1] = form
    M.next()
  elseif ev.type == "form.replied" or ev.type == "form.cancelled" then
    local data = ev.data or {}
    if active and data.id == active.id then
      active = nil
      M.next()
    end
  elseif ev.type == "session.execution.interrupted" or ev.type == "session.execution.failed"
    or ev.type == "session.execution.succeeded" then
    -- The turn is over: a question still on screen is stale.
    active = nil
    queue = {}
    ui.close_if("form")
  elseif ev.type == "opencode.session.changed" then
    -- another session is in play now
    active = nil
    queue = {}
    ui.close_if("form")
  end
end

--- Pick up questions that were already pending (attach, or a missed event).
function M.sync(cb)
  if not session.id() then return cb and cb() end
  api.session_forms(session.id(), function(err, forms)
    if not err and type(forms) == "table" then
      for _, form in ipairs(forms) do
        if form.id and not (active and active.id == form.id) then
          queue[#queue + 1] = form
        end
      end
      M.next()
    end
    if cb then cb(err) end
  end)
end

function M.pending()
  local out = {}
  if active then out[#out + 1] = active end
  vim.list_extend(out, queue)
  return out
end

return M
