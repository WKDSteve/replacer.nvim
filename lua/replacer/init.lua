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
local apply = require("replacer.apply")
local export = require("replacer.export")
local common = require("replacer.pickers.common")
local cmd_mod = require("replacer.command")
local notify = require("replacer.util.notify")
local confirm = require("ui.kit.confirm")

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
--- Resolve the picker UI engine, honoring "auto" (fzf-lua preferred, else telescope).
---@param cfg RP_Config
---@return "fzf"|"telescope"|nil
local function pick_picker(cfg)
  local e = cfg.engine or "auto"
  if e == "fzf" or e == "telescope" then
    ---@cast e "fzf"|"telescope"
    return e
  end
  if pcall(require, "fzf-lua") then
    return "fzf"
  end
  if pcall(require, "telescope") then
    return "telescope"
  end
  return nil
end

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

---@internal
--- Open a read-only scratch split showing diff text.
---@param patch string
local function show_diff_scratch(patch)
  if patch == "" then
    return
  end
  pcall(function()
    vim.cmd("botright new")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(patch, "\n", { plain = true }))
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "diff"
    vim.bo[buf].modifiable = false
    pcall(vim.api.nvim_buf_set_name, buf, "[replacer-plan]")
  end)
end

---@internal
--- Dry-run / export path: compute the plan, report stats, optionally export, preview.
---@param request RP_Request
---@param items RP_Match[]
---@param cfg RP_Config
---@return nil
local function plan(request, items, cfg)
  local results, totals = export.build_results(items, request.new, cfg, request.old)
  notify.info(
    string.format(
      "dry-run: %d spot(s) in %d file(s)%s%s — no changes written",
      totals.spots,
      totals.files,
      totals.skipped > 0 and string.format(" (%d skipped)", totals.skipped) or "",
      totals.unreadable > 0
          and string.format(
            " (%d file(s) could not be read — permissions or vanished since scan)",
            totals.unreadable
          )
        or ""
    )
  )

  if request.export and request.export ~= "" then
    local ok, err = export.write_export(request.export, results, request.new)
    if ok then
      notify.info("plan exported to " .. request.export)
    else
      notify.error(err or "export failed")
    end
  end

  show_diff_scratch(export.build_patch(results))
end

