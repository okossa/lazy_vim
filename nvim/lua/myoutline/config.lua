-- myoutline/config.lua
-- Centralised defaults. Phase 1 only consumes a few of these; the rest are
-- placeholders for later phases (UI, filter, keymaps).

local M = {}

M.defaults = {
  -- Window geometry (Phase 2)
  window = {
    width_ratio = 0.6,   -- 60% of editor columns
    height_ratio = 0.7,  -- 70% of editor lines
    border = "rounded",
    title = " Symbols ",
    title_pos = "center",
  },

  -- Live preview behaviour (Phase 4)
  preview = {
    enabled = true,
    debounce_ms = 30,
    center_on_jump = true, -- run `zz` after moving cursor
  },

  -- Filter (Phase 3)
  filter = {
    case_sensitive = false,
    -- Skip group headers when navigating with <C-n>/<C-p>
    skip_headers_in_nav = true,
  },

  -- Keymaps inside the popup (Phase 2+)
  keymaps = {
    confirm     = "<CR>",
    cancel      = { "<Esc>" },
    next        = { "<C-n>", "<Down>" },
    prev        = { "<C-p>", "<Up>" },
    half_down   = "<C-d>",
    half_up     = "<C-u>",
  },

  -- LSP request (Phase 1)
  lsp = {
    timeout_ms = 2000,
  },
}

-- Allow user override via require("myoutline").setup({...}).
M.options = vim.deepcopy(M.defaults)

function M.apply(user_opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user_opts or {})
  return M.options
end

return M
