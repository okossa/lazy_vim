-- lua/plugins/outline.lua
-- Custom outline plugin (local). Replaces hedyhli/outline.nvim.
-- Source: ~/.config/nvim/lua/myoutline/
return {
  {
    "myoutline",
    dir  = vim.fn.stdpath("config"),
    name = "myoutline",
    lazy = true,
    cmd  = { "MyOutlineOpen", "MyOutlineClose", "MyOutlineToggle", "MyOutlineDump", "MyOutlineHoverDebug", "MyOutlineDebug" },
    keys = {
      { "<leader>o", function() require("myoutline").toggle() end, desc = "Toggle symbol outline" },
    },
    config = function()
      require("myoutline").setup({})
    end,
  },
}
