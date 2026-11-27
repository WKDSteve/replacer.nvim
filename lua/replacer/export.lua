---@module 'replacer.export'
--- Dry-run planning and export of planned replacements.
---
--- Builds an in-memory plan (no buffer writes) from matches, then renders it as:
---   - a unified diff (git-applyable), or
---   - a JSON document (machine-readable for review tooling).
---
--- Reused by :Replace --dry and :Replace --export=<path>.

local encoding = require("replacer.encoding")
local list = require("lib.nvim.ui.list")

local IS_WIN = vim.fn.has("win32") == 1

local M = {}

--------------------------------------------------------------------------------
-- IO helpers
--------------------------------------------------------------------------------

---@internal
--- Read a file's lines, preferring a loaded buffer's content when available
--- (so a dry-run reflects unsaved edits just like the real apply path). The
--- raw io.open fallback strips a leading BOM and trailing \r so the plan
--- matches what the buffer-backed apply path would actually see/write.
---@param path string
---@return string[] lines, boolean ok
local function read_lines(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), true
  end
  local ok, fh = pcall(io.open, path, "r")
  if not ok or not fh then
    return {}, false
  end
  local lines = {}
  local n = 0
  for line in fh:lines() do
    n = n + 1
    if n == 1 then
      line = encoding.strip_bom(line)
    end
    lines[n] = encoding.strip_cr(line)
  end
  fh:close()
  return lines, true
end

---@internal
---@param items RP_Match[]
---@return table<string, RP_Match[]>
---@see replacer.apply.group_by_path
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

--------------------------------------------------------------------------------
-- Plan construction
--------------------------------------------------------------------------------

---@class RP_FileResult
---@field path string
---@field old_lines string[]
---@field new_lines string[]
---@field spots integer
---@field skipped integer
---@field matches RP_Match[]

---@class RP_PlanTotals
---@field files integer
---@field spots integer
---@field skipped integer
---@field unreadable integer  # files whose matches were counted as skipped only because the file itself couldn't be read (permissions, vanished since scan) — see ERR-11 note on `read_lines`

--- Build the change plan for `items` replaced with `new_text`.
--- Only files with at least one applied spot are included in `results`.
---@param items RP_Match[]
---@param new_text string
---@param cfg RP_Config|nil       # optional; enables preserve_whitespace/case_preserve when set
---@param old_pattern string|nil  # the searched pattern; needed for \0-\9 in regex mode
---@return RP_FileResult[] results, RP_PlanTotals totals
function M.build_results(items, new_text, cfg, old_pattern)
  local apply = require("replacer.apply")
  local by_path = group_by_path(items)

  ---@type RP_FileResult[]
  local results = {}
  local totals = { files = 0, spots = 0, skipped = 0, unreadable = 0 }

  for path, path_matches in pairs(by_path) do
    -- ERR-11: `read_lines`'s second value distinguishes "file has no lines"
    -- from "file could not be read" -- an unreadable file must not be
    -- folded into the generic "stale match" skip count with no trace of
    -- the real cause (permissions, a vanished file).
    local old_lines, read_ok = read_lines(path)
    if not read_ok then
      totals.unreadable = totals.unreadable + 1
    end
    local new_lines, spots, skipped =
      apply.compute_file_edits(old_lines, path_matches, new_text, cfg, old_pattern)
    totals.spots = totals.spots + spots
    totals.skipped = totals.skipped + skipped
    if spots > 0 then
      totals.files = totals.files + 1
      results[#results + 1] = {
        path = path,
        old_lines = old_lines,
        new_lines = new_lines,
        spots = spots,
        skipped = skipped,
        matches = path_matches,
      }
    end
  end

  table.sort(results, function(a, b)
    return a.path < b.path
  end)
  return results, totals
end

--------------------------------------------------------------------------------
-- Renderers
--------------------------------------------------------------------------------

---@internal
--- `vim.text.diff` only exists from Neovim 0.11; `vim.diff` is the same
--- function under its pre-0.11 name and is still present on 0.9/0.10 (the
--- plugin's declared minimum).
---@param a string
---@param b string
---@return string|boolean|nil
local function text_diff(a, b)
  local fn = (vim.text and vim.text.diff) or vim.diff
  if not fn then
    return nil
  end
  return fn(a, b, { result_type = "unified", ctxlen = 3 })
end

--- Render a unified diff (git-applyable) for the plan.
---@param results RP_FileResult[]
---@return string
function M.build_patch(results)
  local out = {} ---@type string[]
  for _, r in ipairs(results) do
    local a = table.concat(r.old_lines, "\n") .. "\n"
    local b = table.concat(r.new_lines, "\n") .. "\n"
    local hunks = text_diff(a, b)
    if type(hunks) == "string" and hunks ~= "" then
      local rel = vim.fn.fnamemodify(r.path, ":.")
      -- git reads only "/" as a separator in a patch; on Windows `:.` keeps native backslashes
      -- (elsewhere a backslash is part of a file name and stays)
      if IS_WIN then
        rel = rel:gsub("\\", "/")
      end
      out[#out + 1] = "--- a/" .. rel
      out[#out + 1] = "+++ b/" .. rel
      out[#out + 1] = (hunks:gsub("\n$", ""))
    end
  end
  if #out == 0 then
    return ""
  end
  return table.concat(out, "\n") .. "\n"
end

--- Render the plan as a JSON document.
---@param results RP_FileResult[]
---@param new_text string
---@return string
function M.build_json(results, new_text)
  local files = {}
  local total_spots = 0
  for _, r in ipairs(results) do
    total_spots = total_spots + r.spots
    local matches = {}
    for _, it in ipairs(r.matches) do
      matches[#matches + 1] = {
        lnum = it.lnum,
        col = it.col0 + 1,
        old = it.old,
        new = new_text,
        line = it.line,
      }
    end
    files[#files + 1] = {
      path = vim.fn.fnamemodify(r.path, ":."),
      spots = r.spots,
      skipped = r.skipped,
      matches = matches,
    }
  end
  return vim.json.encode({
    new_text = new_text,
    total_files = #results,
    total_spots = total_spots,
    files = files,
  })
end

--------------------------------------------------------------------------------
-- Quickfix / location list export
--------------------------------------------------------------------------------

--- Build quickfix/loclist entries directly from matches — this exports the
--- search results themselves, not a replacement plan, so no new_text/apply
--- machinery is involved.
---@param items RP_Match[]
---@return table[]
function M.to_qf_entries(items)
  local entries = {}
  for i, it in ipairs(items) do
    entries[i] = {
      filename = it.path,
      lnum = it.lnum,
      col = it.col0 + 1,
      text = it.line,
      type = "I",
    }
  end
  return entries
end

--- Send `items` to the quickfix or (current-window) location list and open it.
---@param items RP_Match[]
---@param use_loclist boolean
---@return nil
function M.send_to_quickfix(items, use_loclist)
  list.set({
    items = M.to_qf_entries(items),
    title = "[replacer]",
    loclist = use_loclist,
    action = "r",
  })
end

--------------------------------------------------------------------------------
-- Export sink
--------------------------------------------------------------------------------

--- Write `content` to `path`, choosing JSON when the path ends in `.json`.
--- Returns ok + an error message on failure.
---@param path string
---@param results RP_FileResult[]
---@param new_text string
---@return boolean ok, string|nil err
function M.write_export(path, results, new_text)
  local is_json = path:lower():match("%.json$") ~= nil
  local content = is_json and M.build_json(results, new_text) or M.build_patch(results)

  return require("lib.nvim.fs.write.to_file")(path, content)
end

return M
