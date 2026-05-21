# 💤 LazyVim — okwe's config

Personal LazyVim configuration. Portable across machines via this repo.

> **Audience for the SETUP section below: another LLM/agent driving installation on a fresh machine.** Follow the steps verbatim, in order. Stop and report if any verification step fails — do not improvise.

---

## What's in this repo

```
nvim/
├── init.lua                # bootstraps lazy.nvim + LazyVim
├── lazy-lock.json          # pinned plugin versions (commit this!)
├── lazyvim.json            # LazyVim extras enabled
├── stylua.toml             # formatter config
├── lua/
│   ├── config/             # LazyVim core overrides (options, keymaps, autocmds, lazy bootstrap)
│   ├── plugins/
│   │   ├── example.lua     # LazyVim starter examples (mostly commented out)
│   │   ├── theme.lua       # colorscheme override
│   │   ├── outline.lua     # wires <leader>o → local `myoutline` plugin (NOT hedyhli/outline.nvim)
│   │   └── roslyn.lua      # native Roslyn LSP wiring for C# (NO wrapper plugin)
│   └── myoutline/          # CUSTOM in-tree plugin: floating-popup symbol outline
│       ├── init.lua        # public API: setup / open / close / toggle + :MyOutline* cmds
│       ├── config.lua      # defaults
│       ├── lsp.lua         # textDocument/documentSymbol request + normalization
│       ├── symbols.lua     # LSP SymbolKind → {icon, hl, group_label}
│       ├── filter.lua      # fuzzy scorer
│       ├── actions.lua     # jump-to-symbol
│       └── ui.lua          # centered floating popup, prompt + grouped list + live preview
```

### Design choices worth knowing
- **No wrapper plugins for Roslyn.** `lua/plugins/roslyn.lua` uses Neovim 0.11+'s core `vim.lsp.config` / `vim.lsp.enable` API directly. The Roslyn binary is installed manually (no Mason).
- **`myoutline` is a local plugin**, lazy-loaded via `lua/plugins/outline.lua` with `dir = vim.fn.stdpath("config")`. It replaces `hedyhli/outline.nvim`. UX: centered floating popup with fuzzy filter and live-preview viewport scrolling in the source buffer.
- **Roslyn quirks handled in code** (do not "fix" these — they exist for a reason):
  - Custom `solution/open` / `project/open` notification on attach (Roslyn doesn't auto-discover the workspace).
  - `workspace/configuration` handler returning sensible defaults for ~60 settings (default `nil` reply disables features like decompiled-source GTD).
  - Wrapper script `~/.local/bin/roslyn` bridges Roslyn's Unix-socket transport (recent versions don't speak stdio) to Neovim via `nc -U`.
  - `BufReadCmd` handler for `source-generated://` URIs to load decompiled / source-generated documents on demand.

---

# 🛠 SETUP on a new machine

## 0. Targets supported
- macOS (Intel x64 or Apple Silicon arm64)
- Linux x64 / arm64

If the target OS is anything else, **stop and ask** before continuing.

## 1. Prerequisites

Install these system-wide. Commands below assume Homebrew on macOS or apt on Debian/Ubuntu. Adapt for other package managers.

| Dependency | Why | Verify |
|---|---|---|
| **Neovim ≥ 0.11** | `vim.lsp.config` / `vim.lsp.enable` API used by `roslyn.lua` | `nvim --version` → first line ≥ `NVIM v0.11.0` |
| **git** | clone this repo + lazy.nvim plugin sync | `git --version` |
| **.NET SDK ≥ 9.0** | runs the Roslyn `Microsoft.CodeAnalysis.LanguageServer.dll` | `dotnet --list-sdks` |
| **netcat (`nc`) with `-U` (Unix socket) support** | wrapper script bridges Roslyn's socket to stdio | `nc -h 2>&1 \| grep -- -U` |
| **python3** | wrapper script parses Roslyn's pipe-announce JSON | `python3 --version` |
| **ripgrep (`rg`)** | LazyVim live grep | `rg --version` |
| **fd** (`fd` or `fdfind`) | LazyVim file finder | `fd --version` |
| **lazygit** *(optional)* | `<leader>gg` in LazyVim | `lazygit --version` |
| **A Nerd Font** | icons in `myoutline` (e.g. 󰊕 󰠱 󰜢) and LazyVim UI | terminal renders the previous glyphs as actual icons, not boxes |

