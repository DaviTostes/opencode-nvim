local cfg = require("opencode-nvim.config")
local log = require("opencode-nvim.log")
local util = require("opencode-nvim.util")

--- Turns editor state into prompt text and file attachments.
---
--- Built-in placeholders in a prompt: `@this`, `@buffer`, `@buffers`,
--- `@diagnostics` and `@diff`. More can be added, or a built-in replaced,
--- through `context.placeholders` (see `M.placeholder_list`).
local M = {}

--- Visual range (1-based, inclusive) captured when the prompt was opened.
---@return { bufnr: integer, first: integer, last: integer }?
function M.selection()
  local first = vim.fn.getpos("'<")
  local last = vim.fn.getpos("'>")
  local bufnr = vim.api.nvim_get_current_buf()
  if first[2] == 0 or last[2] == 0 then return nil end
  local first_line, last_line = first[2], last[2]
  if first_line > last_line then first_line, last_line = last_line, first_line end
  return { bufnr = bufnr, first = first_line, last = last_line }
end

local function target_buf(opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then bufnr = vim.api.nvim_get_current_buf() end
  return bufnr
end

local function range_of(opts)
  if opts.range then return opts.range.first, opts.range.last, opts.range.bufnr end
  local bufnr = target_buf(opts)
  local selection = opts.selection
  if selection and selection.bufnr == bufnr then
    return selection.first, selection.last, selection.bufnr
  end
  if opts.line then return opts.line, opts.line, bufnr end
  return nil, nil, nil
end

local function fenced(name, lines, filetype)
  local out = { string.format("`%s`", name), "```" .. (filetype or "") }
  vim.list_extend(out, lines)
  out[#out + 1] = "```"
  return table.concat(out, "\n")
end

local function directory(opts)
  local session = require("opencode-nvim.session")
  return opts.directory or session.directory()
end

local function fmt_this(opts)
  local bufnr = target_buf(opts)
  local first, last = range_of(opts)
  if not first then
    local cursor = vim.api.nvim_win_get_cursor(0)
    first, last = cursor[1], cursor[1]
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local label = name ~= "" and util.relative(name, directory(opts)) or "[no name]"
  local location = first == last and string.format("%s:%d", label, first)
    or string.format("%s:%d-%d", label, first, last)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  return fenced(location, lines, vim.bo[bufnr].filetype)
end

local function fmt_buffer(opts, files)
  local bufnr = target_buf(opts)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "" end
  local label = util.relative(name, directory(opts))
  if not vim.bo[bufnr].modified then
    return "@" .. label
  end

  local contents = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local limit = cfg.get().context.max_bytes
  if #contents > limit then
    log.warn(string.format("%s is %d bytes; mentioning the file instead of attaching it", label, #contents))
    return "@" .. label
  end
  files[#files + 1] = {
    uri = "data:text/plain;base64," .. vim.base64.encode(contents),
    name = label,
  }
  return string.format("[unsaved attachment: %s]", label)
end

local function fmt_buffers(opts)
  local out = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        out[#out + 1] = "@" .. util.relative(name, directory(opts))
      end
      if #out >= 20 then break end
    end
  end
  if #out == 0 then return "(no open files)" end
  return table.concat(out, ", ")
end

local SEVERITY = { "ERROR", "WARN", "INFO", "HINT" }

local function fmt_diagnostics(opts)
  local bufnr = target_buf(opts)
  local first, last = range_of(opts)
  local items = vim.diagnostic.get(bufnr)
  local out = {}
  local max = cfg.get().context.diagnostics_max
  for _, item in ipairs(items) do
    if not first or (item.lnum + 1) >= first and (item.lnum + 1) <= last then
      out[#out + 1] = string.format("%s:%d:%d %s %s",
        util.relative(vim.api.nvim_buf_get_name(bufnr), directory(opts)),
        item.lnum + 1, item.col + 1,
        SEVERITY[item.severity] or "INFO",
        (item.message or ""):gsub("\n", " "))
      if #out >= max then break end
    end
  end
  if #out == 0 then return "(no diagnostics)" end
  return table.concat(out, "\n")
end

local function fmt_diff(opts)
  local dir = directory(opts)
  -- `vim.system` with a timeout: a huge diff in a big repository used to block
  -- the editor while it was generated.
  local ok, result = pcall(function()
    local process = vim.system({ "git", "-C", dir, "diff", "--no-color", "--no-ext-diff" }, { text = true })
    local completed = process:wait(3000)
    -- `wait` gives up on the timeout but leaves the process running: kill it,
    -- otherwise a slow git keeps working for a diff nobody is going to read.
    if not completed then pcall(function() process:kill("sigkill") end) end
    return completed
  end)
  if not ok or type(result) ~= "table" or result.code ~= 0 then return "(no changes)" end
  local output = result.stdout or ""
  if output == "" then return "(no changes)" end
  local lines = util.truncate_lines(util.lines(output), cfg.get().context.diff_max_lines)
  return "```diff\n" .. table.concat(lines, "\n") .. "\n```"
end

--- `@` starts a placeholder only at the beginning of the text or after a
--- non-word character: `user@example.com` is not a placeholder.
local function at_boundary(text, at)
  if at <= 1 then return true end
  return text:sub(at - 1, at - 1):match("[%w_]") == nil
end

--- Built-in `@` placeholders: the menu entry plus how the marker expands.
---
--- `expand(opts, files)` returns the replacement text; it may push attachments
--- onto `files`. An entry of `context.placeholders` whose word matches one of
--- these replaces it.
local BUILTINS = {
  { word = "@this", menu = "file or selection at the cursor",
    info = "the file (and selection) the cursor is in", expand = fmt_this },
  { word = "@buffer", menu = "the current buffer",
    info = "the current buffer; attached as a file when it has unsaved changes", expand = fmt_buffer },
  { word = "@buffers", menu = "the open buffers",
    info = "the list of open, listed buffers", expand = fmt_buffers },
  { word = "@diagnostics", menu = "diagnostics at the cursor",
    info = "the diagnostics of the file (or the selection), one per line", expand = fmt_diagnostics },
  { word = "@diff", menu = "the working tree diff",
    info = "`git diff` of the session directory", expand = fmt_diff },
}

--- Bare name of a configured word (`"@todo"` and `"todo"` both give `"todo"`),
--- or nil when it is not a string that can follow the `@`.
---@param word any
---@return string?
local function placeholder_name(word)
  if type(word) ~= "string" then return nil end
  return word:match("^@?([%w_%-]+)$")
end

-- A malformed `context.placeholders` entry is skipped. Warn about each problem
-- once: `placeholder_list` is rebuilt on every keystroke, and repeating the same
-- message would drown the log.
local warned = {}
local function warn_once(key, message)
  if warned[key] then return end
  warned[key] = true
  log.warn(message)
end

--- Every `@` placeholder: the built-ins first, then the custom ones from
--- `context.placeholders`. A custom word replaces the built-in of the same name.
---
--- Built fresh on every call (expansions and completion run on every keystroke),
--- never cached: `setup()` may replace `context.placeholders` at any time.
---
--- A custom entry is `{ word = "@name", menu = "...", info = "...", expand = fn }`,
--- where `expand(opts, files)` returns the replacement text (and may return a
--- second table of file attachments). `text = "..."` is shorthand for a static
--- expansion, and `info`/`menu` default sensibly when omitted.
---@return table[]
function M.placeholder_list()
  local list, index = {}, {}
  for _, entry in ipairs(BUILTINS) do
    index[entry.word] = #list + 1
    list[#list + 1] = entry
  end
  for _, entry in ipairs(cfg.get().context.placeholders or {}) do
    if type(entry) ~= "table" then
      warn_once("nontable:" .. tostring(entry), "context.placeholders: skipped a non-table entry")
    else
      local name = placeholder_name(entry.word or entry.name)
      if not name then
        warn_once("noword:" .. tostring(entry.word or entry.name),
          "context.placeholders: skipped an entry with no valid word")
      else
        local expand = entry.expand
        if expand == nil and entry.text ~= nil then
          expand = function() return entry.text end
        end
        if type(expand) ~= "function" then
          warn_once("noexpand:" .. name,
            "context.placeholders: @" .. name .. " has no `expand` or `text`; skipped")
        else
          local item = {
            word = "@" .. name,
            menu = entry.menu or entry.description or "custom placeholder",
            info = entry.info,
            expand = expand,
          }
          local at = index[item.word]
          if at then
            list[at] = item
          else
            index[item.word] = #list + 1
            list[#list + 1] = item
          end
        end
      end
    end
  end
  return list
end

--- Placeholder entry by bare name, or nil.
---@param name string
---@return table?
function M.find_placeholder(name)
  for _, entry in ipairs(M.placeholder_list()) do
    if entry.word == "@" .. name then return entry end
  end
  return nil
end

--- Bare name -> entry map, so expansion does not rebuild the list per `@`.
---@return table<string, table>
local function placeholder_map()
  local map = {}
  for _, entry in ipairs(M.placeholder_list()) do
    map[entry.word:sub(2)] = entry
  end
  return map
end

--- The first well-formed placeholder in `text`, if any.
---@param text string
---@return boolean
function M.has_placeholder(text)
  local map = placeholder_map()
  local at = 1
  while true do
    at = text:find("@", at, true)
    if not at then return false end
    local name = text:match("^@([%w_%-]+)", at)
    if name and map[name] and at_boundary(text, at) then return true end
    at = at + 1
  end
end

--- Replace the placeholders in `text`, appending attachments to `files`.
local function expand_placeholders(text, opts, files)
  local map = placeholder_map()
  local out = {}
  local pos = 1
  while true do
    local at = text:find("@", pos, true)
    if not at then
      out[#out + 1] = text:sub(pos)
      break
    end

    local name = text:match("^@([%w_%-]+)", at)
    local replacement
    if name and at_boundary(text, at) then
      local entry = map[name]
      if entry and type(entry.expand) == "function" then
        local ok, value, extra = pcall(entry.expand, opts, files)
        if not ok then
          log.warn("placeholder @" .. name .. " failed: " .. tostring(value))
        elseif value ~= nil then
          replacement = type(value) == "string" and value or tostring(value)
          if type(extra) == "table" then vim.list_extend(files, extra) end
        end
      end
    end

    if replacement ~= nil then
      out[#out + 1] = text:sub(pos, at - 1) .. replacement
      pos = at + 1 + #name
    else
      -- not a placeholder: keep the `@` and keep scanning after it
      out[#out + 1] = text:sub(pos, at)
      pos = at + 1
    end
  end
  return table.concat(out)
end

--- Compact one-line description of what the editor is looking at.
---
--- This is what makes a plain sentence like "look at this file" work: the model
--- is told which file, where the cursor is and what is selected, without the
--- user having to type a placeholder.
---@param opts? { bufnr?: integer, selection?: table, range?: table, directory?: string, line?: integer }
---@return string?
function M.header(opts)
  opts = opts or {}
  local bufnr = target_buf(opts)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end

  local label = util.relative(name, directory(opts))
  local parts = { string.format("file=%s", label) }
  if vim.bo[bufnr].filetype ~= "" then parts[#parts + 1] = "lang=" .. vim.bo[bufnr].filetype end

  local first, last = range_of(opts)
  if first then
    if first == last then
      parts[#parts + 1] = string.format("cursor=%d", first)
    else
      parts[#parts + 1] = string.format("selection=%d-%d", first, last)
    end
  end
  if vim.bo[bufnr].modified then parts[#parts + 1] = "modified=true" end

  local diagnostics = vim.diagnostic.get(bufnr)
  if #diagnostics > 0 then parts[#parts + 1] = string.format("diagnostics=%d", #diagnostics) end

  return "[editor context] " .. table.concat(parts, " ")
end

--- Expand placeholders in `text`.
---
--- A placeholder only counts when its `@` starts a token (beginning of the text
--- or after a non-word character), so an email like `user@this.com` is left
--- untouched instead of being spliced with a code fence.
---
--- `opts.auto` overrides `context.auto`: pass `false` for text that must stay
--- verbatim apart from explicit placeholders (a slash command's arguments).
---@param text string
---@param opts? { bufnr?: integer, selection?: table, range?: table, directory?: string, auto?: boolean }
---@return string text
---@return table[] files
function M.expand(text, opts)
  opts = opts or {}
  local files = {}

  local explicit = M.has_placeholder(text)
  -- The user's text is expanded first: the editor context that gets prepended
  -- below contains raw buffer lines, and those must never be treated as a
  -- prompt (a `@param` annotation in a selection is not a placeholder).
  local expanded = expand_placeholders(text, opts, files)

  -- With `context.auto` a plain sentence carries the editor context, so the
  -- model knows which file/selection "this" means. Explicit placeholders win.
  local auto = opts.auto
  if auto == nil then auto = cfg.get().context.auto end
  if auto and not explicit then
    local parts = {}
    local header = M.header(opts)
    if header then parts[#parts + 1] = header end
    if range_of(opts) then parts[#parts + 1] = fmt_this(opts) end
    if #parts > 0 then
      expanded = table.concat(parts, "\n") .. "\n\n" .. expanded
    end
  end

  return expanded, files
end

return M
