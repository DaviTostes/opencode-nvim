local log = require("opencode-nvim.log")

local M = {}

---@class opencode.Config
---@field server table
---@field agent string
---@field model? table
---@field permissions table|table[]|false|nil
---@field session table
---@field context table
---@field reload table
---@field ui table
---@field keymaps table
---@field log table

M.defaults = {
  server = {
    command = "opencode2",
    autostart = true,
    hostname = "127.0.0.1",
    url = nil,
    password = nil,
    state_dir = nil,
    start_timeout = 15000, -- ms to wait for a service this plugin started
  },
  agent = "build",
  model = nil,
  permissions = { edit = "ask", shell = "ask" },
  approval = {
    -- "popup": show the turn diff with an undo option; "notify": just warn;
    -- false disables it.
    review = "popup",
    -- Agent (defined in the OpenCode config) whose rules ask for approval.
    -- When it exists, edits pause and the diff is approved before writing.
    agent = "opencode-nvim",
    -- Use any server agent whose rules ask for approval on `edit`.
    auto_detect = true,
    -- Rules written by `:OpencodeApprovalAgent`.
    permissions = {
      { action = "edit", resource = "*", effect = "ask" },
      { action = "shell", resource = "*", effect = "ask" },
    },
  },
  session = {
    history = 30,
    directory = nil,
  },
  context = {
    auto = true,
    max_bytes = 200 * 1024,
    diff_max_lines = 300,
    diagnostics_max = 50,
  },
  reload = {
    enabled = true,
    set_autoread = true,
  },
  ui = {
    panel = { width = 0.42, height = 0.32, max_width = 100, max_height = 22, border = "rounded", folds = true },
    input = { height = 4, border = "rounded" },
    diff = { width = 0.85, height = 0.6, border = "rounded" },
    focus_after_submit = "input", -- "code" | "panel" | "input"
    escape_closes = "all", -- <Esc> in the prompt closes the panel too ("input" keeps it)
  },
  -- No keymaps are created unless you ask for them: set `enabled = true` and
  -- the keys you want. Commands cover every action (see :help opencode-nvim).
  -- NOTE: `vim.g.mapleader` must be set before setup() for `<leader>...`.
  keymaps = {
    enabled = false,
    toggle = nil,
    ask = nil,
    ask_buffer = nil,
    edit = nil,
    actions = nil,
    sessions = nil,
    models = nil,
    agents = nil,
    diff = nil,
    interrupt = nil,
    undo = nil,
    events = nil,
  },
  log = { level = "warn", file = nil },
}

M.options = vim.deepcopy(M.defaults)

---@param opts? table
---@return table
function M.setup(opts)
  opts = opts or {}
  local permissions = opts.permissions
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if permissions ~= nil then M.options.permissions = permissions end
  log.setup(M.options.log)
  return M.options
end

---@return table
function M.get()
  return M.options
end

local BASE_POLICY = {
  { action = "*", resource = "*", effect = "allow" },
  { action = "external_directory", resource = "*", effect = "ask" },
  { action = "read", resource = "*.env", effect = "ask" },
  { action = "read", resource = "*.env.*", effect = "ask" },
  { action = "read", resource = "*.env.example", effect = "allow" },
}

--- Ruleset sent when creating a session.
---
--- A plain map (`{ edit = "ask" }`) is expanded on top of a copy of the
--- OpenCode base policy, and an array is used verbatim. Both shapes work
--- whether the server appends or replaces the session ruleset.
---@return table[]|nil
function M.permission_ruleset()
  local permissions = M.options.permissions
  if permissions == nil or permissions == false then return nil end

  if type(permissions) ~= "table" then return nil end
  if permissions[1] ~= nil then return permissions end

  local rules = vim.deepcopy(BASE_POLICY)
  local actions = vim.tbl_keys(permissions)
  table.sort(actions)
  for _, action in ipairs(actions) do
    rules[#rules + 1] = { action = action, resource = "*", effect = permissions[action] }
  end
  return rules
end

return M