### macOS one-liner
```bash
brew install neovim git dotnet ripgrep fd lazygit
# netcat with -U comes with macOS; python3 too. Nerd Font:
brew install --cask font-jetbrains-mono-nerd-font
```

### Debian/Ubuntu one-liner
```bash
sudo apt update && sudo apt install -y neovim git ripgrep fd-find lazygit netcat-openbsd python3
# .NET 9 SDK: follow https://learn.microsoft.com/dotnet/core/install/linux
# Nerd Font: download a release zip from https://github.com/ryanoasis/nerd-fonts/releases
# and unzip into ~/.local/share/fonts/, then `fc-cache -fv`.
```

### macOS-specific: ensure `~/.local/bin` is on PATH for GUI launchers
The Roslyn wrapper lives at `~/.local/bin/roslyn`. Terminal `nvim` inherits your shell PATH, but GUI launches (Spotlight, Dock) may not. Either always launch `nvim` from a terminal, or configure your shell rc to export `PATH="$HOME/.local/bin:$PATH"` AND ensure your terminal-emulator profile sources the shell as a login shell.

> The Lua config calls `vim.fn.expand("~/.local/bin/roslyn")` with an absolute path, so PATH issues do not affect Neovim itself once the binary exists at that location.

## 2. Clone this repo into the Neovim config slot

```bash
# Back up any existing config first.
if [ -e ~/.config/nvim ] && [ ! -L ~/.config/nvim ]; then
  mv ~/.config/nvim ~/.config/nvim.backup.$(date +%Y%m%d-%H%M%S)
fi

# Clone repo somewhere stable (adjust path if needed).
mkdir -p ~/dev
git clone <THIS_REPO_URL> ~/dev/lazy_vim

# Symlink the nvim/ subfolder into ~/.config/nvim.
ln -sfn ~/dev/lazy_vim/nvim ~/.config/nvim
```

**Verify:**
```bash
readlink ~/.config/nvim
# expected: /Users/<you>/dev/lazy_vim/nvim  (or /home/<you>/dev/lazy_vim/nvim)
ls ~/.config/nvim/init.lua
# expected: file exists
```

## 3. Install the Roslyn LSP server (manual, no Mason)

Roslyn ships as a NuGet package containing a self-contained .NET DLL plus native dependencies. We extract it into `~/.local/share/roslyn-lsp/`.

### 3a. Pick the right runtime ID (RID)
| Platform | RID |
|---|---|
| macOS Intel | `osx-x64` |
| macOS Apple Silicon | `osx-arm64` |
| Linux x64 | `linux-x64` |
| Linux arm64 | `linux-arm64` |

### 3b. Download + extract a recent NuGet build

```bash
# Pick a version. As of this writing, 4.13.x is stable. Bump as needed.
RID="osx-x64"                  # <-- set per the table above
VERSION="4.13.0"               # <-- check https://dev.azure.com/azure-public/vside/_artifacts/feed/vs-impl/NuGet/Microsoft.CodeAnalysis.LanguageServer.${RID}
PKG="microsoft.codeanalysis.languageserver.${RID}"

mkdir -p ~/.local/share/roslyn-lsp
cd /tmp
curl -L -o roslyn.nupkg \
  "https://pkgs.dev.azure.com/azure-public/vside/_apis/packaging/feeds/vs-impl/nuget/packages/${PKG}/versions/${VERSION}/content"

# .nupkg is a zip.
unzip -o roslyn.nupkg -d roslyn-unpacked
# DLLs live under contentFiles/any/any/.
cp -R roslyn-unpacked/contentFiles/any/any/* ~/.local/share/roslyn-lsp/
```