---@internal
--- Handle collected matches: plan (dry/export), apply ALL, or open the picker.
---@param request RP_Request
---@param cfg RP_Config
---@param single_file boolean
---@param items RP_Match[]
---@param finish fun(reason: string, files?: integer, spots?: integer)
---@return nil
local function dispatch(request, cfg, single_file, items, finish)
  -- Plan-only path (dry-run / export). Never writes.
  if request.dry or (request.export and request.export ~= "") then
    plan(request, items, cfg)
    finish("plan")
    return
  end

  -- Everything this run wrote, summed over every apply (ALL, per-file, picker
  -- actions, reopened pickers): reported by the end signal.
  local sum_files, sum_spots = 0, 0
  local function finish_applied()
    finish(sum_spots > 0 and "applied" or "cancelled", sum_files, sum_spots)
  end

  -- Quickfix/loclist export: send the raw match list and open it. Never writes.
  if request.to_quickfix or request.to_loclist then
    export.send_to_quickfix(items, request.to_loclist == true)
    notify.info(
      string.format(
        "%d match(es) sent to %s",
        #items,
        request.to_loclist and "the location list" or "quickfix"
      )
    )
    finish("quickfix")
    return
  end

  -- Applier closure shared by ALL mode, per-file confirm, and the pickers.
  -- Records history for every real apply (never for dry-run/export/
  -- quickfix, which don't reach here); a history-write failure must never
  -- affect the apply itself, hence the pcall.
  --- Apply `chosen` and report `(files, spots)`.
  ---
  --- `apply_matches` runs the wide-scope apply asynchronously (chunked, with a
  --- progress indicator), so the result is delivered through `on_result`
  --- rather than returned. A single-buffer replace still finishes within this
  --- call — `on_result` just fires synchronously in that case. The synchronous
  --- return value is kept for the few callers (and tests) that ignore
  --- `on_result` and only ever apply a handful of files.
  ---@param chosen RP_Match[]
  ---@param replacement string
  ---@param write_changes boolean
  ---@param on_result? fun(files: integer, spots: integer)
  ---@return integer files, integer spots
  local function apply_func(chosen, replacement, write_changes, on_result)
    -- Soft LSP integration: try an LSP-driven rename first for eligible
    -- (identifier-shaped) matches; only whatever falls back goes through
    -- the normal plain-text apply below. Guarded so any failure here just
    -- means nothing was LSP-renamed, never a lost edit.
    local lsp_count = 0
    local to_apply = chosen
    if cfg.lsp then
      local ok_lsp, lsp_renamed, fallback =
        pcall(require("replacer.lsp_rename").try_rename_batch, chosen, replacement)
      if ok_lsp and lsp_renamed and fallback then
        lsp_count = #lsp_renamed
        to_apply = fallback
      end
    end

    local final_files, final_spots = 0, 0
    local function settled(files, spots)
      spots = spots + lsp_count
      final_files, final_spots = files, spots
      sum_files, sum_spots = sum_files + files, sum_spots + spots
      pcall(function()
        require("replacer.history").add(request, { files = files, spots = spots })
      end)
      -- --also-rename-file: single-file scope only (never a directory tree —
      -- that's :ReplaceFNames' job). Guarded so a rename-assist failure never
      -- affects the content apply it followed.
      if cfg._also_rename_file and single_file and files > 0 and chosen[1] then
        pcall(function()
          require("replacer.rename_assist").maybe_rename(
            chosen[1].path,
            request.old,
            replacement,
            cfg
          )
        end)
      end
      if on_result then
        on_result(files, spots)
      end
    end

    apply.apply_matches(to_apply, request.old, replacement, write_changes, cfg, settled)
    return final_files, final_spots
  end

  -- Interactive picker over `pick_items` (auto-detected when engine = "auto").
  -- Shared by the default interactive path and --confirm-per-file's "Only
  -- some" choice, which scopes it to a single file's matches and passes
  -- `on_close` to hear when that picker session is over.
  ---@param pick_items RP_Match[]
  ---@param on_close? fun()
  local function open_picker(pick_items, on_close)
    local engine = pick_picker(cfg)
    if not engine then
      notify.error("no picker available — install fzf-lua or telescope.nvim")
      if on_close then
        vim.schedule(on_close)
      else
        finish("no_picker")
      end
      return
    end
    -- The top-level picker session (no caller-supplied `on_close`) ends the run.
    local rstate = { on_close = on_close or finish_applied }
    if engine == "fzf" then
      require("replacer.pickers.fzf").run(
        request.old,
        pick_items,
        request.new,
        cfg,
        apply_func,
        rstate
      )
    else
      require("replacer.pickers.telescope").run(pick_items, request.new, cfg, apply_func, rstate)
    end
  end

  -- Non-interactive ALL.
  if request.all then
    if cfg.checkpoint then
      local ok_cp, id = pcall(function()
        return require("replacer.checkpoint").create(items)
      end)
      if ok_cp and id then
        notify.info(string.format("checkpoint '%s' created — :ReplaceUndo to revert", id))
      else
        notify.warn("failed to create a checkpoint — proceeding without one")
      end
    end

    if cfg.confirm_per_file then
      local perfile = require("replacer.perfile")
      perfile.run(
        items,
        request.new,
        cfg.write_changes,
        apply_func,
        open_picker,
        function(files, spots)
          common.notify_result(files, spots, cfg)
          finish_applied()
        end
      )
      return
    end

    local fileset = {}
    for _, it in ipairs(items) do
      fileset[it.path] = true
    end
    local filecount = 0
    for _ in pairs(fileset) do
      filecount = filecount + 1
    end

    local wide = (not single_file) and cfg.confirm_wide_scope
    if cfg.confirm_all or wide then
      local messages = require("replacer.messages")
      local msg = messages.fmt(cfg, "confirm_all", #items, filecount)
      confirm.open({
        question = msg,
        on_answer = function(yes)
          if not yes then
            messages.info(cfg, messages.fmt(cfg, "cancelled"))
            finish("cancelled")
            return
          end
          apply_func(items, request.new, cfg.write_changes, function(files, spots)
            common.notify_result(files, spots, cfg)
            finish_applied()
          end)
        end,
      })
      return
    end

    apply_func(items, request.new, cfg.write_changes, function(files, spots)
      common.notify_result(files, spots, cfg)
      finish_applied()
    end)
    return
  end

  open_picker(items)
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
      dispatch(request, cfg, collect_single, items, finish)
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
