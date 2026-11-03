-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- Headless smoke test for the replacer feature set.
-- Run:  nvim -l TESTS/feature_smoke.lua
-- Exercises engine-agnostic paths (no fzf-lua/telescope required):
--   request parsing, error messages, range, native (vimgrep) search,
--   multi-occurrence-per-line, pure edit computation, dry-run, export, real apply.

vim.opt.runtimepath:append(vim.fn.getcwd())

-- lib.nvim lives outside this repo, so `nvim -l TESTS/<suite>.lua` starts
-- without it on the path and every require of replacer.* dies on
-- "module 'lib.nvim.notify' not found". Resolve it first. Pattern A from
-- lib.nvim/templates/README.md (hard dependency: replacer.notify and
-- replacer.gitfiles require lib.nvim unconditionally, so nothing loads
-- without it) -- fail the whole suite rather than reporting phantom passes.
local this_file = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local add_lib_nvim = dofile((this_file:match("^(.*)/[^/]+$") or ".") .. "/resolve_lib_nvim.lua")
if not add_lib_nvim() then
  print("FAIL  cannot locate lib.nvim (a runtime dependency of replacer.nvim).")
  print("      Set $LIB_NVIM_PATH, or check it out next to this repo.")
  os.exit(1)
end
local add_ui_nvim = dofile((this_file:match("^(.*)/[^/]+$") or ".") .. "/resolve_ui_nvim.lua")
if not add_ui_nvim() then
  print("FAIL  cannot locate ui.nvim (a runtime dependency of replacer.nvim).")
  print("      Set $UI_NVIM_PATH, or check it out next to this repo.")
  os.exit(1)
end

local ok_mod, replacer = pcall(require, "replacer")
assert(ok_mod, "failed to require replacer: " .. tostring(replacer))
local command = require("replacer.command")
local rg = require("replacer.rg")
local apply = require("replacer.apply")
local export = require("replacer.export")
local casing = require("replacer.casing")
local regex = require("replacer.regex")
local encoding = require("replacer.encoding")
local root = require("replacer.root")
local gitfiles = require("replacer.gitfiles")
local checkpoint = require("replacer.checkpoint")
local hooks = require("replacer.hooks")
local history = require("replacer.history")
local presets = require("replacer.presets")
local batch = require("replacer.batch")
local messages = require("replacer.messages")
local fnames = require("replacer.fnames")
local lsp_rename = require("replacer.lsp_rename")

local pass, fail = 0, 0
local function check(name, cond, extra)
  if cond then
    pass = pass + 1
    print("PASS  " .. name)
  else
    fail = fail + 1
    print("FAIL  " .. name .. (extra and ("  -> " .. tostring(extra)) or ""))
  end
end

--------------------------------------------------------------------------------
-- 1) Request parsing & error messages
--------------------------------------------------------------------------------
do
  local ok, req = command.parse_request("foo bar")
  check("parse: basic positional", ok and req.old == "foo" and req.new == "bar" and req.scope == "")

  local ok2, _, err2 = command.parse_request("foo")
  check("parse: missing arg -> error", (not ok2) and err2:match("missing"), err2)

  local ok3, _, err3 = command.parse_request("a b c d")
  check("parse: too many -> error", (not ok3) and err3:match("too many"), err3)

  local ok4, _, err4 = command.parse_request("foo bar --bogus")
  check("parse: unknown flag -> error", (not ok4) and err4:match("unknown option"), err4)

  local ok5, req5 = command.parse_request(
    "foo bar % --regex --type=lua --glob=*.x --exclude=node --dry --export=plan.json"
  )
  check(
    "parse: flags collected",
    ok5
      and req5.overrides.literal == false
      and req5.dry == true
      and req5.export == "plan.json"
      and req5.filters.file_types[1] == "lua"
      and req5.filters.globs[1] == "*.x"
      and req5.filters.exclude[1] == "node",
    req5 and vim.inspect(req5.filters)
  )

  local ok6, req6 = command.parse_request("foo bar --type lua")
  check("parse: space-separated value flag", ok6 and req6.filters.file_types[1] == "lua")

  local ok7, req7 = command.parse_request("foo bar", { range = 2, line1 = 5, line2 = 2 })
  check(
    "parse: range normalizes + forces buffer scope",
    ok7 and req7.line_range[1] == 2 and req7.line_range[2] == 5 and req7.scope == "%"
  )

  local ok8, req8 = command.parse_request("foo bar baz", { bang = true })
  check("parse: bang -> all", ok8 and req8.all == true and req8.scope == "baz")

  local okc1, reqc1 = command.parse_request("foo bar --changed")
  check(
    "parse: bare --changed -> all three kinds",
    okc1 and #reqc1.overrides.changed_only == 3,
    reqc1 and reqc1.overrides.changed_only
  )

  local okc2, reqc2 = command.parse_request("foo bar --changed=modified,staged")
  check(
    "parse: --changed=kinds -> specific subset",
    okc2
      and #reqc2.overrides.changed_only == 2
      and reqc2.overrides.changed_only[1] == "modified"
      and reqc2.overrides.changed_only[2] == "staged"
  )

  local okc3, _, errc3 = command.parse_request("foo bar --changed=bogus")
  check(
    "parse: --changed invalid kind -> error",
    (not okc3) and errc3:match("invalid %-%-changed kind"),
    errc3
  )

  local okc4, reqc4 = command.parse_request("foo bar --changed cwd")
  check(
    "parse: --changed never swallows the next token",
    okc4 and reqc4.scope == "cwd" and #reqc4.overrides.changed_only == 3
  )

  local ok9, _, err9 = command.parse_request('"foo bar')
  check(
    "parse: unterminated quote -> specific error",
    (not ok9) and err9:match("unterminated quote"),
    err9
  )

  local ok10, _, err10 = command.parse_request("foo bar --dry=1")
  check(
    "parse: bool flag with value -> specific error",
    (not ok10) and err10:match("does not take a value"),
    err10
  )
end

--------------------------------------------------------------------------------
-- 2) Native (vimgrep) search + multiple occurrences per line
--------------------------------------------------------------------------------
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local file_a = tmp .. "/a.txt"
do
  local fh = assert(io.open(file_a, "w"))
  fh:write("foo and foo and foo\nbar foo baz\nno match here\n")
  fh:close()
end

local cfg = {
  literal = true,
  search_engine = "vimgrep",
  hidden = true,
  file_types = {},
  globs = {},
  exclude = {},
}
do
  local items = rg.collect("foo", { tmp }, cfg)
  check("search: 4 occurrences (3 on line1 + 1 on line2)", #items == 4, #items)
  local line1 = 0
  for _, it in ipairs(items) do
    if it.lnum == 1 then
      line1 = line1 + 1
    end
  end
  check("search: line 1 yields 3 separate entries", line1 == 3, line1)
end

--------------------------------------------------------------------------------
-- 2b) word_boundary: only whole-word matches are kept
--------------------------------------------------------------------------------
do
  local file_b = tmp .. "/b.txt"
  local fh = assert(io.open(file_b, "w"))
  fh:write("foo foobar barfoo xfoox foo.bar\n")
  fh:close()

  local wcfg = {
    literal = true,
    search_engine = "vimgrep",
    hidden = true,
    word_boundary = true,
    file_types = {},
    globs = {},
    exclude = {},
  }
  local witems = rg.collect("foo", { file_b }, wcfg)
  check("word_boundary: only whole-word 'foo' occurrences kept", #witems == 2, #witems)

  local plain_items = rg.collect("foo", { file_b }, {
    literal = true,
    search_engine = "vimgrep",
    hidden = true,
    file_types = {},
    globs = {},
    exclude = {},
  })
  check(
    "word_boundary: off by default finds every substring occurrence",
    #plain_items == 5,
    #plain_items
  )
end

--------------------------------------------------------------------------------
-- 2c) code_only (Tree-sitter, best-effort): fails open with no parser available
--------------------------------------------------------------------------------
do
  local tscode = require("replacer.tscode")
  local is_hit = tscode.is_in_string_or_comment("nonexistent.zzzUnknownExt", "foo", 0, 0)
  check("tscode: unresolvable filetype -> fails open (false)", is_hit == false)
end

