-- myoutline/hover.lua
-- Background enrichment: fire textDocument/hover requests for each method /
-- function / constructor symbol, parse the full signature (params + return
-- type) from the hover response, and report it back to the caller so the UI
-- can re-render with richer detail.
--
-- This is required because some LSP servers (notably Roslyn for C#) populate
-- DocumentSymbol.detail with only the parameter list, omitting the return
-- type. Hover, on the other hand, returns the fully-qualified declaration in
-- a code-fence — which we can parse uniformly across Python (pyright),
-- TypeScript (tsserver/vtsls), C# (Roslyn), and most other LSP servers.
--
-- Results are cached per (bufnr, line:col) so repeated opens of the outline
-- on an unchanged buffer don't refetch.

local M = {}

-- cache[bufnr][line:col] = "signature string"
local cache = {}

-- ------------------------------------------------------- signature parsing

--- Extract the first code-fence (or first non-empty line) from a hover result.
---@param hover table  -- LSP Hover response
---@return string|nil
local function extract_hover_text(hover)
  if not hover or not hover.contents then return nil end
  local c = hover.contents
  local text
  if type(c) == "string" then
    text = c
  elseif type(c) == "table" and c.value then
    text = c.value                                  -- MarkupContent
  elseif type(c) == "table" then
    for _, part in ipairs(c) do                      -- MarkedString[]
      if type(part) == "string" then text = part; break
      elseif type(part) == "table" and part.value then text = part.value; break end
    end
  end
  if not text or text == "" then return nil end

  -- First code-fence body, or first non-empty line otherwise.
  local block = text:match("```[%w_%-]*%s*\n(.-)\n```")
  if not block then
    block = text
  end
  for line in block:gmatch("[^\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then return trimmed end
  end
  return nil
end

--- Find the last balanced `(...)` block in `s`. Returns start/end byte
--- positions (1-indexed, inclusive) or nil.
local function last_balanced_parens(s)
  local depth, open_pos, last_s, last_e = 0, nil, nil, nil
  for i = 1, #s do
    local ch = s:sub(i, i)
    if ch == "(" then
      if depth == 0 then open_pos = i end
      depth = depth + 1
    elseif ch == ")" then
      depth = depth - 1
      if depth == 0 then last_s, last_e = open_pos, i end
    end
  end
  return last_s, last_e
end

-- C#-style modifier tokens to strip when looking for the return type.
local CS_MODIFIERS = {
  "public", "private", "protected", "internal", "static", "async",
  "override", "virtual", "sealed", "abstract", "readonly", "partial",
  "extern", "unsafe", "new",
}

--- Parse a one-line declaration into (params, return_type).
---@param sig string
---@return string|nil params       -- e.g. "(int x, decimal y)"
---@return string|nil return_type  -- e.g. "decimal"  (nil if not detected)
function M._parse(sig)
  if not sig then return nil, nil end

  -- Strip pyright/tsserver prefixes like "(method) ", "(function) ".
  sig = sig:gsub("^%s*%([%w_]+%)%s+", "")

  local ps, pe = last_balanced_parens(sig)
  if not ps then return nil, nil end

  local params = sig:sub(ps, pe)
  local after  = sig:sub(pe + 1)

  -- Python:     (...) -> Ret      |  TS: (...): Ret  |  Other: (...) => Ret
  local ret = after:match("^%s*%->%s*(.+)$")
             or after:match("^%s*:%s*(.+)$")
             or after:match("^%s*=>%s*(.+)$")
  if ret then
    ret = ret:match("^%s*(.-)%s*$")
    -- Drop trailing punctuation like ";" that some servers append.
    ret = ret:gsub("[;%s]+$", "")
    if ret == "" then ret = nil end
    return params, ret
  end

  -- C# style: "<modifiers> <ReturnType> <Name>(<params>)" — return type
  -- sits *before* the parens. Strip modifiers, then take the last token
  -- (sans method name) as the return type.
  local before = sig:sub(1, ps - 1):match("^%s*(.-)%s*$") or ""
  local changed = true
  while changed do
    changed = false
    for _, m in ipairs(CS_MODIFIERS) do
      local stripped = before:gsub("^" .. m .. "%s+", "", 1)
      if stripped ~= before then
        before = stripped
        changed = true
      end
    end
  end
  -- "<ReturnType...> <Name>"  ->  capture everything up to last whitespace
  local ret_cs = before:match("^(.+)%s+[%w_]+$")
  if ret_cs and ret_cs ~= "" then
    return params, ret_cs:match("^%s*(.-)%s*$")
  end

  return params, nil
end

-- ------------------------------------------------------- public API

--- Build a display string for the symbol's `detail` field given the
--- parsed (params, return_type) pair.
---@param params string|nil
---@param ret_type string|nil
---@return string|nil
function M._format(params, ret_type)
  if not params then return nil end
  if ret_type and ret_type ~= "" then
    return params .. " : " .. ret_type
  end
  return params
end

--- Asynchronously enrich `items` with full signatures via textDocument/hover.
--- Calls `on_each(item, new_detail)` exactly once per item that gets an
--- improved signature. Items already in the cache fire on_each immediately
--- (still via vim.schedule for consistency).
---@param bufnr integer
---@param items MyOutline.Item[]
---@param kinds_set table<integer, boolean>
---@param on_each fun(item: table, new_detail: string)
function M.enrich(bufnr, items, kinds_set, on_each)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/hover" })
  if #clients == 0 then return end

  cache[bufnr] = cache[bufnr] or {}
  local buf_cache = cache[bufnr]

  local td = vim.lsp.util.make_text_document_params(bufnr)

  for _, item in ipairs(items) do
    if kinds_set[item.kind] and item.lnum and item.col then
      local key = item.lnum .. ":" .. item.col

      if buf_cache[key] then
        local cached = buf_cache[key]
        vim.schedule(function() on_each(item, cached) end)
      else
        local params = {
          textDocument = td,
          position     = { line = item.lnum, character = item.col },
        }
        vim.lsp.buf_request(bufnr, "textDocument/hover", params, function(err, result)
          if err or not result then return end
          local sig = extract_hover_text(result)
          if not sig then return end
          local p, r = M._parse(sig)
          local new_detail = M._format(p, r)
          if not new_detail then return end
          buf_cache[key] = new_detail
          vim.schedule(function() on_each(item, new_detail) end)
        end)
      end
    end
  end
end

--- Drop the hover cache for a buffer (call when the buffer is edited).
function M.invalidate(bufnr)
  cache[bufnr] = nil
end

return M
