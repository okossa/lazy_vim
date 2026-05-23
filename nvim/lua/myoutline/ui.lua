-- myoutline/ui.lua
-- Centered floating popup with a prompt line on top and a grouped, filterable
-- symbol list below. The selected symbol is highlighted independently of the
-- buffer cursor (cursor stays pinned to the prompt line at all times), so the
-- user can keep typing while navigating with <C-n>/<C-p>.
--
-- Buffer layout:
--   line 1 : query text (user-editable)
--   line 2 : "" (separator)
--   line 3+: rendered grouped list (programmatic, non-editable region)
--
-- We allow the whole buffer to be modifiable (line 1 must be writable for
-- typing), and just snap the cursor back to line 1 whenever it strays.

local config  = require("myoutline.config")
local symbols = require("myoutline.symbols")
local actions = require("myoutline.actions")
local filter  = require("myoutline.filter")
local hover   = require("myoutline.hover")

local M = {}

local LIST_OFFSET = 2          -- list region begins at buffer line LIST_OFFSET + 1 (= 3)
local ns          = vim.api.nvim_create_namespace("myoutline")
local sel_ns      = vim.api.nvim_create_namespace("myoutline_selection")

-- SymbolKinds whose `detail` is worth showing inline (method signatures).
local KINDS_WITH_DETAIL = { [6] = true, [9] = true, [12] = true } -- Method, Constructor, Function

---@class MyOutline.State
---@field popup_buf integer
---@field popup_win integer
---@field source_win integer
---@field source_buf integer
---@field saved_view table              -- winsaveview() snapshot for cancel-restore
---@field saved_cursor integer[]        -- {lnum, col}, 1+0-indexed
---@field all_items MyOutline.Item[]    -- unfiltered, full symbol set
---@field rendered_items MyOutline.Item[]  -- in selectable_lines order
---@field selectable_lines integer[]    -- 1-indexed buffer lines, list area only
---@field line_map table<integer, table>
---@field selected_index integer        -- 1-indexed into selectable_lines (or 0)
---@field preview_timer any
local state = nil

-- ---------------------------------------------------------------- highlights
local function ensure_highlights()
  -- Always white border & title (overrides theme on purpose, per user request).
  vim.api.nvim_set_hl(0, "MyOutlineBorder", { fg = "#ffffff" })
  vim.api.nvim_set_hl(0, "MyOutlineTitle",  { fg = "#ffffff", bold = true })

  local defs = {
    MyOutlineGroupHeader  = { link = "Title", bold = true },
    MyOutlineSelection    = { link = "Visual" },
    MyOutlineIcon         = { link = "Special" },
    MyOutlineSymbolName   = { link = "Normal" },
    MyOutlineDetail       = { link = "Comment" },
    MyOutlinePromptMark   = { link = "Special" },
    MyOutlinePlaceholder  = { link = "Comment" },
    MyOutlineCount        = { link = "Comment" },
    MyOutlineEmpty        = { link = "Comment" },
    MyOutlineSeparator    = { link = "FloatBorder" },
  }
  for name, def in pairs(defs) do
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, def)
    end
  end
end

-- ---------------------------------------------------------------- grouping

-- Group an already-filtered list (preserving group_order from symbols.lua).
local function group_items(items)
  local by_kind = {}
  for _, it in ipairs(items) do
    by_kind[it.kind] = by_kind[it.kind] or {}
    table.insert(by_kind[it.kind], it)
  end
  local groups = {}
  local seen = {}
  for _, kind in ipairs(symbols.group_order) do
    if by_kind[kind] then
      table.insert(groups, { kind = kind, label = symbols.get(kind).group, items = by_kind[kind] })
      seen[kind] = true
    end
  end
  for kind, list in pairs(by_kind) do
    if not seen[kind] then
      table.insert(groups, { kind = kind, label = symbols.get(kind).group, items = list })
    end
  end
  return groups
end

-- ---------------------------------------------------------------- rendering

