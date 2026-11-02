-- Headless test: the search backends behind `replacer.rg`. The native one lives in
-- `replacer.rg.vimgrep`, the shared helpers in `replacer.rg.scan`; `M.collect` picks the
-- backend from a table and must give the same hits through either.
-- Run:  nvim -l TESTS/rg_backends_spec.lua

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

local rg = require("replacer.rg")
local scan = require("replacer.rg.scan")
local vimgrep = require("replacer.rg.vimgrep")

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

-- scan.find_all_occurrences ---------------------------------------------------------------
local lit = scan.find_all_occurrences("foo bar foo", "foo", true)
check("scan: literal finds every hit", #lit == 2 and lit[1].start0 == 0 and lit[2].start0 == 8)
check("scan: end0 is inclusive", lit[1].end0 == 2 and lit[1].text == "foo")
local re = scan.find_all_occurrences("a1 b22", "[0-9][0-9]*", false)
check("scan: regex mode uses Vim regex", #re == 2 and re[2].text == "22")
check("scan: empty pattern or line gives nothing", #scan.find_all_occurrences("x", "", true) == 0)

-- vimgrep.collect / collect_async ---------------------------------------------------------
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "needle one", "none", "needle needle" }, root .. "/a.txt")
vim.fn.writefile({ "nothing here" }, root .. "/b.txt")

local cfg = {
  literal = true,
  search_engine = "vimgrep",
  hidden = true,
  file_types = {},
  globs = {},
  exclude = {},
}

local direct = vimgrep.collect("needle", { root }, cfg)
check("vimgrep.collect: one entry per occurrence", #direct == 3, #direct)

local via, err = rg.collect("needle", { root }, cfg)
check("rg.collect routes search_engine=vimgrep to the native backend", err == nil and #via == 3)

local got
rg.collect_async("needle", { root }, cfg, function(items)
  got = items
end)
vim.wait(2000, function()
  return got ~= nil
end, 10)
check("rg.collect_async routes to the native async backend", got ~= nil and #got == 3)

vim.fn.delete(root, "rf")
print(("%d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
