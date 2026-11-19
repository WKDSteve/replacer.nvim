-- Feature sheet: :ReplaceBatch runs one :Replace per pair of a file over the working directory (the real ripgrep).
return {
  id = "replacer.batch",
  feature = "replacer.batch",
  title = "replacer.nvim: :ReplaceBatch! asks once and runs every pair of a file over the scope",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.sandbox()
      _G.put("src/a.txt", "alpha beta\nalpha\n")
      _G.put("src/b.txt", "beta\n")
      _G.put("pairs.txt", "# two pairs\nalpha => one\nbeta => two\n")]],
      note = "a pair file next to the sources",
    },
    { keys = ":ReplaceBatch! pairs.txt src<CR>" },
    {
      wait = [[_G.screen_has("Apply 2 replace pair")]],
      timeout = 5000,
      note = "one question for the whole batch, naming the pair file",
    },
    { keys = "y" },
    {
      wait = [[_G.get("src/a.txt") == "one two\none\n" and _G.get("src/b.txt") == "two\n"]],
      timeout = 5000,
      note = "both pairs are applied",
    },
    {
      expect = [[_G.get("pairs.txt") == "# two pairs\nalpha => one\nbeta => two\n"]],
      note = "outside the scope",
    },
  },
}
