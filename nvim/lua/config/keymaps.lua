-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Restore traditional H, L for viewport navigation (top/bottom of screen)
vim.keymap.del("n", "<S-h>")
vim.keymap.del("n", "<S-l>")
