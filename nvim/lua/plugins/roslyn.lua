-- Roslyn LSP setup.
--
-- We do NOT use a Roslyn wrapper plugin. Roslyn's LanguageServer speaks LSP
-- over stdio natively, so we configure it directly with Neovim's core
-- `vim.lsp.config` / `vim.lsp.enable` API (Neovim >= 0.11).
--
-- The server binary is installed manually (no Mason): the
-- `Microsoft.CodeAnalysis.LanguageServer.osx-x64` NuGet package (built from
-- github.com/dotnet/roslyn) is extracted to ~/.local/share/roslyn-lsp/, and
-- a wrapper script ~/.local/bin/roslyn launches it via `dotnet`.
--
-- Roslyn-specific quirk: after `initialize` the server does not auto-load a
-- workspace; it expects a custom `solution/open` (or `project/open`)
-- notification. We send that ourselves in `on_attach`.

return {
  -- A spec with no plugin — we just need a place to run our LSP wiring once
  -- lazy.nvim has finished startup. We hook into LazyVim's existing spec so
  -- the config runs at startup without adding any new plugin dependency.
  {
    "LazyVim/LazyVim",
    event = "VeryLazy",
    opts = function()
      local log_dir = vim.fn.stdpath("cache") .. "/roslyn"
      vim.fn.mkdir(log_dir, "p")

      -- Find the closest .sln (preferred) or .csproj walking upward from a path.
      local function find_workspace(start_path)
        local sln = vim.fs.find(function(name)
          return name:match("%.sln$")
        end, { upward = true, path = start_path, type = "file" })[1]
        if sln then
          return "solution", sln
        end

        local csproj = vim.fs.find(function(name)
          return name:match("%.csproj$")
        end, { upward = true, path = start_path, type = "file" })[1]
        if csproj then
          return "project", csproj
        end

        return nil, nil
      end

      -- Pull completion capabilities from blink.cmp (already installed).
      -- IMPORTANT: call get_lsp_capabilities() with NO argument. Passing a
      -- table makes blink treat it as a user override that wins conflicts,
      -- which clobbers blink's enhanced completion config (snippets, resolve,
      -- additionalTextEdits, etc.) and breaks completion on member access.
      local capabilities
      local ok, blink = pcall(require, "blink.cmp")
      if ok and blink.get_lsp_capabilities then
        capabilities = blink.get_lsp_capabilities()
      else
        capabilities = vim.lsp.protocol.make_client_capabilities()
      end

      -- Absolute path to wrapper avoids PATH issues when nvim is launched
      -- from GUI launchers (where ~/.local/bin may not be on PATH).
      local roslyn_cmd = vim.fn.expand("~/.local/bin/roslyn")

      -- Note: the wrapper script handles --logLevel, --extensionLogDirectory,
      -- and the named-pipe handshake (recent Roslyn server versions speak LSP
      -- over a Unix domain socket, not stdio; the wrapper bridges with `nc -U`).
      vim.lsp.config("roslyn", {
        cmd = { roslyn_cmd },
        filetypes = { "cs" },
        root_markers = { "*.sln", "*.csproj", ".git" },
        capabilities = capabilities,
        -- Roslyn issues `workspace/configuration` for ~60 settings at startup.
        -- The default Neovim handler returns nil for everything, which makes
        -- Roslyn treat all features as disabled. Most importantly,
        -- `navigation.dotnet_navigate_to_decompiled_sources = nil` causes
        -- "go to definition" on framework / NuGet types (e.g. `Console`) to
        -- return an empty result instead of decompiled source. We answer
        -- each requested section with a sensible default.
        --
        -- Section names look like:
        --   "csharp|symbol_search.dotnet_search_reference_assemblies"
        --   "navigation.dotnet_navigate_to_decompiled_sources"
        -- We match on the trailing setting name (after the last "|").
        handlers = {
          ["workspace/configuration"] = function(_, params, _, _)
            -- IMPORTANT: response is a positional array (one entry per
            -- requested item, in order). Unknown keys MUST be vim.NIL, not
            -- Lua nil — a Lua nil creates a hole that JSON-encoding compacts,
            -- shifting every later value to the wrong index. That would make
            -- Roslyn apply our values to the wrong settings (and reject them
            -- with type errors).
            local defaults = {
              -- The critical one: enables "go to definition" into decompiled
              -- framework / NuGet source.
              ["navigation.dotnet_navigate_to_decompiled_sources"] = true,
              ["symbol_search.dotnet_search_reference_assemblies"] = true,
              ["completion.dotnet_show_completion_items_from_unimported_namespaces"] = true,
              ["completion.dotnet_show_name_completion_suggestions"] = true,
              ["completion.dotnet_provide_regex_completions"] = true,
            }
            local result = {}
            for i, item in ipairs(params.items or {}) do
              local section = item.section or ""
              local key = section:match("([^|]+)$") or section
              local v = defaults[key]
              if v == nil then
                result[i] = vim.NIL
              else
                result[i] = v
              end
            end
            return result
          end,
        },
        on_attach = function(client, bufnr)
          local bufname = vim.api.nvim_buf_get_name(bufnr)
          local kind, path = find_workspace(bufname)
          if not kind then
            vim.notify(
              "[roslyn] no .sln or .csproj found upward from " .. bufname,
              vim.log.levels.WARN
            )
            return
          end

          if kind == "solution" then
            client.notify("solution/open", { solution = vim.uri_from_fname(path) })
          else
            client.notify("project/open", { projects = { vim.uri_from_fname(path) } })
          end
        end,
      })

      vim.lsp.enable("roslyn")

      -- Metadata-as-source / source-generated document handler.
      --
      -- When you "go to definition" on a framework or NuGet type (e.g.
      -- `Console.WriteLine`), Roslyn returns a URI like:
      --   source-generated:///...
      --   roslyn-source-generated:///...
      -- Neovim's core has no idea how to read those — they're not real files.
      -- Roslyn exposes a custom request `textDocument/_roslyn_sourceGeneratedDocument`
      -- that returns the decompiled / generated source text. We register a
      -- BufReadCmd that fetches the text and dumps it into the buffer.
      local function load_roslyn_virtual_doc(bufnr, uri)
        local clients = vim.lsp.get_clients({ name = "roslyn" })
        if #clients == 0 then
          vim.notify("[roslyn] no roslyn client attached to fetch " .. uri, vim.log.levels.WARN)
          return
        end
        local client = clients[1]
        client.request(
          "textDocument/_roslyn_sourceGeneratedDocument",
          { textDocument = { uri = uri } },
          function(err, result)
            if err then
              vim.notify("[roslyn] failed to fetch " .. uri .. ": " .. vim.inspect(err), vim.log.levels.ERROR)
              return
            end
            local text = (result and result.text) or (type(result) == "string" and result) or ""
            local lines = vim.split(text, "\n", { plain = true })
            vim.schedule(function()
              if not vim.api.nvim_buf_is_valid(bufnr) then return end
              vim.bo[bufnr].modifiable = true
              vim.bo[bufnr].readonly = false
              vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
              vim.bo[bufnr].filetype = "cs"
              vim.bo[bufnr].buftype = "nofile"
              vim.bo[bufnr].modifiable = false
              vim.bo[bufnr].readonly = true
              vim.bo[bufnr].modified = false
            end)
          end,
          bufnr
        )
      end

      vim.api.nvim_create_autocmd("BufReadCmd", {
        group = vim.api.nvim_create_augroup("roslyn_virtual_docs", { clear = true }),
        pattern = { "source-generated://*", "roslyn-source-generated://*" },
        callback = function(args)
          load_roslyn_virtual_doc(args.buf, args.match)
        end,
      })

      -- `vim.lsp.enable` installs a FileType autocmd. If a .cs buffer was
      -- already loaded (e.g. nvim opened with a file on the cmdline) before
      -- our VeryLazy opts ran, that autocmd never fires for it. Replay it.
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "cs" then
          vim.api.nvim_exec_autocmds("FileType", { buffer = buf, modeline = false })
        end
      end
    end,
  },
}
