---@module 'replacer.perfile'
--- Per-file confirmation step for ALL-mode applies (--confirm-per-file):
--- instead of one global "apply ALL N spots across M files?" confirm, ask
--- All/Skip/Only-some/Quit for each file in turn.
---
--- Uses ui.kit.confirm, which is async/callback-based (no blocking
--- return value like the native vim.fn.confirm this replaces). The file loop
--- is therefore callback-recursive: each file's confirm only advances to the
--- next one from inside its own on_answer callback, and the final totals are
--- delivered via `on_done` instead of a synchronous return. "Only some"
--- hands the file to a picker and waits for that picker session to end
--- before it asks about the next file, so no confirm float ever opens over
--- the still-open picker -- see the "Only some" branch below.

local confirm = require("ui.kit.confirm")

local M = {}

---@internal
--- Group matches by file path, returning a stable (sorted) path order so
--- the confirmation sequence is deterministic/reproducible.
---@param items RP_Match[]
---@return table<string, RP_Match[]> by_path, string[] paths
local function group_by_path_sorted(items)
  local by_path = {}
  for i = 1, #items do
    local it = items[i]
    local t = by_path[it.path]
    if not t then
      t = {}
      by_path[it.path] = t
    end
    t[#t + 1] = it
  end
  local paths = {}
  for p in pairs(by_path) do
    paths[#paths + 1] = p
  end
  table.sort(paths)
  return by_path, paths
end

--- Run the per-file confirmation loop, applying accepted files immediately.
---@param items RP_Match[]
---@param new_text string
---@param write_changes boolean
---@param apply_func fun(items: RP_Match[], new_text: string, write_changes: boolean, on_result?: fun(files: integer, spots: integer))
---@param on_pick_file fun(items: RP_Match[], on_close: fun())   # "Only some": open a picker scoped to this file; call on_close once that picker session is over
---@param on_done fun(files: integer, spots: integer)  # called once the loop ends (Quit/<Esc> or all files seen); the totals count only perfile's own "All" applies
function M.run(items, new_text, write_changes, apply_func, on_pick_file, on_done)
  local by_path, paths = group_by_path_sorted(items)
  local total_files, total_spots = 0, 0

  local step

  step = function(i)
    local path = paths[i]
    if not path then
      on_done(total_files, total_spots)
      return
    end

    local list = by_path[path]
    local rel = vim.fn.fnamemodify(path, ":.")

    confirm.open({
      question = string.format("%s (%d match(es))", rel, #list),
      choices = { "All", "Skip", "Only some", "Quit" },
      default = 1, -- the kit focuses the safe button otherwise (Quit)
      on_answer = function(choice)
        if choice == "All" then
          -- apply_func may apply asynchronously (wide file set); advance the
          -- per-file loop only once it has settled so the totals are accurate.
          apply_func(list, new_text, write_changes, function(f, s)
            total_files = total_files + f
            total_spots = total_spots + s
            step(i + 1)
          end)
          return
        elseif choice == "Only some" then
          -- UI-53: hand the file to the picker and do NOT advance yet.
          -- Stacking the next confirm float over the still-open picker
          -- corrupts its internal registry (the same class of bug
          -- pickers/telescope.lua's `do_all` guards against by closing its
          -- own picker before opening a second float). The picker calls
          -- on_close once its session is over -- window closed, its apply
          -- or confirm settled, no reopen pending -- and only then does
          -- the review go on with the remaining files (UI-05: the choice
          -- for this file must not take the independent rest with it).
          local resumed = false
          on_pick_file(list, function()
            if resumed then
              return
            end
            resumed = true
            step(i + 1)
          end)
          return
        elseif choice == nil or choice == "Quit" then -- <Esc>/q or explicit Quit
          on_done(total_files, total_spots)
          return
        end
        -- "Skip": continue to the next file.
        step(i + 1)
      end,
    })
  end

  step(1)
end

return M
