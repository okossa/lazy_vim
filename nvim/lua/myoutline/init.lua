-- myoutline/init.lua
-- Public entry point. Phase 1: only `setup`, `fetch`, and a debug `dump`
-- command for smoke testing. UI (`open`/`close`/`toggle`) lands in Phase 2.

local config  = require("myoutline.config")
local lsp     = require("myoutline.lsp")
local symbols = require("myoutline.symbols")
local ui      = require("myoutline.ui")

local M = {}

function M.setup(user_opts)
  config.apply(user_opts)
end

-- Async fetch — exposed so later phases (and tests) can reuse it.
function M.fetch(bufnr, callback)
  lsp.fetch(bufnr, callback)
end

-- Sync helper for manual inspection.
function M.fetch_sync(bufnr)
  return lsp.fetch_sync(bufnr)
end

-- Group a flat item list by SymbolKind, honouring symbols.group_order.
-- Returns: { { kind = N, label = "Functions", items = {...} }, ... }
function M.group(items)
  local by_kind = {}
  for _, it in ipairs(items or {}) do
    by_kind[it.kind] = by_kind[it.kind] or {}
    table.insert(by_kind[it.kind], it)
  end

  local groups = {}
  local seen = {}
  for _, kind in ipairs(symbols.group_order) do
    if by_kind[kind] then
      table.insert(groups, {
        kind  = kind,
        label = symbols.get(kind).group,
        items = by_kind[kind],
      })
      seen[kind] = true
    end
  end
  -- Append any kinds we didn't list explicitly (forward-compat).
  for kind, list in pairs(by_kind) do
    if not seen[kind] then
      table.insert(groups, {
        kind  = kind,
        label = symbols.get(kind).group,
        items = list,
      })
    end
  end
  return groups
end

-- :MyOutlineDump — print grouped symbols for the current buffer.
-- Phase 1 verification only; removed (or kept hidden) in later phases.
function M._dump()
  local items, err = M.fetch_sync()
  if err then
    vim.notify("myoutline: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  local groups = M.group(items)
  print(string.format("myoutline: %d symbols across %d groups", #items, #groups))
  for _, g in ipairs(groups) do
    print(string.format("  %s (%d)", g.label, #g.items))
    for _, it in ipairs(g.items) do
      print(string.format("    %s  %s  @%d:%d", symbols.get(it.kind).icon, it.name, it.lnum + 1, it.col + 1))
    end
  end
end

vim.api.nvim_create_user_command("MyOutlineDump", function() M._dump() end, {
  desc = "myoutline: dump grouped symbols for current buffer (Phase 1 debug)",
})

-- ---------------------------------------------------------------- public UI

--- Open the outline popup for the current buffer.
function M.open()
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_get_current_buf()

  lsp.fetch(source_buf, function(items, err)
    vim.schedule(function()
      if err then
        vim.notify("myoutline: " .. tostring(err), vim.log.levels.WARN)
        return
      end
      ui.open(items or {}, source_win, source_buf)
    end)
  end)
end

function M.close()
  ui.close()
end

function M.toggle()
  if ui.is_open() then
    ui.close()
  else
    M.open()
  end
end

vim.api.nvim_create_user_command("MyOutlineOpen",   function() M.open()   end, { desc = "myoutline: open popup" })
vim.api.nvim_create_user_command("MyOutlineClose",  function() M.close()  end, { desc = "myoutline: close popup" })
vim.api.nvim_create_user_command("MyOutlineToggle", function() M.toggle() end, { desc = "myoutline: toggle popup" })

-- :MyOutlineHoverDebug — fire a hover at the cursor and print raw + parsed
-- result. Used to verify Roslyn / Pyright / tsserver hover output matches
-- what myoutline.hover's parser expects.
vim.api.nvim_create_user_command("MyOutlineHoverDebug", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local cur   = vim.api.nvim_win_get_cursor(0)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position     = { line = cur[1] - 1, character = cur[2] },
  }
  vim.lsp.buf_request(bufnr, "textDocument/hover", params, function(err, result)
    if err then return vim.notify("hover err: " .. vim.inspect(err), vim.log.levels.ERROR) end
    if not result then return vim.notify("hover: nil result", vim.log.levels.WARN) end
    print("---- raw hover.contents ----")
    print(vim.inspect(result.contents))
    local hover = require("myoutline.hover")
    -- Re-use the internal extractor via a hover-shaped table.
    local p, r = hover._parse((function()
      local c = result.contents
      local text
      if type(c) == "string" then text = c
      elseif type(c) == "table" and c.value then text = c.value
      elseif type(c) == "table" then
        for _, part in ipairs(c) do
          if type(part) == "string" then text = part; break
          elseif type(part) == "table" and part.value then text = part.value; break end
        end
      end
      if not text then return "" end
      local block = text:match("```[%w_%-]*%s*\n(.-)\n```") or text
      for line in block:gmatch("[^\n]+") do
        local t = line:match("^%s*(.-)%s*$")
        if t ~= "" then return t end
      end
      return ""
    end)())
    print("---- parsed ----")
    print(string.format("params = %s", p or "<nil>"))
    print(string.format("return = %s", r or "<nil>"))
  end)
end, { desc = "myoutline: dump LSP hover at cursor + show parser output" })

return M
