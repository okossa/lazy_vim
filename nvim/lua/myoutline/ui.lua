-- myoutline/ui.lua
-- Two-window centered popup architecture:
--
--   ┌─ <filename>.cs ──────────────────────────┐  ← container (back layer, draws border + title)
--   │  > query text                            │  ← prompt window (1 line, focused, user types here)
--   │ ──────────────────────────────────────── │  ← separator (extmark on container row 2)
--   │  Methods                                 │  ← list window (scrolls naturally)
--   │     CalculateFee (decimal x) : decimal   │
--   │     ProcessOrder (Order o)   : Task<bool>│
--   │     ...                                  │
--   └──────────────────────────────────────────┘
--
-- Why two windows: the previous single-buffer design couldn't scroll the
-- list because the cursor was pinned to line 1 (the prompt) and Neovim
-- always forces the viewport to keep the cursor visible. By splitting
-- into a focused 1-line prompt window plus a separate list window, the
-- list window's cursor can move freely and the viewport scrolls
-- automatically — same architecture used by telescope / fzf-lua /
-- snacks.picker.
--
-- A third "container" window sits behind both and is responsible only
-- for rendering the rounded border, the centered title, and the
-- horizontal separator line between prompt and list.

local config  = require("myoutline.config")
local symbols = require("myoutline.symbols")
local actions = require("myoutline.actions")
local filter  = require("myoutline.filter")
local hover   = require("myoutline.hover")

local M = {}

local ns     = vim.api.nvim_create_namespace("myoutline")
local sel_ns = vim.api.nvim_create_namespace("myoutline_selection")

-- SymbolKinds whose `detail` is worth showing inline (method signatures).
local KINDS_WITH_DETAIL = { [6] = true, [9] = true, [12] = true }

-- Inner horizontal padding (cols) on each side of the prompt + list windows.
local INNER_PAD_H = 2

---@class MyOutline.State
---@field container_buf integer
---@field container_win integer
---@field prompt_buf integer
---@field prompt_win integer
---@field list_buf integer
---@field list_win integer
---@field source_win integer
---@field source_buf integer
---@field saved_view table
---@field saved_cursor integer[]
---@field all_items MyOutline.Item[]
---@field rendered_items MyOutline.Item[]
---@field selectable_lines integer[]   -- 1-indexed line numbers within list_buf
---@field line_map table
---@field selected_index integer
---@field preview_timer any
local state = nil

-- ---------------------------------------------------------------- highlights

local function ensure_highlights()
  -- Always white border & title (overrides theme on purpose, per user request).
  vim.api.nvim_set_hl(0, "MyOutlineBorder", { fg = "#ffffff" })
  vim.api.nvim_set_hl(0, "MyOutlineTitle",  { fg = "#ffffff", bold = true })

  local defs = {
    MyOutlineGroupHeader = { link = "Title", bold = true },
    MyOutlineSelection   = { link = "Visual" },
    MyOutlineIcon        = { link = "Special" },
    MyOutlineSymbolName  = { link = "Normal" },
    MyOutlineDetail      = { link = "Comment" },
    MyOutlinePromptMark  = { link = "Special" },
    MyOutlinePlaceholder = { link = "Comment" },
    MyOutlineEmpty       = { link = "Comment" },
    MyOutlineSeparator   = { link = "FloatBorder" },
  }
  for name, def in pairs(defs) do
    if vim.fn.hlexists(name) == 0 then
      vim.api.nvim_set_hl(0, name, def)
    end
  end
end

-- ---------------------------------------------------------------- grouping

local function group_items(items)
  local by_kind = {}
  for _, it in ipairs(items) do
    by_kind[it.kind] = by_kind[it.kind] or {}
    table.insert(by_kind[it.kind], it)
  end
  local groups, seen = {}, {}
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

-- ---------------------------------------------------------------- list build

