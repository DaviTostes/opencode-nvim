local util = require("opencode-nvim.util")

--- Streams blocks of text into a scratch buffer.
---
--- The renderer keeps the authoritative line list in Lua. Lines before
--- `committed` are final, so every update only rewrites the tail (the block
--- currently streaming), which keeps the window view stable and the redraws
--- cheap.
local M = {}

local ns = vim.api.nvim_create_namespace("opencode-nvim")

local HL = {
  text = nil,
  user = "OpencodeUser",
  dim = "OpencodeDim",
  tool = "OpencodeTool",
  toolout = "OpencodeDim",
  toolok = "OpencodeToolOk",
  toolfail = "OpencodeToolFail",
  error = "OpencodeError",
  note = "OpencodeNote",
  meta = "OpencodeMeta",
}

local R = {}
R.__index = R

---@param buf integer
function M.new(buf)
  local self = setmetatable({
    buf = buf,
    lines = {},
    kinds = {},
    committed = 0,
    drawn = 0,
    marked = 0,
    closed = true,
    tools = {},
  }, R)
  self._draw = util.debounce(70, function() self:draw() end)
  return self
end

function R:valid()
  return self.buf and vim.api.nvim_buf_is_valid(self.buf)
end

--- Writes everything that is not in the buffer yet.
---
--- `committed` is the watermark of final lines (they never change again) and
--- `drawn` is what has already been written. Drawing must start at the
--- earliest of both, otherwise a debounced draw would skip lines that were
--- finalized before it ran.
function R:draw()
  if not self:valid() then return end
  -- The panel is display-only: this is the only place that unlocks it (the
  -- buffer is created locked so a stray insert mode or `dd` cannot corrupt the
  -- conversation).
  local locked = not vim.bo[self.buf].modifiable
  if locked then vim.bo[self.buf].modifiable = true end
  -- The panel reads the window view here: whether to follow the end must be
  -- decided *before* the lines change, and never by a sticky flag (moving the
  -- cursor programmatically, e.g. when folding, used to turn it off).
  if self.on_before_draw then pcall(self.on_before_draw) end
  local start = math.min(self.drawn, self.committed)
  local tail = {}
  for index = start + 1, #self.lines do
    tail[#tail + 1] = self.lines[index]
  end
  vim.api.nvim_buf_set_lines(self.buf, start, -1, false, tail)

  -- Highlights: only for lines that are new or were rewritten. Re-applying an
  -- extmark per line on every draw was the hottest path here (a streaming
  -- reasoning block rewrote its whole tail ~14 times per second).
  local previous = self.marked or 0
  if previous > start then
    pcall(vim.api.nvim_buf_clear_namespace, self.buf, ns, start, previous)
    previous = start
  end
  for index = previous + 1, #self.lines do
    local group = HL[self.kinds[index] or "text"]
    if group then
      pcall(vim.api.nvim_buf_set_extmark, self.buf, ns, index - 1, 0, { line_hl_group = group })
    end
  end
  self.marked = #self.lines
  self.drawn = #self.lines
  if locked then vim.bo[self.buf].modifiable = false end
  if self.on_after_draw then pcall(self.on_after_draw) end
end

function R:flush()
  self._draw()
end

--- Range and kind of the block that just finished (used to fold reasoning).
---@return { kind: string?, first: integer?, last: integer? }
function R:last_block()
  return { kind = self.block_kind, first = self.block_start, last = #self.lines }
end

function R:line_count()
  return #self.lines
end

function R:empty()
  return #self.lines == 0
end

function R:finalize()
  self.committed = #self.lines
  self.closed = true
end

--- Rewind the immutable watermark so `line` (and everything after) is
--- redrawn.
function R:rewind(line)
  if line - 1 < self.committed then
    self.committed = math.max(0, line - 1)
  end
  -- the marks of the rewritten region are rebuilt by the next draw
  self.marked = math.min(self.marked or 0, math.max(0, line - 1))
  self.closed = true
end

function R:append(kind, lines)
  for _, line in ipairs(lines) do
    self.lines[#self.lines + 1] = line
    self.kinds[#self.lines] = kind
  end
  if #self.lines == 0 then
    self.lines[1] = ""
    self.kinds[1] = kind
  end
  self.closed = false
end

---@param kind string
---@param text string
---@param prefix? string applied at the start of every new line (a gutter)
function R:delta(kind, text, prefix)
  if type(text) ~= "string" or text == "" then return end
  prefix = prefix or ""
  if self.closed or #self.lines == 0 or self.kinds[#self.lines] ~= kind then
    self.closed = false
    self:append(kind, { prefix })
    self.block_start = #self.lines
    self.block_kind = kind
  end
  local parts = vim.split(text, "\n", { plain = true })
  self.lines[#self.lines] = (self.lines[#self.lines] or "") .. parts[1]
  self.kinds[#self.lines] = kind
  for index = 2, #parts do
    self.lines[#self.lines + 1] = prefix .. parts[index]
    self.kinds[#self.lines] = kind
  end
end

--- Authoritative end of a streamed text part: `session.text.ended` carries the
--- full text, so broken or missed deltas get repaired here.
function R:text_finished(text)
  local start = self.block_start
  if type(text) == "string" and start and self.block_kind == "text" and start <= #self.lines then
    local current = {}
    for index = start, #self.lines do
      current[#current + 1] = self.lines[index]
    end
    if table.concat(current, "\n") ~= text then
      local replacement = util.lines(text)
      local lines, kinds = {}, {}
      for index = 1, start - 1 do
        lines[#lines + 1] = self.lines[index]
        kinds[#kinds + 1] = self.kinds[index]
      end
      for index = 1, #replacement do
        lines[#lines + 1] = replacement[index]
        kinds[#kinds + 1] = "text"
      end
      self.lines, self.kinds = lines, kinds
    end
  end
  self.block_start, self.block_kind = nil, nil
  self:finalize()
  self:draw()
end

function R:stream(kind, text, prefix)
  self:delta(kind, text, prefix)
  self._draw()
end

function R:write(kind, lines)
  self:append(kind, lines)
  self:flush()
end

--- Multiline block that is complete when written.
function R:block(kind, text)
  self:finalize()
  self:append(kind, util.lines(text or ""))
  self:finalize()
  self:flush()
end

--- Replaces the last line equal to `old` (turns the "thinking" placeholder
--- into the block header: the placeholder of the current turn is the newest).
---@return boolean replaced
function R:replace_line(old, new)
  for index = #self.lines, 1, -1 do
    if self.lines[index] == old then
      self.lines[index] = new
      self.committed = math.min(self.committed, index - 1)
      self.drawn = math.min(self.drawn, index - 1)
      self:draw()
      return true
    end
  end
  return false
end

--- Removes the first line that equals `text` (used to take back the "thinking"
--- placeholder and the stall warning).
---@return boolean removed
function R:remove_line(text)
  for index = 1, #self.lines do
    if self.lines[index] == text then
      table.remove(self.lines, index)
      table.remove(self.kinds, index)
      self.committed = math.min(self.committed, #self.lines)
      self.drawn = math.min(self.drawn, #self.lines)
      self:draw()
      return true
    end
  end
  return false
end

function R:user(text)
  self:finalize()
  if #self.lines > 0 then self:append("meta", { "" }) end
  local lines = util.lines(text or "")
  if #lines == 0 then lines = { "" } end
  lines[1] = "❯ " .. lines[1]
  for index = 2, #lines do
    lines[index] = "  " .. lines[index]
  end
  self:append("user", lines)
  self:finalize()
  self:flush()
end

function R:note(text, kind)
  self:block(kind or "note", text)
end

function R:error(text)
  self:block("error", "⚠ " .. (text or "error"))
end

function R:clear()
  self.lines = {}
  self.kinds = {}
  self.tools = {}
  self.committed = 0
  self.drawn = 0
  self.marked = 0
  self.closed = true
  self:draw()
end

--------------------------------------------------------------------------------
-- Tools
--------------------------------------------------------------------------------

local SUMMARY_KEYS = {
  "filePath", "file", "path", "command", "pattern", "query", "url",
  "description", "prompt", "skill", "agent", "directory",
}

local function clip(value, max)
  max = max or 90
  value = tostring(value):gsub("%s+", " ")
  if #value > max then value = value:sub(1, max - 3) .. "..." end
  return value
end

local function summarize_args(text)
  if type(text) ~= "string" or text == "" then return nil end
  local decoded = util.decode(text)
  if type(decoded) == "table" then
    local summary = util.pick_string(decoded, SUMMARY_KEYS)
    if summary then return clip(summary) end
    local keys = vim.tbl_keys(decoded)
    table.sort(keys)
    if #keys > 0 and #keys <= 4 then return table.concat(keys, ", ") end
    return nil
  end
  local single = util.trim(text)
  if single == "" or single:find("\n", 1, true) then return nil end
  return clip(single)
end

function R:tool_header(tool)
  local parts = { "▸", tool.name or "tool" }
  if tool.summary and tool.summary ~= "" then parts[#parts + 1] = tool.summary end
  if tool.status then parts[#parts + 1] = tool.status end
  return table.concat(parts, " ")
end

function R:tool_update(id, changes)
  local tool = self.tools[id]
  if not tool then return end
  if changes.name then tool.name = changes.name end
  if changes.summary then tool.summary = changes.summary end
  if changes.status then tool.status = changes.status end
  if changes.ok ~= nil then tool.ok = changes.ok end
  self.lines[tool.line] = self:tool_header(tool)
  self.kinds[tool.line] = tool.ok == false and "toolfail" or "tool"
  self:rewind(tool.line)
  self:draw()
end

---@param id string
---@param name? string
function R:tool_begin(id, name)
  if self.tools[id] then
    if name then self:tool_update(id, { name = name }) end
    return
  end
  self:finalize()
  self:append("tool", { "" })
  local line = #self.lines
  self.tools[id] = { id = id, line = line, name = name, args = "", ok = nil }
  self.lines[line] = self:tool_header(self.tools[id])
  self.closed = true
  self:draw()
end

function R:tool_args(id, chunk)
  local tool = self.tools[id]
  if not tool then return end
  tool.args = tool.args .. (chunk or "")
  self:tool_update(id, { summary = summarize_args(tool.args) })
end

function R:tool_called(id, name, args)
  if not self.tools[id] then self:tool_begin(id, name) end
  local tool = self.tools[id]
  if type(args) == "string" then
    tool.args = args
  elseif type(args) == "table" then
    tool.args = vim.json.encode(args)
  end
  self:tool_update(id, { name = name, summary = summarize_args(tool.args) })
end

function R:tool_end(id, ok, output)
  if not self.tools[id] then self:tool_begin(id, nil) end
  local tool = self.tools[id]
  self:tool_update(id, { status = ok and "✓" or "✗", ok = ok })
  if type(output) == "string" and output ~= "" then
    self:finalize()
    local lines = util.truncate_lines(util.lines(output), 8, "  ")
    for _, line in ipairs(lines) do
      self:append(ok and "toolout" or "toolfail", { "  " .. line })
    end
    self:finalize()
  end
  self:draw()
end

return M
