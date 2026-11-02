-- Headless test for the public run-end signal: `User ReplacerDone` fires exactly
-- once per replacer.run(), with { reason, applied, files, spots, old, new },
-- however the run ends (ALL apply, dry-run plan, no matches, picker session).
-- Run:  nvim -l TESTS/run_end_signal_spec.lua

vim.opt.runtimepath:append(vim.fn.getcwd())

local this_file = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local dir = this_file:match("^(.*)/[^/]+$") or "."
if not dofile(dir .. "/resolve_lib_nvim.lua")() then
  print("FAIL  cannot locate lib.nvim (a runtime dependency of replacer.nvim).")
  os.exit(1)
end
if not dofile(dir .. "/resolve_ui_nvim.lua")() then
  print("FAIL  cannot locate ui.nvim (a runtime dependency of replacer.nvim).")
  os.exit(1)
end

local replacer = require("replacer")

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

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function write_file(path, content)
  local fh = assert(io.open(path, "w"))
  fh:write(content)
  fh:close()
end

local function read_file(path)
  local fh = assert(io.open(path, "r"))
  local c = fh:read("*a")
  fh:close()
  return c
end

local function setup()
  replacer.setup({
    search_engine = "vimgrep",
    engine = "telescope",
    confirm_all = false,
    confirm_wide_scope = false,
    confirm_per_file = false,
    checkpoint = false,
    write_changes = true,
    deps_popup = false,
  })
end

---@return RP_Request
local function request(old, new, scope, all)
  return {
    old = old,
    new = new,
    scope = scope,
    all = all,
    dry = false,
    overrides = {},
    filters = { file_types = {}, globs = {}, exclude = {} },
  }
end

---Run `fn`, collect every ReplacerDone payload for `wait_ms`.
---@param fn fun()
---@return table[] events
local function collect_events(fn)
  local events = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = replacer.DONE_EVENT,
    callback = function(args)
      events[#events + 1] = args.data
    end,
  })
  fn()
  vim.wait(600, function()
    return false
  end, 20)
  pcall(vim.api.nvim_del_autocmd, id)
  return events
end

check("the event name is public", replacer.DONE_EVENT == "ReplacerDone")

-- ALL apply
do
  setup()
  local f = tmp .. "/all.txt"
  write_file(f, "endword one\nendword two\n")
  local ev = collect_events(function()
    replacer.run(request("endword", "ENDNEW", f, true))
  end)
  check("ALL: exactly one event", #ev == 1, #ev)
  local e = ev[1] or {}
  check(
    "ALL: reason applied, applied=true",
    e.reason == "applied" and e.applied == true,
    vim.inspect(e)
  )
  check("ALL: files/spots are reported", e.files == 1 and e.spots == 2, vim.inspect(e))
  check("ALL: old/new are reported", e.old == "endword" and e.new == "ENDNEW", vim.inspect(e))
  check("ALL: the file was written", read_file(f):find("ENDNEW", 1, true) ~= nil)
end

-- dry-run
do
  setup()
  local f = tmp .. "/dry.txt"
  write_file(f, "dryend here\n")
  local req = request("dryend", "X", f, true)
  req.dry = true
  local ev = collect_events(function()
    replacer.run(req)
  end)
  check(
    "dry-run: one event, reason plan, nothing applied",
    #ev == 1 and ev[1].reason == "plan" and not ev[1].applied,
    vim.inspect(ev)
  )
end

-- no matches
do
  setup()
  local f = tmp .. "/none.txt"
  write_file(f, "nothing relevant\n")
  local ev = collect_events(function()
    replacer.run(request("zzznotthere", "X", f, true))
  end)
  check(
    "no matches: one event, reason no_matches",
    #ev == 1 and ev[1].reason == "no_matches" and not ev[1].applied,
    vim.inspect(ev)
  )
end

-- ALL declined in the confirm float
do
  setup()
  local real = package.loaded["ui.kit.confirm"]
  package.loaded["ui.kit.confirm"] = {
    open = function(o)
      o.on_answer(false)
    end,
  }
  package.loaded["replacer"] = nil
  local r2 = require("replacer")
  r2.setup({ search_engine = "vimgrep", confirm_all = true, checkpoint = false, deps_popup = false })
  local f = tmp .. "/declined.txt"
  write_file(f, "declword\n")
  local ev = collect_events(function()
    r2.run(request("declword", "X", f, true))
  end)
  check(
    "declined: one event, reason cancelled, file untouched",
    #ev == 1 and ev[1].reason == "cancelled" and read_file(f):find("declword", 1, true) ~= nil,
    vim.inspect(ev)
  )
  package.loaded["ui.kit.confirm"] = real
  package.loaded["replacer"] = nil
  replacer = require("replacer")
end

-- picker session: the signal waits for the picker's session end and carries what was applied
do
  setup()
  local seen_rstate
  package.loaded["replacer.pickers.telescope"] = {
    run = function(items, new_text, _, apply_func, rstate)
      seen_rstate = rstate
      -- an action applies one spot, then the session ends (as common.session_end would)
      apply_func({ items[1] }, new_text, true, function()
        rstate.on_close()
        rstate.on_close() -- a second close must stay silent
      end)
    end,
  }
  local f = tmp .. "/picker.txt"
  write_file(f, "pickword one\npickword two\n")
  local ev = collect_events(function()
    replacer.run(request("pickword", "PICKNEW", f, false))
  end)
  check(
    "picker: run() hands the picker a session with on_close",
    seen_rstate and type(seen_rstate.on_close) == "function"
  )
  check("picker: exactly one event despite two closes", #ev == 1, #ev)
  check(
    "picker: reports the one applied spot",
    ev[1] and ev[1].reason == "applied" and ev[1].spots == 1,
    vim.inspect(ev)
  )
  package.loaded["replacer.pickers.telescope"] = nil
end

-- picker session ended without applying
do
  setup()
  package.loaded["replacer.pickers.telescope"] = {
    run = function(_, _, _, _, rstate)
      rstate.on_close()
    end,
  }
  local f = tmp .. "/picker_cancel.txt"
  write_file(f, "cancword\n")
  local ev = collect_events(function()
    replacer.run(request("cancword", "X", f, false))
  end)
  check(
    "picker closed without an apply: reason cancelled, applied=false",
    #ev == 1 and ev[1].reason == "cancelled" and ev[1].applied == false,
    vim.inspect(ev)
  )
  package.loaded["replacer.pickers.telescope"] = nil
end

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then
  vim.cmd("cquit 1")
end
