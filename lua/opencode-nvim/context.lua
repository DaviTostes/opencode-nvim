local cfg = require("opencode-nvim.config")
local log = require("opencode-nvim.log")
local util = require("opencode-nvim.util")

--- Turns editor state into prompt text and file attachments.
---
--- Supported placeholders in a prompt: `@this`, `@buffer`, `@buffers`,
--- `@diagnostics` and `@diff`.
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
  local lines = vim.fn.systemlist({ "git", "-C", dir, "diff", "--no-color" })
  if vim.v.shell_error ~= 0 or #lines == 0 then return "(no changes)" end
  lines = util.truncate_lines(lines, cfg.get().context.diff_max_lines)
  return "```diff\n" .. table.concat(lines, "\n") .. "\n```"
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
---@param text string
---@param opts? { bufnr?: integer, selection?: table, range?: table, directory?: string }
---@return string text
---@return table[] files
function M.expand(text, opts)
  opts = opts or {}
  local files = {}

  -- With `context.auto` a plain sentence carries the editor context, so the
  -- model knows which file/selection "this" means. Explicit placeholders win.
  local explicit = text:find("@%w+") ~= nil
  if cfg.get().context.auto and not explicit then
    local parts = {}
    local header = M.header(opts)
    if header then parts[#parts + 1] = header end
    local first = range_of(opts)
    if first then parts[#parts + 1] = fmt_this(opts) end
    if #parts > 0 then
      text = table.concat(parts, "\n") .. "\n\n" .. text
    end
  end

  local expanded = text:gsub("@(%w+)", function(name)
    if name == "this" then
      return fmt_this(opts)
    elseif name == "buffer" then
      return fmt_buffer(opts, files)
    elseif name == "buffers" then
      return fmt_buffers(opts)
    elseif name == "diagnostics" then
      return fmt_diagnostics(opts)
    elseif name == "diff" then
      return fmt_diff(opts)
    end
    return "@" .. name
  end)

  return expanded, files
end

return M
