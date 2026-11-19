-- TESTS/sheets/features.lua -- the functionalities of replacer.nvim that start a process (ripgrep, git), as its
-- user meets them; `testing sheets report` says which ones have a feature sheet (`feature = "<id>"`) and `testing
-- perf` measures them through those sheets. Data: read with an empty environment like a sheet (testing.nvim
-- docs/SHEETS.md). The list follows docs/commands.md and docs/FEATURES/.
return {
  {
    id = "replacer.replace-cwd",
    title = ":Replace over the working directory: to the quickfix list, as a dry run with its diff, and with the bang",
    surface = { "command:Replace", "command:Replacer" },
    docs = "docs/commands.md",
  },
  {
    id = "replacer.replace-stream",
    title = ":Replace --stream parses ripgrep's --json output as it arrives",
    surface = { "command:Replace", "config:stream" },
    docs = "docs/commands.md",
  },
  {
    id = "replacer.replace-changed",
    title = ":Replace --changed narrows the search to the files git reports as modified, staged or untracked",
    surface = { "command:Replace" },
    docs = "docs/WORKFLOW.md",
  },
  {
    id = "replacer.surround-cwd",
    title = ":Surround wraps every match across a scope with a delimiter and skips the wrapped ones",
    surface = { "command:Surround", "command:Wrap" },
    docs = "docs/commands.md",
  },
  {
    id = "replacer.batch",
    title = ":ReplaceBatch runs every old => new pair of a file, the clipboard or the quickfix list",
    surface = { "command:ReplaceBatch" },
    docs = "docs/commands.md",
  },
  {
    id = "replacer.preset",
    title = ":ReplaceSavePreset keeps a request with its flags, :ReplacePreset runs it again",
    surface = { "command:ReplaceSavePreset", "command:ReplacePreset" },
    docs = "docs/commands.md",
  },
  {
    id = "replacer.history",
    title = ":ReplaceHistory lists the last applies and re-runs the one picked",
    surface = { "command:ReplaceHistory" },
    docs = "docs/commands.md",
  },
  {
    id = "replacer.root",
    title = ":ReplaceRoot searches the project root detected from the current file",
    surface = { "command:ReplaceRoot" },
    docs = "docs/commands.md",
  },
  {
    id = "replacer.health",
    title = ":checkhealth replacer probes ripgrep (version, a --json test run) and the declared tools",
    docs = "docs/health.md",
  },
  {
    id = "replacer.tree-action",
    title = '"Replace in this file or folder" on a node of a tree view runs :Replace with the node as the scope',
    -- needs a tree that reads lib.nvim's tree registry (filetree.nvim); its search is the one of replacer.replace-cwd
    perf = "user",
  },
  {
    id = "replacer.lsp-rename",
    title = ":Replace --lsp upgrades identifier-shaped matches to a rename through the attached language server",
    surface = { "command:Replace" },
    perf = "user",
  },
}