--- Build the *list region* lines (starts at buffer line LIST_OFFSET+1).
---@param groups table[]
---@return string[] lines
---@return table[]  line_map_partial   -- index i = relative line, value = meta
---@return integer[] selectable_relative -- relative line numbers (1-indexed within list region)
---@return MyOutline.Item[] rendered_items
local function build_list_region(groups)
  local lines, lmap, selectable, rendered = {}, {}, {}, {}

  if #groups == 0 then
    lines[1] = "  No matches"
    lmap[1] = { kind = "empty" }
    return lines, lmap, selectable, rendered
  end

  for gi, group in ipairs(groups) do
    if gi > 1 then
      table.insert(lines, "")
      table.insert(lmap, { kind = "blank" })
    end
    table.insert(lines, group.label)
    table.insert(lmap, { kind = "header", label = group.label, kind_id = group.kind })

    for _, item in ipairs(group.items) do
      local sym = symbols.get(item.kind)
      local prefix = string.format("  %s  ", sym.icon)
      local line
      local detail_start_col  -- byte col where detail begins, or nil
      if KINDS_WITH_DETAIL[item.kind] and item.detail and item.detail ~= "" then
        line = prefix .. item.name .. " " .. item.detail
        detail_start_col = #prefix + #item.name + 1
      else
        line = prefix .. item.name
      end
      table.insert(lines, line)
      table.insert(lmap, {
        kind             = "symbol",
        item             = item,
        icon_hl          = sym.hl,
        name_start_col   = #prefix,
        detail_start_col = detail_start_col,
      })
      table.insert(selectable, #lines)
      table.insert(rendered, item)
    end
  end
  return lines, lmap, selectable, rendered
end

-- Paint group-header + icon highlights for the list region.
local function apply_static_highlights(buf, line_map)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  -- Prompt: ">" marker is always shown inline at col 0 (virtual, can't be deleted).
  -- When the query is empty, a muted placeholder is shown alongside it.
  local q = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  local prompt_vt = { { "> ", "MyOutlinePromptMark" } }
  if q == "" then
    table.insert(prompt_vt, { "Type to filter symbols…", "MyOutlinePlaceholder" })
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text     = prompt_vt,
    virt_text_pos = "inline",
    hl_mode       = "combine",
  })

  -- Horizontal separator on line 2 (between prompt and list).
  local sep_width = state and vim.api.nvim_win_is_valid(state.popup_win)
    and vim.api.nvim_win_get_width(state.popup_win) or 80
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, {
    virt_text     = { { string.rep("─", sep_width), "MyOutlineSeparator" } },
    virt_text_pos = "overlay",
    hl_mode       = "combine",
  })

  -- List region highlights
  for rel_lnum, meta in ipairs(line_map) do
    local lnum0 = LIST_OFFSET + rel_lnum - 1  -- 0-indexed line in buffer
    if meta.kind == "header" then
      vim.api.nvim_buf_add_highlight(buf, ns, "MyOutlineGroupHeader", lnum0, 0, -1)
    elseif meta.kind == "symbol" then
      -- Icon highlight: from byte 2 up to where the name begins.
      vim.api.nvim_buf_add_highlight(buf, ns, meta.icon_hl or "MyOutlineIcon",
        lnum0, 2, meta.name_start_col)
      -- Name highlight: from name start to either detail start or EOL.
      local name_end = meta.detail_start_col or -1
      vim.api.nvim_buf_add_highlight(buf, ns, "MyOutlineSymbolName",
        lnum0, meta.name_start_col, name_end)
      -- Detail (method signature) in muted colour.
      if meta.detail_start_col then
        vim.api.nvim_buf_add_highlight(buf, ns, "MyOutlineDetail",
          lnum0, meta.detail_start_col, -1)
      end
    elseif meta.kind == "empty" then
      vim.api.nvim_buf_add_highlight(buf, ns, "MyOutlineEmpty", lnum0, 0, -1)
    end
  end
end

