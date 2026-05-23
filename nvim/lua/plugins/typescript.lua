-- Minimal LazyVim TypeScript/JavaScript support.
-- Uses LazyVim's official TypeScript extra, which defaults to vtsls.
-- vtsls supports textDocument/documentSymbol, so myoutline can keep using
-- the standard LSP documentSymbol request with no plugin-specific changes.
return {
  { import = "lazyvim.plugins.extras.lang.typescript.init" },
}
