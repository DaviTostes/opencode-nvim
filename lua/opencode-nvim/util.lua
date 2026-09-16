local uv = vim.uv or vim.loop
local M = {}

--- Path relative to `base` without relying on `vim.fs.relpath` (which returns
--- nil in some builds even for valid inputs).
---@param path string
---@param base string
---@return string
function M.relative(path, base)
  local p = vim.fs.normalize(path)
  local b = vim.fs.normalize(base)
  if p == b then return "." end
  b = (b:gsub("/+$", ""))
  if p:sub(1, #b + 1) == b .. "/" then return p:sub(#b + 2) end
  return p
end

--- Absolute normalized path, resolving relative paths against `base`.
---@param path string
---@param base? string
---@return string
function M.abs(path, base)
  local out = path
  if path:sub(1, 4) == "file" then
    out = (path:gsub("^file://", ""))
  end
  if out:sub(1, 1) == "~" then
    out = vim.fn.expand(out)
  elseif out:sub(1, 1) ~= "/" then
    out = vim.fs.joinpath(base or (uv.cwd() or "."), out)
  end
  return vim.fs.normalize(out)
end

--- Repository root of `dir`, falling back to `dir` itself.
---@param dir? string
---@return string
function M.root(dir)
  dir = dir or uv.cwd() or "."
  return vim.fs.root(dir, { ".git", ".jj", ".hg" }) or dir
end

function M.trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.is_blank(text)
  return M.trim(text) == ""
end

--- Build a query string from a table (nil values are skipped).
---@param params? table<string, any>
---@return string
function M.query(params)
  if not params then return "" end
  local parts = {}
  for key, value in pairs(params) do
    if value ~= nil then
      parts[#parts + 1] = vim.uri_encode(key) .. "=" .. vim.uri_encode(tostring(value), "rfc3986")
    end
  end
  if #parts == 0 then return "" end
  return "?" .. table.concat(parts, "&")
end

--- Coalesce calls until `ms` of quiet time has passed.
---@param ms integer
---@param fn function
---@return function
function M.debounce(ms, fn)
  local timer = uv.new_timer()
  return function(...)
    local args = { n = select("#", ...), ... }
    timer:stop()
    timer:start(ms, 0, vim.schedule_wrap(function()
      fn(unpack(args, 1, args.n))
    end))
  end
end

--- Split a string into lines without dropping the trailing empty line.
---@param text string
---@return string[]
function M.lines(text)
  if text == "" then return {} end
  return vim.split(text, "\n", { plain = true })
end

--- Truncate a list of lines to `max`, appending a marker.
---@param lines string[]
---@param max integer
---@param indent? string
---@return string[]
function M.truncate_lines(lines, max, indent)
  if #lines <= max then return lines end
  local out = {}
  for i = 1, max do out[i] = lines[i] end
  out[#out + 1] = (indent or "") .. string.format("… +%d linhas", #lines - max)
  return out
end

--- First non-empty string among the given keys of `tbl`.
---@param tbl any
---@param keys string[]
---@return string?
function M.pick_string(tbl, keys)
  if type(tbl) ~= "table" then return nil end
  for _, key in ipairs(keys) do
    local value = tbl[key]
    if type(value) == "string" and value ~= "" then return value end
  end
  return nil
end

--- Deep search for the first value stored under any of `keys`.
---@param tbl any
---@param keys string[]
---@param depth? integer
---@return any
function M.deep_find(tbl, keys, depth)
  depth = depth or 3
  if depth < 0 or type(tbl) ~= "table" then return nil end
  for _, key in ipairs(keys) do
    if tbl[key] ~= nil then return tbl[key] end
  end
  for _, value in pairs(tbl) do
    if type(value) == "table" then
      local found = M.deep_find(value, keys, depth - 1)
      if found ~= nil then return found end
    end
  end
  return nil
end

--- Collect every string in a nested table (depth limited).
---@param tbl any
---@param out? string[]
---@param depth? integer
---@return string[]
function M.collect_strings(tbl, out, depth)
  out = out or {}
  depth = depth or 4
  if depth < 0 or type(tbl) ~= "table" then return out end
  for _, value in pairs(tbl) do
    if type(value) == "string" then
      out[#out + 1] = value
    elseif type(value) == "table" then
      M.collect_strings(value, out, depth - 1)
    end
  end
  return out
end

--- Human readable message for any error value (string or the `{code,message}`
--- tables produced by the API layer).
---@param err any
---@return string
function M.err_text(err)
  if err == nil then return "erro desconhecido" end
  if type(err) == "string" then return err end
  if type(err) == "table" then
    if err.message then return string.format("%s (code=%s)", tostring(err.message), tostring(err.code)) end
    local ok, encoded = pcall(vim.inspect, err)
    return ok and encoded or "erro"
  end
  return tostring(err)
end

--- Decode JSON, returning nil instead of raising.
---@param text string
---@return any
function M.decode(text)
  if type(text) ~= "string" or text == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then return nil end
  return decoded
end

return M
