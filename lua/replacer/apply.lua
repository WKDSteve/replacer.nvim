---@module 'replacer.apply'
--- Replacement application and edit computation.
---
--- Two layers:
---   - `compute_file_edits` is a PURE function: given a file's lines and the
---     matches for that file, it returns the rewritten lines plus counts. It has
---     no side effects and is unit-testable. It backs dry-run and patch export.
---   - `apply_matches` performs the real, side-effecting buffer edits with
---     defensive guards (handle validation + pcall) and optional writes.
---
--- All offsets are byte-based (col0), consistent with the collectors.

local Err = require("replacer.error")
local notify = require("replacer.util.notify")

-- Soft dependency: the apply phase over a wide scope (`cwd`/dir + --all) loads
-- and rewrites every matched file, which blocks the UI with no feedback the
-- same way the search used to. `rg.lua` already reports search progress through
-- this module; mirror it here. No-op when lib.nvim is absent.
local ok_progress, progress_mod = pcall(require, "lib.nvim.progress")

local M = {}

--- Files applied per event-loop tick in the async path. Smaller than the
--- search chunk size (`rg.VIMGREP_CHUNK_SIZE`) because each file here costs a
--- `bufadd` + `bufload` + `:write`, not just a read. A match set that fits in
--- one chunk is applied synchronously (no scheduling, no indicator) so a
--- single-buffer replace keeps its exact prior timing.
local APPLY_CHUNK_SIZE = 10

--------------------------------------------------------------------------------
-- Per-match replacement text (cfg-driven transforms)
--------------------------------------------------------------------------------

---@internal
--- When `old_text` has leading/trailing whitespace (e.g. matched via a regex
--- like `\s*foo\s*`), sandwich `new_text` between that same whitespace instead
--- of letting it clobber the surrounding formatting. A no-op when `old_text`
--- is empty or pure whitespace (no "core" token to preserve around).
---@param old_text string
---@param new_text string
---@return string
local function wrap_with_original_whitespace(old_text, new_text)
  if old_text == "" or not old_text:match("%S") then
    return new_text
  end
  local leading = old_text:match("^%s*") or ""
  local trailing = old_text:match("%s*$") or ""
  return leading .. new_text .. trailing
end

---@internal
--- Resolve the effective replacement text for one match, applying optional
--- cfg-driven transforms on top of the plain `new_text`, in order:
---   1. backreferences: in regex mode, expand \0-\9 against `old_pattern`
---      matched on the match's own source `line`.
---   2. case_preserve: re-case the (possibly backref-expanded) new_text to
---      match old_text's case style (foo->bar, Foo->Bar, FOO->BAR, …).
---   3. preserve_whitespace: re-wrap new_text in old_text's leading/trailing ws.
--- Case detection runs on the "core" of old_text (trimmed of whitespace) so
--- the transforms compose correctly when several are enabled together. A
--- nil/plain cfg (or every transform disabled/inapplicable) returns
--- `new_text` unchanged, so existing callers keep their exact prior behavior.
---@param old_text string
---@param new_text string
---@param cfg RP_Config|nil
---@param old_pattern string|nil    # the searched pattern; needed for \0-\9 in regex mode
---@param line string|nil           # the match's own source line; needed for \0-\9
---@return string
local function effective_new_text(old_text, new_text, cfg, old_pattern, line)
  if cfg and cfg.literal == false and old_pattern and line then
    local regex = require("replacer.regex")
    if regex.has_backrefs(new_text) then
      new_text = regex.expand_backrefs(new_text, line, old_pattern)
    end
  end
  if cfg and cfg.case_preserve then
    local casing = require("replacer.casing")
    local core = old_text:match("^%s*(.-)%s*$")
    new_text = casing.apply(new_text, casing.detect(core))
  end
  if cfg and cfg.preserve_whitespace then
    new_text = wrap_with_original_whitespace(old_text, new_text)
  end
  return new_text
