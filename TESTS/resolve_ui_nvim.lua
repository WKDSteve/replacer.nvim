-- TESTS/resolve_ui_nvim.lua — ui.nvim's counterpart to resolve_lib_nvim.lua,
-- same file, same reasoning, one dependency over: `ui.kit.confirm` moved out
-- of `lib.nvim.ui.kit` in the 2026-09 migration, and replacer.init requires
-- it unconditionally at module load (same tier as lib.nvim.notify/gitfiles),
-- so `nvim -l TESTS/<suite>.lua` needs ui.nvim resolvable too, before any
-- suite requires replacer.
--
-- Loaded with `dofile`, never `require`, for the same reason
-- resolve_lib_nvim.lua is: it has to run *before* ui.nvim is requireable, so
-- it cannot itself live under `lua/ui/`. Kept as one shared file rather than
-- pasted into each runner so the copies cannot drift apart.
--
-- Recognizes, in priority order:
--   1. $UI_NVIM_PATH         -- explicit override (CI, worktrees, non-standard layouts)
--   2. <repo>/../ui.nvim     -- sibling checkout (the common local-dev layout)
--   3. stdpath("data")/lazy/ui.nvim -- the lazy.nvim-managed copy
--
-- A sibling checkout wins over the plugin-manager copy on purpose, same as
-- resolve_lib_nvim.lua: the lazy.nvim-managed clone is frequently older than
-- the working checkout, and testing against a stale ui.nvim gives misleading
-- failures.

---@return string|nil ui_nvim_root  Absolute, normalized path, or nil if not found.
local function add_ui_nvim()
  local candidates = {}
  if vim.env.UI_NVIM_PATH then
    candidates[#candidates + 1] = vim.env.UI_NVIM_PATH
  end
  -- testing.nvim sets $UI_NVIM_DIR for every dependency it resolved: under `ci commit` the project
  -- is a worktree in the temp directory, with no sibling checkout beside it.
  if vim.env.UI_NVIM_DIR then
    candidates[#candidates + 1] = vim.env.UI_NVIM_DIR
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/../ui.nvim"
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/ui.nvim"

  for _, path in ipairs(candidates) do
    local norm = vim.fs.normalize(path)
    if vim.fn.isdirectory(norm .. "/lua/ui") == 1 then
      vim.opt.rtp:append(norm)
      -- rtp alone is not enough here either -- see resolve_lib_nvim.lua's
      -- own comment on why package.path also needs the entry.
      package.path = table.concat({
        norm .. "/lua/?.lua",
        norm .. "/lua/?/init.lua",
        package.path,
      }, ";")
      return norm
    end
  end
  return nil
end

return add_ui_nvim
