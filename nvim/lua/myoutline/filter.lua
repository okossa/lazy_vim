-- myoutline/filter.lua
-- Tiny fuzzy matcher. No external deps.
-- score(query, name) -> number | nil  (nil = no match)
--
-- Scoring rules (additive):
--   +1 per matched char
--   +3 when match continues a contiguous run
--   +4 when match lands right after a word boundary (_  -  .  /  space)
--   +3 when match lands at a CamelCase boundary (lowercase -> uppercase)
--   +5 when match is at index 1 (prefix start)
--   tie-breaker: small penalty for haystack length (prefer shorter names)

local M = {}

local function is_word_boundary_char(c)
  return c == "_" or c == "-" or c == "." or c == "/" or c == " "
end

function M.score(query, name)
  if query == nil or query == "" then return 0 end
  if name == nil or name == "" then return nil end

  local q = query:lower()
  local h = name:lower()
  local hlen = #h

  local s = 0
  local h_idx = 1
  local prev_matched_at = nil

  for i = 1, #q do
    local qc = q:sub(i, i)
    local found = h:find(qc, h_idx, true)
    if not found then return nil end

    s = s + 1

    if prev_matched_at and found == prev_matched_at + 1 then
      s = s + 3
    end
    if found == 1 then
      s = s + 5
    end
    if found > 1 then
      local prev = h:sub(found - 1, found - 1)
      if is_word_boundary_char(prev) then
        s = s + 4
      end
      local orig_c    = name:sub(found, found)
      local orig_prev = name:sub(found - 1, found - 1)
      if orig_c:match("%u") and orig_prev:match("%l") then
        s = s + 3
      end
    end

    prev_matched_at = found
    h_idx = found + 1
  end

  s = s - (hlen * 0.01)
  return s
end

--- Filter+sort items. Returns a new list (preserves group_order via re-group later).
---@param items MyOutline.Item[]
---@param query string
---@return MyOutline.Item[] filtered
function M.apply(items, query)
  if not query or query == "" then
    return items
  end
  local scored = {}
  for _, it in ipairs(items) do
    local sc = M.score(query, it.name)
    if sc ~= nil then
      table.insert(scored, { item = it, score = sc })
    end
  end
  table.sort(scored, function(a, b)
    if a.score == b.score then
      return a.item.lnum < b.item.lnum
    end
    return a.score > b.score
  end)
  local out = {}
  for _, s in ipairs(scored) do
    table.insert(out, s.item)
  end
  return out
end

return M
