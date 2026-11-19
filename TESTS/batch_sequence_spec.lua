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

vim.fn.delete(tmp, "rf")

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then
  vim.cmd("cquit 1")
end
