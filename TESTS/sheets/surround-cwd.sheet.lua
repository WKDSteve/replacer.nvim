-- Feature sheet: :Surround over the working directory (the :Replace pipeline with the real ripgrep), idempotent.
return {
  id = "replacer.surround-cwd",
  feature = "replacer.surround-cwd",
  title = "replacer.nvim: :Surround! wraps every match across the working directory and skips the wrapped ones",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.sandbox()
      _G.put("a.md", "a word here\nand **word** done\n")
      _G.put("b.md", "word\n")]],
      note = "one match is already bold",
    },
    { keys = ":Surround! word ** cwd<CR>" },
    {
      wait = [[_G.screen_has("Apply ALL")]],
      timeout = 5000,
      note = "the bang asks once",
    },
    { keys = "y" },
    {
      wait = [[_G.get("b.md") == "**word**\n"]],
      timeout = 5000,
      note = "the match is wrapped",
    },
    {
      expect = [[_G.get("a.md") == "a **word** here\nand **word** done\n"]],
      note = "the wrapped one is left alone",
    },
  },
}
