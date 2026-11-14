# Configuration

Everything goes through `setup()` (or lazy.nvim's `opts`). Defaults live in
[`config/DEFAULTS.lua`](../lua/replacer/config/DEFAULTS.lua); the type
contract is [`types/config.lua`](../lua/replacer/types/config.lua)'s
`RP_Config`.

```lua
require("replacer").setup({
  engine = "auto",
  progress_style = "auto",
})
```

Most of these have a per-run flag equivalent, so a one-off search never needs
a config change — see [commands.md](commands.md).

## Engines and backends

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `engine` | `"auto"｜"fzf"｜"telescope"` | `"auto"` | Picker UI. `"auto"` prefers fzf-lua, else telescope |
| `search_engine` | `"auto"｜"ripgrep"｜"vimgrep"` | `"auto"` | Match collector. `"auto"` prefers ripgrep, else the native vimgrep scan |
| `stream` | boolean | `false` | Incremental `rg --json` parsing for smoother progress. Ripgrep backend only |
| `fzf` | table | `{ winopts = { width = 0.85, height = 0.70 } }` | Extra fzf-lua options, merged into the picker opts |
| `telescope` | table | `{ layout_config = { width = 0.85, height = 0.70 } }` | Extra Telescope options (theme/layout) |

## Scope and filters

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `default_scope` | string | `"%"` | Scope used when `:Replace` is given none: `"%"`, `"cwd"`, `"."`, `"root"`, or a path |
| `file_types` | string[] | `{}` | Default ripgrep `--type` filters, e.g. `{ "lua" }` |
| `globs` | string[] | `{}` | Default include globs, e.g. `{ "*.lua" }` |
| `exclude` | string[] | `{}` | Default exclude path/glob patterns, e.g. `{ "node_modules" }` |
| `hidden` | boolean | `true` | Include dotfiles (`--hidden`) |
| `git_ignore` | boolean | `true` | Respect `.gitignore`; `false` passes `--no-ignore` |
| `exclude_git_dir` | boolean | `true` | Exclude `.git/` explicitly (`--glob !.git`) |

## Matching

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `literal` | boolean | `true` | Fixed-strings search. `false` is regex mode |
| `smart_case` | boolean | `true` | ripgrep `-S` |
| `word_boundary` | boolean | `false` | Keep only whole-word matches |
| `code_only` | boolean | `false` | Skip matches inside strings/comments (Tree-sitter, best-effort) |
| `case_preserve` | boolean | `false` | Re-case the replacement to each match's own case style |
| `preserve_whitespace` | boolean | `false` | Keep a match's own leading/trailing whitespace around the replacement |

## Applying

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `write_changes` | boolean | `true` | Write modified buffers on apply; `false` leaves them unsaved for you to review |
| `confirm_all` | boolean | `true` | Confirm before replacing every match at once |
| `confirm_wide_scope` | boolean | `false` | Extra confirmation for a non-buffer (cwd/dir) ALL apply |
| `confirm_per_file` | boolean | `false` | ALL-mode: ask All/Skip/Only-some/Quit per file. **Supersedes** `confirm_all` and `confirm_wide_scope` when enabled |
| `checkpoint` | boolean | `false` | ALL-mode: snapshot every touched file first, for `:ReplaceUndo` |
| `safe_mode` | boolean | `false` | Skip read-only, oversized and binary files instead of touching them |
| `max_file_size` | integer | `5 * 1024 * 1024` | Bytes. Only enforced while `safe_mode` is on |
| `skip_binary` | boolean | `true` | Only enforced while `safe_mode` is on |
| `lsp` | boolean | `false` | Try an LSP-driven rename for identifier-shaped matches, falling back to a plain text edit |
| `hooks` | table | `{}` | `before_apply` / `after_apply` / `before_write` / `after_write`, see below |

## UI and feedback

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `preview_context` | integer | `3` | Context lines shown around a hit in the preview |
| `progress_style` | `"auto"｜"notify"｜"statusline"｜"fidget"｜"float"｜"kit"` | `"auto"` | See [progress-indicator.md](progress-indicator.md) |
| `progress_throttle_ms` | integer | `100` | Minimum time between progress redraws while streaming ripgrep's stdout. Raise it if a notify backend that cannot replace in place floods you |
| `quiet` | boolean | `false` | Suppress routine info-level notifications. Warnings and errors always show |
| `messages` | table | `{}` | Override message templates by key, see below |
| `keymaps` | table | see [BINDINGS.md](BINDINGS.md#picker-keymaps) | Buffer-local picker keymaps |
| `history_max_entries` | integer | `50` | How many past applies `:ReplaceHistory` keeps. `0` disables history entirely |
| `tree` | boolean \| table | `true` | "Replace in this file or folder" on a node of a tree view, see [api.md](api.md#in-a-tree-view). `{ key = "<leader>r" }` also puts it on a key in the tree buffer; `false` does not offer it |
| `deps_popup` | boolean | `true` | The one-time `lib.nvim.deps` "declared tools" popup, see [installation.md](installation.md#declared-cli-tools) |

## Picker keymaps

```lua
keymaps = {
  toggle_select      = "<Tab>",   -- multi-select + move to next
  toggle_select_prev = "<S-Tab>", -- multi-select + move to previous
  apply_all          = "<C-a>",   -- replace ALL matches, respects confirm_all
  replace_and_reopen = "<C-r>",   -- apply entry under cursor, reopen with the rest
  filter             = "<C-f>",   -- filter results (needs pickers.nvim; no-op with a hint otherwise)
  quit               = "<Esc>",   -- close the picker
}
```

Every one is buffer-local to the picker window; the plugin sets no global
keymap. `<CR>` (apply to the selection) is fixed — it is each backend's own
default key. Full table, including which of these which-key can label per
backend: [BINDINGS.md](BINDINGS.md#picker-keymaps).

## Messages and quiet mode

Each value is a `string.format` template. A malformed override is shown
verbatim rather than raising.

| Key | Default | Arguments |
| --- | --- | --- |
| `confirm_all` | `Apply ALL %d spot(s) across %d file(s)?` | spots, files |
| `confirm_all_short` | `Apply replacement to ALL %d spot(s)?` | spots |
| `cancelled` | `cancelled` | — |
| `result` | `%d spot(s) in %d file(s)` | spots, files |
| `no_matches` | `no matches found` | — |
| `surround_prompt` | `Surround with: ` | — |
| `surround_cancelled` | `Surround: cancelled (no delimiter)` | — |

```lua
require("replacer").setup({
  quiet = false,
  messages = {
    no_matches = "keine Treffer",
    result = "%d Fundstelle(n) in %d Datei(en)",
  },
})
```

## Hooks

Four events fire once per file around the apply pipeline. Each key takes a
function or a list of functions. Config hooks run before ones registered
through [`replacer.hooks.on()`](api.md#requirereplacerhooksonevent-fn). A hook
error is caught and warned — never allowed to abort the apply.

```lua
require("replacer").setup({
  hooks = {
    -- ctx = { path, matches, new_text }; return false to veto this file
    before_apply = function(ctx)
      if ctx.path:match("%.generated%.lua$") then return false end
    end,
    -- ctx = { path, bufnr, ok }
    after_write = function(ctx)
      if ctx.ok then vim.system({ "stylua", ctx.path }) end
    end,
  },
})
```

| Event | `ctx` | Notes |
| --- | --- | --- |
| `before_apply` | `{ path, matches, new_text }` | Returning `false` skips this file |
| `after_apply` | `{ path, spots, skipped }` | — |
| `before_write` | `{ path, bufnr }` | Only when `write_changes` is on |
| `after_write` | `{ path, bufnr, ok }` | `ok` is false on a failed write |

See [FEATURES/APPLY.md](FEATURES/APPLY.md#hook-system) for the mechanics and
[WORKFLOW.md](WORKFLOW.md#hooks-live-around-the-write-not-around-the-search)
for what they are worth composing into.
