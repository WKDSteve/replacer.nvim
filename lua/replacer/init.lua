---@module 'replacer'
--- Core orchestration: parse a request, collect matches, then either plan
--- (dry-run / export) or apply (interactive picker / non-interactive ALL).
---
--- Public API:
---   - setup(opts): initialize/override configuration
---   - run(request): execute a replace workflow from a parsed request
---       (also accepts the legacy positional form run(old, new, scope, all))
---
--- Notes:
---   - `setup` delegates to `replacer.config.setup`.
---   - `run` merges per-run flag overrides + filters via `replacer.config.resolve`
---     without mutating global state.

local M = {}

local cfg_mod = require("replacer.config")
local rg = require("replacer.rg")
local cmd_mod = require("replacer.command")
local dispatch = require("replacer.dispatch")
local notify = require("replacer.util.notify")

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Initialize/override configuration (delegates to replacer.config).
---@param opts RP_Config|table|nil
---@return nil
function M.setup(opts)
  cfg_mod.setup(opts)

  -- One-time (persisted across restarts) popup on the first setup() after
  -- installing this plugin: which CLI tools it wants and why
  -- (docs/install.json). `:Lib deps show replacer.nvim` thereafter.
  -- `cfg_mod.get().deps_popup = false` (set right in the setup() spec,
  -- config/DEFAULTS.lua) disables it for this plugin specifically.
  -- pcall'd: an older lib.nvim without lib.nvim.deps mustn't break setup()
  -- over an informational popup.
  if cfg_mod.get().deps_popup ~= false then
    local ok_deps, deps = pcall(require, "lib.nvim.deps")
    if ok_deps then
      deps.show_once("replacer.nvim")
    end
  end
end

--------------------------------------------------------------------------------
-- Run end signal (User ReplacerDone)
--------------------------------------------------------------------------------

---Name of the `User` autocmd pattern fired exactly once when a `:Replace` run is
---over, whatever way it ended. `args.data` is a `RP_RunEnd`.
M.DONE_EVENT = "ReplacerDone"

---@class RP_RunEnd
---@field reason "applied"|"cancelled"|"no_matches"|"plan"|"quickfix"|"no_scope"|"no_picker"|"error"
---@field applied boolean  true when at least one spot was written
---@field files integer    files changed by this run (0 when nothing applied)
---@field spots integer    spots changed by this run (0 when nothing applied)
---@field old string       the searched text of the run
---@field new string       the replacement of the run

---@internal
---Build the once-only `finish(reason, files, spots)` for one run. The first call
---fires `User ReplacerDone`; later calls (a window close after the apply, a
---callback reached twice) are ignored. Fired on a scheduled tick so the code
---that ended the run unwinds first.
---@param request RP_Request
---@return fun(reason: string, files?: integer, spots?: integer)
local function make_finish(request)
  local ended = false
  return function(reason, files, spots)
    if ended then
      return
    end
    ended = true
    files, spots = files or 0, spots or 0
    local data = {
      reason = reason,
      applied = spots > 0,
      files = files,
      spots = spots,
      old = request.old or "",
      new = request.new or "",
    }
    vim.schedule(function()
      pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = M.DONE_EVENT,
        modeline = false,
        data = data,
      })
    end)
  end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

