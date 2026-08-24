if vim.g.loaded_tether_nvim then
  return
end
vim.g.loaded_tether_nvim = true

if vim.fn.has("nvim-0.11") == 0 then
  vim.schedule(function()
    vim.notify("tether.nvim requires Neovim 0.11+", vim.log.levels.ERROR, { title = "tether.nvim" })
  end)
end
