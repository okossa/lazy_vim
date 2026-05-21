-- myoutline/symbols.lua
-- LSP SymbolKind -> { icon, hl, group_label }
-- Numbers per LSP spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#symbolKind
-- Icons are Nerd Font glyphs (no nvim-web-devicons dependency required).

local M = {}

-- Pluralised group labels so headers read naturally ("Functions", "Classes"…).
M.kinds = {
  [1]  = { name = "File",          icon = "󰈙", hl = "MyOutlineFile",          group = "Files" },
  [2]  = { name = "Module",        icon = "󰕳", hl = "MyOutlineModule",        group = "Modules" },
  [3]  = { name = "Namespace",     icon = "󰌗", hl = "MyOutlineNamespace",     group = "Namespaces" },
  [4]  = { name = "Package",       icon = "󰏗", hl = "MyOutlinePackage",       group = "Packages" },
  [5]  = { name = "Class",         icon = "󰠱", hl = "MyOutlineClass",         group = "Classes" },
  [6]  = { name = "Method",        icon = "󰆧", hl = "MyOutlineMethod",        group = "Methods" },
  [7]  = { name = "Property",      icon = "󰜢", hl = "MyOutlineProperty",      group = "Properties" },
  [8]  = { name = "Field",         icon = "󰜢", hl = "MyOutlineField",         group = "Fields" },
  [9]  = { name = "Constructor",   icon = "",  hl = "MyOutlineConstructor",   group = "Constructors" },
  [10] = { name = "Enum",          icon = "󰒻", hl = "MyOutlineEnum",          group = "Enums" },
  [11] = { name = "Interface",     icon = "",  hl = "MyOutlineInterface",     group = "Interfaces" },
  [12] = { name = "Function",      icon = "󰊕", hl = "MyOutlineFunction",      group = "Functions" },
  [13] = { name = "Variable",      icon = "󰀫", hl = "MyOutlineVariable",      group = "Variables" },
  [14] = { name = "Constant",      icon = "󰏿", hl = "MyOutlineConstant",      group = "Constants" },
  [15] = { name = "String",        icon = "󰀬", hl = "MyOutlineString",        group = "Strings" },
  [16] = { name = "Number",        icon = "󰎠", hl = "MyOutlineNumber",        group = "Numbers" },
  [17] = { name = "Boolean",       icon = "◩",  hl = "MyOutlineBoolean",       group = "Booleans" },
  [18] = { name = "Array",         icon = "󰅪", hl = "MyOutlineArray",         group = "Arrays" },
  [19] = { name = "Object",        icon = "󰅩", hl = "MyOutlineObject",        group = "Objects" },
  [20] = { name = "Key",           icon = "󰌋", hl = "MyOutlineKey",           group = "Keys" },
  [21] = { name = "Null",          icon = "󰟢", hl = "MyOutlineNull",          group = "Nulls" },
  [22] = { name = "EnumMember",    icon = "",  hl = "MyOutlineEnumMember",    group = "Enum Members" },
  [23] = { name = "Struct",        icon = "󰙅", hl = "MyOutlineStruct",        group = "Structs" },
  [24] = { name = "Event",         icon = "",  hl = "MyOutlineEvent",         group = "Events" },
  [25] = { name = "Operator",      icon = "󰆕", hl = "MyOutlineOperator",      group = "Operators" },
  [26] = { name = "TypeParameter", icon = "",  hl = "MyOutlineTypeParameter", group = "Type Parameters" },
}

-- Stable display order for groups (matches a sensible "outline" reading order).
M.group_order = {
  5, 23, 11, 10, 22,     -- Class, Struct, Interface, Enum, EnumMember
  9, 6, 12,              -- Constructor, Method, Function
  7, 8,                  -- Property, Field
  14, 13,                -- Constant, Variable
  24, 25, 26,            -- Event, Operator, TypeParameter
  3, 2, 4,               -- Namespace, Module, Package
  17, 16, 15, 18, 19, 20, 21, -- primitives / containers
  1,                     -- File last
}

function M.get(kind)
  return M.kinds[kind] or { name = "Unknown", icon = "?", hl = "MyOutlineUnknown", group = "Other" }
end

return M
