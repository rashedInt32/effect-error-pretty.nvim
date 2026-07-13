-- Minimal init for running plenary tests from CLI.
local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1, "S").source:sub(2)), ":h:h")
vim.opt.runtimepath:prepend(root)

-- Honour NVIM_APPNAME / XDG_DATA_HOME rather than hardcoding the XDG default,
-- and say so loudly when plenary can't be found: the alternative is an opaque
-- "E492: Not an editor command: PlenaryBustedDirectory" much later.
local candidates = {}
if os.getenv("PLENARY_PATH") then
  table.insert(candidates, os.getenv("PLENARY_PATH"))
end
table.insert(candidates, vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
table.insert(candidates, vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim")

for _, path in ipairs(candidates) do
  if path and vim.fn.isdirectory(path) == 1 then
    vim.opt.runtimepath:prepend(path)
    break
  end
end

vim.cmd("runtime plugin/plenary.vim")

if vim.fn.exists(":PlenaryBustedDirectory") == 0 then
  error("plenary.nvim not found. Set PLENARY_PATH, or install it under " .. vim.fn.stdpath("data"))
end
