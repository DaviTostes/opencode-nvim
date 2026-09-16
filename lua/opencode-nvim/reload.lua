local cfg = require("opencode-nvim.config")
local log = require("opencode-nvim.log")
local session = require("opencode-nvim.session")
local util = require("opencode-nvim.util")

--- Reloads buffers when the agent edits files on disk.
local M = {}

local pending = {}
local scheduled = false

local HEADER_PATTERNS = {
  "^%+%+%+ b/(.+)$",
  "^%-%-%- a/(.+)$",
  "^%+%+%+ (.+)$",
  "^%-%-%- (.+)$",
  "^%*%*%* Update File: (.+)$",
  "^%*%*%* Add File: (.+)$",
  "^%*%*%* Move to: (.+)$",
}

local function looks_like_path(value)
  if type(value) ~= "string" then return false end
  if #value == 0 or #value > 4096 then return false end
  if value:find("\n", 1, true) then return false end
  if value:sub(1, 1) == "/" then return true end
  if value:match("^%.[%./]") then return true end
  if value:find("/", 1, true) and value:match("%.[%w_%-]+$") then return true end
  return false
end

local function collect(value, out, depth)
  depth = depth or 0
  if depth > 4 then return out end
  if type(value) == "string" then
    if looks_like_path(value) then out[#out + 1] = value end
    if value:find("\n", 1, true) then
      for line in value:gmatch("[^\r\n]+") do
        for _, pattern in ipairs(HEADER_PATTERNS) do
          local captured = line:match(pattern)
          if captured and captured ~= "/dev/null" then
            out[#out + 1] = util.trim(captured)
          end
        end
      end
    end
  elseif type(value) == "table" then
    for _, item in pairs(value) do
      collect(item, out, depth + 1)
    end
  end
  return out
end

--- Paths mentioned anywhere inside an event payload.
---@param data table
---@return string[]
function M.paths_from(data)
  local found = collect(data, {})
  local seen, out = {}, {}
  for _, path in ipairs(found) do
    path = util.trim(path)
    if path ~= "" and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  return out
end

local function reload_file(path)
  local absolute = util.abs(path, session.directory())
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and util.abs(name) == absolute then
        if vim.bo[bufnr].modified then
          log.info(util.relative(name, session.directory()) .. " mudou no disco, mas o buffer tem alterações não salvas")
          return
        end
        if vim.bo[bufnr].buftype ~= "" then return end
        local view = vim.api.nvim_win_call
        vim.api.nvim_buf_call(bufnr, function()
          pcall(vim.cmd, "silent! checktime")
        end)
        log.info("recarregado", util.relative(name, session.directory()))
        vim.api.nvim_exec_autocmds("User", { pattern = "OpencodeFileReloaded", data = { bufnr = bufnr, file = name } })
        return
      end
    end
  end
end

--- Emit a single `OpencodeFileReloaded` per file, after all pending edits.
function M.flush()
  scheduled = false
  local files = pending
  pending = {}
  for path in pairs(files) do
    pcall(reload_file, path)
  end
end

local function queue(path)
  if not path or path == "" then return end
  pending[path] = true
  if scheduled then return end
  scheduled = true
  vim.defer_fn(M.flush, 80)
end

--- Reload every unmodified normal buffer from disk (used after a revert).
function M.reload_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].buftype == ""
      and not vim.bo[bufnr].modified
      and vim.api.nvim_buf_get_name(bufnr) ~= "" then
      vim.api.nvim_buf_call(bufnr, function()
        pcall(vim.cmd, "silent! checktime")
      end)
    end
  end
end

function M.on_event(ev)
  if not cfg.get().reload.enabled then return end
  if ev.type == "file.edited" or ev.type == "session.file.edited" then
    for _, path in ipairs(M.paths_from(ev.data or {})) do
      queue(path)
    end
  elseif ev.type == "session.tool.success" then
    -- Some tools embed the patch in their output; use it as a fallback signal.
    local paths = M.paths_from(ev.data or {})
    for _, path in ipairs(paths) do
      queue(path)
    end
  end
end

return M
