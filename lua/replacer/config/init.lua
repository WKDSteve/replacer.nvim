---@module 'replacer.config'
--- Central configuration for replacer.
--- Responsibilities:
---   - Provide Defaults and a validated, mutable runtime state
---   - Expose `setup(opts)` for user init
---   - Expose `get()` to read the effective config (copy)
---   - Expose `resolve(partial)` to merge+validate ad-hoc overrides
---
--- Notes:
---   - `get()` returns a deep copy to avoid accidental mutation by callers.
---   - `engine` selects the picker UI ("fzf"|"telescope"|"auto").
---   - `search_engine` selects the match collector ("ripgrep"|"vimgrep"|"auto").
---     "auto" prefers ripgrep when the `rg` executable is available and falls
---     back to the native (vimgrep-style) scanner otherwise.
---   - Pure default values live in `replacer.config.DEFAULTS`; this module only
---     holds validation/merging logic.

local M = {}

---@type RP_Config
local Defaults = require("replacer.config.DEFAULTS")

---@type RP_Config
local state = vim.deepcopy(Defaults)

---What the last `setup()` had to reject or degrade, for `:checkhealth`.
--- Populated by `M.setup` only -- `M.resolve` merges per-run overrides built
--- by the command layer itself (e.g. `changed_only`/`also_rename_file`,
--- which are intentionally not RP_Config fields), so treating every
--- `:Replace --changed` invocation as a config typo would be noise, not a
--- diagnostic.
---@type string[]
local issues = {}

--------------------------------------------------------------------------------
-- Validators / Coercers (defensive)
--------------------------------------------------------------------------------

---@internal
---@param v any
---@return boolean|nil # strict boolean or nil when unrecognized
local function as_bool(v)
  if type(v) == "boolean" then
    return v
  end
  if v == 1 or v == "1" or v == "true" then
    return true
  end
  if v == 0 or v == "0" or v == "false" then
    return false
  end
  return nil
end

---@internal
---@param v any
---@return integer|nil
local function as_pos_int(v)
  if type(v) == "number" and v == math.floor(v) and v >= 0 then
    return v
  end
  return nil
end

---@internal
---@param v any
---@return "fzf"|"telescope"|"auto"|nil
local function as_engine(v)
  if type(v) ~= "string" then
    return nil
  end
  local s = v:lower():gsub("%s+", ""):gsub("%-", "_")
  if s == "fzf" or s == "fzf_lua" then
    return "fzf"
  end
  if s == "telescope" then
    return "telescope"
  end
  if s == "auto" then
    return "auto"
  end
  return nil
end

---@internal
---@param v any
---@return "ripgrep"|"vimgrep"|"auto"|nil
local function as_search_engine(v)
  if type(v) ~= "string" then
    return nil
  end
  local s = v:lower():gsub("%s+", ""):gsub("%-", "_")
  if s == "ripgrep" or s == "rg" then
    return "ripgrep"
  end
  if s == "vimgrep" or s == "native" or s == "vim" then
    return "vimgrep"
  end
  if s == "auto" then
    return "auto"
  end
  return nil
end

---@internal
---@param v any
---@return "auto"|"notify"|"statusline"|"fidget"|"float"|"kit"|nil
local function as_progress_style(v)
  if type(v) ~= "string" then
    return nil
  end
  local s = v:lower():gsub("%s+", "")
  if
    s == "auto"
    or s == "notify"
    or s == "statusline"
    or s == "fidget"
    or s == "float"
    or s == "kit"
  then
    return s
  end
  return nil
end