**Verify:**
```bash
ls ~/.local/share/roslyn-lsp/Microsoft.CodeAnalysis.LanguageServer.dll
# expected: file exists
```

If the URL above 404s or the package layout has changed, **stop and ask the human** — the publishing infrastructure does shift occasionally. Do not improvise an alternative download source.

### 3c. Install the wrapper script

Create `~/.local/bin/roslyn`:

```bash
mkdir -p ~/.local/bin
cat > ~/.local/bin/roslyn <<'EOF'
#!/usr/bin/env bash
# Wrapper for Microsoft.CodeAnalysis.LanguageServer (Roslyn LSP).
# Bridges Roslyn's Unix-socket transport to LSP-over-stdio for Neovim.
set -e

DLL="$HOME/.local/share/roslyn-lsp/Microsoft.CodeAnalysis.LanguageServer.dll"
LOG_DIR="${ROSLYN_LOG_DIR:-$HOME/.cache/nvim/roslyn}"
mkdir -p "$LOG_DIR"

ANNOUNCE=$(mktemp)
SERVER_PID=

cleanup() {
  rm -f "$ANNOUNCE"
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

dotnet "$DLL" \
  --logLevel=Information \
  --extensionLogDirectory="$LOG_DIR" \
  >"$ANNOUNCE" 2>>"$LOG_DIR/server.stderr.log" &
SERVER_PID=$!

for _ in $(seq 1 100); do
  [ -s "$ANNOUNCE" ] && break
  sleep 0.1
done

PIPE=$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1]))["pipeName"])
except Exception:
    sys.exit(1)' "$ANNOUNCE" 2>/dev/null || true)

if [ -z "$PIPE" ]; then
  echo "roslyn-wrapper: failed to read pipeName from server (see $LOG_DIR/server.stderr.log)" >&2
  exit 1
fi

exec nc -U "$PIPE"
EOF
chmod +x ~/.local/bin/roslyn
```

**Verify:**
```bash
~/.local/bin/roslyn </dev/null >/dev/null 2>&1 &
PID=$!
sleep 2
kill $PID 2>/dev/null
ls ~/.cache/nvim/roslyn/server.stderr.log
# expected: log file exists, no fatal "Could not execute because..." errors inside.
```

## 4. First Neovim launch

```bash
nvim
```

Expected sequence:
1. lazy.nvim bootstraps itself (clones from GitHub on first run).
2. lazy.nvim reads `lazy-lock.json` and installs every plugin at the pinned commit.
3. LazyVim UI appears. Plugin install progress shown in a floating window.
4. Quit and relaunch once installs finish: `:qa` then `nvim` again.

**Verify in `nvim`:**
- `:Lazy` — all plugins listed, none in error state.
- `:checkhealth` — no critical (red) failures. Yellow warnings are usually fine.
- `:lua print(vim.version().major .. "." .. vim.version().minor)` → `0.11` or higher.

## 5. Verify the Roslyn LSP

1. Open any `.cs` file inside a folder that contains a `.sln` or `.csproj` (walking upward):
   ```bash
   nvim path/to/SomeFile.cs
   ```
2. Wait ~10-30 seconds for the solution to load.
3. Check `:LspInfo` (or `:checkhealth lsp`): a client named `roslyn` should be attached.
4. Test:
   - **Completion**: type `Console.` — completion popup appears with `WriteLine`, etc.
   - **Go to definition**: cursor on `Console`, press `gd` — opens a decompiled-source buffer (no "no definition found").
   - **Diagnostics**: introduce a syntax error — squigglies appear within a few seconds.

If any of those fail:
- Check `~/.cache/nvim/roslyn/server.stderr.log` for server errors.
- Check `:messages` in Neovim for `[roslyn]` notifications.
- Confirm `:lua =vim.lsp.get_clients({name="roslyn"})` returns a non-empty list.

