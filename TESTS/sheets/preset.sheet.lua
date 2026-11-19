-- Feature sheet: a named preset is saved and run again later, over the working directory (the real ripgrep).
-- A preset keeps the request, its flags and `--all`; an output mode (--dry, --to-quickfix) is chosen per run.
return {
  id = "replacer.preset",
  feature = "replacer.preset",
  title = "replacer.nvim: :ReplaceSavePreset keeps a request with its flags, :ReplacePreset runs it as saved",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.sandbox()
      _G.put("a.lua", "old_name()\n")
      _G.put("b.txt", "old_name\n")]],
      note = "the preset is kept below the child's sandboxed stdpath('data')",
    },
    { keys = ":ReplaceSavePreset lua-only old_name new_name cwd --type=lua --all<CR>" },
    { wait = [[_G.noted("preset 'lua-only' saved")]], note = "saving runs nothing" },
    { expect = [[_G.get("a.lua") == "old_name()\n"]] },
    { keys = ":ReplacePreset lua-only<CR>" },
    {
      wait = [[_G.screen_has("Apply ALL 1 spot")]],
      timeout = 5000,
      note = "ripgrep found the one .lua match",
    },
    { keys = "y" },
    { wait = [[_G.get("a.lua") == "new_name()\n"]], timeout = 5000, note = "applied as saved" },
    {
      expect = [[_G.get("b.txt") == "old_name\n"]],
      note = "the saved --type=lua leaves the .txt file alone",
    },
  },
}