local function build_list_lines(groups)
  local lines, lmap, selectable, rendered = {}, {}, {}, {}

  if #groups == 0 then
    lines[1] = "  No matches"
    lmap[1]  = { kind = "empty" }
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
      local line, detail_start
      if KINDS_WITH_DETAIL[item.kind] and item.detail and item.detail ~= "" then
        line = prefix .. item.name .. " " .. item.detail
        detail_start = #prefix + #item.name + 1
      else
        line = prefix .. item.name
      end
      table.insert(lines, line)
      table.insert(lmap, {
        kind             = "symbol",
        item             = item,
        icon_hl          = sym.hl,
        name_start_col   = #prefix,
        detail_start_col = detail_start,
      })
      table.insert(selectable, #lines)
      table.insert(rendered, item)
    end
  end
  return lines, lmap, selectable, rendered
end

local function apply_list_highlights(buf, lmap)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for lnum, meta in ipairs(lmap) do
    local lnum0 = lnum - 1
    if meta.kind == "header" then
      vim.api.nvim_buf_add_highlight(buf, ns, "MyOutlineGroupHeader", lnum0, 0, -1)
    elseif meta.kind == "symbol" then
      vim.api.nvim_buf_add_highlight(buf, ns, meta.icon_hl or "MyOutlineIcon",
        lnum0, 2, meta.name_start_col)
      local name_end = meta.detail_start_col or -1
      vim.api.nvim_buf_add_highlight(buf, ns, "MyOutlineSymbolName",
        lnum0, meta.name_start_col, name_end)
      if meta.detail_start_col then
        vim.api.nvim_buf_add_highlight(buf, ns, "MyOutlineDetail",
          lnum0, meta.detail_start_col, -1)
      end
    elseif meta.kind == "empty" then
      vim.api.nvim_buf_add_highlight(buf, ns, "MyOutlineEmpty", lnum0, 0, -1)
    end
  end
end

local function apply_prompt_decorations(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
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
end

local function apply_container_separator(buf, width)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if width < 1 then return end
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, {
    virt_text     = { { string.rep("─", width), "MyOutlineSeparator" } },
    virt_text_pos = "overlay",
    hl_mode       = "combine",
  })
end

local function update_title()
  if not state or not vim.api.nvim_win_is_valid(state.container_win) then return end
  local bufname = vim.api.nvim_buf_get_name(state.source_buf)
  local tail = vim.fn.fnamemodify(bufname, ":t")
  if tail == "" then tail = "[No Name]" end
  pcall(vim.api.nvim_win_set_config, state.container_win, {
    title     = " " .. tail .. " ",
    title_pos = "center",
  })
end

local function paint_selection()
  vim.api.nvim_buf_clear_namespace(state.list_buf, sel_ns, 0, -1)
  if state.selected_index == 0 then return end
  local lnum = state.selectable_lines[state.selected_index]
  if not lnum then return end
  local lnum0 = lnum - 1
  vim.api.nvim_buf_add_highlight(state.list_buf, sel_ns, "MyOutlineSelection",
    lnum0, 0, -1)
  -- Move the list window's cursor to the selection. Because list_win isn't
  -- the focused window, this only repositions the cursor and scrolls the
  -- viewport — focus stays on the prompt so the user keeps typing.
  if vim.api.nvim_win_is_valid(state.list_win) then
    pcall(vim.api.nvim_win_set_cursor, state.list_win, { lnum, 0 })
  end
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
  if not vim.api.nvim_win_is_valid(state.list_win) then return end
  local n = math.max(1, math.floor(vim.api.nvim_win_get_height(state.list_win) / 2))
  set_selected((state.selected_index == 0 and 1 or state.selected_index) + dir * n)
end

-- ---------------------------------------------------------------- re-render

local rerendering = false

local function refilter_and_render()
  if rerendering then return end
  rerendering = true
  local ok, err = pcall(function()
    local query = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, 1, false)[1] or ""
    local filtered = filter.apply(state.all_items, query)
    local groups   = group_items(filtered)
    local lines, lmap, selectable, rendered = build_list_lines(groups)

    -- Rewrite list buffer.
    vim.bo[state.list_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
    vim.bo[state.list_buf].modifiable = false

    state.line_map        = lmap
    state.rendered_items  = rendered
    state.selectable_lines = selectable

    apply_list_highlights(state.list_buf, lmap)
    apply_prompt_decorations(state.prompt_buf)
    update_title()

    if #state.selectable_lines > 0 then
      set_selected(1)
    else
      state.selected_index = 0
      paint_selection()
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
  M._close(false)
  if vim.api.nvim_win_is_valid(src_win) then
    vim.api.nvim_set_current_win(src_win)
    actions.jump_to(src_win, item, center)
  end
end

function M.cancel()
  M._close(true)
end

function M._close(restore)
  if not state then return end
  clear_preview_timer()

  local src_win    = state.source_win
  local saved_view = state.saved_view
  local saved_cur  = state.saved_cursor

  if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
    vim.cmd("stopinsert")
  end

  for _, win in ipairs({ state.prompt_win, state.list_win, state.container_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ state.prompt_buf, state.list_buf, state.container_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
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
    and state.prompt_win ~= nil
    and vim.api.nvim_win_is_valid(state.prompt_win)
end

-- Internal: expose state for :MyOutlineDebug. Not part of the public API.
function M._state() return state end

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

  bind({ "i", "n" }, km.confirm,   M.confirm)
  bind({ "i", "n" }, km.cancel,    M.cancel)
  bind({ "i", "n" }, km.next,      M.next)
  bind({ "i", "n" }, km.prev,      M.prev)
  bind({ "i", "n" }, km.half_down, function() half_jump(1)  end)
  bind({ "i", "n" }, km.half_up,   function() half_jump(-1) end)
end

-- ---------------------------------------------------------------- geometry

local function compute_geometry()
  local cols  = vim.o.columns
  local lines = vim.o.lines
  local width  = math.floor(cols  * config.options.window.width_ratio)
  local height = math.floor(lines * config.options.window.height_ratio)
  local row = math.floor((lines - height) / 2 - 1)
  local col = math.floor((cols  - width)  / 2)
  return width, height, row, col
end

-- ---------------------------------------------------------------- open

function M.open(items, source_win, source_buf)
  ensure_highlights()
  if M.is_open() then M._close(true) end

  local W, H, R, C = compute_geometry()
  -- Need at minimum: prompt(1) + separator(1) + list(2 rows) = 4.
  if H < 4 then H = 4 end

  -- Create the three buffers.
  local container_buf = vim.api.nvim_create_buf(false, true)
  local prompt_buf    = vim.api.nvim_create_buf(false, true)
  local list_buf      = vim.api.nvim_create_buf(false, true)

  for _, b in ipairs({ container_buf, prompt_buf, list_buf }) do
    vim.bo[b].buftype   = "nofile"
    vim.bo[b].bufhidden = "wipe"
    vim.bo[b].swapfile  = false
  end
  vim.bo[prompt_buf].filetype = "myoutline"
  vim.bo[list_buf].filetype   = "myoutline"

  -- Seed container with H blank lines so the separator extmark on line 2 has a row to live on.
  do
    local lines = {}
    for _ = 1, H do table.insert(lines, "") end
    vim.api.nvim_buf_set_lines(container_buf, 0, -1, false, lines)
  end

  -- Prompt: single editable blank line.
  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "" })
  -- List: empty (refilter populates).
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, {})

  -- Suppress completion popups on the prompt buffer (blink.cmp, nvim-cmp, native).
  vim.b[prompt_buf].completion = false
  pcall(function() require("cmp").setup.buffer({ enabled = false }, prompt_buf) end)
  vim.bo[prompt_buf].complete     = ""
  vim.bo[prompt_buf].omnifunc     = ""
  vim.bo[prompt_buf].completefunc = ""

  -- Title: source filename.
  local title_tail = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(source_buf), ":t")
  if title_tail == "" then title_tail = "[No Name]" end

  -- 1) Container (back layer, focusable=false). Draws border + title.
  local container_win = vim.api.nvim_open_win(container_buf, false, {
    relative  = "editor",
    row       = R,
    col       = C,
    width     = W,
    height    = H,
    style     = "minimal",
    border    = config.options.window.border,
    title     = " " .. title_tail .. " ",
    title_pos = "center",
    focusable = false,
    noautocmd = true,
    zindex    = 10,
  })
  vim.wo[container_win].winhighlight =
    "Normal:NormalFloat,FloatBorder:MyOutlineBorder,FloatTitle:MyOutlineTitle"
  vim.wo[container_win].cursorline = false
  vim.wo[container_win].wrap       = false

  -- 2) Prompt window (1 line tall, with horizontal padding inside the container).
  --    NB: row = R + 1 because the container's top BORDER lives at row R; its
  --    first content row is R + 1. Putting the prompt at row R would paint
  --    over the title.
  local inner_w = math.max(1, W - 2 * INNER_PAD_H)
  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
    relative  = "editor",
    row       = R + 1,
    col       = C + INNER_PAD_H,
    width     = inner_w,
    height    = 1,
    style     = "minimal",
    border    = "none",
    focusable = true,
    noautocmd = true,
    zindex    = 30,
  })
  vim.wo[prompt_win].winhighlight = "Normal:NormalFloat"
  vim.wo[prompt_win].cursorline   = false
  vim.wo[prompt_win].wrap         = false
  vim.wo[prompt_win].number       = false
  vim.wo[prompt_win].signcolumn   = "no"

  -- 3) List window (rest of container height, below the separator row).
  --    Container content rows (1-indexed inside the container's content area):
  --      row 1 (screen R+1) — prompt
  --      row 2 (screen R+2) — separator (extmark on container buffer line 1)
  --      row 3+ (screen R+3..) — list
  local list_h = math.max(1, H - 2)
  local list_win = vim.api.nvim_open_win(list_buf, false, {
    relative  = "editor",
    row       = R + 3,
    col       = C + INNER_PAD_H,
    width     = inner_w,
    height    = list_h,
    style     = "minimal",
    border    = "none",
    focusable = false,
    noautocmd = true,
    zindex    = 20,
  })
  vim.wo[list_win].winhighlight = "Normal:NormalFloat"
  vim.wo[list_win].cursorline   = false
  vim.wo[list_win].wrap         = false
  vim.wo[list_win].number       = false
  vim.wo[list_win].signcolumn   = "no"
  vim.wo[list_win].conceallevel = 0
  vim.wo[list_win].foldenable   = false

  -- Container separator (row 2, full container width).
  apply_container_separator(container_buf, W)

  -- Save source view for cancel-restore.
  local saved_view = vim.api.nvim_win_call(source_win, function() return vim.fn.winsaveview() end)
  local saved_cur  = vim.api.nvim_win_get_cursor(source_win)

  state = {
    container_buf    = container_buf,
    container_win    = container_win,
    prompt_buf       = prompt_buf,
    prompt_win       = prompt_win,
    list_buf         = list_buf,
    list_win         = list_win,
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

  set_keymaps(prompt_buf)

  local group = vim.api.nvim_create_augroup("MyOutlineAU_" .. prompt_buf, { clear = true })

  -- Re-filter on every keystroke in the prompt buffer.
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    group    = group,
    buffer   = prompt_buf,
    callback = function()
      if not state then return end
      refilter_and_render()
    end,
  })

  -- Auto-close when the prompt window loses focus.
  vim.api.nvim_create_autocmd("WinLeave", {
    group    = group,
    buffer   = prompt_buf,
    once     = true,
    callback = function() vim.schedule(function() M.cancel() end) end,
  })

  -- Initial render + enter insert mode at end of prompt.
  refilter_and_render()
  pcall(vim.api.nvim_win_set_cursor, prompt_win, { 1, 0 })
  vim.cmd("startinsert!")

  -- Async return-type enrichment via LSP hover. Mutate item.detail in place,
  -- debounce re-renders into a single repaint.
  do
    local pending_timer
    local function schedule_rerender()
      if pending_timer then pending_timer:stop(); pending_timer:close() end
      pending_timer = vim.defer_fn(function()
        pending_timer = nil
        if state and vim.api.nvim_buf_is_valid(state.list_buf) then
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