---@internal
--- Append every element of `src` onto `dst` (in place).
---@param dst string[]
---@param src string[]|nil
local function extend(dst, src)
  local list = src or {}
  for i = 1, #list do
    dst[#dst + 1] = list[i]
  end
end

---@internal
--- Build the effective per-run config from a request (overrides + filters + range).
---@param request RP_Request
---@return RP_Config
local function effective_cfg(request)
  local cfg = cfg_mod.resolve(request.overrides or {})
  extend(cfg.file_types, request.filters and request.filters.file_types)
  extend(cfg.globs, request.filters and request.filters.globs)
  extend(cfg.exclude, request.filters and request.filters.exclude)
  cfg._line_range = request.line_range
  cfg._old_len = cfg.literal and #request.old or 0
  cfg._changed_only = request.overrides and request.overrides.changed_only
  cfg._also_rename_file = request.overrides and request.overrides.also_rename_file
  return cfg
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

--- Execute a replace workflow.
--- Accepts a structured RP_Request, or the legacy positional form
--- run(old, new_text, scope, all) for backward compatibility.
---@param request RP_Request|string
---@param new_text? string
---@param scope? string
---@param all? boolean
---@return nil
function M.run(request, new_text, scope, all)
  if type(request) == "string" then
    request = {
      old = request,
      new = new_text or "",
      scope = scope or "",
      all = all and true or false,
      dry = false,
      export = nil,
      line_range = nil,
      overrides = {},
      filters = { file_types = {}, globs = {}, exclude = {} },
    }
  end
  ---@cast request RP_Request

  local cfg = effective_cfg(request)
  local finish = make_finish(request)

  -- 1) Resolve scope (fall back to configured default when none was given).
  local scope_tok = (request.scope ~= "" and request.scope) or cfg.default_scope or "%"
  local roots, single_file = cmd_mod.resolve_scope(scope_tok)
  if not roots or #roots == 0 then
    finish("no_scope")
    return -- resolve_scope already notified on edge cases
  end
  ---@cast roots string[]

  -- Collection is wrapped so both paths -- plain scope and --changed, whose
  -- git lookup is asynchronous now -- reach it the same way.
  ---@param collect_roots string[]
  ---@param collect_single boolean
  local function collect(collect_roots, collect_single)
    -- 2) Collect matches asynchronously (ripgrep is non-blocking; vimgrep is sync),
    --    then 3) dispatch to plan / ALL / picker inside the callback.
    local function on_collected(items, err)
      if err then
        notify.error(require("replacer.error").format(err))
        finish("error")
        return
      end
      if not items or #items == 0 then
        local messages = require("replacer.messages")
        messages.info(cfg, messages.fmt(cfg, "no_matches"))
        finish("no_matches")
        return
      end
      -- Optional post-collection filter (e.g. :Surround skipping already-wrapped
      -- matches). Applied here so plan/ALL/picker all see the same reduced set.
      if request.filter then
        local kept = vim.tbl_filter(request.filter, items)
        if #kept == 0 then
          notify.info(request.filter_empty_msg or "no matches left after filtering")
          finish("no_matches")
          return
        end
        items = kept
      end
      dispatch.dispatch(request, cfg, collect_single, items, finish)
    end

    if cfg.stream then
      -- --stream: incremental ripgrep parsing for smoother, filter-aware
      -- progress as matches are found. The picker itself still only opens
      -- once collection finishes (on_batch is reserved for future live
      -- picker fill) -- see rg.collect_streaming's docstring.
      rg.collect_streaming(request.old, collect_roots, cfg, function(_new_batch) end, on_collected)
    else
      rg.collect_async(request.old, collect_roots, cfg, on_collected)
    end
  end

  -- 1b) --changed: restrict roots to git changed/staged/untracked files,
  -- intersected with the resolved scope (a specific dir/file still narrows
  -- the git file list, it doesn't widen it).
  if cfg._changed_only then
    local gitfiles = require("replacer.gitfiles")
    local start_dir = single_file and vim.fn.fnamemodify(roots[1], ":h") or roots[1]
    gitfiles.list(start_dir, cfg._changed_only, function(files, top, failed_kinds)
      if not top then
        notify.warn("--changed: not inside a git repository")
        finish("no_scope")
        return
      end
      if failed_kinds then
        notify.warn(
          "--changed: git query failed for "
            .. table.concat(failed_kinds, ", ")
            .. " — results may be incomplete"
        )
      end
      -- git always reports forward-slash paths regardless of OS; normalize
      -- the scope prefix the same way before comparing (fnamemodify keeps
      -- native backslashes on Windows).
      local prefix = vim.fn.fnamemodify(roots[1], ":p"):gsub("\\", "/"):gsub("/+$", "")
      local filtered = {}
      for _, f in ipairs(files) do
        if single_file then
          if f == prefix then
            filtered[#filtered + 1] = f
          end
        elseif f == prefix or f:sub(1, #prefix + 1) == prefix .. "/" then
          filtered[#filtered + 1] = f
        end
      end
      if #filtered == 0 then
        notify.info("--changed: no changed files match the current scope")
        finish("no_matches")
        return
      end
      collect(filtered, false)
    end)
    return
  end

  collect(roots, single_file)
end

return M
