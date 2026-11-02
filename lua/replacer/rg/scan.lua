---@module 'replacer.rg.scan'
--- Shared helpers of the search backends (`replacer.rg`, `replacer.rg.vimgrep`):
--- the optional progress handle and the per-line occurrence scanner.
---
---@see replacer.rg
---@see replacer.rg.vimgrep

local M = {}

--------------------------------------------------------------------------------
-- Progress reporting (optional: soft dependency on lib.nvim)
--------------------------------------------------------------------------------

local ok_progress, progress_mod = pcall(require, "lib.nvim.progress")

---@internal
--- Start a progress handle, or nil when lib.nvim isn't installed. Every call
--- site must guard with `if h then ... end` — the search still works without
--- lib.nvim, only the indicator is skipped.
---@param cfg RP_RG_Config
---@return Lib.Progress.Handle|nil
function M.new_progress(cfg)
  if not ok_progress then
    return nil
  end
  return progress_mod.create({ title = "[replacer]", style = cfg.progress_style or "auto" })
end

--------------------------------------------------------------------------------
-- Shared: occurrence scanning
--------------------------------------------------------------------------------

---@internal
--- Find every occurrence of `pattern` in `line_text`.
--- Literal mode uses plain byte search; regex mode uses Vim regex via matchstrpos.
---@param line_text string
---@param pattern string
---@param literal boolean
---@return { start0: integer, end0: integer, text: string }[]
function M.find_all_occurrences(line_text, pattern, literal)
  local out = {}
  if line_text == "" or not pattern or pattern == "" then
    return out
  end

  local n = 0 -- explicit index avoids recomputing #out per append
  if literal then
    local start = 1
    while true do
      local s, e = line_text:find(pattern, start, true)
      if not s then
        break
      end
      n = n + 1
      out[n] = { start0 = s - 1, end0 = e - 1, text = line_text:sub(s, e) }
      start = e + 1
    end
  else
    local pos = 0
    while true do
      local mt = vim.fn.matchstrpos(line_text, pattern, pos)
      local matched, s, e = mt[1], mt[2], mt[3]
      if s == -1 or not matched or matched == "" then
        break
      end
      n = n + 1
      out[n] = { start0 = s, end0 = e - 1, text = matched }
      pos = e
      if pos >= #line_text then
        break
      end
    end
  end
  return out
end

return M
