---@module 'replacer.rg'
--- Match collection with selectable backend.
---
--- Backends:
---   - ripgrep : fast, honors .gitignore / --type / --glob (requires `rg`)
---   - vimgrep : native Lua scanner (no external deps), used as automatic
---               fallback when ripgrep is unavailable or when forced via config.
---
--- Both backends:
---   - emit one RP_Match per occurrence (multiple hits on a line -> multiple
---     selectable entries),
---   - operate on byte offsets (col0) to stay consistent with apply.lua,
---   - honor `cfg.file_types` / `cfg.globs` / `cfg.exclude` filters,
---   - restrict to `cfg._line_range` (a {l1,l2} span) when present.
---
--- A modified, file-backed buffer is scanned from its in-memory content to avoid
--- stale coordinates against the on-disk file.

local notify = require("replacer.util.notify")
local encoding = require("replacer.encoding")
local spawn_env = require("lib.nvim.cross.run.env")

local M = {}

--------------------------------------------------------------------------------
-- Progress reporting (optional: soft dependency on lib.nvim)
--------------------------------------------------------------------------------

local ok_progress, progress_mod = pcall(require, "lib.nvim.progress")

---@internal
--- Start a progress handle, or nil when lib.nvim isn't installed. Every call
--- site must guard with `if h then ... end` — the search still works without
--- lib.nvim, only the indicator is skipped.
---@param cfg RP_RG_Config
---@return Lib.Progress.Handle|nil
local function new_progress(cfg)
  if not ok_progress then
    return nil
  end
  return progress_mod.create({ title = "[replacer]", style = cfg.progress_style or "auto" })
end

--------------------------------------------------------------------------------
-- Shared: occurrence scanning
--------------------------------------------------------------------------------

---@internal
--- Find every occurrence of `pattern` in `line_text`.
--- Literal mode uses plain byte search; regex mode uses Vim regex via matchstrpos.
---@param line_text string
---@param pattern string
---@param literal boolean
---@return { start0: integer, end0: integer, text: string }[]
local function find_all_occurrences(line_text, pattern, literal)
  local out = {}
  if line_text == "" or not pattern or pattern == "" then
    return out
  end

  local n = 0 -- explicit index avoids recomputing #out per append
  if literal then
    local start = 1
    while true do
      local s, e = line_text:find(pattern, start, true)
      if not s then
        break
      end
      n = n + 1
      out[n] = { start0 = s - 1, end0 = e - 1, text = line_text:sub(s, e) }
      start = e + 1
    end
  else
    local pos = 0
    while true do
      local mt = vim.fn.matchstrpos(line_text, pattern, pos)
      local matched, s, e = mt[1], mt[2], mt[3]
      if s == -1 or not matched or matched == "" then
        break
      end
      n = n + 1
      out[n] = { start0 = s, end0 = e - 1, text = matched }
      pos = e
      if pos >= #line_text then
        break
      end
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- Buffer-aware fast path
--------------------------------------------------------------------------------

