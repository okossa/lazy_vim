-- myoutline/lsp.lua
-- Requests textDocument/documentSymbol and normalises the response into a
-- flat list of items the rest of the plugin can consume.
--
-- The LSP spec allows two shapes:
--   1. DocumentSymbol[]    -- hierarchical, has `range` + `selectionRange` + `children`
--   2. SymbolInformation[] -- flat, has `location.range` and `containerName`
-- Roslyn returns DocumentSymbol[] in practice, but we normalise both to be safe
-- (same approach as outline.nvim's provider layer).

local config = require("myoutline.config")

local M = {}

---@class MyOutline.Item
---@field name string
---@field kind integer          -- LSP SymbolKind
---@field detail string|nil
---@field lnum integer          -- 0-indexed line of selectionRange start
---@field col integer           -- 0-indexed col of selectionRange start
---@field end_lnum integer
---@field end_col integer
---@field depth integer         -- nesting depth (0 = top level)
---@field parent string|nil     -- parent symbol name, for display only

-- Recursive flattener for DocumentSymbol[].
local function flatten_document_symbols(nodes, out, depth, parent)
  for _, node in ipairs(nodes or {}) do
    local sel = node.selectionRange or node.range
    table.insert(out, {
      name     = node.name,
      kind     = node.kind,
      detail   = node.detail,
      lnum     = sel.start.line,
      col      = sel.start.character,
      end_lnum = sel["end"].line,
      end_col  = sel["end"].character,
      depth    = depth,
      parent   = parent,
    })
    if node.children and #node.children > 0 then
      flatten_document_symbols(node.children, out, depth + 1, node.name)
    end
  end
end

-- Flat SymbolInformation[] -> same shape.
local function flatten_symbol_information(nodes, out)
  for _, node in ipairs(nodes or {}) do
    local r = node.location and node.location.range
    if r then
      table.insert(out, {
        name     = node.name,
        kind     = node.kind,
        detail   = nil,
        lnum     = r.start.line,
        col      = r.start.character,
        end_lnum = r["end"].line,
        end_col  = r["end"].character,
        depth    = 0,
        parent   = node.containerName,
      })
    end
  end
end

-- Detect which shape the server returned (DocumentSymbol has `range`,
-- SymbolInformation has `location`).
local function normalize(result)
  local out = {}
  if not result or vim.tbl_isempty(result) then
    return out
  end
  local first = result[1]
  if first.location then
    flatten_symbol_information(result, out)
  else
    flatten_document_symbols(result, out, 0, nil)
  end
  return out
end

--- Fetch document symbols for `bufnr` (default: current buffer).
--- Calls `callback(items, err)` on completion. Async.
---@param bufnr integer|nil
---@param callback fun(items: MyOutline.Item[]|nil, err: string|nil)
function M.fetch(bufnr, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" })
  if #clients == 0 then
    return callback(nil, "No LSP client attached to buffer " .. bufnr .. " supports documentSymbol")
  end

  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }

  vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", params, function(err, result, _ctx)
    if err then
      return callback(nil, err.message or vim.inspect(err))
    end
    callback(normalize(result), nil)
  end)
end

--- Synchronous variant — blocks up to `config.options.lsp.timeout_ms`.
--- Useful for `:lua print(vim.inspect(require'myoutline.lsp'.fetch_sync()))`
--- smoke-testing in Phase 1.
---@param bufnr integer|nil
---@return MyOutline.Item[]|nil items
---@return string|nil err
function M.fetch_sync(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
  local responses, err = vim.lsp.buf_request_sync(
    bufnr,
    "textDocument/documentSymbol",
    params,
    config.options.lsp.timeout_ms
  )
  if err then return nil, err end
  if not responses then return nil, "no LSP response" end
  for _, resp in pairs(responses) do
    if resp.error then return nil, resp.error.message end
    if resp.result then return normalize(resp.result), nil end
  end
  return {}, nil
end

return M
