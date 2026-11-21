-- TESTS/refine_wiring.lua — the replacer side of the picker filter feature.
-- Run:  nvim -l TESTS/refine_wiring.lua
--
-- This file covers `replacer.pickers.common`: the `pickers.refine` handle it
-- builds for an `RP_Match` list, and the `without()` helper the reopen path
-- leans on. pickers.nvim is picked up as a sibling checkout (same rule as
-- lib.nvim); the refine-handle checks are skipped with a note if it is absent.
-- (An earlier version of this comment claimed the picker `run()` functions
-- "need telescope/fzf loaded and are exercised manually" -- they don't, and
-- now aren't: TESTS/pickers_backends.lua drives both with the actual backend
-- module stubbed at package.loaded, covering the `<C-f>` filter wiring this
-- feature adds to each picker's attach_mappings/actions table.)
---@diagnostic disable: need-check-nil

vim.opt.runtimepath:append(vim.fn.getcwd())

local this = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local add_lib_nvim = dofile((this:match("^(.*)/[^/]+$") or ".") .. "/resolve_lib_nvim.lua")
if not add_lib_nvim() then
  print("FAIL  cannot locate lib.nvim (a runtime dependency of replacer.nvim).")
  os.exit(1)
end
local add_ui_nvim = dofile((this:match("^(.*)/[^/]+$") or ".") .. "/resolve_ui_nvim.lua")
if not add_ui_nvim() then
  print("FAIL  cannot locate ui.nvim (a runtime dependency of replacer.nvim).")
  os.exit(1)
end

-- pickers.nvim: the CI checkout below .deps/, a sibling checkout, else the
-- lazy-managed copy. Built by appending — a nil $PICKERS_NVIM_PATH at index 1
-- would stop ipairs early.
do
  local cands = {}
  if vim.env.PICKERS_NVIM_PATH then
    cands[#cands + 1] = vim.env.PICKERS_NVIM_PATH
  end
  cands[#cands + 1] = vim.fn.getcwd() .. "/.deps/pickers.nvim"
  cands[#cands + 1] = vim.fn.getcwd() .. "/../pickers.nvim"
  cands[#cands + 1] = vim.fn.stdpath("data") .. "/lazy/pickers.nvim"
  for _, p in ipairs(cands) do
    local norm = vim.fs.normalize(p)
    if vim.fn.isdirectory(norm .. "/lua/pickers") == 1 then
      vim.opt.rtp:append(norm)
      package.path =
        table.concat({ norm .. "/lua/?.lua", norm .. "/lua/?/init.lua", package.path }, ";")
      break
    end
  end
end

local passed, failed = 0, 0
local function check(name, cond, detail)
  if cond then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (detail and ("  → " .. detail) or ""))
  end
end

local common = require("replacer.pickers.common")

-- ── without() ───────────────────────────────────────────────────────────────
do
  local list = { { id = 1 }, { id = 2 }, { id = 3 } }
  local out = common.without(list, 2)
  check("without: drops the id", #out == 2 and out[1].id == 1 and out[2].id == 3)
  check("without: input untouched", #list == 3)
  check("without: missing id is a no-op copy", #common.without(list, 99) == 3)
end

-- ── new_refine() ────────────────────────────────────────────────────────────
do
  local has_pickers = pcall(require, "pickers.refine")
  if not has_pickers then
    print("  skip refine-handle checks (pickers.nvim not found)")
  else
    local h = common.new_refine()
    check("new_refine: returns a handle when pickers.nvim is present", h ~= nil)

    local matches = {
      { id = 1, path = vim.fn.getcwd() .. "/lua/replacer/apply.lua", line = "local M = {}" },
      { id = 2, path = vim.fn.getcwd() .. "/lua/replacer/rg.lua", line = "run ripgrep here" },
      { id = 3, path = vim.fn.getcwd() .. "/docs/FEATURES.md", line = "ripgrep is the default" },
    }

    -- path filter matches the cwd-relative form the list shows
    local prev = vim.ui
    vim.ui = {
      select = function(choices, _o, cb)
        for _, c in ipairs(choices) do
          if c.kind == "add" and c.field == "path" and not c.negate then
            return cb(c)
          end
        end
      end,
      input = function(_o, cb)
        cb("lua/replacer")
      end,
    }
    h:prompt(function() end)
    local f1 = h:apply(matches)
    check("new_refine: path clause filters on the relative path", #f1 == 2)

    -- stack a content-excludes clause
    vim.ui = {
      select = function(choices, _o, cb)
        for _, c in ipairs(choices) do
          if c.kind == "add" and c.field == "content" and c.negate then
            return cb(c)
          end
        end
      end,
      input = function(_o, cb)
        cb("ripgrep")
      end,
    }
    h:prompt(function() end)
    local f2 = h:apply(matches)
    check("new_refine: clauses stack (path AND ¬content)", #f2 == 1 and f2[1].id == 1)

    check(
      "new_refine: title reflects the stack",
      h:title("Select matches", #f2, #matches):find("¬content", 1, true) ~= nil
    )

    vim.ui = prev
  end
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
