-- TESTS/resolve_lib_nvim.lua — copied from lib.nvim/templates/resolve_lib_nvim.lua.
--
-- `nvim -l TESTS/<suite>.lua` starts with lib.nvim absent from both
-- `runtimepath` and `package.path`, so every module that hard-requires
-- `lib.nvim.*` (replacer.notify, replacer.gitfiles, ...) dies on the first
-- require. This puts lib.nvim on the path before any suite requires replacer.
--
-- Loaded with `dofile`, never `require`: the whole point is to run *before*
-- lib.nvim is requireable, so it cannot itself live under `lua/lib/`. It is
-- kept as one shared file rather than pasted into all three runners so the
-- three copies cannot drift apart.
--
-- Recognizes, in priority order:
--   1. $LIB_NVIM_PATH        -- explicit override (CI, worktrees, non-standard layouts)
--   2. <repo>/../lib.nvim    -- sibling checkout (the common local-dev layout)
--   3. stdpath("data")/lazy/lib.nvim -- the lazy.nvim-managed copy
--
-- A sibling checkout wins over the plugin-manager copy on purpose: the
-- lazy.nvim-managed clone is frequently older than the working checkout, and
-- testing against a stale lib.nvim gives misleading failures.

---@return string|nil lib_nvim_root  Absolute, normalized path, or nil if not found.
local function add_lib_nvim()
  -- Built by appending, not as a literal: an unset $LIB_NVIM_PATH would put a
  -- nil at index 1 and `ipairs` would stop before checking anything.
  local candidates = {}
  if vim.env.LIB_NVIM_PATH then
    candidates[#candidates + 1] = vim.env.LIB_NVIM_PATH
  end
  -- testing.nvim sets $LIB_NVIM_DIR for every dependency it resolved: under `ci commit` the project
  -- is a worktree in the temp directory, with no sibling checkout beside it.
  if vim.env.LIB_NVIM_DIR then
    candidates[#candidates + 1] = vim.env.LIB_NVIM_DIR
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/../lib.nvim"
  candidates[#candidates + 1] = vim.fn.stdpath("data") .. "/lazy/lib.nvim"

  for _, path in ipairs(candidates) do
    -- Normalize first: the sibling candidate contains a ".." segment and the
    -- stdpath one mixes separators on Windows; the runtimepath module searcher
    -- does not resolve either, so an unnormalized entry silently finds nothing.
    local norm = vim.fs.normalize(path)
    if vim.fn.isdirectory(norm .. "/lua/lib") == 1 then
      vim.opt.rtp:append(norm)
      -- rtp alone is not enough here: the runtimepath searcher does not pick
      -- up entries appended after startup on every Neovim version this suite
      -- may run under. lib.nvim's own README prescribes registering it on
      -- package.path as well (the C require searcher is the fallback that
      -- always applies).
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

return add_lib_nvim
