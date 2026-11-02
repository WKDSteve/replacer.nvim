---@module 'replacer.rg.vimgrep'
--- Native Lua search backend of `replacer.rg`: walks the roots itself (no external
--- dependency), used as the automatic fallback when ripgrep is unavailable or when
--- forced via config. `collect` blocks; `collect_async` scans in event-loop chunks.
---
---@see replacer.rg

local notify = require("replacer.util.notify")
local encoding = require("replacer.encoding")
local scan = require("replacer.rg.scan")

local M = {}

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
--- Decide whether a file path passes the configured filters.
---@param path string
---@param cfg RP_RG_Config
---@return boolean
local function passes_filters(path, cfg)
  local name = vim.fn.fnamemodify(path, ":t")

  if cfg.hidden == false and name:sub(1, 1) == "." then
    return false
  end

  if cfg.safe_mode then
    if cfg.max_file_size and cfg.max_file_size > 0 then
      local size = vim.fn.getfsize(path)
      if size < 0 or size > cfg.max_file_size then
        return false
      end
    end
    if cfg.skip_binary ~= false and is_binary_file(path) then
      return false
    end
  end

  -- file_types are interpreted as extensions in native mode
  local types = cfg.file_types or {}
  if #types > 0 then
    local ext = name:match("%.([%w_]+)$")
    local ok = false
    for _, ft in ipairs(types) do
      if ext == ft then
        ok = true
        break
      end
    end
    if not ok then
      return false
    end
  end

  -- include globs (filename must match at least one)
  local globs = cfg.globs or {}
  if #globs > 0 then
    local ok = false
    for _, g in ipairs(globs) do
      if vim.fn.match(name, vim.fn.glob2regpat(g)) >= 0 then
        ok = true
        break
      end
    end
    if not ok then
      return false
    end
  end

  -- excludes (substring match anywhere in the path)
  for _, ex in ipairs(cfg.exclude or {}) do
    if path:find(ex, 1, true) then
      return false
    end
  end

  return true
end

---@internal
--- Recursively list candidate files under a root directory.
---@param root string
---@param cfg RP_RG_Config
---@param acc string[]
---@return boolean ok  # false when `root` itself could not be opened for listing
local function list_files(root, cfg, acc)
  local ok, iter = pcall(vim.fs.dir, root, { depth = 32 })
  if not ok or not iter then
    return false
  end
  local n = #acc
  for name, typ in iter do
    -- skip .git subtree
    local in_git_dir = cfg.exclude_git_dir and name:find("%.git[/\\]")
    if typ == "file" and not in_git_dir then
      local full = root .. "/" .. name
      if passes_filters(full, cfg) then
        n = n + 1
        acc[n] = full
      end
    end
  end
  return true
end

---@internal
--- Scan a single file's lines for occurrences.
---@param old string
---@param path string
---@param cfg RP_RG_Config
---@param id_start integer
---@param acc RP_Match[]
---@return integer next_id, boolean ok  # ok false when `path` could not be opened
local function scan_file(old, path, cfg, id_start, acc)
  local id = id_start
  local ok, fh = pcall(io.open, path, "r")
  if not ok or not fh then
    return id, false
  end
  local lnum = 0
  for line in fh:lines() do
    lnum = lnum + 1
    if lnum == 1 then
      line = encoding.strip_bom(line)
    end
    line = encoding.strip_cr(line)
    local occs = scan.find_all_occurrences(line, old, cfg.literal)
    for _, occ in ipairs(occs) do
      id = id + 1
      -- Invariant: id == #acc, so id is also the next array index.
      acc[id] = {
        id = id,
        path = path,
        lnum = lnum,
        col0 = occ.start0,
        old = occ.text,
        line = line,
      }
    end
  end
  fh:close()
  return id, true
end

---@internal
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@return RP_Match[]
function M.collect(old, roots, cfg)
  ---@type RP_Match[]
  local matches = {}
  local id = 0
  -- ERR-11: an unreadable root/file yields zero matches for that path
  -- indistinguishably from "nothing there matched" -- count skips and warn
  -- once at the end so the caller can tell the difference.
  local unreadable = 0
  for _, root in ipairs(roots) do
    if vim.fn.isdirectory(root) ~= 0 then
      local files = {} ---@type string[]
      if not list_files(root, cfg, files) then
        unreadable = unreadable + 1
      end
      for _, f in ipairs(files) do
        local ok
        id, ok = scan_file(old, f, cfg, id, matches)
        if not ok then
          unreadable = unreadable + 1
        end
      end
    elseif passes_filters(root, cfg) then
      local ok
      id, ok = scan_file(old, root, cfg, id, matches)
      if not ok then
        unreadable = unreadable + 1
      end
    end
  end
  if unreadable > 0 then
    notify.warn(
      string.format("vimgrep scan: %d path(s) could not be read and were skipped", unreadable)
    )
  end
  return matches
end

--- Number of files scanned per `vim.schedule` tick in the async variant.
--- Keeps the native fallback responsive (non-blocking) on large trees.
local VIMGREP_CHUNK_SIZE = 25

---@internal
--- Async, chunked counterpart to `collect`: scans `VIMGREP_CHUNK_SIZE`
--- files per event-loop tick instead of one blocking loop, and reports
--- progress after each chunk. Used only by `M.collect_async`; `M.collect`
--- (sync API, used by tests) keeps calling the blocking `collect`.
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@param on_done fun(items: RP_Match[]|nil, err: RP_Error|nil)
function M.collect_async(old, roots, cfg, on_done)
  ---@type string[]
  local files = {}
  -- ERR-11: same accounting as `collect` -- an unreadable root/file
  -- must not look identical to "nothing there matched".
  local unreadable = 0
  for _, root in ipairs(roots) do
    if vim.fn.isdirectory(root) ~= 0 then
      if not list_files(root, cfg, files) then
        unreadable = unreadable + 1
      end
    elseif passes_filters(root, cfg) then
      files[#files + 1] = root
    end
  end

  local h = scan.new_progress(cfg)
  local total = #files
  local matches, id, i = {}, 0, 0

  local function step()
    if h and h.cancelled then
      on_done(nil, require("replacer.error").search_error("search cancelled"))
      return
    end

    local last = math.min(i + VIMGREP_CHUNK_SIZE, total)
    for j = i + 1, last do
      local ok
      id, ok = scan_file(old, files[j], cfg, id, matches)
      if not ok then
        unreadable = unreadable + 1
      end
    end
    i = last
    if h then
      h:update({ text = "scanning files…", current = i, total = total })
    end

    if i < total then
      vim.schedule(step)
      return
    end

    if h then
      local fileset, n_files = {}, 0
      for _, it in ipairs(matches) do
        if not fileset[it.path] then
          fileset[it.path] = true
          n_files = n_files + 1
        end
      end
      h:finish(string.format("%d match(es) in %d file(s)", #matches, n_files))
    end
    if unreadable > 0 then
      notify.warn(
        string.format("vimgrep scan: %d path(s) could not be read and were skipped", unreadable)
      )
    end
    on_done(matches, nil)
  end

  step()
end

return M