local function paint_selection()
  vim.api.nvim_buf_clear_namespace(state.popup_buf, sel_ns, 0, -1)
  if state.selected_index == 0 then return end
  local lnum = state.selectable_lines[state.selected_index]
  if not lnum then return end
  local lnum0 = LIST_OFFSET + lnum - 1
  vim.api.nvim_buf_add_highlight(state.popup_buf, sel_ns, "MyOutlineSelection", lnum0, 0, -1)

  -- Keep selection visible in the popup viewport (without moving cursor).
  vim.api.nvim_win_call(state.popup_win, function()
    local top    = vim.fn.line("w0")
    local bottom = vim.fn.line("w$")
    local target = lnum0 + 1
    if target < top or target > bottom then
      -- scroll without moving cursor: temporarily move, zz, move back
      local cur = vim.api.nvim_win_get_cursor(state.popup_win)
      pcall(vim.api.nvim_win_set_cursor, state.popup_win, { target, 0 })
      vim.cmd("normal! zz")
      pcall(vim.api.nvim_win_set_cursor, state.popup_win, cur)
    end
  end)
end

local function update_title()
  if not state or not vim.api.nvim_win_is_valid(state.popup_win) then return end
  local bufname = vim.api.nvim_buf_get_name(state.source_buf)
  local tail = vim.fn.fnamemodify(bufname, ":t")
  if tail == "" then tail = "[No Name]" end
  pcall(vim.api.nvim_win_set_config, state.popup_win, {
    title     = " " .. tail .. " ",
    title_pos = "center",
  })
end

-- ---------------------------------------------------------------- preview

local function clear_preview_timer()
  if state.preview_timer then
    pcall(function()
      state.preview_timer:stop()
      state.preview_timer:close()
    end)
    state.preview_timer = nil
  end
end

local function preview_current()
  if not config.options.preview.enabled then return end
  if state.selected_index == 0 then return end
  if not vim.api.nvim_win_is_valid(state.source_win) then return end
  local item = state.rendered_items[state.selected_index]
  if not item then return end

  clear_preview_timer()
  local delay = config.options.preview.debounce_ms or 0
  if delay <= 0 then
    actions.jump_to(state.source_win, item, config.options.preview.center_on_jump)
    return
  end

  state.preview_timer = vim.defer_fn(function()
    state.preview_timer = nil
    if not state or not vim.api.nvim_win_is_valid(state.source_win) then return end
    local it = state.rendered_items[state.selected_index]
    if not it then return end
    actions.jump_to(state.source_win, it, config.options.preview.center_on_jump)
  end, delay)
end

-- ---------------------------------------------------------------- navigation

local function set_selected(idx)
  local n = #state.selectable_lines
  if n == 0 then
    state.selected_index = 0
  else
    idx = ((idx - 1) % n + n) % n + 1
    state.selected_index = idx
  end
  paint_selection()
  preview_current()
end

function M.next()
  if #state.selectable_lines == 0 then return end
  set_selected(state.selected_index == 0 and 1 or state.selected_index + 1)
end

