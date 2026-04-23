-- Minimal init for running plenary tests from CLI.
local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":h:h")
vim.opt.runtimepath:prepend(root)

local plenary = vim.fn.expand("$HOME/.local/share/nvim/lazy/plenary.nvim")
if vim.fn.isdirectory(plenary) == 1 then
  vim.opt.runtimepath:prepend(plenary)
end

vim.cmd("runtime plugin/plenary.vim")
