if vim.g.loaded_opencode_nvim == 1 then return end
vim.g.loaded_opencode_nvim = 1

-- Configure with defaults unless the user calls setup() first.
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    require("opencode-nvim")._autosetup()
  end,
})
