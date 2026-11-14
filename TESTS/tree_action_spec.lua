-- Headless test for the tree action: "Replace in this file or folder" registered at
-- lib.nvim.tree.registry (`replacer.integrations.tree`), which the own tree of filetree.nvim reads.
-- What is checked here is the entry and what its `run` does with a node; that a tree offers a
-- registered action on a key and in its menu is filetree.nvim's own spec.
-- Run:  nvim -l TESTS/tree_action_spec.lua

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

local registry = require("lib.nvim.tree.registry")
local replacer = require("replacer")
local tree = require("replacer.integrations.tree")

---The registered entry, or nil.
local function entry()
  return registry.get("action", tree.NAME)
end

-- the questions of the action, answered from a queue; every prompt is recorded
local answers, prompts = {}, {}
local real_input = vim.ui.input
---@diagnostic disable-next-line: duplicate-set-field
vim.ui.input = function(opts, cb)
  prompts[#prompts + 1] = opts.prompt
  cb(table.remove(answers, 1))
end

-- what `:Replace` would be run with
local runs = {}
local real_run = replacer.run
---@diagnostic disable-next-line: duplicate-set-field
replacer.run = function(old, new, scope)
  runs[#runs + 1] = { old, new, scope }
end

-- ── setup registers it ────────────────────────────────────────────────────────
replacer.setup({ deps_popup = false })
local action = entry()
check("setup registers the action at the tree registry", action ~= nil)
check("it applies to a node with a path", vim.deep_equal(action.needs, { "path" }))
check("it says that it changes files", action.mutates == true)
check("without a configured key it has none", action.key == nil)
check("it has a description for the menu", type(action.desc) == "string" and action.desc ~= "")

-- ── what it runs ──────────────────────────────────────────────────────────────
local folder = vim.fn.tempname():gsub("\\", "/") .. "/src"
answers = { "old name", "new name" }
action.run({ { path = folder, kind = "dir" } }, {})
check("it asks for the text to find, naming the node", prompts[1] == "Replace in src: ", prompts[1])
check(
  "... and for the replacement, naming what is replaced",
  prompts[2] == 'Replace "old name" with: ',
  prompts[2]
)
check(
  "... and runs the replace with the node as the scope",
  vim.deep_equal(runs, { { "old name", "new name", folder } }),
  vim.inspect(runs)
)

runs, prompts, answers = {}, {}, { "gone", "" }
action.run({ { path = folder .. "/a.lua", kind = "file" } }, {})
check(
  "an empty replacement is a deletion",
  vim.deep_equal(runs, { { "gone", "", folder .. "/a.lua" } }),
  vim.inspect(runs)
)

runs, prompts, answers = {}, {}, {}
action.run({ { path = folder, kind = "dir" } }, {})
check("a cancelled first question runs nothing", #runs == 0 and #prompts == 1)

runs, prompts, answers = {}, {}, { "" }
action.run({ { path = folder, kind = "dir" } }, {})
check("an empty search text runs nothing", #runs == 0 and #prompts == 1)

runs, prompts, answers = {}, {}, { "x" }
action.run({ { path = folder, kind = "dir" } }, {})
check("a cancelled second question runs nothing", #runs == 0 and #prompts == 2)

runs, prompts = {}, {}
action.run({ { id = "heading", kind = "group" } }, {})
action.run({}, {})
check("a node without a path, or none, asks nothing", #runs == 0 and #prompts == 0)

-- ── the option ────────────────────────────────────────────────────────────────
replacer.setup({ deps_popup = false, tree = { key = "<leader>r" } })
check("tree = { key = ... } puts the action on that key", entry() and entry().key == "<leader>r")
check("... as one entry, not two", #vim.tbl_filter(function(e)
  return e.name == tree.NAME
end, registry.list("action")) == 1)

replacer.setup({ deps_popup = false, tree = { key = 7 } })
check("a key that is none keeps the default (offered, no key)", entry() and entry().key == nil)

replacer.setup({ deps_popup = false, tree = false })
check("tree = false takes the action out", entry() == nil)

replacer.setup({ deps_popup = false })
check("the default offers it again", entry() ~= nil)
tree.unregister()
check("unregister removes it", entry() == nil)
tree.unregister()
check("... and a second unregister is harmless", entry() == nil)

vim.ui.input = real_input
replacer.run = real_run

print(("\nreplacer.nvim tree_action_spec: %d passed, %d failed"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