function M.prev()
  if #state.selectable_lines == 0 then return end
  set_selected(state.selected_index == 0 and #state.selectable_lines or state.selected_index - 1)
end

local function half_jump(dir)
  if #state.selectable_lines == 0 then return end
  local n = math.max(1, math.floor(vim.api.nvim_win_get_height(state.popup_win) / 2))
  set_selected((state.selected_index == 0 and 1 or state.selected_index) + dir * n)
end

-- ---------------------------------------------------------------- re-render

local rerendering = false

--- Re-render the list region using the current query.
local function refilter_and_render()
  if rerendering then return end
  rerendering = true
  local ok, err = pcall(function()
  local query = vim.api.nvim_buf_get_lines(state.popup_buf, 0, 1, false)[1] or ""

  local filtered = filter.apply(state.all_items, query)
  local groups   = group_items(filtered)

  local lines, lmap, selectable_rel, rendered = build_list_region(groups)

  local buf = state.popup_buf
  vim.bo[buf].modifiable = true
  -- Wipe everything from line 3 onwards and rewrite.
  local total_lines = vim.api.nvim_buf_line_count(buf)
  if total_lines > LIST_OFFSET then
    vim.api.nvim_buf_set_lines(buf, LIST_OFFSET, -1, false, {})
  end
  vim.api.nvim_buf_set_lines(buf, LIST_OFFSET, LIST_OFFSET, false, lines)

  -- Update state
  state.line_map = lmap
  state.rendered_items = rendered
  state.selectable_lines = {}
  for _, rel in ipairs(selectable_rel) do
    table.insert(state.selectable_lines, rel)  -- relative to list region start
  end

  apply_static_highlights(buf, lmap)
  update_title()

  -- Reset selection to first match
  if #state.selectable_lines > 0 then
    set_selected(1)
  else
    state.selected_index = 0
    paint_selection()
    -- No preview when empty; restore original view so user isn't stranded.
    if vim.api.nvim_win_is_valid(state.source_win) then
      vim.api.nvim_win_call(state.source_win, function()
        vim.fn.winrestview(state.saved_view)
      end)
    end
  end
  end)
  rerendering = false
  if not ok then
    vim.notify("myoutline render error: " .. tostring(err), vim.log.levels.ERROR)
  end
end

-- ---------------------------------------------------------------- actions

local function current_symbol()
  if state.selected_index == 0 then return nil end
  return state.rendered_items[state.selected_index]
end

function M.confirm()
  local item = current_symbol()
  if not item then return end
  local src_win = state.source_win
  local center  = config.options.preview.center_on_jump
  M._close(false)  -- false = don't restore original view (commit the preview)
  if vim.api.nvim_win_is_valid(src_win) then
    vim.api.nvim_set_current_win(src_win)
    actions.jump_to(src_win, item, center)
  end
end

function M.cancel()
  M._close(true)   -- true = restore original cursor & view
end

function M._close(restore)
  if not state then return end
  clear_preview_timer()

  local src_win    = state.source_win
  local saved_view = state.saved_view
  local saved_cur  = state.saved_cursor

  -- Leave insert mode before closing the window to avoid getting stuck.
  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end

  if vim.api.nvim_win_is_valid(state.popup_win) then
    vim.api.nvim_win_close(state.popup_win, true)
  end
  if vim.api.nvim_buf_is_valid(state.popup_buf) then
    vim.api.nvim_buf_delete(state.popup_buf, { force = true })
  end
  state = nil

  if restore and vim.api.nvim_win_is_valid(src_win) then
    vim.api.nvim_set_current_win(src_win)
    pcall(vim.api.nvim_win_set_cursor, src_win, saved_cur)
    vim.api.nvim_win_call(src_win, function()
      vim.fn.winrestview(saved_view)
    end)
  end
end

function M.close() M.cancel() end

function M.is_open()
  return state ~= nil
    and vim.api.nvim_win_is_valid(state.popup_win)
end

-- ---------------------------------------------------------------- keymaps

local function set_keymaps(buf)
  local opts = { buffer = buf, nowait = true, silent = true }
  local km   = config.options.keymaps

  local function bind(modes, lhs_list, fn)
    if type(lhs_list) == "string" then lhs_list = { lhs_list } end
    for _, lhs in ipairs(lhs_list) do
      vim.keymap.set(modes, lhs, fn, opts)
    end
  end

  -- Bind in BOTH insert and normal modes — user is in insert mode while
  -- typing the filter, but might drop to normal mode.
  bind({ "i", "n" }, km.confirm,   M.confirm)
  bind({ "i", "n" }, km.cancel,    M.cancel)
  bind({ "i", "n" }, km.next,      M.next)
  bind({ "i", "n" }, km.prev,      M.prev)
  bind({ "i", "n" }, km.half_down, function() half_jump(1)  end)
  bind({ "i", "n" }, km.half_up,   function() half_jump(-1) end)
end

-- ---------------------------------------------------------------- window

local function compute_geometry()
  local cols  = vim.o.columns
  local lines = vim.o.lines
  local width  = math.floor(cols  * config.options.window.width_ratio)
  local height = math.floor(lines * config.options.window.height_ratio)
  local row = math.floor((lines - height) / 2 - 1)
  local col = math.floor((cols  - width)  / 2)
  return width, height, row, col
end

--- Open popup pre-populated with the full (unfiltered) flat item list.
---@param items MyOutline.Item[]
---@param source_win integer
---@param source_buf integer
function M.open(items, source_win, source_buf)
  ensure_highlights()
  if M.is_open() then M._close(true) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].filetype  = "myoutline"

  -- Suppress completion popups (blink.cmp, nvim-cmp, native) on the prompt
  -- buffer so they don't hover over the filtered symbol list.
  vim.b[buf].completion = false                                    -- blink.cmp
  pcall(function() require("cmp").setup.buffer({ enabled = false }, buf) end) -- nvim-cmp
  vim.bo[buf].complete     = ""                                    -- native ins-completion sources
  vim.bo[buf].omnifunc     = ""
  vim.bo[buf].completefunc = ""

  -- Seed lines 1 (prompt) and 2 (separator). List region rendered below.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "", "" })

  local width, height, row, col = compute_geometry()
  local initial_tail = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source_buf), ":t")
  if initial_tail == "" then initial_tail = "[No Name]" end
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    style     = "minimal",
    border    = config.options.window.border,
    title     = " " .. initial_tail .. " ",
    title_pos = "center",
    noautocmd = true,
  })

  vim.wo[win].cursorline   = false
  vim.wo[win].wrap         = false
  vim.wo[win].number       = false
  vim.wo[win].signcolumn   = "no"
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:MyOutlineBorder,FloatTitle:MyOutlineTitle"

  -- Save source view for cancel-restore.
  local saved_view = vim.api.nvim_win_call(source_win, function() return vim.fn.winsaveview() end)
  local saved_cur  = vim.api.nvim_win_get_cursor(source_win)

  state = {
    popup_buf        = buf,
    popup_win        = win,
    source_win       = source_win,
    source_buf       = source_buf,
    saved_view       = saved_view,
    saved_cursor     = saved_cur,
    all_items        = items,
    rendered_items   = {},
    selectable_lines = {},
    line_map         = {},
    selected_index   = 0,
    preview_timer    = nil,
  }

  set_keymaps(buf)

  -- Pin cursor to the prompt line. Any stray cursor movement snaps back.
  local pin_group = vim.api.nvim_create_augroup("MyOutlinePin_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group  = pin_group,
    buffer = buf,
    callback = function()
      if not state then return end
      local cur = vim.api.nvim_win_get_cursor(state.popup_win)
      if cur[1] ~= 1 then
        local col_target = #(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
        pcall(vim.api.nvim_win_set_cursor, state.popup_win, { 1, col_target })
      end
    end,
  })

  -- Re-filter on every keystroke.
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group  = pin_group,
    buffer = buf,
    callback = function()
      if not state then return end
      refilter_and_render()
    end,
  })

  -- Auto-close on focus loss.
  vim.api.nvim_create_autocmd("WinLeave", {
    group  = pin_group,
    buffer = buf,
    once   = true,
    callback = function() vim.schedule(function() M.cancel() end) end,
  })

  -- Initial render + enter insert mode at end of (empty) prompt.
  refilter_and_render()
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  vim.cmd("startinsert!")

  -- Asynchronously upgrade method/function/constructor signatures with full
  -- info (params + return type) via textDocument/hover. Responses arrive out
  -- of order and over tens of ms, so we coalesce them into a single re-render
  -- using a short debounce timer.
  do
    local pending_timer
    local function schedule_rerender()
      if pending_timer then pending_timer:stop(); pending_timer:close() end
      pending_timer = vim.defer_fn(function()
        pending_timer = nil
        if state and vim.api.nvim_buf_is_valid(state.popup_buf) then
          refilter_and_render()
        end
      end, 60)
    end
    hover.enrich(source_buf, items, KINDS_WITH_DETAIL, function(item, new_detail)
      item.detail = new_detail
      schedule_rerender()
    end)
  end
end

return M