---@internal
---@param path string
---@return boolean modified, integer|nil bufnr
local function is_buffer_modified(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 then
    return false, nil
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return false, nil
  end
  return vim.bo[bufnr].modified, bufnr
end

---@internal
---@param old string
---@param bufnr integer
---@param cfg RP_RG_Config
---@return RP_Match[]
local function collect_from_buffer(old, bufnr, cfg)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local matches = {}
  local id = 0

  for lnum, line in ipairs(lines) do
    local occs = find_all_occurrences(line, old, cfg.literal)
    for _, occ in ipairs(occs) do
      id = id + 1
      -- id is the running occurrence count, so it is also the next array index.
      matches[id] = {
        id = id,
        path = path,
        lnum = lnum,
        col0 = occ.start0,
        old = occ.text,
        line = line,
      }
    end
  end
  return matches
end

--------------------------------------------------------------------------------
-- ripgrep backend
--------------------------------------------------------------------------------

---@internal
--- Build the ripgrep argument vector from config + filters.
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@return string[]
local function build_rg_args(old, roots, cfg)
  local args = { "rg", "--json", "-n", "--column", "--hidden", "-o" }

  if cfg.smart_case then
    args[#args + 1] = "-S"
  end
  if cfg.literal then
    args[#args + 1] = "--fixed-strings"
  end
  if cfg.hidden == false then
    for i = #args, 1, -1 do
      if args[i] == "--hidden" then
        table.remove(args, i)
      end
    end
  end
  if cfg.git_ignore == false then
    args[#args + 1] = "--no-ignore"
  end
  if cfg.exclude_git_dir then
    args[#args + 1] = "--glob"
    args[#args + 1] = "!.git"
  end
  if cfg.safe_mode and cfg.max_file_size and cfg.max_file_size > 0 then
    args[#args + 1] = "--max-filesize"
    args[#args + 1] = tostring(cfg.max_file_size)
  end

  -- Filters
  for _, ft in ipairs(cfg.file_types or {}) do
    args[#args + 1] = "--type"
    args[#args + 1] = ft
  end
  for _, g in ipairs(cfg.globs or {}) do
    args[#args + 1] = "--glob"
    args[#args + 1] = g
  end
  for _, ex in ipairs(cfg.exclude or {}) do
    -- A bare word excludes a directory subtree anywhere; an explicit glob is used as-is.
    if not ex:find("[*/?%[]") then
      args[#args + 1] = "--glob"
      args[#args + 1] = "!**/" .. ex .. "/**"
      args[#args + 1] = "--glob"
      args[#args + 1] = "!" .. ex
    else
      args[#args + 1] = "--glob"
      args[#args + 1] = "!" .. ex
    end
  end

  args[#args + 1] = old
  for i = 1, #roots do
    args[#args + 1] = roots[i]
  end
  return args
end

---@internal
--- Parse one line of ripgrep `--json` stdout (a single event, no trailing
--- newline) into the matches it produces, continuing id numbering from
--- `id_start`. Non-match events (begin/end/summary) and malformed JSON
--- produce no matches. Factored out of parse_rg_json so the streaming
--- collector (collect_streaming) can reuse the exact same per-event logic
--- incrementally instead of only at the end of a full stdout blob.
---@param line string
---@param old string
---@param cfg RP_RG_Config
---@param id_start integer
---@return RP_Match[] matches, integer next_id
local function parse_rg_json_line(line, old, cfg, id_start)
  ---@type RP_Match[]
  local matches = {}
  local id = id_start

  local okj, ev = pcall(vim.json.decode, line)
  if okj and ev and ev.type == "match" and ev.data then
    local d = ev.data
    local path = (d.path and d.path.text) or ""
    local lnum = d.line_number or 0
    local text = (d.lines and d.lines.text) or ""
    local submatches = d.submatches

    if path ~= "" and lnum > 0 then
      local line_text = tostring(text):gsub("\r?\n$", "")

      if submatches and #submatches > 0 then
        if #submatches == 1 then
          -- Defensive: rg may report one submatch where the line holds several.
          local local_occ = find_all_occurrences(line_text, old, cfg.literal)
          if #local_occ > 1 then
            for _, occ in ipairs(local_occ) do
              id = id + 1
              matches[#matches + 1] = {
                id = id,
                path = path,
                lnum = lnum,
                col0 = occ.start0,
                old = occ.text,
                line = line_text,
              }
            end
          else
            local sm = submatches[1]
            if type(sm.start) == "number" then
              id = id + 1
              matches[#matches + 1] = {
                id = id,
                path = path,
                lnum = lnum,
                col0 = sm.start,
                old = (sm.match and sm.match.text) or old or "",
                line = line_text,
              }
            end
          end
        else
          for _, sm in ipairs(submatches) do
            if type(sm.start) == "number" then
              id = id + 1
              matches[#matches + 1] = {
                id = id,
                path = path,
                lnum = lnum,
                col0 = sm.start,
                old = (sm.match and sm.match.text) or old or "",
                line = line_text,
              }
            end
          end
        end
      else
        for _, occ in ipairs(find_all_occurrences(line_text, old, cfg.literal)) do
          id = id + 1
          matches[#matches + 1] = {
            id = id,
            path = path,
            lnum = lnum,
            col0 = occ.start0,
            old = occ.text,
            line = line_text,
          }
        end
      end
    end
  end

  return matches, id
end

---@internal
--- Parse ripgrep `--json` stdout into a flat list of matches.
---@param stdout string
---@param old string
---@param cfg RP_RG_Config
---@return RP_Match[]
local function parse_rg_json(stdout, old, cfg)
  ---@type RP_Match[]
  local matches = {}
  local id = 0

  for line in string.gmatch((stdout or ""), "([^\n]+)\n?") do
    local line_matches, next_id = parse_rg_json_line(line, old, cfg, id)
    id = next_id
    for _, m in ipairs(line_matches) do
      matches[#matches + 1] = m
    end
  end

  return matches
end

---@internal
--- ripgrep exits 2 as soon as ONE path is unreadable (broken symlink, locked
--- file, ...) even though every other file was searched fine. Treat the run as
--- a partial success when stderr consists solely of per-path I/O errors
--- (`rg: <path>: ... (os error N)`); a bad regex or flag still fails.
---@param code integer
---@param stderr string|nil
---@return boolean
local function is_partial_failure(code, stderr)
  if code ~= 2 or not stderr or not stderr:match("%S") then
    return false
  end
  for line in stderr:gmatch("[^\r\n]+") do
    if not line:match("^rg: .+%(os error %d+%)%s*$") then
      return false
    end
  end
  return true
end

---@internal
--- Normalise rg's exit code: a partial failure (see is_partial_failure) is
--- reported to the user as a warning and counts as success (0).
---@param code integer
---@param stderr string|nil
---@return integer
local function tolerate_partial_failure(code, stderr)
  if not is_partial_failure(code, stderr) then
    return code
  end
  local _, n = stderr:gsub("[^\r\n]+", "")
  notify.warn(string.format("%d unreadable path(s) skipped (broken symlink?)", n))
  return 0
end

---@internal
--- Run ripgrep synchronously and parse the result. Errors are returned (not
--- notified here) so the calling layer decides how to surface them — matches
--- the async sibling `collect_ripgrep_async` below.
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@return RP_Match[], RP_Error|nil
local function collect_ripgrep(old, roots, cfg)
  local args = build_rg_args(old, roots, cfg)
  if vim.system then
    local obj = vim.system(args, spawn_env.apply({ text = true })):wait()
    local code = tolerate_partial_failure(obj and obj.code or 1, obj and obj.stderr)
    if code ~= 0 and code ~= 1 then
      return {}, require("replacer.error").search_error("rg failed", obj and obj.stderr or nil)
    end
    return parse_rg_json(obj and obj.stdout or "", old, cfg), nil
  end
  local ok_run, out = require("lib.nvim.cross.run_argv").run_blocking_captured(args)
  if not ok_run and vim.v.shell_error ~= 1 then
    return {}, require("replacer.error").search_error("rg failed (sync)", out or nil)
  end
  return parse_rg_json(out, old, cfg), nil
end

--- Minimum time between progress redraws while streaming stdout. Prevents
--- flooding a "notify" style that cannot replace in place (no nvim-notify)
--- with one notification per stdout chunk on large searches.
---@return integer
local function progress_throttle_ms()
  local ok, config = pcall(require, "replacer.config")
  if not ok or type(config.get) ~= "function" then
    return 100
  end
  local n = (config.get() or {}).progress_throttle_ms
  return (type(n) == "number" and n >= 0) and n or 100
end

---@internal
--- Run ripgrep asynchronously (non-blocking). Falls back to sync when
--- `vim.system` is unavailable. Errors are passed to `on_done` (not notified
--- here) so the calling layer decides how to surface them.
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@param on_done fun(items: RP_Match[]|nil, err: RP_Error|nil)
local function collect_ripgrep_async(old, roots, cfg, on_done)
  if not vim.system then
    on_done(collect_ripgrep(old, roots, cfg), nil)
    return
  end
  local args = build_rg_args(old, roots, cfg)
  local h = new_progress(cfg)

  local chunks, n_chunks = {}, 0
  local match_count = 0
  -- Leading only: a progress line dropped inside the window is replaced by the next one.
  local progress = require("lib.nvim.patterns.throttle").new(function()
    vim.schedule(function()
      h:update({ text = string.format("%d match(es) found…", match_count) })
    end)
  end, progress_throttle_ms(), { trailing = false })

  local proc = vim.system(
    args,
    spawn_env.apply({
      text = true,
      stdout = function(_, data)
        if not data then
          return
        end
        n_chunks = n_chunks + 1
        chunks[n_chunks] = data
        if not h then
          return
        end
        for _ in data:gmatch('"type":"match"') do
          match_count = match_count + 1
        end
        progress.call()
      end,
    }),
    function(obj)
      -- on_exit runs off the main loop; re-enter it before any vim.* work.
      vim.schedule(function()
        local code = tolerate_partial_failure(obj and obj.code or 1, obj and obj.stderr)
        if code ~= 0 and code ~= 1 then
          local err = (h and h.cancelled)
              and require("replacer.error").search_error("search cancelled")
            or require("replacer.error").search_error("ripgrep failed", obj and obj.stderr or nil)
          if h then
            h:cancel("search failed")
          end
          on_done(nil, err)
          return
        end
        local items = parse_rg_json(table.concat(chunks), old, cfg)
        if h then
          local files, n_files = {}, 0
          for _, it in ipairs(items) do
            if not files[it.path] then
              files[it.path] = true
              n_files = n_files + 1
            end
          end
          h:finish(string.format("%d match(es) in %d file(s)", #items, n_files))
        end
        on_done(items, nil)
      end)
    end
  )

  if h then
    h:on_cancel(function()
      pcall(function()
        proc:kill(15)
      end)
    end)
  end
end

--------------------------------------------------------------------------------
-- vimgrep (native) backend
--------------------------------------------------------------------------------

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
    local occs = find_all_occurrences(line, old, cfg.literal)
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
local function collect_vimgrep(old, roots, cfg)
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
--- Async, chunked counterpart to `collect_vimgrep`: scans `VIMGREP_CHUNK_SIZE`
--- files per event-loop tick instead of one blocking loop, and reports
--- progress after each chunk. Used only by `M.collect_async`; `M.collect`
--- (sync API, used by tests) keeps calling the blocking `collect_vimgrep`.
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@param on_done fun(items: RP_Match[]|nil, err: RP_Error|nil)
local function collect_vimgrep_async(old, roots, cfg, on_done)
  ---@type string[]
  local files = {}
  -- ERR-11: same accounting as `collect_vimgrep` -- an unreadable root/file
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

  local h = new_progress(cfg)
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

--------------------------------------------------------------------------------
-- Backend selection
--------------------------------------------------------------------------------

---@internal
--- Resolve the effective search backend, applying the ripgrep->vimgrep fallback.
---@param cfg RP_RG_Config
---@return "ripgrep"|"vimgrep"
local function pick_backend(cfg)
  local want = cfg.search_engine or "auto"
  local has_rg = vim.fn.executable("rg") == 1
  if want == "vimgrep" then
    return "vimgrep"
  end
  if want == "ripgrep" then
    if has_rg then
      return "ripgrep"
    end
    notify.warn("ripgrep not found — falling back to vimgrep")
    return "vimgrep"
  end
  return has_rg and "ripgrep" or "vimgrep"
end

---@internal
--- Restrict items to cfg._line_range (a {l1,l2} span) when present.
---@param items RP_Match[]
---@param cfg RP_RG_Config
---@return RP_Match[]
local function apply_line_range(items, cfg)
  local range = cfg._line_range
  if type(range) ~= "table" then
    return items
  end
  local l1, l2 = range[1], range[2]
  if type(l1) ~= "number" or type(l2) ~= "number" then
    return items
  end
  local out = {}
  local n = 0
  for _, it in ipairs(items) do
    if it.lnum >= l1 and it.lnum <= l2 then
      n = n + 1
      out[n] = it
    end
  end
  return out
end

---@internal
--- True when a byte is a "word" byte (letter/digit/underscore) — an ASCII
--- approximation of `\w`, matching what ripgrep's own `-w` treats as a word
--- character closely enough for boundary detection purposes.
---@param byte string|nil  # a single character, or nil (out of bounds)
---@return boolean
local function is_word_byte(byte)
  return byte ~= nil and byte:match("[%w_]") ~= nil
end

---@internal
--- Restrict items to whole-word matches: the byte immediately before the
--- match and the byte immediately after it (if any) must NOT be word bytes.
--- A no-op unless cfg.word_boundary is set.
---@param items RP_Match[]
---@param cfg RP_RG_Config
---@return RP_Match[]
local function apply_word_boundary(items, cfg)
  if not cfg.word_boundary then
    return items
  end
  local out, n = {}, 0
  for _, it in ipairs(items) do
    local line = it.line or ""
    local mlen = #(it.old or "")
    local before = it.col0 > 0 and line:sub(it.col0, it.col0) or nil
    ---@type string|nil
    local after = line:sub(it.col0 + mlen + 1, it.col0 + mlen + 1)
    if after == "" then
      after = nil
    end
    if not is_word_byte(before) and not is_word_byte(after) then
      n = n + 1
      out[n] = it
    end
  end
  return out
end

---@internal
--- Drop matches that fall inside a string/comment Tree-sitter node
--- (best-effort, fails open — see replacer.tscode). A no-op unless
--- cfg.code_only is set. Reads each affected file once, grouped by path.
---@param items RP_Match[]
---@param cfg RP_RG_Config
---@return RP_Match[]
local function apply_code_only(items, cfg)
  if not cfg.code_only or #items == 0 then
    return items
  end
  local tscode = require("replacer.tscode")

  ---@type table<string, string>
  local content_cache = {}
  local function read(path)
    local cached = content_cache[path]
    if cached ~= nil then
      return cached
    end
    local ok, fh = pcall(io.open, path, "r")
    local content = (ok and fh) and fh:read("*a") or ""
    if ok and fh then
      fh:close()
    end
    content_cache[path] = content
    return content
  end

  local out, n = {}, 0
  for _, it in ipairs(items) do
    local content = read(it.path)
    if
      content == "" or not tscode.is_in_string_or_comment(it.path, content, it.lnum - 1, it.col0)
    then
      n = n + 1
      out[n] = it
    end
  end
  return out
end

---@internal
--- Compose every post-collection, cfg-driven filter (line range, word
--- boundary, code-only) into one call so every backend/scope combination
--- applies them identically.
---@param items RP_Match[]
---@param cfg RP_RG_Config
---@return RP_Match[]
local function post_filter(items, cfg)
  return apply_code_only(apply_word_boundary(apply_line_range(items, cfg), cfg), cfg)
end

--------------------------------------------------------------------------------
-- Public entry
--------------------------------------------------------------------------------

--- Collect matches for `old` under `roots` using the configured backend.
--- Errors from the ripgrep backend are returned (not notified here) so the
--- calling layer decides how to surface them — matches `M.collect_async`.
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@return RP_Match[], RP_Error|nil
function M.collect(old, roots, cfg)
  -- Modified, file-backed single buffer: scan in-memory content.
  if #roots == 1 then
    local modified, bufnr = is_buffer_modified(roots[1])
    if modified and bufnr then
      notify.info("scanning modified buffer instead of disk")
      return post_filter(collect_from_buffer(old, bufnr, cfg), cfg), nil
    end
  end

  local backend = pick_backend(cfg)
  local items, err
  if backend == "ripgrep" then
    items, err = collect_ripgrep(old, roots, cfg)
  else
    items = collect_vimgrep(old, roots, cfg)
  end

  return post_filter(items, cfg), err
end

--- Collect matches asynchronously, invoking `on_done(items, err)` when ready.
--- Both ripgrep and the native vimgrep backend run non-blocking (no UI freeze
--- on large repos); only the modified-buffer fast path completes synchronously
--- and calls `on_done` immediately. Errors are reported via `err` (the caller
--- notifies).
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@param on_done fun(items: RP_Match[]|nil, err: RP_Error|nil)
---@return nil
function M.collect_async(old, roots, cfg, on_done)
  -- Modified, file-backed single buffer: scan in-memory content (sync).
  if #roots == 1 then
    local modified, bufnr = is_buffer_modified(roots[1])
    if modified and bufnr then
      notify.info("scanning modified buffer instead of disk")
      on_done(post_filter(collect_from_buffer(old, bufnr, cfg), cfg), nil)
      return
    end
  end

  if pick_backend(cfg) == "ripgrep" then
    collect_ripgrep_async(old, roots, cfg, function(items, err)
      if err then
        on_done(nil, err)
      else
        on_done(post_filter(items or {}, cfg), nil)
      end
    end)
  else
    collect_vimgrep_async(old, roots, cfg, function(items, err)
      if err then
        on_done(nil, err)
      else
        on_done(post_filter(items or {}, cfg), nil)
      end
    end)
  end
end

--- Collect matches, invoking `on_batch(new_items)` incrementally as
--- complete ripgrep --json lines arrive (already post_filter'd, so a batch
--- is exactly what a caller would show immediately) and `on_done(items,
--- err)` once at the end with everything collected. Backs --stream.
---
--- Only the ripgrep backend streams incrementally; the modified-buffer
--- fast path and the vimgrep backend (no incremental JSON to parse) fall
--- back to a single on_batch call with everything at once, so callers can
--- rely on a consistent on_batch/on_done contract regardless of backend.
---@param old string
---@param roots string[]
---@param cfg RP_RG_Config
---@param on_batch fun(new_items: RP_Match[])
---@param on_done fun(items: RP_Match[]|nil, err: RP_Error|nil)
---@return nil
function M.collect_streaming(old, roots, cfg, on_batch, on_done)
  if #roots == 1 then
    local modified, bufnr = is_buffer_modified(roots[1])
    if modified and bufnr then
      notify.info("scanning modified buffer instead of disk")
      local items = post_filter(collect_from_buffer(old, bufnr, cfg), cfg)
      if #items > 0 then
        on_batch(items)
      end
      on_done(items, nil)
      return
    end
  end

  if pick_backend(cfg) ~= "ripgrep" or not vim.system then
    M.collect_async(old, roots, cfg, function(items, err)
      if items and #items > 0 then
        on_batch(items)
      end
      on_done(items, err)
    end)
    return
  end

  local args = build_rg_args(old, roots, cfg)
  local h = new_progress(cfg)

  ---@type RP_Match[]
  local all_items = {}
  local id, buf_tail = 0, ""

  --- Feed one stdout chunk: extract every complete line (a chunk boundary
  --- can land mid-line), parse+filter them into one batch, and hand that
  --- batch to on_batch. Any trailing partial line is kept for the next call.
  ---@param chunk string
  local function feed(chunk)
    local data = buf_tail .. chunk
    local last_nl = data:match(".*\n()") -- byte index just past the last \n, or nil
    local complete, rest
    if last_nl then
      complete, rest = data:sub(1, last_nl - 1), data:sub(last_nl)
    else
      complete, rest = "", data
    end
    buf_tail = rest
    if complete == "" then
      return
    end

    ---@type RP_Match[]
    local raw_batch = {}
    for line in complete:gmatch("([^\n]+)") do
      local line_matches, next_id = parse_rg_json_line(line, old, cfg, id)
      id = next_id
      for _, m in ipairs(line_matches) do
        raw_batch[#raw_batch + 1] = m
      end
    end
    if #raw_batch == 0 then
      return
    end

    local batch = post_filter(raw_batch, cfg)
    if #batch == 0 then
      return
    end
    for _, m in ipairs(batch) do
      all_items[#all_items + 1] = m
    end
    on_batch(batch)
  end

  local proc = vim.system(
    args,
    spawn_env.apply({
      text = true,
      stdout = function(_, data)
        if not data then
          return
        end
        vim.schedule(function()
          feed(data)
          if h then
            h:update({ text = string.format("%d match(es) found…", #all_items) })
          end
        end)
      end,
    }),
    function(obj)
      vim.schedule(function()
        if buf_tail ~= "" then
          feed("\n")
        end -- flush a trailing line with no final newline

        local code = tolerate_partial_failure(obj and obj.code or 1, obj and obj.stderr)
        if code ~= 0 and code ~= 1 then
          local err = (h and h.cancelled)
              and require("replacer.error").search_error("search cancelled")
            or require("replacer.error").search_error("ripgrep failed", obj and obj.stderr or nil)
          if h then
            h:cancel("search failed")
          end
          on_done(nil, err)
          return
        end

        if h then
          local files, n_files = {}, 0
          for _, it in ipairs(all_items) do
            if not files[it.path] then
              files[it.path] = true
              n_files = n_files + 1
            end
          end
          h:finish(string.format("%d match(es) in %d file(s)", #all_items, n_files))
        end
        on_done(all_items, nil)
      end)
    end
  )

  if h then
    h:on_cancel(function()
      pcall(function()
        proc:kill(15)
      end)
    end)
  end
end

return M
