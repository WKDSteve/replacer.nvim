-- Headless test: the ripgrep async progress line is throttled (leading edge only).
-- Many stdout chunks inside `progress_throttle_ms` must cause ONE h:update, and a
-- chunk after the window a second one. Without the throttle every chunk updates.
-- Run:  nvim -l TESTS/rg_progress_throttle_spec.lua

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
local progress_mod = require("lib.nvim.progress")

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

local cfg = {
  literal = true,
  search_engine = "ripgrep",
  hidden = true,
  file_types = {},
  globs = {},
  exclude = {},
}

local MATCH = vim.json.encode({
  type = "match",
  data = {
    path = { text = "C:/x/ok.txt" },
    lines = { text = "foo here\n" },
    line_number = 1,
    absolute_offset = 0,
    submatches = { { match = { text = "foo" }, start = 0, ["end"] = 3 } },
  },
}) .. "\n"

-- Fake progress handle: counts update calls.
local updates, finished = 0, false
local real_create = progress_mod.create
progress_mod.create = function()
  return {
    update = function()
      updates = updates + 1
    end,
    finish = function()
      finished = true
    end,
    cancel = function() end,
    on_cancel = function() end,
  }
end

local N_BURST = 50
local real_system = vim.system
---@diagnostic disable-next-line: duplicate-set-field
vim.system = function(_, opts, cb)
  for _ = 1, N_BURST do
    opts.stdout(nil, MATCH)
  end
  -- the first burst has landed; let the window (100 ms default) pass, then a later chunk
  vim.defer_fn(function()
    opts.stdout(nil, MATCH)
    vim.defer_fn(function()
      cb({ code = 0, stdout = "", stderr = "" })
    end, 20)
  end, 250)
  return { kill = function() end }
end

local done, got = false, nil
rg.collect_async("foo", { "." }, cfg, function(items, err)
  got = { items = items, err = err }
  done = true
end)
vim.wait(5000, function()
  return done
end, 20)

vim.system = real_system
progress_mod.create = real_create

check("search completed without error", got and got.err == nil, got and got.err and got.err.message)
check("progress was finished", finished)
check(
  string.format("%d chunks in one window -> one update, one more after the window", N_BURST + 1),
  updates == 2,
  "updates = " .. updates
)

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
if fail > 0 then
  vim.cmd("cquit 1")
end
