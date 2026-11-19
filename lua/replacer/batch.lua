---@module 'replacer.batch'
--- Batch replaces: run multiple {old -> new} pairs in one invocation,
--- imported from a file, the clipboard/unnamed register, or the quickfix
--- list.
---   :ReplaceBatch[!] {source} [scope] [--flags]
---
--- {source} is a file path, or one of: clipboard/+ (the "+" register),
--- unnamed/" (the unnamed register), qf/quickfix (quickfix list `text`
--- fields).
---
--- Pair format, auto-detected:
---   - line-oriented (default): one "old => new" per line; blank lines and
---     "#"-prefixed comments are ignored.
---   - JSON: a `[{"old": "...", "new": "..."}, ...]` array, used when the
---     (trimmed) content starts with "[".
---
--- Each pair is dispatched as its own full :Replace run (search + apply),
--- sequentially and non-interactively (the bang form / --all semantics) --
--- this reuses the exact same pipeline (dry-run, filters, checkpoints,
--- hooks, history, …) rather than reimplementing search-and-apply, so every
--- pair gets its own result notification exactly like a normal :Replace!
--- would produce.

local notify = require("replacer.util.notify")

local M = {}

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

---@class RP_BatchPair
---@field old string
---@field new string

---@internal
--- Parse the line-oriented "old => new" format.
---@param content string
---@return RP_BatchPair[]|nil pairs, string|nil err
local function parse_lines(content)
  local out = {}
  local lnum = 0
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lnum = lnum + 1
    local trimmed = vim.trim(line)
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      local old, new = trimmed:match("^(.-)%s=>%s(.*)$")
      if not old then
        return nil, string.format("batch line %d: expected 'old => new', got: %s", lnum, line)
      end
      out[#out + 1] = { old = old, new = new }
    end
  end
  return out, nil
end

---@internal
--- Parse a JSON array of {old, new}.
---@param content string
---@return RP_BatchPair[]|nil pairs, string|nil err
local function parse_json(content)
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return nil, "batch: invalid JSON"
  end
  local out = {}
  for i, entry in ipairs(data) do
    if type(entry) ~= "table" or type(entry.old) ~= "string" or type(entry.new) ~= "string" then
      return nil, string.format("batch: JSON entry #%d missing string old/new", i)
    end
    out[#out + 1] = { old = entry.old, new = entry.new }
  end
  return out, nil
end

--- Parse batch content, auto-detecting JSON (leading "[") vs the line format.
---@param content string
---@return RP_BatchPair[]|nil pairs, string|nil err
function M.parse(content)
  local trimmed = vim.trim(content or "")
  if trimmed == "" then
    return nil, "batch: empty input"
  end
  if trimmed:sub(1, 1) == "[" then
    return parse_json(trimmed)
  end
  return parse_lines(content)
end

--------------------------------------------------------------------------------
-- Sources
--------------------------------------------------------------------------------

---@internal
--- Resolve {source} into raw text content.
---@param source string
---@return string|nil content, string|nil err
local function read_source(source)
  local lc = source:lower()
  if lc == "clipboard" or source == "+" then
    return vim.fn.getreg("+"), nil
  end
  if source == '"' or lc == "unnamed" then
    return vim.fn.getreg('"'), nil
  end
  if lc == "qf" or lc == "quickfix" then
    local qf = vim.fn.getqflist()
    local lines = {}
    for _, e in ipairs(qf) do
      lines[#lines + 1] = e.text
    end
    return table.concat(lines, "\n"), nil
  end
  if vim.fn.filereadable(source) == 1 then
    local ok, lines = pcall(vim.fn.readfile, source)
    if not ok then
      return nil, "batch: failed to read " .. source
    end
    return table.concat(lines, "\n"), nil
  end
  return nil,
    "batch: source not found — expected a file path, 'clipboard'/'+', "
      .. "'unnamed'/'\"', or 'qf'/'quickfix', got: "
      .. source
end

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

---@internal
--- Dispatch every pair as its own :Replace-equivalent request via `run_fun`
--- (search + apply, or plan-only when `req_template.dry` is set). Each
--- pair's own result is reported by the normal apply pipeline.
---
--- One pair at a time: the next pair starts when the run of the one before is
--- over (its `on_end`, fired with `User ReplacerDone`). The search of a run is
--- asynchronous; started all at once, a later pair searched a file before an
--- earlier pair had written it and then skipped its own spots there as
--- "changed content".
---@param pairs_list RP_BatchPair[]
---@param scope string
---@param req_template RP_Request
---@param run_fun fun(request: RP_Request): nil
---@param source string  # for the summary notification only
---@return nil
local function dispatch_all(pairs_list, scope, req_template, run_fun, source)
  notify.info(string.format("batch: dispatched %d pair(s) from %s", #pairs_list, source))

  local function run_pair(i)
    local pair = pairs_list[i]
    if not pair then
      return
    end
    local started_next = false
    local function next_pair()
      if started_next then
        return
      end
      started_next = true
      run_pair(i + 1)
    end
    ---@type RP_Request
    local req = vim.deepcopy(req_template)
    req.old, req.new, req.scope = pair.old, pair.new, scope
    -- Batch is inherently non-interactive (a picker per pair makes no
    -- sense); dispatch() ignores `all` entirely on the --dry/plan path
    -- anyway, so this is a no-op when req.dry is set.
    req.all = true
    -- UI-01: the batch itself is the one bulk/destructive action, confirmed
    -- once below (see `M.run`) -- each pair's own dispatch must not open a
    -- second confirm on top of that.
    req.overrides = req.overrides or {}
    req.overrides.confirm_all = false
    req.overrides.confirm_wide_scope = false
    req.on_end = next_pair
    local ok, err = pcall(run_fun, req)
    if not ok then
      -- a pair that raised never reaches its end signal: report it and go on
      notify.error(string.format("batch: pair %d (%s) failed: %s", i, pair.old, tostring(err)))
      next_pair()
    end
  end

  run_pair(1)
end

--- Run every pair, sequentially dispatching one :Replace-equivalent request
--- per pair. A real (non-dry) run asks for confirmation ONCE for the whole
--- batch instead of once per pair (UI-01) -- up to 40 stacked "Apply ALL?"
--- floats, arriving in collection-completion order rather than file order,
--- was the previous behavior.
---@param source string
---@param scope string
---@param req_template RP_Request     # carries dry/all/overrides/filters from the command line
---@param run_fun fun(request: RP_Request): nil
---@return nil
function M.run(source, scope, req_template, run_fun)
  local content, err = read_source(source)
  if not content then
    notify.error(err or ("batch: could not read " .. source))
    return
  end

  local pairs_list, perr = M.parse(content)
  if not pairs_list then
    notify.error(perr or "batch: could not parse the source")
    return
  end
  if #pairs_list == 0 then
    notify.info("batch: no pairs found")
    return
  end

  -- --dry never writes and dispatch() routes it to the plan-only path
  -- before it would ever reach a confirm -- skip straight to dispatching.
  if req_template.dry then
    dispatch_all(pairs_list, scope, req_template, run_fun, source)
    return
  end

  local cfg = require("replacer.config").resolve(req_template.overrides or {})
  -- SEC: the gate must consider confirm_wide_scope too, not just
  -- confirm_all -- a user who left confirm_all off but opted into
  -- confirm_wide_scope (a narrower, independent safety setting; see
  -- DEFAULTS.lua/types/config.lua) still expects a confirm before a batch
  -- runs unattended across a non-single-file scope. dispatch_all() forces
  -- both overrides off per pair (UI-01: one confirm for the whole batch,
  -- not once per pair), so this up-front check is the only place either
  -- setting can still take effect for a batch run.
  local scope_tok = (scope ~= "" and scope) or cfg.default_scope or "%"
  local _, single_file = require("replacer.command").resolve_scope(scope_tok)
  local wide = (not single_file) and cfg.confirm_wide_scope
  if not cfg.confirm_all and not wide then
    dispatch_all(pairs_list, scope, req_template, run_fun, source)
    return
  end

  require("ui.kit.confirm").open({
    question = string.format(
      "Apply %d replace pair(s) from %s? (each pair searches and replaces across the given scope)",
      #pairs_list,
      source
    ),
    on_answer = function(yes)
      if yes then
        dispatch_all(pairs_list, scope, req_template, run_fun, source)
      else
        notify.info("batch: cancelled")
      end
    end,
  })
end

--------------------------------------------------------------------------------
-- :ReplaceBatch
--------------------------------------------------------------------------------

local USAGE = "Usage: :ReplaceBatch[!] {source} [scope] [--flags]   "
  .. '(source: file path, clipboard/+, unnamed/", or qf/quickfix)'

--- Register :ReplaceBatch.
---@param run_fun fun(request: RP_Request): nil
---@return nil
function M.register(run_fun)
  local usercmd = require("lib.nvim.bindings.usercmd")
  local command = require("replacer.command")

  usercmd.create("ReplaceBatch", function(opts)
    local raw = (type(opts.args) == "string") and opts.args or ""
    local tokens, unterminated = command.tokenize(raw)
    if unterminated then
      notify.error("ReplaceBatch: unterminated quote in argument list.\n" .. USAGE)
      return
    end

    ---@type RP_Request
    local req = {
      old = "",
      new = "",
      scope = "",
      all = opts.bang and true or false,
      dry = false,
      export = nil,
      line_range = nil,
      overrides = {},
      filters = { file_types = {}, globs = {}, exclude = {} },
    }
    local positionals, err = command.apply_tokens(tokens, req)
    if not positionals then
      notify.error("ReplaceBatch: " .. err)
      return
    end
    if #positionals < 1 or #positionals > 2 then
      notify.error(USAGE)
      return
    end

    M.run(positionals[1], positionals[2] or "", req, run_fun)
  end, { nargs = "+", bang = true, desc = USAGE })
end

return M