end

--------------------------------------------------------------------------------
-- Pure edit computation
--------------------------------------------------------------------------------

--- Apply `new_text` at every match position on a copy of `lines`.
--- Matches are applied right-to-left per line so earlier byte offsets stay valid.
--- A match whose recorded text no longer sits at its offset is skipped (stale).
---@param lines string[]            # 1-based file content
---@param matches RP_Match[]        # matches belonging to this file
---@param new_text string
---@param cfg RP_Config|nil         # optional; enables preserve_whitespace/case_preserve/backrefs
---@param old_pattern string|nil    # the searched pattern; needed for \0-\9 in regex mode
---@return string[] new_lines, integer spots, integer skipped
function M.compute_file_edits(lines, matches, new_text, cfg, old_pattern)
  -- Group matches per line (parallel count map avoids recomputing #t per push).
  ---@type table<integer, RP_Match[]>
  local by_lnum = {}
  local counts = {}
  for i = 1, #matches do
    local it = matches[i]
    local key = it.lnum
    local t = by_lnum[key]
    if not t then
      t = {}
      by_lnum[key] = t
    end
    local c = (counts[key] or 0) + 1
    counts[key] = c
    t[c] = it
  end

  -- Copy lines (do not mutate caller input).
  local new_lines = {}
  for i = 1, #lines do
    new_lines[i] = lines[i]
  end

  local spots, skipped = 0, 0
  for lnum, list in pairs(by_lnum) do
    table.sort(list, function(a, b)
      return a.col0 > b.col0
    end)
    local line = new_lines[lnum]
    if type(line) == "string" then
      for _, it in ipairs(list) do
        local old_text = it.old or ""
        local s, e = it.col0, it.col0 + #old_text
        local seg = line:sub(s + 1, e)
        if seg == old_text then
          local repl = effective_new_text(old_text, new_text, cfg, old_pattern, it.line)
          line = line:sub(1, s) .. repl .. line:sub(e + 1)
          spots = spots + 1
        else
          skipped = skipped + 1
        end
      end
      new_lines[lnum] = line
    else
      skipped = skipped + #list
    end
  end

  return new_lines, spots, skipped
end

--------------------------------------------------------------------------------
-- Real buffer application (side-effecting, guarded)
--------------------------------------------------------------------------------

---@internal
--- Group matches by file path.
---@param items RP_Match[]
---@return table<string, RP_Match[]>
---@see replacer.export.group_by_path
local function group_by_path(items)
  local by_path = {}
  local counts = {}
  for i = 1, #items do
    local it = items[i]
    local key = it.path
    local t = by_path[key]
    if not t then
      t = {}
      by_path[key] = t
    end
    local c = (counts[key] or 0) + 1
    counts[key] = c
    t[c] = it
  end
  return by_path
end

---@internal
--- Sniff the first 512 bytes of `path` for a NUL byte (the classic
--- binary-file heuristic used by grep/git/etc).
---@param path string
---@return boolean
local function is_binary_file(path)
  local ok, fh = pcall(io.open, path, "rb")
  if not ok or not fh then
    return false
  end
  local chunk = fh:read(512)
  fh:close()
  return chunk ~= nil and chunk:find("\0", 1, true) ~= nil
end

---@internal
--- When cfg.safe_mode is set, decide whether `path` should be skipped
--- (read-only / oversized / binary) instead of edited. Returns nil to
--- proceed, or a short human-readable reason to skip.
---@param path string
---@param cfg RP_Config
---@return string|nil reason
local function safe_mode_skip_reason(path, cfg)
  if vim.fn.filewritable(path) == 0 then
    return "read-only"
  end
  if cfg.max_file_size and cfg.max_file_size > 0 then
    local size = vim.fn.getfsize(path)
    if size > cfg.max_file_size then
      return "too large"
    end
  end
  if cfg.skip_binary ~= false and is_binary_file(path) then
    return "binary"
  end
  return nil
end

---@internal
--- Apply every match for one file, bottom-up, with guards. Extracted so the
--- sync and chunked-async drivers below share exactly one implementation.
---@param path string
---@param list RP_Match[]
---@param old string
---@param new_text string
---@param write_changes boolean
---@param cfg RP_Config|nil
---@return integer counted   # 1 when this file ends up modified (written or counted), else 0
---@return integer spots     # spots applied in this file
---@return integer skipped   # matches skipped in this file (stale / safe_mode / veto)
---@return RP_Error|nil err
local function apply_one(path, list, old, new_text, write_changes, cfg)
  if cfg and cfg.safe_mode then
    local reason = safe_mode_skip_reason(path, cfg)
    if reason then
      notify.warn(
        string.format("safe_mode: skipping %s (%s)", vim.fn.fnamemodify(path, ":."), reason)
      )
      return 0, 0, #list, nil
    end
  end

  local proceed = require("replacer.hooks").run(
    "before_apply",
    { path = path, matches = list, new_text = new_text },
    cfg
  )
  if not proceed then
    return 0, 0, #list, nil
  end

  -- Resolve & load the buffer defensively.
  local ok_add, bufnr = pcall(vim.fn.bufadd, path)
  if not ok_add or type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0, 0, 0, Err.write_error("cannot open buffer for " .. path)
  end
  pcall(vim.fn.bufload, bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return 0, 0, 0, Err.write_error("cannot load " .. path)
  end

  -- Bottom-up so earlier edits do not shift later offsets.
  table.sort(list, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum > b.lnum
    end
    return a.col0 > b.col0
  end)

  local skipped, file_spots = 0, 0
  for i = 1, #list do
    local it = list[i]
    local row = it.lnum - 1
    local ok_line, line = pcall(function()
      return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    end)
    line = (ok_line and line) or ""
    local old_text = it.old or ""
    local s, e = it.col0, it.col0 + #old_text
    local seg = line:sub(s + 1, e)

    if seg == old_text then
      local repl = effective_new_text(old_text, new_text, cfg, old, line)
      local ok_set = pcall(vim.api.nvim_buf_set_text, bufnr, row, s, row, e, { repl })
      if ok_set then
        file_spots = file_spots + 1
      else
        skipped = skipped + 1
      end
    else
      skipped = skipped + 1
    end
  end

  if skipped > 0 and skipped >= #list * 0.5 then
    notify.warn(
      string.format(
        "%s: %d/%d spot(s) skipped — buffer may have changed; re-run :Replace",
        vim.fn.fnamemodify(path, ":."),
        skipped,
        #list
      )
    )
  end

  require("replacer.hooks").run(
    "after_apply",
    { path = path, spots = file_spots, skipped = skipped },
    cfg
  )

  -- Write or count modified files.
  if vim.bo[bufnr].modified then
    if write_changes then
      require("replacer.hooks").run("before_write", { path = path, bufnr = bufnr }, cfg)
      local ok_write = pcall(function()
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("silent noautocmd write")
        end)
      end)
      require("replacer.hooks").run(
        "after_write",
        { path = path, bufnr = bufnr, ok = ok_write },
        cfg
      )
      if ok_write then
        return 1, file_spots, skipped, nil
      end
      return 0,
        file_spots,
        skipped,
        Err.write_error("failed to write " .. vim.fn.fnamemodify(path, ":."))
    end
    return 1, file_spots, skipped, nil
  end

  return 0, file_spots, skipped, nil
end

--- Apply replacements to the matched buffers, bottom-up, with guards.
---
--- When `on_done` is given and the match set spans more than one chunk, files
--- are applied `APPLY_CHUNK_SIZE` per event-loop tick with a `lib.nvim.progress`
--- indicator, and the totals are delivered through `on_done` instead of the
--- return values (a wide `cwd`/dir replace loads and rewrites hundreds of
--- files — doing that in one synchronous loop freezes the editor). A set that
--- fits in one chunk, and every caller that passes no `on_done` (tests, patch
--- export), keeps the fully synchronous path and its return values unchanged.
---@param items RP_Match[]
---@param old string                # the searched pattern; used for \0-\9 backrefs in regex mode
---@param new_text string
---@param write_changes boolean
---@param cfg RP_Config|nil
---@param on_done? fun(files: integer, spots: integer, errors: RP_Error[])
---@param on_error? fun(err: string) # A chunk raised: called instead of `on_done` (async path only).
---@return integer files, integer spots, RP_Error[] errors
---@see replacer.lsp_rename.try_rename_batch
function M.apply_matches(items, old, new_text, write_changes, cfg, on_done, on_error)
  local by_path = group_by_path(items)

  ---@type string[]
  local paths = {}
  for path in pairs(by_path) do
    paths[#paths + 1] = path
  end
  table.sort(paths) -- deterministic order (matches replacer.perfile)

  local files, spots, skipped_total = 0, 0, 0
  ---@type RP_Error[]
  local errors = {}

  local function tally(counted, s, sk, err)
    files = files + counted
    spots = spots + s
    skipped_total = skipped_total + sk
    if err then
      errors[#errors + 1] = err
    end
  end

  local function finish_reporting()
    if skipped_total > 0 then
      notify.warn(string.format("%d match(es) skipped due to changed content.", skipped_total))
    end
    for i = 1, #errors do
      notify.error(Err.format(errors[i]))
    end
  end

  -- Synchronous path: no callback, or a set small enough that scheduling it
  -- would only add latency with no visible indicator (150ms delay guard).
  if type(on_done) ~= "function" or #paths <= APPLY_CHUNK_SIZE then
    for _, path in ipairs(paths) do
      tally(apply_one(path, by_path[path], old, new_text, write_changes, cfg))
    end
    finish_reporting()
    if on_done then
      on_done(files, spots, errors)
    end
    return files, spots, errors
  end

  -- Chunked async path.
  local h = ok_progress
      and progress_mod.create({
        title = "[replacer]",
        style = (cfg and cfg.progress_style) or "auto",
      })
    or nil
  local total = #paths
  local i = 0
  local run_step -- the guarded `step`, set below; later chunks are scheduled through it
  local delivered = false -- `on_done` was reached (it may itself be what raised)

  local function deliver()
    finish_reporting()
    delivered = true
    on_done(files, spots, errors)
  end

  local function step()
    -- A user-requested cancel stops scheduling more work; whatever was already
    -- written stays written (there is no transaction to roll back), and the
    -- totals so far are still reported.
    if h and h.cancelled then
      deliver()
      return
    end

    local last = math.min(i + APPLY_CHUNK_SIZE, total)
    for j = i + 1, last do
      tally(apply_one(paths[j], by_path[paths[j]], old, new_text, write_changes, cfg))
    end
    i = last

    if h then
      h:update({ text = "applying replacements…", current = i, total = total })
    end

    if i < total then
      vim.schedule(run_step)
      return
    end

    if h then
      h:finish(string.format("%d file(s), %d spot(s)", files, spots))
    end
    deliver()
  end

  -- A chunk that raises on a later tick would never reach `on_done`, and the run
  -- would have no end: report it, close the indicator, and hand it to `on_error`
  -- (or end with the totals so far when the caller gave none, unless `on_done`
  -- itself raised: it is never called twice).
  local function guarded_step()
    local ok, err = xpcall(step, debug.traceback)
    if ok then
      return
    end
    if h then
      pcall(h.finish, h, "failed")
    end
    notify.error("apply failed: " .. tostring(err))
    if on_error then
      on_error(err)
    elseif not delivered then
      delivered = true
      on_done(files, spots, errors)
    end
  end
  run_step = guarded_step

  guarded_step()
  return files, spots, errors -- best-effort snapshot; async callers use on_done
end

return M
