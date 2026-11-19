---@module 'replacer.types'
--- Central type definitions for the replacer plugin.
--- Purely for LuaLS; no runtime effect.

----------------
-- Core enums  --
----------------

---@alias RP_Engine
---| "fzf"        # Use ibhagwan/fzf-lua picker
---| "telescope"  # Use nvim-telescope/telescope.nvim picker

---@alias RP_Scope
---| "%"      # current buffer (file-backed only)
---| "buf"    # alias for "%"
---| "cwd"    # current working directory
---| "."      # alias for "cwd"
---| "root"   # auto-detected project root (see replacer.root); falls back to cwd
---| string   # absolute/relative file or directory path

-- rg module accepts the same config surface (subset used).
---@alias RP_RG_Config RP_Config

----------------
-- Public API  --
----------------

---@alias ReplacerSetup fun(user: RP_Config|nil): nil
---@alias ReplacerRun fun(request: RP_Request|string, new_text?: string, scope?: string, all?: boolean): nil

--- Public facade of the plugin (returned by `require("replacer")`).
---@class Replacer
---@field setup fun(opts: RP_Config|table|nil): nil
---@field run fun(request: RP_Request|string, new_text?: string, scope?: string, all?: boolean): nil

----------------
-- Errors      --
----------------

--- Structured error value (see replacer.error).
---@class RP_Error
---@field type string      # stable discriminator, e.g. "WriteError"
---@field message string
---@field cause any|nil

----------------
-- Command API --
----------------

--- Per-run override surface produced by command flags (merged over config).
---@class RP_Overrides
---@field literal? boolean
---@field smart_case? boolean
---@field hidden? boolean
---@field git_ignore? boolean
---@field engine? "fzf"|"telescope"
---@field preview_context? integer
---@field preserve_whitespace? boolean
---@field case_preserve? boolean
---@field word_boundary? boolean
---@field code_only? boolean
---@field safe_mode? boolean
---@field max_file_size? integer
---@field changed_only? string[]  # subset of {"modified","staged","untracked"}
---@field confirm_per_file? boolean
---@field checkpoint? boolean
---@field also_rename_file? boolean
---@field lsp? boolean
---@field stream? boolean

--- Filters produced by command flags (merged over config filter lists).
---@class RP_Filters
---@field file_types string[]
---@field globs string[]
---@field exclude string[]

--- Structured request parsed from a :Replace invocation.
---@class RP_Request
---@field old string
---@field new string
---@field scope string
---@field all boolean              # non-interactive: apply to every match
---@field dry boolean              # plan only; compute edits, no writes
---@field export string|nil        # export path for the planned diff/JSON
---@field to_quickfix boolean|nil  # send matches to the quickfix list instead of applying
---@field to_loclist boolean|nil   # send matches to the (current-window) location list instead
---@field line_range integer[]|nil # {line1, line2} when a [range] was given
---@field overrides RP_Overrides
---@field filters RP_Filters
---@field filter? fun(match: RP_Match): boolean  # keep predicate applied post-collection (true = keep)
---@field filter_empty_msg? string  # notice shown when filter removes every match
---@field on_end? fun(data: RP_RunEnd)  # called once when the run is over, right after `User ReplacerDone`

---@alias ReplacerRunCallback fun(request: RP_Request): nil
---@alias ReplacerResolveScopeFn fun(scope: RP_Scope): string[], boolean
---@alias ReplacerRunRegisterFn fun(run_fun: ReplacerRunCallback): nil

---@class ReplacerCommand
---@field register ReplacerRunRegisterFn
---@field resolve_scope ReplacerResolveScopeFn
---@field parse_request fun(raw: string|nil, cmd_opts: table|nil): boolean, RP_Request|nil, string|nil

return {}