## 6. Verify the custom `myoutline` plugin

1. Inside any LSP-attached buffer (e.g. the C# file from step 5):
   ```vim
   :MyOutlineToggle
   ```
   or press `<leader>o`.
2. Expected: centered floating popup with:
   - Prompt line at top (empty, with "Type to filter symbols…" placeholder).
   - Horizontal `─` separator.
   - Grouped symbol list ("Classes", "Methods", "Properties", …) with Nerd Font icons.
   - Method names followed by their parameter signatures in muted colour.
3. Start typing — list filters live; **source buffer viewport scrolls** to the highlighted symbol.
4. `<CR>` jumps & closes (normal mode). `<Esc>` cancels and restores original cursor + view.

If icons render as boxes/`?` → your Nerd Font is not active in the terminal. Fix the terminal font, not the config.

## 7. Format-on-save / Stylua *(optional, dev only)*

```bash
brew install stylua          # macOS
# Linux: cargo install stylua, or download a release binary
```

`stylua.toml` at repo root configures formatting. Pre-commit hook (if any) lives outside this repo.

---

# 🧩 Day-to-day maintenance

## Update plugins
```vim
:Lazy sync
```
Then commit the updated `lazy-lock.json`:
```bash
cd ~/dev/lazy_vim
git add nvim/lazy-lock.json
git commit -m "chore: update plugin lockfile"
git push
```

## Update Roslyn LSP
Re-run step 3b with a newer `VERSION`. The wrapper script does not need changes.

## Pull changes on another machine
```bash
cd ~/dev/lazy_vim
git pull
nvim   # let lazy auto-sync to the new lockfile, or run :Lazy sync
```

## Where state lives (NOT in this repo, do not commit)
- `~/.local/share/nvim/` — plugin clones (lazy.nvim manages)
- `~/.local/state/nvim/` — shada, swap, undo
- `~/.cache/nvim/` — runtime cache, including `roslyn/server.stderr.log`
- `~/.local/share/roslyn-lsp/` — Roslyn DLLs (installed in step 3b)
- `~/.local/bin/roslyn` — wrapper script (installed in step 3c)

---

# 🚨 Things NOT to change without explicit approval

These exist because of specific upstream quirks and breaking them silently destroys functionality:

1. **`lua/plugins/roslyn.lua`** — every comment in this file documents a real bug or LSP-spec quirk. In particular:
   - The `workspace/configuration` handler MUST return `vim.NIL` (not Lua `nil`) for unknown keys, or array indices shift and Roslyn applies values to the wrong settings.
   - `blink.cmp.get_lsp_capabilities()` MUST be called with NO argument. Passing a table makes blink treat it as a user override that clobbers its own enhanced completion config, breaking member-access completion.
   - `solution/open` / `project/open` MUST be sent on attach. Roslyn does not auto-load workspaces.
   - The replay loop at the bottom (`nvim_exec_autocmds("FileType", …)`) handles the case where a `.cs` buffer was loaded before `VeryLazy` fired.
2. **The Roslyn wrapper script** — Roslyn's stdio transport is gone in current builds. Switching back to plain `cmd = { "dotnet", "Microsoft.CodeAnalysis.LanguageServer.dll", "--stdio" }` will hang at the handshake.
3. **`lua/myoutline/ui.lua` cursor-pinning autocmd** — the popup keeps the cursor on line 1 (prompt) at all times. Selection is purely visual (extmark highlight). Removing this breaks typing-vs-navigation interaction.
4. **`lua/myoutline/ui.lua` completion-disable block** — the prompt buffer explicitly disables blink.cmp / nvim-cmp / native completion. Without this, an autocomplete popup hovers over the filtered symbol list.

---

# 📚 References
- LazyVim docs: <https://lazyvim.github.io>
- Roslyn LanguageServer source: <https://github.com/dotnet/roslyn> (`src/Features/LanguageServer/`)
- Neovim core LSP API (0.11+): `:h vim.lsp.config`, `:h vim.lsp.enable`