--------------------------------------------------------------------------------
-- 2d) safe_mode: oversized/binary files are excluded from vimgrep scanning
--------------------------------------------------------------------------------
do
  local file_big = tmp .. "/big.txt"
  do
    local fh = assert(io.open(file_big, "w"))
    fh:write(string.rep("foo ", 100))
    fh:close()
  end
  local file_bin = tmp .. "/bin.dat"
  do
    local fh = assert(io.open(file_bin, "wb"))
    fh:write("foo\0bar")
    fh:close()
  end

  local safe_items = rg.collect("foo", { file_big, file_bin }, {
    literal = true,
    search_engine = "vimgrep",
    hidden = true,
    safe_mode = true,
    max_file_size = 50,
    skip_binary = true,
    file_types = {},
    globs = {},
    exclude = {},
  })
  check("safe_mode: oversized + binary files excluded", #safe_items == 0, #safe_items)

  local unsafe_items = rg.collect("foo", { file_big, file_bin }, {
    literal = true,
    search_engine = "vimgrep",
    hidden = true,
    safe_mode = false,
    file_types = {},
    globs = {},
    exclude = {},
  })
  check("safe_mode: off by default finds matches in both files", #unsafe_items > 0, #unsafe_items)
end

--------------------------------------------------------------------------------
-- 2e) encoding: BOM/CRLF-aware raw reads (vimgrep backend + export)
--------------------------------------------------------------------------------
do
  check("encoding: strip_bom removes leading BOM", encoding.strip_bom("\239\187\191foo") == "foo")
  check("encoding: strip_bom no-op without BOM", encoding.strip_bom("foo") == "foo")
  check("encoding: strip_cr removes trailing CR", encoding.strip_cr("foo\r") == "foo")
  check("encoding: strip_cr no-op without CR", encoding.strip_cr("foo") == "foo")
  check("encoding: detect_eol crlf", encoding.detect_eol("a\r\nb") == "crlf")
  check("encoding: detect_eol lf", encoding.detect_eol("a\nb") == "lf")

  local file_crlf = tmp .. "/crlf.txt"
  do
    local fh = assert(io.open(file_crlf, "wb"))
    fh:write("\239\187\191foo bar\r\nfoo baz\r\n")
    fh:close()
  end
  local crlf_items = rg.collect("foo", { file_crlf }, {
    literal = true,
    search_engine = "vimgrep",
    hidden = true,
    file_types = {},
    globs = {},
    exclude = {},
  })
  check(
    "encoding: BOM stripped -> match on line 1 starts at col0 0",
    crlf_items[1] and crlf_items[1].col0 == 0,
    crlf_items[1] and crlf_items[1].col0
  )
  local has_cr = false
  for _, it in ipairs(crlf_items) do
    if it.line:find("\r", 1, true) then
      has_cr = true
    end
  end
  check("encoding: no stray \\r left in collected line text", not has_cr)
end

--------------------------------------------------------------------------------
-- 2f) root: marker-based project root detection
--------------------------------------------------------------------------------
do
  -- tmp/mono/{.git, pkg/{package.json, src/deep/}}
  local mono = tmp .. "/mono"
  vim.fn.mkdir(mono .. "/.git", "p")
  vim.fn.mkdir(mono .. "/pkg/src/deep", "p")
  do
    local fh = assert(io.open(mono .. "/pkg/package.json", "w"))
    fh:write("{}")
    fh:close()
  end

  local candidates = root.detect(mono .. "/pkg/src/deep")
  check("root: finds both the package.json dir and the git root", #candidates == 2, #candidates)
  check("root: nearest-first ordering", candidates[1] == mono .. "/pkg", candidates[1])
  check("root: farthest is the git root", candidates[2] == mono, candidates[2])

  local best = root.detect_best(mono .. "/pkg/src/deep")
  check("root: detect_best prefers the outermost .git root", best == mono, best)

  -- PERF-72: the outermost `.git` candidate must be skipped when it is
  -- exactly the home directory (a dotfiles repo), falling back to the
  -- nearest marker match instead of silently widening to all of $HOME.
  do
    local uv = vim.uv or vim.loop
    local orig_home = uv.os_homedir
    uv.os_homedir = function()
      return mono
    end
    local ok_call, best_when_home = pcall(root.detect_best, mono .. "/pkg/src/deep")
    uv.os_homedir = orig_home
    check(
      "root: detect_best skips the home directory even when it has .git",
      ok_call and best_when_home == mono .. "/pkg",
      best_when_home
    )
  end

  local no_markers = tmp .. "/no_markers_here"
  vim.fn.mkdir(no_markers, "p")
  local empty_best, empty_candidates = root.detect_best(no_markers)
  check("root: no markers found -> nil, empty list", empty_best == nil and #empty_candidates == 0)
end

--------------------------------------------------------------------------------
-- 2g) gitfiles / --changed: restrict roots to git changed/staged/untracked
--------------------------------------------------------------------------------
if vim.fn.executable("git") == 1 then
  local repo = tmp .. "/gitrepo"
  vim.fn.mkdir(repo, "p")
  local function git(args)
    local cmd = { "git", "-C", repo }
    vim.list_extend(cmd, args)
    vim.system(cmd, { text = true }):wait()
  end
  git({ "init", "-q" })
  git({ "config", "user.email", "test@test.com" })
  git({ "config", "user.name", "test" })

  local f1 = repo .. "/tracked.txt"
  do
    local fh = assert(io.open(f1, "w"))
    fh:write("foo one\n")
    fh:close()
  end
  git({ "add", "tracked.txt" })
  git({ "commit", "-q", "-m", "init" })

  -- Modify the tracked file (unstaged "modified") and add an untracked file.
  do
    local fh = assert(io.open(f1, "w"))
    fh:write("foo one changed\n")
    fh:close()
  end
  local f2 = repo .. "/untracked.txt"
  do
    local fh = assert(io.open(f2, "w"))
    fh:write("foo two\n")
    fh:close()
  end

  -- gitfiles.list is asynchronous (it chains vim.system spawns); pump the loop
  -- until the callback fires so the assertions below stay readable.
  local function list_sync(dir, kinds)
    local files, top, done
    gitfiles.list(dir, kinds, function(f, t)
      files, top, done = f, t, true
    end)
    if not vim.wait(10000, function()
      return done
    end) then
      error("gitfiles.list did not call back within 10s for " .. vim.inspect(kinds))
    end
    return files, top
  end

  local no_cb = select(2, pcall(gitfiles.list, repo, { "modified" }))
  check(
    "gitfiles: calling list without a callback errors loudly",
    type(no_cb) == "string" and no_cb:find("on_done must be a function", 1, true) ~= nil,
    no_cb
  )

  local modified_only = list_sync(repo, { "modified" })
  check(
    "gitfiles: modified-only lists the tracked file",
    #modified_only == 1 and modified_only[1]:find("tracked.txt", 1, true) ~= nil,
    vim.inspect(modified_only)
  )

  local untracked_only = list_sync(repo, { "untracked" })
  check(
    "gitfiles: untracked-only lists the new file",
    #untracked_only == 1 and untracked_only[1]:find("untracked.txt", 1, true) ~= nil,
    vim.inspect(untracked_only)
  )

  local both = list_sync(repo, { "modified", "untracked" })
  check("gitfiles: combined kinds lists both files", #both == 2, #both)

  local not_repo, no_top = list_sync(tmp, { "modified" })
  check("gitfiles: outside a repo -> nil top, empty list", no_top == nil and #not_repo == 0)

  -- End-to-end via replacer.run: --changed restricts to only the modified
  -- file, leaving untracked.txt's "foo" untouched.
  replacer.setup({ search_engine = "vimgrep", confirm_all = false, write_changes = true })
  local req = {
    old = "foo",
    new = "XXX",
    scope = repo,
    all = true,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = { changed_only = { "modified" } },
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  replacer.run(req)
  -- Wait on the outcome, not on a stopwatch. Since --changed became
  -- asynchronous (it spawns git to resolve the file list before replacing),
  -- a flat `vim.wait(200)` was a race: it passed most of the time and failed
  -- roughly one run in six on Windows, where process spawn is slower. Polling
  -- for the write both removes the flake and returns as soon as it lands.
  local function read_file(path)
    return assert(io.open(path, "r")):read("*a")
  end
  if not vim.wait(10000, function()
    return read_file(f1):match("XXX") ~= nil
  end, 20) then
    print("NOTE  --changed did not write within 10s; asserting on what is there")
  end
  local c1 = read_file(f1)
  local c2 = read_file(f2)
  check("changed: modified file was updated", c1:match("XXX") ~= nil, c1)
  check("changed: untracked file left alone (not in 'modified' kind)", c2:match("foo") ~= nil, c2)
else
  print("SKIP  gitfiles/--changed tests (git not on PATH)")
end

--------------------------------------------------------------------------------
-- 2h) perfile: per-file All/Skip/Only-some/Quit confirmation loop
--------------------------------------------------------------------------------
do
  ---@diagnostic disable: missing-fields
  local items = {
    { id = 1, path = "a.txt", lnum = 1, col0 = 0, old = "foo", line = "foo" },
    { id = 2, path = "b.txt", lnum = 1, col0 = 0, old = "foo", line = "foo" },
    { id = 3, path = "c.txt", lnum = 1, col0 = 0, old = "foo", line = "foo" },
  }
  ---@diagnostic enable: missing-fields

  -- perfile now confirms via ui.kit.confirm (async on_answer, callback-
  -- recursive loop) instead of the old blocking vim.fn.confirm; stub the kit
  -- module and force a reload so perfile picks up the stub's `confirm.open`.
  -- The stub answers synchronously, so the whole recursive chain (and the
  -- final on_done) unwinds within the initial perfile.run() call, same as
  -- the old blocking version did.
  local answers = { "All", "Skip", "Quit" }
  local call_n = 0
  package.loaded["ui.kit.confirm"] = {
    open = function(opts)
      call_n = call_n + 1
      opts.on_answer(answers[call_n])
    end,
  }
  package.loaded["replacer.perfile"] = nil
  local perfile_stubbed = require("replacer.perfile")

  local applied_paths = {}
  local function fake_apply(list, _new_text, _write, on_result)
    applied_paths[#applied_paths + 1] = list[1].path
    -- perfile now advances its loop from apply_func's completion callback
    -- (the real apply_matches applies a wide file set asynchronously).
    if on_result then
      on_result(1, #list)
    end
    return 1, #list
  end
  local picked_files = {}
  local function fake_pick(list)
    picked_files[#picked_files + 1] = list[1].path
  end

  local files, spots
  perfile_stubbed.run(items, "bar", true, fake_apply, fake_pick, function(f, s)
    files, spots = f, s
  end)

  package.loaded["ui.kit.confirm"] = nil
  package.loaded["replacer.perfile"] = nil

  check(
    "perfile: only a.txt (All) got applied",
    #applied_paths == 1 and applied_paths[1] == "a.txt",
    vim.inspect(applied_paths)
  )
  check(
    "perfile: totals reflect only the applied file",
    files == 1 and spots == 1,
    files .. " " .. spots
  )
  check("perfile: stops at Quit, c.txt never confirmed", call_n == 3, call_n)
  check("perfile: Only-some callback never triggered here", #picked_files == 0)
  check("perfile: on_done fired synchronously with the stubbed confirm", files ~= nil)
end

--------------------------------------------------------------------------------
-- 2h-2) perfile: "Only some" hands the file to the picker, waits while that
-- picker session is open (UI-53: no confirm float over it), and goes on with
-- the remaining files once the picker reports its end (UI-05: the choice for
-- one file must not take the independent rest with it).
--------------------------------------------------------------------------------
do
  ---@diagnostic disable: missing-fields
  local items = {
    { id = 1, path = "a.txt", lnum = 1, col0 = 0, old = "foo", line = "foo" },
    { id = 2, path = "b.txt", lnum = 1, col0 = 0, old = "foo", line = "foo" },
    { id = 3, path = "c.txt", lnum = 1, col0 = 0, old = "foo", line = "foo" },
  }
  ---@diagnostic enable: missing-fields

  local answers = { "Only some", "All", "Skip" }
  local asked = {}
  package.loaded["ui.kit.confirm"] = {
    open = function(opts)
      asked[#asked + 1] = opts.question
      opts.on_answer(answers[#asked])
    end,
  }
  package.loaded["replacer.perfile"] = nil
  local perfile_stubbed2 = require("replacer.perfile")

  local applied_paths2 = {}
  local function fake_apply2(list, _new_text, _write, on_result)
    applied_paths2[#applied_paths2 + 1] = list[1].path
    if on_result then
      on_result(1, #list)
    end
    return 1, #list
  end
  local picked_files2 = {}
  local picker_close
  local function fake_pick2(list, on_close)
    picked_files2[#picked_files2 + 1] = list[1].path
    picker_close = on_close
  end

  local files2, spots2
  perfile_stubbed2.run(items, "bar", true, fake_apply2, fake_pick2, function(f, s)
    files2, spots2 = f, s
  end)

  check(
    "perfile: Only-some hands the file to the picker",
    #picked_files2 == 1 and picked_files2[1] == "a.txt",
    vim.inspect(picked_files2)
  )
  check(
    "perfile: Only-some waits while the picker is open -- b.txt's confirm not yet opened",
    #asked == 1,
    vim.inspect(asked)
  )
  check("perfile: Only-some never calls apply_func itself", #applied_paths2 == 0)
  check("perfile: the loop has not ended while the picker is open", files2 == nil)
  check(
    "perfile: the picker gets an on_close callback to report its end",
    type(picker_close) == "function"
  )

  if type(picker_close) == "function" then
    picker_close()
    picker_close() -- a second report must not ask about the files twice
  end

  package.loaded["ui.kit.confirm"] = nil
  package.loaded["replacer.perfile"] = nil

  check(
    "perfile: after the picker closes, the review goes on with b.txt and c.txt",
    #asked == 3
      and asked[2]:find("b.txt", 1, true) ~= nil
      and asked[3]:find("c.txt", 1, true) ~= nil,
    vim.inspect(asked)
  )
  check(
    "perfile: b.txt (All after the resume) got applied",
    #applied_paths2 == 1 and applied_paths2[1] == "b.txt",
    vim.inspect(applied_paths2)
  )
  check(
    "perfile: on_done fires once all files are seen, with perfile's own totals",
    files2 == 1 and spots2 == 1,
    tostring(files2) .. " " .. tostring(spots2)
  )
end

--------------------------------------------------------------------------------
-- 2i) checkpoint: snapshot + restore (--checkpoint / :ReplaceUndo)
--------------------------------------------------------------------------------
do
  local file_cp = tmp .. "/checkpoint.txt"
  local original = "line one\nline two\n"
  do
    local fh = assert(io.open(file_cp, "w"))
    fh:write(original)
    fh:close()
  end

  ---@diagnostic disable: missing-fields
  local items = { { id = 1, path = file_cp, lnum = 1, col0 = 0, old = "line", line = "line one" } }
  ---@diagnostic enable: missing-fields

  local id = checkpoint.create(items)
  check("checkpoint: create returns an id", type(id) == "string" and id ~= "", id)

  -- Mutate the file after the checkpoint, as a real apply would.
  do
    local fh = assert(io.open(file_cp, "w"))
    fh:write("MUTATED\n")
    fh:close()
  end

  local restored, err = checkpoint.undo(id)
  check("checkpoint: undo restores exactly one file", restored == 1 and err == nil, err)

  local fh2 = assert(io.open(file_cp, "r"))
  local content_after = fh2:read("*a")
  fh2:close()
  check("checkpoint: content restored byte-exact", content_after == original, content_after)

  local list = checkpoint.list()
  local found = false
  for _, cid in ipairs(list) do
    if cid == id then
      found = true
    end
  end
  check("checkpoint: list() includes the created id", found)

  local _, err2 = checkpoint.undo("does-not-exist")
  check("checkpoint: undo of unknown id -> error", err2 ~= nil, err2)
end

--------------------------------------------------------------------------------
-- 2j) hooks: config.hooks + M.on(), veto, and wired-in apply_matches
--------------------------------------------------------------------------------
do
  local calls = {}
  local proceed = hooks.run("before_apply", { path = "x" }, {
    hooks = {
      before_apply = function(ctx)
        calls[#calls + 1] = "cfg:" .. ctx.path
      end,
    },
  })
  check(
    "hooks: config-declared hook fires",
    #calls == 1 and calls[1] == "cfg:x",
    vim.inspect(calls)
  )
  check("hooks: no veto -> proceed true", proceed == true)

  hooks.clear()
  calls = {}
  hooks.on("before_apply", function(ctx)
    calls[#calls + 1] = "on:" .. ctx.path
  end)
  hooks.run("before_apply", { path = "y" }, nil)
  check(
    "hooks: M.on() programmatic hook fires without cfg.hooks",
    #calls == 1 and calls[1] == "on:y",
    vim.inspect(calls)
  )

  hooks.clear()
  hooks.on("before_apply", function()
    return false
  end)
  local proceed2 = hooks.run("before_apply", { path = "z" }, nil)
  check("hooks: before_apply returning false vetoes", proceed2 == false)

  hooks.clear()
  hooks.on("before_apply", function()
    error("boom")
  end)
  local ok_run, proceed3 = pcall(hooks.run, "before_apply", { path = "z" }, nil)
  check(
    "hooks: an erroring hook is caught, never aborts the caller",
    ok_run == true and proceed3 == true
  )

  hooks.clear()

  -- Characterisation of the contract (the registry underneath is lib.nvim.hooks): config hooks run
  -- before programmatic ones, a list of config hooks runs in order, a hook after a vetoing one still
  -- runs, an unknown event is refused with this module's own message, and a config entry that is not
  -- callable is reported instead of aborting.
  do
    local order = {}
    hooks.on("after_apply", function()
      order[#order + 1] = "on"
    end)
    hooks.run("after_apply", {}, {
      hooks = {
        after_apply = {
          function()
            order[#order + 1] = "cfg1"
          end,
          function()
            order[#order + 1] = "cfg2"
          end,
        },
      },
    })
    check(
      "hooks: config hooks (in list order) run before M.on() hooks",
      table.concat(order, ",") == "cfg1,cfg2,on",
      table.concat(order, ",")
    )
    hooks.clear()

    local ran_after_veto = false
    hooks.on("before_apply", function()
      return false
    end)
    hooks.on("before_apply", function()
      ran_after_veto = true
    end)
    local vetoed = hooks.run("before_apply", {}, nil)
    check(
      "hooks: a hook after a vetoing one still runs",
      vetoed == false and ran_after_veto == true
    )
    hooks.clear()

    local ok_on, err_on = pcall(hooks.on, "nope_event", function() end)
    check(
      "hooks: an unknown event is refused with this module's message",
      ok_on == false
        and tostring(err_on):find("replacer.hooks: unknown event 'nope_event'", 1, true) ~= nil,
      tostring(err_on)
    )

    -- a programmatic registration is strict: a non-function is a call-site error raised at on(),
    -- naming the problem (config entries stay lenient, see the next check)
    local ok_fn, err_fn = pcall(hooks.on, "before_apply", 42)
    check(
      "hooks: on() with a non-function raises at registration and names the problem",
      ok_fn == false and tostring(err_fn):find("a hook must be a function", 1, true) ~= nil,
      tostring(err_fn)
    )
    local proceed_after_bad_on = hooks.run("before_apply", {}, nil)
    check("hooks: a rejected on() registered nothing", proceed_after_bad_on == true)

    local ok_bad, proceed_bad = pcall(
      hooks.run,
      "before_apply",
      {},
      { hooks = { before_apply = { "not callable" } } }
    )
    check(
      "hooks: a non-callable config entry never aborts the apply",
      ok_bad == true and proceed_bad == true
    )

    -- a nil hole in a config list (`cond and fn or nil`) keeps the hooks behind it
    local vetoed_after_hole = hooks.run("before_apply", {}, {
      hooks = {
        before_apply = {
          nil,
          function()
            return false
          end,
        },
      },
    })
    check(
      "hooks: a nil hole in a config list keeps the hooks behind it (and their veto)",
      vetoed_after_hole == false
    )

    -- only before_apply is a gate
    hooks.on("before_write", function()
      return false
    end)
    check(
      "hooks: only before_apply can veto",
      hooks.run("before_write", {}, nil) == true and hooks.run("before_apply", {}, nil) == true
    )
    hooks.clear()

    -- an erroring hook is reported through the notifier
    local notify_mod = require("replacer.util.notify")
    local warned
    local real_warn = notify_mod.warn
    notify_mod.warn = function(msg)
      warned = msg
    end
    hooks.on("after_write", function()
      error("boom")
    end)
    hooks.run("after_write", {}, nil)
    notify_mod.warn = real_warn
    check(
      "hooks: an erroring hook is reported as hook '<event>' errored",
      type(warned) == "string" and warned:find("hook 'after_write' errored", 1, true) ~= nil,
      tostring(warned)
    )
  end

  hooks.clear()

  -- End-to-end: a before_apply hook vetoing one file via apply_matches.
  local file_h1 = tmp .. "/hook1.txt"
  local file_h2 = tmp .. "/hook2.txt"
  do
    local fh = assert(io.open(file_h1, "w"))
    fh:write("foo\n")
    fh:close()
  end
  do
    local fh = assert(io.open(file_h2, "w"))
    fh:write("foo\n")
    fh:close()
  end

  ---@diagnostic disable: missing-fields
  local hitems = {
    { id = 1, path = file_h1, lnum = 1, col0 = 0, old = "foo" },
    { id = 2, path = file_h2, lnum = 1, col0 = 0, old = "foo" },
  }
  ---@diagnostic enable: missing-fields

  hooks.on("before_apply", function(ctx)
    return ctx.path ~= file_h2
  end)
  local hfiles, hspots = apply.apply_matches(hitems, "foo", "bar", true, {})
  hooks.clear()

  check(
    "hooks: veto'd file is skipped by apply_matches",
    hfiles == 1 and hspots == 1,
    hfiles .. " " .. hspots
  )
  local hc1 = assert(io.open(file_h1, "r")):read("*a")
  local hc2 = assert(io.open(file_h2, "r")):read("*a")
  check("hooks: non-vetoed file was updated", hc1:match("bar") ~= nil, hc1)
  check("hooks: vetoed file left untouched", hc2:match("foo") ~= nil, hc2)
end

--------------------------------------------------------------------------------
-- 2k) history: records applies, re-runnable entries
--------------------------------------------------------------------------------
do
  local before = #history.load()
  local req = {
    old = "__hist_test_old__",
    new = "__hist_test_new__",
    scope = "%",
    all = false,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = {},
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  history.add(req, { files = 2, spots = 5 })
  local loaded = history.load()
  -- The stored file is a real, shared stdpath("data") location capped at 50
  -- entries: once already saturated (e.g. from repeated local test runs),
  -- adding one more keeps the list at 50 (oldest evicted) instead of
  -- growing it further -- assert "grew, or already at the cap" rather than
  -- an exact size delta.
  check(
    "history: add() grows the stored list (or is already at the 50-entry cap)",
    #loaded == before + 1 or (#loaded == 50 and before >= 50),
    #loaded
  )
  check("history: newest entry is first", loaded[1].old == "__hist_test_old__", loaded[1].old)
  check("history: files/spots recorded", loaded[1].files == 2 and loaded[1].spots == 5)

  -- history.pick() now selects via ui.kit.select (on_select(item, idx))
  -- instead of the old blocking vim.ui.select(items, opts, on_choice); stub the
  -- kit module and force a reload so history.lua picks up the stub.
  local picked
  package.loaded["ui.kit"] = {
    select = function(opts)
      opts.on_select(opts.items[1], 1)
    end,
  }
  package.loaded["replacer.history"] = nil
  local history_stubbed = require("replacer.history")
  history_stubbed.pick(function(r)
    picked = r
  end)
  package.loaded["ui.kit"] = nil
  package.loaded["replacer.history"] = nil
  check(
    "history: pick() re-runs the newest entry",
    picked ~= nil and picked.old == "__hist_test_old__" and picked.new == "__hist_test_new__"
  )
end

--------------------------------------------------------------------------------
-- 2k2) history: history_max_entries = 0 is honored as "keep no history",
--      not silently treated as unset (config.get().history_max_entries == 0
--      is a legitimate, reachable state -- as_pos_int honors 0 -- so the
--      sole consumer must too, not fall back to the 50-entry default).
--
--      Runs against a throwaway stdpath("data"), NOT the real shared one
--      2k/2l use: history_max_entries = 0 makes M.add() truncate
--      history.json to empty via a real (uncorrupted) code path -- unlike
--      2l's injected-garbage case, a snapshot-and-restore here would both
--      lose the developer's actual history for good if this block were
--      interrupted before the restore ran, and race a concurrently running
--      Neovim instance's own :Replace applies to the same file. Stubbing
--      vim.fn.stdpath("data") for this block only (history_path() re-reads
--      it on every call, nothing caches it at require time) sidesteps both
--      risks instead of trying to make a crash-safe backup of the real file.
--------------------------------------------------------------------------------
do
  local config = require("replacer.config")
  local orig_stdpath = vim.fn.stdpath
  local tmp_data = vim.fn.tempname()
  vim.fn.mkdir(tmp_data, "p")
  vim.fn.stdpath = function(what)
    if what == "data" then
      return tmp_data
    end
    return orig_stdpath(what)
  end

  local ok, err = pcall(function()
    config.setup({ history_max_entries = 0 })
    package.loaded["replacer.history"] = nil
    local history_zero = require("replacer.history")

    local req = {
      old = "__hist_zero_test_old__",
      new = "__hist_zero_test_new__",
      scope = "%",
      all = false,
      dry = false,
      export = nil,
      line_range = nil,
      overrides = {},
      filters = { file_types = {}, globs = {}, exclude = {} },
    }
    history_zero.add(req, { files = 1, spots = 1 })
    local loaded = history_zero.load()
    check("history: history_max_entries = 0 keeps zero entries", #loaded == 0, #loaded)
  end)

  -- Always restore the real vim.fn.stdpath and drop the sandboxed config,
  -- even if the block above errored -- later tests (e.g. 2l, right below)
  -- rely on vim.fn.stdpath("data") being the real one again.
  vim.fn.stdpath = orig_stdpath
  pcall(vim.fn.delete, tmp_data, "rf")
  config.setup({ history_max_entries = 50 })
  package.loaded["replacer.history"] = nil
  check("history: history_max_entries = 0 test block ran without error", ok, err)
end

--------------------------------------------------------------------------------
-- 2l) history: a corrupt history.json is backed up, not silently discarded
--------------------------------------------------------------------------------
do
  local hist_path = vim.fn.stdpath("data") .. "/replacer/history.json"
  local corrupt_path = hist_path .. ".corrupt"
  pcall(vim.fn.delete, corrupt_path)

  -- Preserve whatever real history already exists (this is the shared
  -- stdpath("data") file also used by the block above) and restore it after.
  local original = vim.fn.filereadable(hist_path) == 1 and vim.fn.readfile(hist_path) or nil

  vim.fn.mkdir(vim.fn.fnamemodify(hist_path, ":h"), "p")
  local garbage = "{not valid json"
  vim.fn.writefile({ garbage }, hist_path)

  package.loaded["replacer.history"] = nil
  local history_corrupt = require("replacer.history")
  local loaded = history_corrupt.load()
  check(
    "history: corrupt file loads as empty, not an error",
    type(loaded) == "table" and #loaded == 0
  )
  check(
    "history: corrupt file backed up to history.json.corrupt",
    vim.fn.filereadable(corrupt_path) == 1
  )
  if vim.fn.filereadable(corrupt_path) == 1 then
    local backed_up = table.concat(vim.fn.readfile(corrupt_path), "\n")
    check("history: backup preserves the original corrupt bytes", backed_up == garbage, backed_up)
  end

  pcall(vim.fn.delete, corrupt_path)
  if original then
    vim.fn.writefile(original, hist_path)
  else
    pcall(vim.fn.delete, hist_path)
  end
  package.loaded["replacer.history"] = nil
end

--------------------------------------------------------------------------------
-- 2l) presets: save/load/run/delete
--------------------------------------------------------------------------------
do
  local name = "__test_preset_replacer_ci__"
  presets.delete(name) -- clean slate in case a previous run left it behind

  ---@type RP_Request
  local req = {
    old = "foo",
    new = "bar",
    scope = "cwd",
    all = true,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = { literal = false },
    filters = { file_types = { "lua" }, globs = {}, exclude = {} },
  }
  presets.save(name, req)

  local names = presets.names()
  local found = false
  for _, n in ipairs(names) do
    if n == name then
      found = true
    end
  end
  check("presets: save() shows up in names()", found)

  local loaded_req = presets.as_request(name)
  check(
    "presets: as_request() round-trips old/new/scope/all",
    loaded_req
      and loaded_req.old == "foo"
      and loaded_req.new == "bar"
      and loaded_req.scope == "cwd"
      and loaded_req.all == true
  )
  check(
    "presets: as_request() round-trips overrides/filters",
    loaded_req
      and loaded_req.overrides.literal == false
      and loaded_req.filters.file_types[1] == "lua"
  )

  check("presets: unknown name -> nil", presets.as_request("__does_not_exist__") == nil)

  -- SEC-33: presets.json is untrusted on load -- a corrupted/hand-edited
  -- entry must be rejected cleanly, not crash deep in the replace pipeline.
  local bad_name = "bad_" .. name
  presets.save(bad_name, {
    old = 123, -- wrong type -- must be rejected outright
    new = "bar",
    scope = "cwd",
    all = false,
    overrides = { changed_only = "not-a-table" },
    filters = { file_types = { "lua", 5, true }, globs = {}, exclude = {} },
  })
  local bad_req, bad_err = presets.as_request(bad_name)
  check(
    "presets: as_request() rejects a non-string old instead of crashing",
    bad_req == nil and type(bad_err) == "string",
    vim.inspect({ bad_req, bad_err })
  )
  presets.delete(bad_name)

  local partial_name = "partial_" .. name
  presets.save(partial_name, {
    old = "foo",
    new = "bar",
    scope = "cwd",
    all = false,
    overrides = { changed_only = "not-a-table" }, -- would throw via ipairs() unvalidated
    filters = { file_types = { "lua", 5, true }, globs = {}, exclude = {} },
  })
  local partial_req = presets.as_request(partial_name)
  check(
    "presets: as_request() drops a non-table changed_only override",
    partial_req ~= nil and partial_req.overrides.changed_only == nil,
    vim.inspect(partial_req and partial_req.overrides)
  )
  check(
    "presets: as_request() drops non-string filter entries",
    partial_req ~= nil
      and #partial_req.filters.file_types == 1
      and partial_req.filters.file_types[1] == "lua",
    vim.inspect(partial_req and partial_req.filters)
  )
  presets.delete(partial_name)

  presets.delete(name)
  check("presets: delete() removes it", presets.as_request(name) == nil)
end

--------------------------------------------------------------------------------
-- 2m) batch: pair parsing (line + JSON), sources, end-to-end multi-pair run
--------------------------------------------------------------------------------
do
  local pairs1, perr1 = batch.parse("foo => bar\n# a comment\n\nbaz => qux\n")
  check("batch: line format parses two pairs", pairs1 and #pairs1 == 2, perr1)
  check("batch: line format pair 1", pairs1 and pairs1[1].old == "foo" and pairs1[1].new == "bar")
  check("batch: line format pair 2", pairs1 and pairs1[2].old == "baz" and pairs1[2].new == "qux")

  local pairs2, perr2 = batch.parse('[{"old":"a","new":"b"},{"old":"c","new":"d"}]')
  check("batch: JSON format parses two pairs", pairs2 and #pairs2 == 2, perr2)
  check("batch: JSON format pair 1", pairs2 and pairs2[1].old == "a" and pairs2[1].new == "b")

  local _, perr3 = batch.parse("not a valid line")
  check("batch: malformed line -> error", perr3 ~= nil, perr3)

  local _, perr4 = batch.parse("")
  check("batch: empty input -> error", perr4 ~= nil, perr4)

  -- End-to-end: two pairs, two files, via M.run + a real run_fun.
  local file_b1 = tmp .. "/batch1.txt"
  local file_b2 = tmp .. "/batch2.txt"
  do
    local fh = assert(io.open(file_b1, "w"))
    fh:write("alpha\n")
    fh:close()
  end
  do
    local fh = assert(io.open(file_b2, "w"))
    fh:write("beta\n")
    fh:close()
  end

  local batch_file = tmp .. "/batch_spec.txt"
  do
    local fh = assert(io.open(batch_file, "w"))
    fh:write("alpha => ALPHA\nbeta => BETA\n")
    fh:close()
  end

  replacer.setup({ search_engine = "vimgrep", confirm_all = false, write_changes = true })
  ---@type RP_Request
  local btpl = {
    old = "",
    new = "",
    scope = "",
    all = false,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = {},
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  batch.run(batch_file, tmp, btpl, replacer.run)
  -- The apply is asynchronous: wait for its effect, not a fixed time (a loaded machine needs longer).
  vim.wait(5000, function()
    local a, b = io.open(file_b1, "r"), io.open(file_b2, "r")
    local done = false
    if a and b then
      done = a:read("*a"):find("ALPHA", 1, true) ~= nil
        and b:read("*a"):find("BETA", 1, true) ~= nil
    end
    if a then
      a:close()
    end
    if b then
      b:close()
    end
    return done
  end, 20)

  local bc1 = assert(io.open(file_b1, "r")):read("*a")
  local bc2 = assert(io.open(file_b2, "r")):read("*a")
  check("batch: pair 1 applied across the batch scope", bc1:match("ALPHA") ~= nil, bc1)
  check("batch: pair 2 applied across the batch scope", bc2:match("BETA") ~= nil, bc2)

  -- UI-01: with confirm_all on, a real batch run must ask ONCE for the
  -- whole batch, not once per pair (previously: one `ui.kit.confirm` float
  -- per pair, in collection-completion order).
  local file_c1 = tmp .. "/batch_confirm1.txt"
  local file_c2 = tmp .. "/batch_confirm2.txt"
  local function write_file(path, content)
    local fh = assert(io.open(path, "w"))
    fh:write(content)
    fh:close()
  end
  write_file(file_c1, "gamma\n")
  write_file(file_c2, "delta\n")

  local confirm_batch_file = tmp .. "/batch_confirm_spec.txt"
  write_file(confirm_batch_file, "gamma => GAMMA\ndelta => DELTA\n")

  replacer.setup({ confirm_all = true })

  local confirm_calls = 0
  package.loaded["ui.kit.confirm"] = {
    open = function(opts)
      confirm_calls = confirm_calls + 1
      opts.on_answer(true)
    end,
  }

  ---@type RP_Request
  local btpl2 = {
    old = "",
    new = "",
    scope = "",
    all = false,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = {},
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  batch.run(confirm_batch_file, tmp, btpl2, replacer.run)
  -- The batch applies asynchronously: wait for its effect, not a fixed time.
  vim.wait(10000, function()
    local a, b = io.open(file_c1, "r"), io.open(file_c2, "r")
    local ok = a and b and a:read("*a"):match("GAMMA") and b:read("*a"):match("DELTA")
    if a then
      a:close()
    end
    if b then
      b:close()
    end
    return ok and true or false
  end, 10)

  package.loaded["ui.kit.confirm"] = nil
  replacer.setup({ confirm_all = false })

  check(
    "batch: confirm_all -> exactly one confirm for the whole batch (UI-01)",
    confirm_calls == 1,
    confirm_calls
  )

  local cc1 = assert(io.open(file_c1, "r")):read("*a")
  local cc2 = assert(io.open(file_c2, "r")):read("*a")
  check("batch: pair 1 applied after the single confirm", cc1:match("GAMMA") ~= nil, cc1)
  check("batch: pair 2 applied after the single confirm", cc2:match("DELTA") ~= nil, cc2)

  -- SEC: confirm_all=false must NOT silently defeat confirm_wide_scope=true
  -- for a batch run over a non-single-file scope -- the two are independent
  -- settings (DEFAULTS.lua) and dispatch_all() forces both off per pair
  -- (UI-01), so the up-front M.run gate is the only place confirm_wide_scope
  -- can still fire for a batch.
  local file_d1 = tmp .. "/batch_wide1.txt"
  local file_d2 = tmp .. "/batch_wide2.txt"
  write_file(file_d1, "epsilon\n")
  write_file(file_d2, "zeta\n")

  local wide_batch_file = tmp .. "/batch_wide_spec.txt"
  write_file(wide_batch_file, "epsilon => EPSILON\nzeta => ZETA\n")

  replacer.setup({ confirm_all = false, confirm_wide_scope = true })

  local wide_confirm_calls = 0
  package.loaded["ui.kit.confirm"] = {
    open = function(opts)
      wide_confirm_calls = wide_confirm_calls + 1
      opts.on_answer(true)
    end,
  }

  ---@type RP_Request
  local btpl3 = {
    old = "",
    new = "",
    scope = "",
    all = false,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = {},
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  -- `tmp` (a directory) is a non-single-file scope, so confirm_wide_scope
  -- must gate this run even though confirm_all is off.
  batch.run(wide_batch_file, tmp, btpl3, replacer.run)
  vim.wait(10000, function()
    local a, b = io.open(file_d1, "r"), io.open(file_d2, "r")
    local ok = a and b and a:read("*a"):match("EPSILON") and b:read("*a"):match("ZETA")
    if a then
      a:close()
    end
    if b then
      b:close()
    end
    return ok and true or false
  end, 10)

  package.loaded["ui.kit.confirm"] = nil
  replacer.setup({ confirm_all = false, confirm_wide_scope = false })

  check(
    "batch: confirm_all=false + confirm_wide_scope=true -> still confirms once (SEC)",
    wide_confirm_calls == 1,
    wide_confirm_calls
  )

  local dc1 = assert(io.open(file_d1, "r")):read("*a")
  local dc2 = assert(io.open(file_d2, "r")):read("*a")
  check("batch: pair 1 applied after the wide-scope confirm", dc1:match("EPSILON") ~= nil, dc1)
  check("batch: pair 2 applied after the wide-scope confirm", dc2:match("ZETA") ~= nil, dc2)
end

--------------------------------------------------------------------------------
-- 2n) messages: i18n / template overrides + quiet mode
--------------------------------------------------------------------------------
do
  check("messages: default template", messages.fmt(nil, "no_matches") == "no matches found")
  check(
    "messages: default with args",
    messages.fmt(nil, "result", 3, 2) == "3 spot(s) in 2 file(s)"
  )

  local overridden = messages.fmt({ messages = { no_matches = "keine Treffer" } }, "no_matches")
  check("messages: cfg.messages overrides the template", overridden == "keine Treffer", overridden)

  local overridden2 = messages.fmt({ messages = { result = "%d/%d" } }, "result", 3, 2)
  check("messages: overridden template applies args", overridden2 == "3/2", overridden2)

  local malformed =
    messages.fmt({ messages = { result = "%s %s %s (too many specifiers)" } }, "result", 3, 2)
  check(
    "messages: malformed override falls back to itself instead of erroring",
    malformed == "%s %s %s (too many specifiers)",
    malformed
  )

  local unknown = messages.fmt(nil, "not_a_real_key")
  check("messages: unknown key falls back to the key itself", unknown == "not_a_real_key")

  local infos = {}
  local orig_notify_info = require("replacer.util.notify").info
  require("replacer.util.notify").info = function(msg)
    infos[#infos + 1] = msg
  end
  messages.info({ quiet = true }, "should be suppressed")
  messages.info({ quiet = false }, "should show")
  messages.info(nil, "should also show")
  require("replacer.util.notify").info = orig_notify_info
  check(
    "messages: quiet=true suppresses info()",
    #infos == 2 and infos[1] == "should show",
    vim.inspect(infos)
  )
end

--------------------------------------------------------------------------------
-- 2o) config: replace_and_reopen keymap default + override
--------------------------------------------------------------------------------
do
  replacer.setup({}) -- reset to defaults after earlier setup() calls in this file
  local cfg1 = require("replacer.config").get()
  check(
    "config: replace_and_reopen defaults to <C-r>",
    cfg1.keymaps.replace_and_reopen == "<C-r>",
    cfg1.keymaps.replace_and_reopen
  )

  replacer.setup({ keymaps = { replace_and_reopen = "<leader>r" } })
  local cfg2 = require("replacer.config").get()
  check(
    "config: replace_and_reopen is overridable",
    cfg2.keymaps.replace_and_reopen == "<leader>r",
    cfg2.keymaps.replace_and_reopen
  )
  replacer.setup({ keymaps = { replace_and_reopen = "<C-r>" } }) -- restore default for later tests
end

--------------------------------------------------------------------------------
-- 2p) fnames: filename/directory rename (collect, nested filter, apply)
--------------------------------------------------------------------------------
do
  local fn_root = tmp .. "/fn"
  vim.fn.mkdir(fn_root .. "/foo_dir", "p")
  do
    local fh = assert(io.open(fn_root .. "/foo_dir/foo_inner.txt", "w"))
    fh:write("inner\n")
    fh:close()
  end
  do
    local fh = assert(io.open(fn_root .. "/foo_dir/plain.txt", "w"))
    fh:write("plain\n")
    fh:close()
  end
  do
    local fh = assert(io.open(fn_root .. "/foo_file.txt", "w"))
    fh:write("top\n")
    fh:close()
  end
  do
    local fh = assert(io.open(fn_root .. "/other.txt", "w"))
    fh:write("other\n")
    fh:close()
  end

  local matches = fnames.collect("foo", "bar", fn_root, { hidden = true, exclude_git_dir = true })
  check("fnames: collect finds dir + nested file + top-level file", #matches == 3, #matches)

  local kept, skipped = fnames.filter_nested(matches)
  check(
    "fnames: nested match is filtered out",
    #kept == 2 and skipped == 1,
    #kept .. "/" .. skipped
  )

  local preview = fnames.build_preview(kept)
  check(
    "fnames: preview mentions both kept renames",
    preview:find("foo_dir", 1, true) ~= nil and preview:find("foo_file.txt", 1, true) ~= nil,
    preview
  )

  local renamed, errors = fnames.apply(kept)
  check(
    "fnames: apply renamed both kept entries",
    renamed == 2 and #errors == 0,
    vim.inspect(errors)
  )

  check("fnames: old dir gone", vim.fn.isdirectory(fn_root .. "/foo_dir") == 0)
  check("fnames: new dir exists", vim.fn.isdirectory(fn_root .. "/bar_dir") == 1)
  check(
    "fnames: nested file moved along, basename untouched (not renamed this run)",
    vim.fn.filereadable(fn_root .. "/bar_dir/foo_inner.txt") == 1
  )
  check(
    "fnames: sibling file inside the renamed dir also moved along",
    vim.fn.filereadable(fn_root .. "/bar_dir/plain.txt") == 1
  )
  check("fnames: old top-level file gone", vim.fn.filereadable(fn_root .. "/foo_file.txt") == 0)
  check("fnames: new top-level file exists", vim.fn.filereadable(fn_root .. "/bar_file.txt") == 1)
  check("fnames: unrelated file untouched", vim.fn.filereadable(fn_root .. "/other.txt") == 1)
end

--------------------------------------------------------------------------------
-- 2p2) fnames: a case-only rename is not "destination already exists" (BUG, fixed)
--------------------------------------------------------------------------------
do
  -- On a case-insensitive, case-preserving filesystem (NTFS, default APFS)
  -- new_path resolves to the SAME file as old_path, so the ERR-30
  -- pre-write existence check must not read that as a genuine collision.
  local ci_root = tmp .. "/fn_ci"
  vim.fn.mkdir(ci_root, "p")
  do
    local fh = assert(io.open(ci_root .. "/Config.lua", "w"))
    fh:write("case-only\n")
    fh:close()
  end

  local renamed, errors = fnames.apply({
    { old_path = ci_root .. "/Config.lua", new_path = ci_root .. "/config.lua", is_dir = false },
  })
  check(
    "fnames: case-only rename is applied, not skipped as a collision",
    renamed == 1 and #errors == 0,
    vim.inspect(errors)
  )
  check(
    "fnames: the file survives the case-only rename under its new casing",
    vim.fn.filereadable(ci_root .. "/config.lua") == 1
  )

  -- A GENUINE destination collision (a different file already sitting on
  -- new_path) must still be refused -- the dev+ino identity check must not
  -- have made this a no-op.
  local blocked_root = tmp .. "/fn_blocked"
  vim.fn.mkdir(blocked_root, "p")
  do
    local fh = assert(io.open(blocked_root .. "/foo.txt", "w"))
    fh:write("source\n")
    fh:close()
  end
  do
    local fh = assert(io.open(blocked_root .. "/bar.txt", "w"))
    fh:write("pre-existing, different file\n")
    fh:close()
  end
  local renamed_blocked, errors_blocked = fnames.apply({
    {
      old_path = blocked_root .. "/foo.txt",
      new_path = blocked_root .. "/bar.txt",
      is_dir = false,
    },
  })
  check(
    "fnames: a genuine destination collision is still refused",
    renamed_blocked == 0 and #errors_blocked == 1,
    vim.inspect(errors_blocked)
  )
  check(
    "fnames: the pre-existing destination file is untouched",
    vim.fn.filereadable(blocked_root .. "/foo.txt") == 1
  )
end

--------------------------------------------------------------------------------
-- 2q) rename_assist: --also-rename-file (single-file scope only)
--------------------------------------------------------------------------------
do
  -- rename_assist now confirms via ui.kit.confirm (async on_answer)
  -- instead of the old blocking vim.fn.confirm; stub the kit module and
  -- force a reload so rename_assist picks up the stub's `confirm.open`.
  local answer_with -- set per sub-test before calling maybe_rename
  package.loaded["ui.kit.confirm"] = {
    open = function(opts)
      opts.on_answer(answer_with)
    end,
  }
  package.loaded["replacer.rename_assist"] = nil
  local rename_assist = require("replacer.rename_assist")

  local ra_dir = tmp .. "/ra"
  vim.fn.mkdir(ra_dir, "p")
  local old_file = ra_dir .. "/foo_widget.txt"
  do
    local fh = assert(io.open(old_file, "w"))
    fh:write("foo content\n")
    fh:close()
  end

  -- No match in the basename -> no-op, no prompt at all.
  local confirm_calls = 0
  require("ui.kit.confirm").open = function(opts)
    confirm_calls = confirm_calls + 1
    opts.on_answer(answer_with)
  end
  answer_with = false
  rename_assist.maybe_rename(old_file, "nonexistent_pattern", "bar", {})
  check("rename_assist: no basename match -> no prompt at all", confirm_calls == 0)

  -- Match + Yes -> renamed.
  answer_with = true
  rename_assist.maybe_rename(old_file, "foo", "bar", {})
  check(
    "rename_assist: match + Yes -> file renamed",
    confirm_calls == 1
      and vim.fn.filereadable(ra_dir .. "/bar_widget.txt") == 1
      and vim.fn.filereadable(old_file) == 0
  )

  -- Match + No -> left alone.
  local old_file2 = ra_dir .. "/foo_second.txt"
  do
    local fh = assert(io.open(old_file2, "w"))
    fh:write("x\n")
    fh:close()
  end
  answer_with = false
  rename_assist.maybe_rename(old_file2, "foo", "bar", {})
  check("rename_assist: match + No -> left alone", vim.fn.filereadable(old_file2) == 1)

  -- End-to-end via replacer.run with --also-rename-file, single-file scope.
  local content_file = ra_dir .. "/foo_target.txt"
  do
    local fh = assert(io.open(content_file, "w"))
    fh:write("foo body\n")
    fh:close()
  end
  answer_with = true
  replacer.setup({ search_engine = "vimgrep", confirm_all = false, write_changes = true })
  local req = {
    old = "foo",
    new = "bar",
    scope = content_file,
    all = true,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = { also_rename_file = true },
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  replacer.run(req)
  vim.wait(5000, function()
    return vim.fn.filereadable(ra_dir .. "/bar_target.txt") == 1
  end, 20)
  check(
    "rename_assist: end-to-end via --also-rename-file renames the file",
    vim.fn.filereadable(ra_dir .. "/bar_target.txt") == 1 and vim.fn.filereadable(content_file) == 0
  )
  local final_content = assert(io.open(ra_dir .. "/bar_target.txt", "r")):read("*a")
  check(
    "rename_assist: content also replaced",
    final_content:match("bar body") ~= nil,
    final_content
  )

  package.loaded["ui.kit.confirm"] = nil
  package.loaded["replacer.rename_assist"] = nil
end

--------------------------------------------------------------------------------
-- 2r) lsp_rename: identifier-shape guard + fallback when no client is attached
--------------------------------------------------------------------------------
do
  check("lsp_rename: plain identifier", lsp_rename.looks_like_identifier("foo_bar1") == true)
  check("lsp_rename: rejects whitespace", lsp_rename.looks_like_identifier("foo bar") == false)
  check("lsp_rename: rejects punctuation", lsp_rename.looks_like_identifier("foo.bar") == false)
  check("lsp_rename: rejects empty", lsp_rename.looks_like_identifier("") == false)
  check("lsp_rename: rejects nil", lsp_rename.looks_like_identifier(nil) == false)

  local file_lsp = tmp .. "/lsp.txt"
  do
    local fh = assert(io.open(file_lsp, "w"))
    fh:write("foo\n")
    fh:close()
  end

  ---@diagnostic disable: missing-fields
  local litem = { id = 1, path = file_lsp, lnum = 1, col0 = 0, old = "foo" }
  ---@diagnostic enable: missing-fields

  -- No LSP client is attached to this scratch file in the test sandbox, so
  -- try_rename must fall back cleanly (no hang, no error) rather than
  -- assume a client is present -- this is the single most important
  -- guarantee for a "soft" feature: normal operation must never regress
  -- when no LSP server is available.
  local done, ok_result = false, nil
  lsp_rename.try_rename(litem, "bar", function(ok)
    done = true
    ok_result = ok
  end)
  vim.wait(500, function()
    return done
  end, 10)
  check(
    "lsp_rename: falls back (on_done(false)) with no attached client",
    done and ok_result == false
  )

  local lsp_renamed, fallback = lsp_rename.try_rename_batch({ litem }, "bar", 500)
  check(
    "lsp_rename: try_rename_batch routes to fallback with no client",
    #lsp_renamed == 0 and #fallback == 1
  )

  -- End-to-end: cfg.lsp = true but no client attached -> normal plain-text
  -- apply still happens (the fallback path must never lose the edit).
  replacer.setup({
    search_engine = "vimgrep",
    confirm_all = false,
    write_changes = true,
    lsp = true,
  })
  ---@type RP_Request
  local lreq = {
    old = "foo",
    new = "bar",
    scope = file_lsp,
    all = true,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = { lsp = true },
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  replacer.run(lreq)
  vim.wait(500)
  local lcontent = assert(io.open(file_lsp, "r")):read("*a")
  check(
    "lsp_rename: --lsp with no client still applies the plain-text replace",
    lcontent:match("bar") ~= nil,
    lcontent
  )
  replacer.setup({ lsp = false }) -- restore default for later tests
end

--------------------------------------------------------------------------------
-- 2s) rg.collect_streaming: incremental batches, same final result as collect_async
--------------------------------------------------------------------------------
if vim.fn.executable("rg") == 1 then
  local stream_dir = tmp .. "/stream"
  vim.fn.mkdir(stream_dir, "p")
  for i = 1, 5 do
    local fh = assert(io.open(string.format("%s/f%d.txt", stream_dir, i), "w"))
    fh:write(string.format("needle line %d\nsecond needle here\n", i))
    fh:close()
  end

  local rcfg = {
    literal = true,
    search_engine = "ripgrep",
    hidden = true,
    smart_case = true,
    file_types = {},
    globs = {},
    exclude = {},
  }

  local batches, batch_calls = {}, 0
  local streamed_items, streamed_err, streamed_done = nil, nil, false
  rg.collect_streaming("needle", { stream_dir }, rcfg, function(new_batch)
    batch_calls = batch_calls + 1
    for _, m in ipairs(new_batch) do
      batches[#batches + 1] = m
    end
  end, function(items, err)
    streamed_items, streamed_err, streamed_done = items, err, true
  end)
  vim.wait(10000, function()
    return streamed_done
  end, 10)

  check("streaming: on_done eventually fires", streamed_done, streamed_done)
  check(
    "streaming: no error",
    streamed_err == nil,
    streamed_err and require("replacer.error").format(streamed_err)
  )
  check("streaming: at least one batch delivered", batch_calls >= 1, batch_calls)
  check(
    "streaming: batches sum to the same count as on_done's final list",
    #batches == (streamed_items and #streamed_items or -1),
    #batches
  )

  -- Cross-check against the non-streaming async collector: same search must
  -- produce the same match set (streaming's incremental parser must be
  -- semantically equivalent to the batch parser it was factored out of).
  local async_items, async_done = nil, false
  rg.collect_async("needle", { stream_dir }, rcfg, function(items)
    async_items = items
    async_done = true
  end)
  vim.wait(10000, function()
    return async_done
  end, 10)

  check(
    "streaming: same match count as the non-streaming collector",
    streamed_items and async_items and #streamed_items == #async_items,
    ("streamed=%s async=%s"):format(
      tostring(streamed_items and #streamed_items),
      tostring(async_items and #async_items)
    )
  )

  local function fingerprint(items)
    local keys = {}
    for _, it in ipairs(items) do
      keys[#keys + 1] = string.format("%s:%d:%d:%s", it.path, it.lnum, it.col0, it.old)
    end
    table.sort(keys)
    return table.concat(keys, "|")
  end
  check(
    "streaming: identical match set (path/line/col/text) as the non-streaming collector",
    streamed_items and async_items and fingerprint(streamed_items) == fingerprint(async_items)
  )

  -- End-to-end through the real pipeline: :Replace ... --stream --all must
  -- apply correctly, exercising init.lua's cfg.stream branch.
  replacer.setup({ search_engine = "ripgrep", confirm_all = false, write_changes = true })
  local ok9, sreq = command.parse_request("needle NEEDLE --stream")
  sreq = assert(sreq, "parse_request must return a request for a valid line")
  check("streaming: --stream flag parses", ok9 and sreq.overrides.stream == true)
  sreq.scope, sreq.all = stream_dir, true
  replacer.run(sreq)
  -- Wait on the outcome, not on a stopwatch: --stream spawns a real rg
  -- process and applies on its exit callback, so a flat `vim.wait(2000)` was
  -- the same race the `--changed` case above documents. Poll for the write.
  local function read_streamed()
    return assert(io.open(stream_dir .. "/f1.txt", "r")):read("*a")
  end
  local streamed_written = vim.wait(10000, function()
    return read_streamed():match("NEEDLE") ~= nil
  end, 20)
  if not streamed_written then
    print("NOTE  --stream --all did not write within 10s; asserting on what is there")
  end
  local sc1 = read_streamed()
  check(
    "streaming: end-to-end :Replace --stream --all applies correctly",
    sc1:match("NEEDLE") ~= nil and not sc1:match("needle"),
    sc1
  )
else
  print("SKIP  rg.collect_streaming tests (ripgrep not on PATH)")
end

--------------------------------------------------------------------------------
-- 3) Pure edit computation
--------------------------------------------------------------------------------
do
  local items = rg.collect("foo", { file_a }, cfg)
  local by = {}
  for _, it in ipairs(items) do
    by[#by + 1] = it
  end
  local new_lines, spots, skipped =
    apply.compute_file_edits({ "foo and foo and foo", "bar foo baz", "no match here" }, by, "X")
  check("compute: spots == 4", spots == 4, spots)
  check("compute: no skips", skipped == 0, skipped)
  check("compute: line1 rewritten", new_lines[1] == "X and X and X", new_lines[1])
  check("compute: line2 rewritten", new_lines[2] == "bar X baz", new_lines[2])
end

--------------------------------------------------------------------------------
-- 3b) preserve_whitespace: replacement is sandwiched in the match's own ws
--------------------------------------------------------------------------------
do
  ---@diagnostic disable: missing-fields
  local matches =
    { { id = 1, path = "x", lnum = 1, col0 = 3, old = "  foo  ", line = "___  foo  ___" } }
  ---@diagnostic enable: missing-fields
  local new_lines, spots = apply.compute_file_edits(
    { "___  foo  ___" },
    matches,
    "bar",
    { preserve_whitespace = true }
  )
  check(
    "preserve_whitespace: sandwiches replacement in original ws",
    spots == 1 and new_lines[1] == "___  bar  ___",
    new_lines[1]
  )

  local new_lines2 = apply.compute_file_edits({ "___  foo  ___" }, matches, "bar", nil)
  check(
    "preserve_whitespace: off by default (cfg=nil) -> plain replace",
    new_lines2[1] == "___bar___",
    new_lines2[1]
  )
end

--------------------------------------------------------------------------------
-- 3c) case_preserve: casing.lua detection + application, and apply.lua wiring
--------------------------------------------------------------------------------
do
  check("casing: detect lower", casing.detect("foo") == "lower")
  check("casing: detect upper", casing.detect("FOO") == "upper")
  check("casing: detect title", casing.detect("Foo") == "title")
  check("casing: detect camel", casing.detect("fooBar") == "camel")
  check("casing: detect pascal", casing.detect("FooBar") == "pascal")
  check("casing: detect nil for non-letters", casing.detect("123") == nil)

  check("casing: apply lower", casing.apply("BAZ", "lower") == "baz")
  check("casing: apply upper", casing.apply("baz", "upper") == "BAZ")
  check("casing: apply title", casing.apply("baz qux", "title") == "Baz qux")
  check("casing: apply camel", casing.apply("baz_qux", "camel") == "bazQux")
  check("casing: apply pascal", casing.apply("baz_qux", "pascal") == "BazQux")

  ---@diagnostic disable: missing-fields
  local m_lower = { id = 1, path = "x", lnum = 1, col0 = 0, old = "foo", line = "foo foo" }
  local m_upper = { id = 2, path = "x", lnum = 1, col0 = 4, old = "FOO", line = "foo FOO" }
  ---@diagnostic enable: missing-fields
  local nl = apply.compute_file_edits({ "foo FOO" }, { m_lower }, "bar", { case_preserve = true })
  check("case_preserve: lower match -> lower replacement", nl[1] == "bar FOO", nl[1])
  local nl2 = apply.compute_file_edits({ "foo FOO" }, { m_upper }, "bar", { case_preserve = true })
  check("case_preserve: upper match -> upper replacement", nl2[1] == "foo BAR", nl2[1])
end

--------------------------------------------------------------------------------
-- 3d) regex helpers: escape + backreference expansion
--------------------------------------------------------------------------------
do
  local escaped = regex.escape("a.b*c[d]")
  check("regex: escape special chars", escaped == "a\\.b\\*c\\[d\\]", escaped)
  check("regex: has_backrefs true", regex.has_backrefs("\\1-\\2") == true)
  check("regex: has_backrefs false", regex.has_backrefs("plain") == false)

  local capture_pattern = "\\(\\w\\+\\)=\\(\\w\\+\\)"
  local expanded = regex.expand_backrefs("\\2_\\1", "foo=bar", capture_pattern)
  check("regex: backrefs expand from vim regex capture groups", expanded == "bar_foo", expanded)

  local unchanged = regex.expand_backrefs("plain", "foo=bar", capture_pattern)
  check("regex: no backrefs -> untouched fast path", unchanged == "plain")

  ---@diagnostic disable: missing-fields
  local m = { id = 1, path = "x", lnum = 1, col0 = 0, old = "foo=bar", line = "foo=bar" }
  ---@diagnostic enable: missing-fields
  local nl = apply.compute_file_edits(
    { "foo=bar" },
    { m },
    "\\2_\\1",
    { literal = false },
    capture_pattern
  )
  check("regex: backrefs wired through compute_file_edits", nl[1] == "bar_foo", nl[1])
end

--------------------------------------------------------------------------------
-- 4) Dry-run plan + patch + JSON export
--------------------------------------------------------------------------------
do
  local items = rg.collect("foo", { file_a }, cfg)
  local results, totals = export.build_results(items, "X")
  check("plan: totals.spots == 4", totals.spots == 4, totals.spots)
  check("plan: totals.files == 1", totals.files == 1, totals.files)

  local patch = export.build_patch(results)
  check("patch: has unified headers", patch:match("%-%-%- a/") and patch:match("%+%+%+ b/"), patch)
  check("patch: contains an added line", patch:match("\n%+"), patch)

  local json = export.build_json(results, "X")
  local ok, decoded = pcall(vim.json.decode, json)
  check("json: decodes", ok and decoded.total_spots == 4, ok and decoded.total_spots)

  local jpath = tmp .. "/plan.json"
  local okw = export.write_export(jpath, results, "X")
  check("export: json file written", okw and vim.fn.filereadable(jpath) == 1)

  local ppath = tmp .. "/plan.patch"
  local okp = export.write_export(ppath, results, "X")
  check("export: patch file written", okp and vim.fn.filereadable(ppath) == 1)

  -- ERR-11: a match on a file that cannot be read must be counted
  -- distinctly from one that was merely stale, not folded silently into
  -- the same "skipped" bucket.
  local missing_path = tmp .. "/does-not-exist.txt"
  ---@diagnostic disable: missing-fields
  local bogus = { id = 99, path = missing_path, lnum = 1, col0 = 0, old = "foo", line = "foo" }
  ---@diagnostic enable: missing-fields
  local _, bogus_totals = export.build_results({ bogus }, "X")
  check(
    "plan: unreadable file counted distinctly (unreadable == 1)",
    bogus_totals.unreadable == 1,
    bogus_totals.unreadable
  )
end

--------------------------------------------------------------------------------
-- 5) Real apply via M.run (non-interactive ALL), files actually changed
--------------------------------------------------------------------------------
do
  replacer.setup({ search_engine = "vimgrep", confirm_all = false, write_changes = true })
  local request = {
    old = "foo",
    new = "XXX",
    scope = file_a,
    all = true,
    dry = false,
    export = nil,
    line_range = nil,
    overrides = {},
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  replacer.run(request)

  -- read file back
  local fh = assert(io.open(file_a, "r"))
  local content = fh:read("*a")
  fh:close()
  check(
    "apply: all 'foo' replaced with 'XXX'",
    not content:match("foo") and content:match("XXX"),
    content
  )
end

--------------------------------------------------------------------------------
-- 5b) Wide apply is chunked + async: a match set larger than APPLY_CHUNK_SIZE
--     is applied across event-loop ticks and the totals arrive via on_done,
--     not the return value.
--------------------------------------------------------------------------------
do
  local wide = tmp .. "/wide"
  vim.fn.mkdir(wide, "p")
  local n = 25 -- > APPLY_CHUNK_SIZE (10)
  for i = 1, n do
    local fh = assert(io.open(string.format("%s/f%02d.txt", wide, i), "w"))
    fh:write("foo here\nand foo again\n")
    fh:close()
  end

  local items = rg.collect("foo", { wide }, { search_engine = "vimgrep" })
  check("apply(wide): collected matches across all files", #items == n * 2, #items)

  local done_files, done_spots
  local sync_files = apply.apply_matches(items, "foo", "W", true, {}, function(f, s)
    done_files, done_spots = f, s
  end)
  check(
    "apply(wide): synchronous return is a partial snapshot (first chunk only)",
    sync_files > 0 and sync_files < n,
    tostring(sync_files)
  )

  local settled = vim.wait(5000, function()
    return done_files ~= nil
  end)
  check(
    "apply(wide): on_done fired with the real total",
    settled and done_files == n,
    tostring(done_files)
  )
  check("apply(wide): every spot applied", done_spots == n * 2, tostring(done_spots))

  local last = assert(io.open(string.format("%s/f%02d.txt", wide, n), "r")):read("*a")
  check(
    "apply(wide): the last file was actually written",
    not last:match("foo") and last:match("W"),
    last
  )
end

--------------------------------------------------------------------------------
-- 6) Quickfix/loclist export
--------------------------------------------------------------------------------
do
  local file_qf = tmp .. "/qf.txt"
  do
    local fh = assert(io.open(file_qf, "w"))
    fh:write("foo one\nfoo two\n")
    fh:close()
  end

  local items = rg.collect("foo", { file_qf }, cfg)
  local entries = export.to_qf_entries(items)
  check("qf: entry count matches items", #entries == #items, #entries)
  check(
    "qf: entry has filename/lnum/col/text",
    entries[1].filename == file_qf
      and type(entries[1].lnum) == "number"
      and type(entries[1].col) == "number"
      and type(entries[1].text) == "string"
  )

  vim.fn.setqflist({}, "r")
  replacer.setup({ search_engine = "vimgrep", confirm_all = false, write_changes = true })
  local request = {
    old = "foo",
    new = "XXX",
    scope = file_qf,
    all = false,
    dry = false,
    export = nil,
    to_quickfix = true,
    line_range = nil,
    overrides = {},
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
  replacer.run(request)
  vim.wait(200)
  local qf = vim.fn.getqflist()
  check("qf: :Replace --to-quickfix populates the quickfix list", #qf > 0, #qf)

  local fh2 = assert(io.open(file_qf, "r"))
  local content_after_qf = fh2:read("*a")
  fh2:close()
  check("qf: --to-quickfix never writes", content_after_qf:match("foo") ~= nil, content_after_qf)
end

--------------------------------------------------------------------------------
print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then
  vim.cmd("cquit 1")
end
