--- Minimal logging for opencode-nvim.
local M = {
  level = "warn",
  file = nil,
}

local levels = { debug = 10, info = 20, warn = 30, error = 40 }

local function threshold()
  return levels[M.level] or levels.warn
end

---@param opts { level?: string, file?: string }
function M.setup(opts)
  opts = opts or {}
  if opts.level then M.level = opts.level end
  if opts.file then M.file = opts.file end
end

local function stringify(value)
  if type(value) == "string" then return value end
  local ok, out = pcall(vim.inspect, value)
  return ok and out or tostring(value)
end

function M.log(level, ...)
  if (levels[level] or levels.info) < threshold() then return end
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = stringify(select(i, ...))
  end
  local message = table.concat(parts, " ")

  if M.file then
    local fd = io.open(M.file, "a")
    if fd then
      fd:write(string.format("%s [%s] %s\n", os.date("%H:%M:%S"), level, message))
      fd:close()
    end
  end

  if level == "error" then
    vim.notify("opencode-nvim: " .. message, vim.log.levels.ERROR)
  elseif level == "warn" then
    vim.notify("opencode-nvim: " .. message, vim.log.levels.WARN)
  end
end

function M.debug(...) M.log("debug", ...) end
function M.info(...) M.log("info", ...) end
function M.warn(...) M.log("warn", ...) end
function M.error(...) M.log("error", ...) end

--- Always shown to the user, regardless of log level.
function M.notify(message, level)
  vim.notify("opencode-nvim: " .. message, level or vim.log.levels.INFO)
end

return M
