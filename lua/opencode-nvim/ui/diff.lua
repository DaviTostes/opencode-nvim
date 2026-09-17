local cfg = require("opencode-nvim.config")
local log = require("opencode-nvim.log")

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

--- Close the popup only when it was opened by `kind` (so finishing a turn does
--- not close a diff or a doctor view you opened yourself).
---@param kind string
function M.close_if(kind)
  if active and active.kind == kind then close() end
end

--- Buffer lines cannot contain newlines: split them (callers may pass blocks).
local function normalize_lines(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    if type(line) ~= "string" then line = tostring(line) end
    if line:find("\n", 1, true) then
      for piece in (line .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = piece
      end
    else
      out[#out + 1] = line
    end
  end
  return out
end

---@param opts { title: string, lines: string[], filetype?: string, width?: number, height?: number, keymaps: table[], on_close?: fun() }
local function open_float(opts)
  close()

  local previous_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, normalize_lines(opts.lines))
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
    footer = opts.footer or nil,
    footer_pos = opts.footer and "center" or nil,
    zindex = 100,
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = "Normal:OpencodeNormal,FloatBorder:OpencodeBorder,FloatTitle:OpencodeTitle"

  active = { buf = buf, win = win, on_close = opts.on_close, previous_win = previous_win, kind = opts.kind }

  local keymaps = vim.deepcopy(opts.keymaps or {})
  -- Only add the defaults when the caller did not define them: a later
  -- `vim.keymap.set` for the same key would silently override the caller (that
  -- is how "<Esc> decide later" used to end up as a plain close).
  local defined = {}
  for _, map in ipairs(keymaps) do defined[map[1]] = true end
  if not defined["q"] then keymaps[#keymaps + 1] = { "q", close, "close" } end
  if not defined["<Esc>"] then keymaps[#keymaps + 1] = { "<Esc>", close, "close" } end

  for _, map in ipairs(keymaps) do
    local action = map[2]
    vim.keymap.set("n", map[1], function()
      local ok, err = pcall(action)
      if not ok then
        log.notify("popup action failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "opencode-nvim: " .. tostring(map[3] or "action"),
    })
  end

  return active
end

--- Keys are shown in the float footer so they never scroll out of view.
local READ_HINT = "j/k, <C-d>/<C-u>, / and gg/G to read"
local function footer(extra)
  if extra and extra ~= "" then return " " .. extra .. "  ·  " .. READ_HINT .. " " end
  return " " .. READ_HINT .. "  ·  q/<Esc> close "
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
  local hint

  if opts.on_choice then
    -- NOTE: navigation keys stay free. `n` (search next) and `a` were actions
    -- before, which silently ran them when the user tried to navigate.
    hint = "<CR>/y allow once   A allow always   x reject   <Esc> later"
    keymaps[#keymaps + 1] = { "<CR>", function() local cb = opts.on_choice; close(); cb("once") end, "allow once" }
    keymaps[#keymaps + 1] = { "y", function() local cb = opts.on_choice; close(); cb("once") end, "allow once" }
    keymaps[#keymaps + 1] = { "A", function() local cb = opts.on_choice; close(); cb("always") end, "allow always" }
    keymaps[#keymaps + 1] = { "x", function()
      local cb = opts.on_choice
      close()
      vim.ui.input({ prompt = "Rejection reason (optional): " }, function(text)
        cb("reject", text)
      end)
    end, "reject" }
    keymaps[#keymaps + 1] = { "<Esc>", function() local cb = opts.on_choice; close(); cb(nil) end, "decide later" }
    keymaps[#keymaps + 1] = { "q", function() local cb = opts.on_choice; close(); cb(nil) end, "decide later" }
  end

  return open_float({
    title = opts.title or "diff",
    lines = lines,
    filetype = "diff",
    keymaps = keymaps,
    footer = footer(hint),
    kind = "permission",
  })
end

--- Simple confirmation popup with the same decision options.
---@param opts { title: string, body: string[], on_choice: fun(choice: "once"|"always"|"reject"|nil, message?: string) }
function M.confirm(opts)
  local lines = vim.deepcopy(opts.body or {})

  local keymaps = {
    { "<CR>", function() local cb = opts.on_choice; close(); cb("once") end, "allow once" },
    { "y", function() local cb = opts.on_choice; close(); cb("once") end, "allow once" },
    { "A", function() local cb = opts.on_choice; close(); cb("always") end, "allow always" },
    { "x", function()
      local cb = opts.on_choice
      close()
      vim.ui.input({ prompt = "Rejection reason (optional): " }, function(text)
        cb("reject", text)
      end)
    end, "reject" },
    { "<Esc>", function() local cb = opts.on_choice; close(); cb(nil) end, "decide later" },
    { "q", function() local cb = opts.on_choice; close(); cb(nil) end, "decide later" },
  }

  return open_float({
    title = opts.title or "permission",
    lines = lines,
    height = 0.4,
    width = 0.7,
    keymaps = keymaps,
    footer = footer("<CR>/y allow once   A allow always   x reject   <Esc> later"),
    kind = "permission",
  })
end

--- Review popup shown after a turn that changed files: keep or revert it.
---@param opts { title?: string, patches: table[], on_revert?: fun() }
function M.review(opts)
  local lines = patch_lines(opts.patches)
  return open_float({
    title = opts.title or "turn changes",
    lines = lines,
    filetype = "diff",
    kind = "review",
    keymaps = {
      { "<CR>", close, "keep" },
      { "u", function()
        close()
        if opts.on_revert then opts.on_revert() end
      end, "undo the turn" },
    },
    footer = footer("<CR> keep   u undo the turn"),
  })
end

--- Numbered chooser popup (used for questions): digits pick an option, <CR>
--- picks the option on the cursor line, `o` types a custom answer.
---@param opts { title?: string, body?: string[], options: { label: string, description?: string }[], on_choice: fun(index: integer?), on_other?: fun() }
function M.choose(opts)
  local lines = vim.deepcopy(opts.body or {})
  lines[#lines + 1] = ""

  local keymaps = {}
  for index, option in ipairs(opts.options) do
    lines[#lines + 1] = string.format("  [%d] %s%s", index, option.label,
      option.description and ("  — " .. option.description) or "")
    if index <= 9 then
      keymaps[#keymaps + 1] = { tostring(index), function()
        local cb = opts.on_choice
        close()
        cb(index)
      end, option.label }
    end
  end

  -- <CR> picks the option under the cursor
  keymaps[#keymaps + 1] = { "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local index = tonumber(line:match("^%s*%[(%d+)%]"))
    local cb = opts.on_choice
    if index and opts.options[index] then
      close()
      return cb(index)
    end
    close()
    cb(1)
  end, "choose" }

  if opts.on_other then
    keymaps[#keymaps + 1] = { "o", function()
      local other = opts.on_other
      close()
      other()
    end, "type an answer" }
  end
  keymaps[#keymaps + 1] = { "<Esc>", function()
    local cb = opts.on_choice
    close()
    cb(nil)
  end, "answer later" }

  local hint = "<CR> choose   1-9 pick"
  if opts.on_other then hint = hint .. "   o type" end
  hint = hint .. "   <Esc> later"

  return open_float({
    title = opts.title or "question",
    lines = lines,
    height = math.min(0.6, 0.25 + 0.04 * #opts.options),
    width = 0.7,
    keymaps = keymaps,
    footer = footer(hint),
    kind = "form",
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
    footer = footer(),
    kind = opts.kind,
  })
end

return M
