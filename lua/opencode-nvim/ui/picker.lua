--- Thin wrapper over `mini.pick` (when installed) or `vim.ui.select`.
local M = {}

---@param items string[]
---@param opts { name?: string, prompt?: string }
---@param on_choice fun(choice: string?)
function M.pick(items, opts, on_choice)
  opts = opts or {}
  if #items == 0 then return on_choice(nil) end

  local ok, mini = pcall(require, "mini.pick")
  if ok and type(mini) == "table" and type(mini.start) == "function" then
    local success = pcall(mini.start, {
      source = {
        name = opts.name or "opencode",
        items = items,
        choose = function(item)
          on_choice(item)
        end,
      },
    })
    if success then return end
  end

  vim.ui.select(items, { prompt = opts.prompt or opts.name or "choose" }, function(choice)
    on_choice(choice)
  end)
end

return M
