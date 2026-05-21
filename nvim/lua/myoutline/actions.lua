-- myoutline/actions.lua
-- Cursor movement, jump, close. Phase 2: jump + close only.
-- Phase 4 will add live preview + restore-on-cancel.

local M = {}

--- Move source-window cursor to a symbol and (optionally) center the view.
---@param winid integer
---@param item MyOutline.Item
---@param center boolean
function M.jump_to(winid, item, center)
  if not vim.api.nvim_win_is_valid(winid) then return end
  -- LSP is 0-indexed; Neovim cursor API is (1-indexed line, 0-indexed col).
  vim.api.nvim_win_set_cursor(winid, { item.lnum + 1, item.col })
  if center then
    vim.api.nvim_win_call(winid, function() vim.cmd("normal! zz") end)
  end
end

return M
