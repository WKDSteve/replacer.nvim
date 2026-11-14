---@module 'replacer.types.config'
--------------------------------------------------------------------------------
-- Types (LuaLS)
--------------------------------------------------------------------------------

---@class RP_PickerFzf
---@field winopts table|nil

---@class RP_PickerTelescope
---@field layout_config table|nil

---Buffer-local picker keymaps. All set inside the picker window only.
---@class RP_Keymaps
---@field toggle_select?      string -- multi-select + move to next (default "<Tab>")
---@field toggle_select_prev? string -- multi-select + move to previous (default "<S-Tab>")
---@field apply_all?          string -- replace ALL matches, respects confirm_all (default "<C-a>")
---@field quit?                string -- close the picker (default "<Esc>")
---@field replace_and_reopen?  string -- apply entry under cursor, reopen with the rest (default "<C-r>")
---@field filter?               string -- open the filter prompt (pickers.refine: stacked path/content clauses); needs pickers.nvim (default "<C-f>")

---Lua before/after callbacks around the apply pipeline. Each key takes a
---single function or a list of functions; a before_apply hook may return
---`false` to skip (veto) that file. See lua/replacer/hooks.lua.
---@class RP_Hooks
---@field before_apply? fun(ctx: table)|fun(ctx: table)[]
---@field after_apply?  fun(ctx: table)|fun(ctx: table)[]
---@field before_write? fun(ctx: table)|fun(ctx: table)[]
---@field after_write?  fun(ctx: table)|fun(ctx: table)[]

---@class RP_Config
---@field engine?               "fzf"|"telescope"|"auto"  -- picker UI; "auto" -> fzf-lua if present, else telescope
---@field search_engine?        "ripgrep"|"vimgrep"|"auto" -- match collector; "auto" -> rg if present, else vimgrep
---@field progress_style?       "auto"|"notify"|"statusline"|"fidget"|"float"|"kit"
---@field write_changes?        boolean
---@field confirm_all?          boolean
---@field confirm_wide_scope?   boolean
---@field preview_context?      integer
---@field hidden?               boolean
---@field exclude_git_dir?      boolean
---@field literal?              boolean     -- default search mode (flags may override per-run)
---@field _old_len? 	           number
---@field _line_range?       integer[]   -- internal: {line1, line2} from a [range], see replacer.rg
---@field _changed_only?       string[]    -- internal: set by --changed, see replacer.gitfiles
---@field _also_rename_file?   boolean     -- internal: set by --also-rename-file
---@field smart_case?           boolean
---@field default_scope?        string      -- "%", "cwd", ".", or explicit path
---@field file_types?           string[]    -- ripgrep --type values (e.g. { "lua" })
---@field globs?                string[]     -- include glob patterns (e.g. { "*.lua" })
---@field exclude?              string[]     -- exclude path/glob patterns (e.g. { "node_modules" })
---@field fzf?                  RP_PickerFzf|nil
---@field telescope?            RP_PickerTelescope|nil
---@field git_ignore?           boolean
---@field keymaps?              RP_Keymaps
---@field preserve_whitespace?  boolean     -- keep old_text's leading/trailing ws around new_text
---@field case_preserve?        boolean     -- re-case new_text to match each match's case style
---@field word_boundary?        boolean     -- keep only whole-word matches
---@field code_only?            boolean     -- skip matches inside strings/comments (Tree-sitter, best-effort)
---@field safe_mode?            boolean     -- skip read-only/oversized/binary files instead of touching them
---@field max_file_size?        integer     -- bytes; only enforced when safe_mode is true
---@field skip_binary?          boolean     -- only enforced when safe_mode is true
---@field confirm_per_file?     boolean     -- ALL-mode: ask All/Skip/Only-some/Quit per file
---@field checkpoint?           boolean     -- ALL-mode: snapshot files before applying (:ReplaceUndo)
---@field hooks?                RP_Hooks    -- before/after callbacks around the apply pipeline
---@field messages?             table<string, string>  -- string.format template overrides, see replacer.messages
---@field quiet?                boolean     -- suppress routine info-level notifications (warnings/errors still show)
---@field lsp?                  boolean     -- soft LSP rename for identifier-shaped matches, see replacer.lsp_rename
---@field stream?               boolean     -- incremental rg parsing for smoother progress, see rg.collect_streaming
---@field deps_popup?           boolean     -- lib.nvim.deps "declared tools" popup once, ever, on first setup() after install (default true; needs lib.nvim.deps — a no-op without it)
---@field tree?                 boolean|{ key?: string|string[]|false }  -- "Replace in this file or folder" on a node of a tree view (default true: offered without a key), see replacer.integrations.tree
---@field history_max_entries? integer     -- how many past searches the history keeps (default 50; 0 disables history)
---@field progress_throttle_ms? integer    -- minimum ms between progress redraws while streaming rg's stdout (default 100)

---@class ReplacerConfigModule
---@field setup fun(opts:RP_Config|table|nil): nil
---@field get fun(): RP_Config
---@field resolve fun(partial:table|nil): RP_Config
---@field issues fun(): string[]  -- unknown/invalid options the last setup() had to reject or degrade (ERR-22, ERR-50); see :checkhealth replacer

return {}
