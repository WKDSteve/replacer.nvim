---@module 'replacer.integrations.tree'
---@brief "Replace in this file or folder" as an action on a node of a tree view.
---@description
--- Registers one action at `lib.nvim.tree.registry`. A tree that reads the registry (the own tree of
--- filetree.nvim) offers it on every node that is a file or a folder on disk: in its context menu, in
--- its action list, and on a key when one is configured. The action asks for the text to find and the
--- text to put in its place, and runs `:Replace` with the node as the scope, so the matches go
--- through the same picker, dry run and undo as a `:Replace` typed by hand.
---
--- Soft in both directions. The registry is lib.nvim's: without a tree that reads it the entry is never
--- looked at, and without a lib.nvim that has the registry nothing is registered.

local M = {}

M.NAME = "replacer.replace"

---@class Replacer.Tree.Opts
---@field key? string|string[]|false  Key(s) in the tree buffer (default: none; the action is in the menu).

---@type fun()|nil
local unregister = nil

---Ask one line. `nil` when the person gave up.
---@param prompt string
---@param cb fun(text: string|nil)
local function ask(prompt, cb)
  vim.ui.input({ prompt = prompt }, cb)
end

---Ask what to replace by what and run it on `path`. An empty search text or a cancelled question
---runs nothing; an empty replacement is a deletion and is asked for as such.
---@param path string  A file or a folder.
---@param run? fun(old: string, new: string, scope: string)  Default: `require("replacer").run`.
function M.replace_in(path, run)
  run = run or function(old, new, scope)
    require("replacer").run(old, new, scope)
  end
  local name = vim.fn.fnamemodify(path, ":t")
  if name == "" then
    name = path
  end
  ask(("Replace in %s: "):format(name), function(old)
    if old == nil or old == "" then
      return
    end
    ask(("Replace %q with: "):format(old), function(new)
      if new == nil then
        return
      end
      run(old, new, path)
    end)
  end)
end

---Register the action. Without `lib.nvim.tree.registry` (an older lib.nvim) nothing happens.
---@param opts? Replacer.Tree.Opts
---@return boolean registered
function M.register(opts)
  local ok, registry = pcall(require, "lib.nvim.tree.registry")
  if not ok or type(registry.action) ~= "function" then
    return false
  end
  M.unregister()
  opts = opts or {}
  unregister = registry.action({
    name = M.NAME,
    desc = "Replace in this file or folder (replacer.nvim)",
    key = opts.key or nil,
    needs = { "path" },
    mutates = true,
    run = function(nodes)
      local node = nodes and nodes[1]
      if node and type(node.path) == "string" then
        M.replace_in(node.path)
      end
    end,
  })
  return true
end

---Take the action out again.
function M.unregister()
  if unregister then
    unregister()
    unregister = nil
  end
end

return M