---@internal
--- Coerce a value into a clean array of non-empty strings.
--- Accepts a single string (wrapped) or a list; ignores non-strings.
---@param v any
---@return string[]
local function as_string_list(v)
  if type(v) == "string" then
    return (v ~= "") and { v } or {}
  end
  if type(v) ~= "table" then
    return {}
  end
  local out = {} ---@type string[]
  for i = 1, #v do
    local s = v[i]
    if type(s) == "string" and s ~= "" then
      out[#out + 1] = s
    end
  end
  return out
end

---@internal
---@param t table|nil
---@return table
local function tbl(t)
  return (type(t) == "table") and t or {}
end

---@internal
--- Pick a boolean override, falling back to `default` only when unset/unrecognized.
--- NOTE: do not use `as_bool(x) or default` — a legitimate `false` would be lost.
---@param v any
---@param default boolean
---@return boolean
local function pick_bool(v, default)
  local b = as_bool(v)
  if b == nil then
    return default
  end
  return b
end

---@internal
--- `key` with the nearest known option as a hint when one is plausible
--- (edit distance <= 3). `path_prefix` (e.g. "keymaps.") is prepended to
--- both the reported key and the suggestion so a nested typo reads as a
--- full dotted path, not a bare, out-of-context name.
---@param key string
---@param known table<string, true>
---@param path_prefix string|nil
---@return string
local function describe_unknown_key(key, known, path_prefix)
  local levenshtein = require("lib.lua.strings.distance").levenshtein
  local prefix = path_prefix or ""
  local best, best_distance = nil, nil
  for candidate in pairs(known) do
    local d = levenshtein(key, candidate)
    if d <= 3 and (best_distance == nil or d < best_distance) then
      best, best_distance = candidate, d
    end
  end
  if best then
    return string.format("unknown option '%s%s' (did you mean '%s%s'?)", prefix, key, prefix, best)
  end
  return string.format("unknown option '%s%s'", prefix, key)
end

---@internal
--- Merge user-supplied keymaps over the defaults, key by key. An invalid
--- (non-string or empty) value for a given key silently keeps its default
--- instead of disabling the keymap outright.
---
--- `keymaps` is itself a fixed, fully-typed schema (RP_Keymaps), so a typo
--- here (e.g. `toggle_slect` for `toggle_select`) is the exact same failure
--- mode `sanitize_keys` exists to catch at the top level -- one level
--- deeper: without this check the bogus key is simply never read, the
--- intended key silently keeps its default, and nothing is reported
--- anywhere, including `:checkhealth` (ERR-50).
---@param v any
---@return table<string, string> out, string[] new_issues
local function as_keymaps(v)
  local user = tbl(v)
  local out = vim.deepcopy(assert(Defaults.keymaps, "DEFAULTS always carries keymaps"))
  local known = {}
  for key in pairs(out) do
    known[key] = true
  end
  local new_issues = {}
  for key, uv in pairs(user) do
    if known[key] then
      if type(uv) == "string" and uv ~= "" then
        out[key] = uv
      end
    else
      new_issues[#new_issues + 1] = describe_unknown_key(tostring(key), known, "keymaps.")
    end
  end
  return out, new_issues
end

---@internal
--- Drop top-level keys `setup()` doesn't recognize, BEFORE the merge --
--- otherwise a typo (e.g. `smartcase` for `smart_case`) survives into the
--- intermediate merged table and `validate`'s key-by-key rebuild drops it
--- later with no diagnostic anywhere (ERR-50).
---@param user_opts table
---@return table clean, string[] new_issues
local function sanitize_keys(user_opts)
  local known = {}
  for k in pairs(Defaults) do
    known[k] = true
  end
  local clean, new_issues = {}, {}
  for key, value in pairs(user_opts) do
    if known[key] then
      clean[key] = value
    else
      new_issues[#new_issues + 1] = describe_unknown_key(tostring(key), known)
    end
  end
  return clean, new_issues
end

---@internal
--- Record that `field` had a present-but-invalid value that degraded to its
--- default (ERR-22): `raw` is what the user passed, `coerced` is what the
--- matching `as_*` validator made of it (nil means rejected).
---@param field_issues string[]
---@param field string
---@param raw any
---@param coerced any
local function record_degraded(field_issues, field, raw, coerced)
  if raw ~= nil and coerced == nil then
    field_issues[#field_issues + 1] =
      string.format("'%s': invalid value %s -- using default", field, vim.inspect(raw))
  end
end

---@internal
---@param cfg table|nil
---@return RP_Config out, string[] field_issues  # field_issues: present-but-invalid single values that degraded to their default (ERR-22), plus unknown nested keys (e.g. keymaps.<typo>) dropped before their nested merge (ERR-50)
local function validate(cfg)
  cfg = tbl(cfg)

  local out = vim.deepcopy(Defaults)
  ---@type string[]
  local field_issues = {}

  local engine_v = as_engine(cfg.engine)
  record_degraded(field_issues, "engine", cfg.engine, engine_v)
  out.engine = engine_v or out.engine

  local search_engine_v = as_search_engine(cfg.search_engine)
  record_degraded(field_issues, "search_engine", cfg.search_engine, search_engine_v)
  out.search_engine = search_engine_v or out.search_engine

  local progress_style_v = as_progress_style(cfg.progress_style)
  record_degraded(field_issues, "progress_style", cfg.progress_style, progress_style_v)
  out.progress_style = progress_style_v or out.progress_style
  out.write_changes = pick_bool(cfg.write_changes, out.write_changes)
  out.confirm_all = pick_bool(cfg.confirm_all, out.confirm_all)
  out.confirm_wide_scope = pick_bool(cfg.confirm_wide_scope, out.confirm_wide_scope)
  out.preview_context = as_pos_int(cfg.preview_context) or out.preview_context
  out.hidden = pick_bool(cfg.hidden, out.hidden)
  out.exclude_git_dir = pick_bool(cfg.exclude_git_dir, out.exclude_git_dir)
  out.literal = pick_bool(cfg.literal, out.literal)
  out.smart_case = pick_bool(cfg.smart_case, out.smart_case)
  out.git_ignore = pick_bool(cfg.git_ignore, out.git_ignore)
  out.preserve_whitespace = pick_bool(cfg.preserve_whitespace, out.preserve_whitespace)
  out.case_preserve = pick_bool(cfg.case_preserve, out.case_preserve)
  out.word_boundary = pick_bool(cfg.word_boundary, out.word_boundary)
  out.code_only = pick_bool(cfg.code_only, out.code_only)
  out.safe_mode = pick_bool(cfg.safe_mode, out.safe_mode)
  out.skip_binary = pick_bool(cfg.skip_binary, out.skip_binary)
  out.max_file_size = as_pos_int(cfg.max_file_size) or out.max_file_size
  out.confirm_per_file = pick_bool(cfg.confirm_per_file, out.confirm_per_file)
  out.checkpoint = pick_bool(cfg.checkpoint, out.checkpoint)
  -- hooks holds function values -- assign the merged table directly rather
  -- than deep-copying (vim.deepcopy of function leaves is unnecessary and
  -- functions are inherently reference values).
  out.hooks = tbl(cfg.hooks)
  -- messages holds string.format templates keyed by message id (plain
  -- string values) -- a shallow merge over defaults, same rationale as hooks.
  out.messages = tbl(cfg.messages)
  out.quiet = pick_bool(cfg.quiet, out.quiet)
  out.lsp = pick_bool(cfg.lsp, out.lsp)
  out.stream = pick_bool(cfg.stream, out.stream)
  out.deps_popup = pick_bool(cfg.deps_popup, out.deps_popup)
  -- a boolean, or a table with the key(s) of the tree action; anything else keeps the default
  if type(cfg.tree) == "boolean" then
    out.tree = cfg.tree
  elseif type(cfg.tree) == "table" then
    local key = cfg.tree.key
    local valid = key == nil or key == false or type(key) == "string" or type(key) == "table"
    out.tree = valid and { key = key or nil } or out.tree
  end
  out.history_max_entries = as_pos_int(cfg.history_max_entries) or out.history_max_entries
  -- `as_pos_int` would reject 0, and 0 is meaningful here: redraw on every
  -- chunk, no throttling at all.
  if type(cfg.progress_throttle_ms) == "number" and cfg.progress_throttle_ms >= 0 then
    out.progress_throttle_ms = math.floor(cfg.progress_throttle_ms)
  end

  if type(cfg.default_scope) == "string" and cfg.default_scope ~= "" then
    out.default_scope = cfg.default_scope
  end

  -- Filter lists
  out.file_types = as_string_list(cfg.file_types)
  out.globs = as_string_list(cfg.globs)
  out.exclude = as_string_list(cfg.exclude)

  local keymaps_v, keymaps_issues = as_keymaps(cfg.keymaps)
  out.keymaps = keymaps_v
  vim.list_extend(field_issues, keymaps_issues)

  -- nested picker tables (shallow-merge over defaults)
  do
    local fzf = tbl(cfg.fzf)
    out.fzf = vim.tbl_deep_extend("force", vim.deepcopy(Defaults.fzf), fzf)
  end
  do
    local tel = tbl(cfg.telescope)
    out.telescope = vim.tbl_deep_extend("force", vim.deepcopy(Defaults.telescope), tel)
  end

  return out, field_issues
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Initialize/override configuration.
---
--- Unknown top-level keys and present-but-invalid single values (ERR-50,
--- ERR-22) are rejected/degraded here, before the merge, and recorded for
--- `M.issues()`/`:checkhealth` -- see `sanitize_keys`/`record_degraded`.
--- @param opts RP_Config|table|nil
--- @return nil
function M.setup(opts)
  local clean, key_issues = sanitize_keys(tbl(opts))
  local new_state, field_issues = validate(clean)
  state = new_state
  issues = vim.list_extend(vim.list_extend({}, key_issues), field_issues)
  if #issues > 0 then
    require("replacer.util.notify").warn("setup(): ignored config: " .. table.concat(issues, "; "))
  end
end

--- Get the current effective configuration (deep copy, read-only for callers).
--- @return RP_Config
function M.get()
  return vim.deepcopy(state)
end

--- What the last `setup()` had to reject or degrade: unknown top-level keys
--- and present-but-invalid single values, one human-readable line each.
--- Empty when everything was accepted. See `:checkhealth replacer`.
--- @return string[]
function M.issues()
  return vim.list_extend({}, issues)
end

--- Resolve a partial override against the current state (without mutating it).
--- Useful for per-run overrides (e.g., flags from :Replace) -- deliberately
--- NOT key-sanitized like `M.setup`: the command layer's own override
--- tables intentionally carry non-RP_Config keys (`changed_only`,
--- `also_rename_file`), which `validate` already drops silently by only
--- copying known fields into `out`.
--- @param partial table|nil
--- @return RP_Config
function M.resolve(partial)
  local merged = vim.tbl_deep_extend("force", {}, state, tbl(partial))
  local out = validate(merged)
  return out
end

return M ---@type ReplacerConfigModule
