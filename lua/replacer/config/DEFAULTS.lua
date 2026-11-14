---@module 'replacer.config.DEFAULTS'
--- Pure default values for replacer's runtime config. No logic here — see
--- `replacer.config` for validation/merging.

---@type RP_Config
return {
  -- Picker UI: "auto" picks fzf-lua if present, else telescope.
  engine = "auto",
  -- Search backend: "auto" picks ripgrep when available, else vimgrep (native).
  search_engine = "auto",
  -- Progress indicator style (requires lib.nvim; silently skipped otherwise):
  -- "auto" | "notify" | "statusline" | "fidget" | "float" | "kit". See lib.nvim.progress.
  progress_style = "auto",

  write_changes = true,
  confirm_all = true,
  confirm_wide_scope = false,
  preview_context = 3,
  hidden = true,
  exclude_git_dir = true,
  literal = true,
  smart_case = true,
  default_scope = "%",
  -- When true, a match's own leading/trailing whitespace (relevant with regex
  -- patterns like `\s*foo\s*`) is preserved around the replacement instead of
  -- being clobbered by it.
  preserve_whitespace = false,
  -- When true, re-case the replacement to match each match's own case style:
  -- foo->bar, Foo->Bar, FOO->BAR, fooBar->bazQux, FooBar->BazQux.
  case_preserve = false,
  -- When true, only whole-word matches are kept (the byte before/after the
  -- match must not be a word byte: letter/digit/underscore).
  word_boundary = false,
  -- When true, matches falling inside a string/comment Tree-sitter node are
  -- skipped (best-effort; falls back to keeping everything when no parser
  -- is available for the file's language). See lua/replacer/tscode.lua.
  code_only = false,
  -- Safe-mode: skip read-only / oversized / binary files instead of
  -- touching them. Off by default; max_file_size/skip_binary only take
  -- effect once safe_mode is enabled.
  safe_mode = false,
  max_file_size = 5 * 1024 * 1024, -- 5 MiB
  skip_binary = true,
  -- ALL-mode: ask All/Skip/Only-some/Quit per file instead of one global
  -- "apply ALL?" confirmation. Supersedes confirm_all/confirm_wide_scope
  -- when enabled.
  confirm_per_file = false,
  -- ALL-mode: snapshot every about-to-be-touched file before applying, so
  -- :ReplaceUndo can restore them. See lua/replacer/checkpoint.lua.
  checkpoint = false,
  -- Lua before/after callbacks around the apply pipeline. Each key takes a
  -- single function or a list of functions: { before_apply = fn, ... }.
  -- See lua/replacer/hooks.lua.
  hooks = {},
  -- i18n / message customization: override any key in
  -- lua/replacer/messages.lua's DEFAULTS (string.format templates), and/or
  -- suppress routine info-level notifications entirely with quiet = true
  -- (warnings/errors always show).
  messages = {},
  quiet = false,
  -- Soft LSP integration: when a match's old/new text both look like plain
  -- identifiers and its buffer has an LSP client that supports rename, use
  -- an LSP-driven rename for that match instead of a plain text edit.
  -- Always falls back to plain text otherwise. See lua/replacer/lsp_rename.lua.
  lsp = false,
  -- Use the incremental ripgrep --json parser (collect_streaming) instead
  -- of parsing the full stdout blob at the end. Ripgrep backend only
  -- (other paths already deliver everything at once); gives smoother,
  -- filter-aware progress updates as matches are found. NOTE: the picker
  -- itself still opens once collection finishes -- true live picker fill
  -- (select matches while the search is still running) is not implemented
  -- yet, see lua/replacer/rg.lua collect_streaming docstring.
  stream = false,
  -- How many past searches `:ReplaceHistory` keeps.
  history_max_entries = 50,
  -- Minimum time between progress redraws while streaming ripgrep's stdout.
  -- Raise it if a "notify" style that cannot replace in place floods you on
  -- large searches; lower it for a smoother bar.
  progress_throttle_ms = 100,

  -- One-time "which CLI tools does this plugin want, and why" popup on
  -- first setup() after install (via lib.nvim.deps). false disables it for
  -- this plugin specifically, right here in the spec passed to setup() —
  -- no vim.g needed. See docs/installation.md.
  deps_popup = true,

  -- "Replace in this file or folder" on a node of a tree view (the own tree
  -- of filetree.nvim reads it from lib.nvim's registry). true: in the tree's
  -- menu and action list; { key = "<leader>r" }: on that key in the tree
  -- buffer as well; false: not offered.
  tree = true,

  -- Filters (also overridable per-run via command flags).
  file_types = {}, -- ripgrep --type values, e.g. { "lua", "md" }
  globs = {}, -- include glob patterns, e.g. { "*.lua" }
  exclude = {}, -- path/glob patterns to exclude, e.g. { "node_modules", "*.min.js" }

  fzf = { winopts = { width = 0.85, height = 0.70 } },
  telescope = { layout_config = { width = 0.85, height = 0.70 } },
  git_ignore = true,

  -- Picker keymaps (buffer-local, set inside the picker window only).
  -- Match the previously hardcoded values, so existing setups are unaffected.
  keymaps = {
    toggle_select = "<Tab>", -- multi-select + move to next
    toggle_select_prev = "<S-Tab>", -- multi-select + move to previous
    apply_all = "<C-a>", -- replace ALL matches (respects confirm_all)
    quit = "<Esc>", -- close the picker (double-<Esc> in fzf's terminal)
    -- Apply the entry under cursor, reopen with the rest. A modifier key by
    -- design (not a bare letter): both pickers' query line is live text
    -- input, so a bare letter would swallow that character instead of
    -- reaching the search box.
    replace_and_reopen = "<C-r>",
    -- Open the filter prompt: stacked path/content clauses via pickers.nvim's
    -- `pickers.refine`. A modifier key (same reasoning as replace_and_reopen).
    -- No-op with a hint when pickers.nvim is not installed.
    filter = "<C-f>",
  },
}
