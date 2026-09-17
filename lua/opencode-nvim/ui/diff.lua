local cfg = require("opencode-nvim.config")

--- Floating popups: diff review and permission confirmation.
local M = {}

local active = nil

local function close()
  if active and active.win and vim.api.nvim_win_is_valid(active.win) then
    pcall(vim.api.nvim_win_close, active.win, true)
  end
  if active and active.buf and vim.api.nvim_buf_is_valid(active.buf) then
    pcall(vim.api.nvim_buf_delete, active.buf, { force = true })
  end
  local previous = active and active.previous_win
  active = nil
  if previous and vim.api.nvim_win_is_valid(previous) then
    pcall(vim.api.nvim_set_current_win, previous)
  end
end

M.close = close

---@param opts { title: string, lines: string[], filetype?: string, width?: number, height?: number, keymaps: table[], on_close?: fun() }
local function open_float(opts)
  close()

  local previous_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines or {})
  if opts.filetype then vim.bo[buf].filetype = opts.filetype end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local ui = cfg.get().ui.diff or {}
  local width = math.max(20, math.floor(vim.o.columns * (opts.width or ui.width or 0.85)))
  local height = math.max(5, math.floor(vim.o.lines * (opts.height or ui.height or 0.6)))
  if width > vim.o.columns - 2 then width = vim.o.columns - 2 end
  if height > vim.o.lines - 4 then height = vim.o.lines - 4 end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = ui.border or "rounded",
    title = " " .. (opts.title or "opencode") .. " ",
    title_pos = "center",
    zindex = 100,
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winhighlight = "Normal:OpencodeNormal,FloatBorder:OpencodeBorder,FloatTitle:OpencodeTitle"

  active = { buf = buf, win = win, on_close = opts.on_close, previous_win = previous_win }

  local keymaps = vim.deepcopy(opts.keymaps or {})
  keymaps[#keymaps + 1] = { "q", close, "close" }
  keymaps[#keymaps + 1] = { "<Esc>", close, "close" }

  for _, map in ipairs(keymaps) do
    vim.keymap.set("n", map[1], map[2], {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "opencode-nvim: " .. tostring(map[3] or "action"),
    })
  end

  return active
end

local function patch_lines(patches)
  local lines = {}
  for _, patch in ipairs(patches or {}) do
    lines[#lines + 1] = string.format("── %s  (%s  +%d -%d)",
      patch.file or "?", patch.status or "modified", patch.additions or 0, patch.deletions or 0)
    lines[#lines + 1] = ""
    for line in (patch.patch or ""):gmatch("[^\r\n]+") do
      lines[#lines + 1] = line
    end
    lines[#lines + 1] = ""
  end
  if #lines == 0 then lines = { "(no changes in the diff)" } end
  return lines
end

--- Diff popup. With `on_choice`, asks for approval; otherwise it is read-only.
---@param opts { title: string, patches: table[], on_choice?: fun(choice: "once"|"always"|"reject"|nil, message?: string) }
function M.patches(opts)
  local lines = patch_lines(opts.patches)
  local keymaps = {}

  if opts.on_choice then
    lines[#lines + 1] = "<CR> allow once    a allow always    n reject    <Esc> decide later"
    keymaps[#keymaps + 1] = { "<CR>", function() local cb = opts.on_choice; close(); cb("once") end, "allow once" }
    keymaps[#keymaps + 1] = { "a", function() local cb = opts.on_choice; close(); cb("always") end, "allow always" }
    keymaps[#keymaps + 1] = { "n", function()
      local cb = opts.on_choice
      close()
      vim.ui.input({ prompt = "Rejection reason (optional): " }, function(text)
        cb("reject", text)
      end)
    end, "reject" }
    keymaps[#keymaps + 1] = { "<Esc>", function() local cb = opts.on_choice close() cb(nil) end, "decide later" }
  end

  return open_float({
    title = opts.title or "diff",
    lines = lines,
    filetype = "diff",
    keymaps = keymaps,
  })
end

--- Simple confirmation popup with the same decision options.
---@param opts { title: string, body: string[], on_choice: fun(choice: "once"|"always"|"reject"|nil, message?: string) }
function M.confirm(opts)
  local lines = vim.deepcopy(opts.body or {})
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<CR> allow once    a allow always    n reject    <Esc> decide later"

  local keymaps = {
    { "<CR>", function() local cb = opts.on_choice; close(); cb("once") end, "allow once" },
    { "a", function() local cb = opts.on_choice; close(); cb("always") end, "allow always" },
    { "n", function()
      local cb = opts.on_choice
      close()
      vim.ui.input({ prompt = "Rejection reason (optional): " }, function(text)
        cb("reject", text)
      end)
    end, "reject" },
    { "<Esc>", function() local cb = opts.on_choice close() cb(nil) end, "decide later" },
  }

  return open_float({
    title = opts.title or "permission",
    lines = lines,
    height = 0.4,
    width = 0.7,
    keymaps = keymaps,
  })
end

--- Review popup shown after a turn that changed files: keep or revert it.
---@param opts { title?: string, patches: table[], on_revert?: fun() }
function M.review(opts)
  local lines = patch_lines(opts.patches)
  lines[#lines + 1] = "<CR> keep    r undo the turn    <Esc> close"
  return open_float({
    title = opts.title or "turn changes",
    lines = lines,
    filetype = "diff",
    keymaps = {
      { "<CR>", close, "keep" },
      { "r", function()
        close()
        if opts.on_revert then opts.on_revert() end
      end, "undo the turn" },
    },
  })
end

--- Read-only text popup (used by `:OpencodeEvents`).
function M.text(opts)
  return open_float({
    title = opts.title or "opencode",
    lines = opts.lines or {},
    filetype = opts.filetype,
    width = opts.width,
    height = opts.height,
    keymaps = {},
  })
end

return M
