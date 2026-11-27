-- Headless test: :ReplaceBatch runs its pairs one after the other. The next pair starts only when the run of
-- the one before is over (its `on_end`), so a later pair never searches a file an earlier pair is about to
-- write (it skipped its spots there as "changed content" when all pairs started at once). The last part runs
-- two overlapping pairs through the real pipeline and checks both are applied.
-- Run:  nvim -l TESTS/batch_sequence_spec.lua

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
local batch = require("replacer.batch")

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
  local fh = assert(io.open(path, "wb"))
  fh:write(content)
  fh:close()
end

local function read_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local s = fh:read("*a")
  fh:close()
  return s
end

---@return RP_Request
local function template()
  return {
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
end

-- 1) with a run that does not end on its own, only the first pair is started
do
  local pairs_file = tmp .. "/pairs.txt"
  write_file(pairs_file, "a => 1\nb => 2\nc => 3\n")
  local runs = {}
  local tpl = template()
  tpl.dry = true -- no confirmation in front of the dispatch
  batch.run(pairs_file, tmp, tpl, function(req)
    runs[#runs + 1] = req
  end)
  check("only the first pair runs before its end", #runs == 1, #runs)
  check("the first pair is a => 1", runs[1] and runs[1].old == "a" and runs[1].new == "1")
  check("the pair carries an on_end", runs[1] and type(runs[1].on_end) == "function")

  if runs[1] and runs[1].on_end then
    runs[1].on_end({})
    runs[1].on_end({}) -- a second end of the same run starts nothing more
  end
  check("its end starts exactly the second pair", #runs == 2 and runs[2].old == "b", #runs)
  if runs[2] and runs[2].on_end then
    runs[2].on_end({})
  end
  check("then the third", #runs == 3 and runs[3].old == "c", #runs)
end

-- 2) a pair that raises is reported and the batch goes on
do
  local pairs_file = tmp .. "/pairs_err.txt"
  write_file(pairs_file, "x => 1\ny => 2\n")
  local seen = {}
  local tpl = template()
  tpl.dry = true
  batch.run(pairs_file, tmp, tpl, function(req)
    seen[#seen + 1] = req.old
    if req.old == "x" then
      error("boom")
    end
  end)
  check(
    "a raising pair does not stop the next",
    vim.deep_equal(seen, { "x", "y" }),
    vim.inspect(seen)
  )
end

-- 3) overlapping pairs through the real pipeline: both land in the shared file
do
  local src = tmp .. "/src"
  vim.fn.mkdir(src, "p")
  write_file(src .. "/a.txt", "alpha beta\nalpha\n")
  write_file(src .. "/b.txt", "beta\n")
  local pairs_file = tmp .. "/pairs_real.txt"
  write_file(pairs_file, "alpha => one\nbeta => two\n")
  replacer.setup({ confirm_all = false, confirm_wide_scope = false, write_changes = true })
  batch.run(pairs_file, src, template(), replacer.run)
  local ok = vim.wait(10000, function()
    return read_file(src .. "/a.txt") == "one two\none\n" and read_file(src .. "/b.txt") == "two\n"
  end, 20)
  check(
    "both pairs are applied to the file they share",
    ok,
    vim.inspect({ read_file(src .. "/a.txt"), read_file(src .. "/b.txt") })
  )
end

-- Collect the reason of every run end (`User ReplacerDone`); the returned function stops listening.
local function done_reasons()
  local reasons = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = replacer.DONE_EVENT,
    callback = function(ev)
      reasons[#reasons + 1] = ev.data and ev.data.reason
    end,
  })
  return reasons, function()
    vim.api.nvim_del_autocmd(id)
  end
end

-- 4) a pair whose search callback raises (after run() returned) ends as "error"; the next pair still runs
do
  local src = tmp .. "/src_cb"
  vim.fn.mkdir(src, "p")
  write_file(src .. "/a.txt", "alpha\n")
  write_file(src .. "/b.txt", "beta\n")
  local pairs_file = tmp .. "/pairs_cb.txt"
  write_file(pairs_file, "alpha => one\nbeta => two\n")
  replacer.setup({ confirm_all = false, confirm_wide_scope = false, write_changes = true })
  local dispatch = require("replacer.dispatch")
  local real_dispatch = dispatch.dispatch
  local raised = false
  dispatch.dispatch = function(request, ...)
    if request.old == "alpha" then
      raised = true
      error("boom in the search callback")
    end
    return real_dispatch(request, ...)
  end
  local reasons, stop = done_reasons()
  batch.run(pairs_file, src, template(), replacer.run)
  local ok = vim.wait(10000, function()
    return read_file(src .. "/b.txt") == "two\n" and #reasons >= 2
  end, 20)
  stop()
  dispatch.dispatch = real_dispatch
  check("the search callback raised", raised)
  check(
    "a raising search callback does not stop the next pair",
    ok and read_file(src .. "/a.txt") == "alpha\n",
    vim.inspect({ read_file(src .. "/a.txt"), read_file(src .. "/b.txt"), reasons })
  )
  check("that run ends as error", reasons[1] == "error", vim.inspect(reasons))
end

-- 5) a later (scheduled) chunk of a wide apply raises: the run ends as "error", the next pair still runs
do
  local src = tmp .. "/src_chunk"
  vim.fn.mkdir(src, "p")
  for n = 1, 25 do -- more than one apply chunk (10 files each)
    write_file(string.format("%s/f%02d.txt", src, n), "gamma\n")
  end
  write_file(src .. "/z.txt", "delta\n")
  local pairs_file = tmp .. "/pairs_chunk.txt"
  write_file(pairs_file, "gamma => g\ndelta => d\n")
  replacer.setup({ confirm_all = false, confirm_wide_scope = false, write_changes = true })
  local progress = require("lib.nvim.progress")
  local real_create = progress.create
  local updates = 0
  -- the real handle (the search reports through one too); only the apply's second update raises
  progress.create = function(...)
    local h = real_create(...)
    local real_update = h.update
    h.update = function(self, u)
      if type(u) == "table" and u.text == "applying replacements…" then
        updates = updates + 1
        if updates == 2 then -- the second chunk runs on a later tick
          error("boom in a later apply chunk")
        end
      end
      return real_update(self, u)
    end
    return h
  end
  local reasons, stop = done_reasons()
  batch.run(pairs_file, src, template(), replacer.run)
  local ok = vim.wait(10000, function()
    return read_file(src .. "/z.txt") == "d\n" and #reasons >= 2
  end, 20)
  stop()
  progress.create = real_create
  check("the second apply chunk raised", updates >= 2, updates)
  check(
    "a raising apply chunk does not stop the next pair",
    ok,
    vim.inspect({ read_file(src .. "/z.txt"), reasons })
  )
  check("that run ends as error", reasons[1] == "error", vim.inspect(reasons))
end

-- 6) without on_error, an on_done that raises on the last chunk is not called a second time
do
  local src = tmp .. "/src_done"
  vim.fn.mkdir(src, "p")
  local items = {}
  for n = 1, 12 do -- two chunks: the last one runs on a later tick
    local path = string.format("%s/f%02d.txt", src, n)
    write_file(path, "omega\n")
    items[#items + 1] = { id = n, path = path, lnum = 1, col0 = 0, old = "omega", line = "omega" }
  end
  local calls = 0
  require("replacer.apply").apply_matches(items, "omega", "o", true, {}, function()
    calls = calls + 1
    error("boom in on_done")
  end)
  vim.wait(5000, function()
    return calls > 0
  end, 20)
  vim.wait(200) -- room for a second call
  check("a raising on_done is called once", calls == 1, calls)
end

vim.fn.delete(tmp, "rf")

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then
  vim.cmd("cquit 1")
end
