---@module 'replacer.dispatch'
--- What `replacer.run` does with the collected matches: write a plan (dry run / export),
--- send them to quickfix, apply ALL (with checkpoint / per-file / confirm), or open the picker.
--- Split out of `init.lua`; the apply path and the picker opener are built by two small
--- factories that share one explicit `tally` instead of closure upvalues.
---
---@see replacer

local apply = require("replacer.apply")
local export = require("replacer.export")
local common = require("replacer.pickers.common")
local notify = require("replacer.util.notify")

local M = {}

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

---@class RP_DispatchTally
---@field files integer # Files written by every apply of this run so far.
---@field spots integer # Spots written by every apply of this run so far.

---@internal
--- Build the applier shared by ALL mode, per-file confirm and the pickers.
--- Records history for every real apply (never for dry-run/export/quickfix, which
--- do not reach here); a history-write failure must never affect the apply itself,
--- hence the pcall. Every apply adds into `tally`, which the end signal reports.
---
--- The returned function applies `chosen` and reports `(files, spots)`. The
--- wide-scope apply (`apply_matches`) runs asynchronously (chunked, with a progress
--- indicator), so the result is delivered through `on_result` rather than returned;
--- a single-buffer replace still finishes within the call, so `on_result` fires
--- synchronously then. The synchronous return value is kept for the few callers
--- (and tests) that ignore `on_result` and only ever apply a handful of files.
---@param request RP_Request
---@param cfg RP_Config
---@param single_file boolean
---@param tally RP_DispatchTally
---@return fun(chosen: RP_Match[], replacement: string, write_changes: boolean, on_result?: fun(files: integer, spots: integer)): integer, integer
local function make_applier(request, cfg, single_file, tally)
  return function(chosen, replacement, write_changes, on_result)
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
      tally.files, tally.spots = tally.files + files, tally.spots + spots
      pcall(function()
        require("replacer.history").add(request, { files = files, spots = spots })
      end)
      -- --also-rename-file: single-file scope only (never a directory tree:
      -- that is the job of :ReplaceFNames). Guarded so a rename-assist failure never
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
end

---@internal
--- Build the interactive picker opener over a list of matches (engine auto-detected
--- when `cfg.engine = "auto"`). Shared by the default interactive path and
--- --confirm-per-file's "Only some" choice, which scopes it to a single file's matches
--- and passes `on_close` to hear when that picker session is over.
---@param request RP_Request
---@param cfg RP_Config
---@param apply_func function # From `make_applier`.
---@param finish fun(reason: string, files?: integer, spots?: integer)
---@param finish_applied fun() # Ends the run with the tally; the top-level session's default `on_close`.
---@return fun(pick_items: RP_Match[], on_close?: fun())
local function make_picker_opener(request, cfg, apply_func, finish, finish_applied)
  return function(pick_items, on_close)
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
end

---@class RP_AllContext
---@field request RP_Request
---@field cfg RP_Config
---@field single_file boolean
---@field items RP_Match[]
---@field finish fun(reason: string, files?: integer, spots?: integer)
---@field finish_applied fun()
---@field apply_func function # From `make_applier`.
---@field open_picker function # From `make_picker_opener`.

---@internal
--- ALL mode: optional checkpoint, then per-file confirm, confirm-all / wide-scope
--- confirm, or a straight apply of every match.
---@param ctx RP_AllContext
local function apply_all(ctx)
  local request, cfg, items = ctx.request, ctx.cfg, ctx.items
  local finish, finish_applied, apply_func = ctx.finish, ctx.finish_applied, ctx.apply_func

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

  local function applied(files, spots)
    common.notify_result(files, spots, cfg)
    finish_applied()
  end

  if cfg.confirm_per_file then
    require("replacer.perfile").run(
      items,
      request.new,
      cfg.write_changes,
      apply_func,
      ctx.open_picker,
      applied
    )
    return
  end

  local fileset, filecount = {}, 0
  for _, it in ipairs(items) do
    if not fileset[it.path] then
      fileset[it.path] = true
      filecount = filecount + 1
    end
  end

  local wide = (not ctx.single_file) and cfg.confirm_wide_scope
  if cfg.confirm_all or wide then
    local messages = require("replacer.messages")
    -- Resolved per call: the confirm float is replaced in specs after `replacer` loaded.
    require("ui.kit.confirm").open({
      question = messages.fmt(cfg, "confirm_all", #items, filecount),
      on_answer = function(yes)
        if not yes then
          messages.info(cfg, messages.fmt(cfg, "cancelled"))
          finish("cancelled")
          return
        end
        apply_func(items, request.new, cfg.write_changes, applied)
      end,
    })
    return
  end

  apply_func(items, request.new, cfg.write_changes, applied)
end

---@internal
--- Handle collected matches: plan (dry/export), quickfix, apply ALL, or open the picker.
---@param request RP_Request
---@param cfg RP_Config
---@param single_file boolean
---@param items RP_Match[]
---@param finish fun(reason: string, files?: integer, spots?: integer)
---@return nil
function M.dispatch(request, cfg, single_file, items, finish)
  -- Plan-only path (dry-run / export). Never writes.
  if request.dry or (request.export and request.export ~= "") then
    plan(request, items, cfg)
    finish("plan")
    return
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

  -- Everything this run wrote, summed over every apply (ALL, per-file, picker
  -- actions, reopened pickers): reported by the end signal.
  ---@type RP_DispatchTally
  local tally = { files = 0, spots = 0 }
  local function finish_applied()
    finish(tally.spots > 0 and "applied" or "cancelled", tally.files, tally.spots)
  end

  local apply_func = make_applier(request, cfg, single_file, tally)
  local open_picker = make_picker_opener(request, cfg, apply_func, finish, finish_applied)

  if request.all then
    apply_all({
      request = request,
      cfg = cfg,
      single_file = single_file,
      items = items,
      finish = finish,
      finish_applied = finish_applied,
      apply_func = apply_func,
      open_picker = open_picker,
    })
    return
  end

  open_picker(items)
end

return M
