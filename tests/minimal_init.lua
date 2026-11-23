vim.opt.rtp:append "."

local plenary_dir = vim.fn.getcwd() .. "/tests/plenary.nvim"
vim.opt.rtp:append(plenary_dir)
