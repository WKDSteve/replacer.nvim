-- Feature sheet: a project-wide :Replace, as a user runs it, with the real ripgrep in a throwaway project. The
-- search is the asynchronous ripgrep backend (lua/replacer/rg.lua, collect_ripgrep_async); the quickfix run and the
-- dry run write nothing, the bang writes every match.
return {
  id = "replacer.replace-cwd",
  feature = "replacer.replace-cwd",
  title = "replacer.nvim: :Replace over the working directory to the quickfix list, as a dry run and with the bang",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.sandbox()
      _G.put("a.lua", "local foo = 1\nprint(foo)\n")
      _G.put("sub/b.txt", "foo and foo\nbar\n")
      _G.put("c.md", "nothing here\n")]],
      note = "a throwaway project, the editor's cwd moves into it",
    },
    { keys = ":Replace foo baz cwd --to-quickfix<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 4]],
      timeout = 5000,
      note = "ripgrep found every occurrence",
    },
    {
      expect = [[_G.qf() == "a.lua:1 a.lua:2 b.txt:1 b.txt:1"]],
      note = "two on one line are two entries",
    },
    {
      expect = [[_G.get("a.lua") == "local foo = 1\nprint(foo)\n"]],
      note = "the quickfix run writes nothing",
    },
    { lua = [[vim.cmd("cclose"); vim.fn.setqflist({}, "r")]] },

    { keys = ":Replace foo baz cwd --dry<CR>" },
    {
      wait = [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("+local baz = 1", 1, true)]],
      timeout = 5000,
      note = "the dry run shows the diff it would apply",
    },
    { expect = [[_G.get("sub/b.txt") == "foo and foo\nbar\n"]], note = "and writes nothing" },
    { lua = [[vim.cmd("silent! only"); _G.notes = {}]] },

    { keys = ":Replace! foo baz cwd<CR>" },
    {
      wait = [[_G.screen_has("Apply ALL 4 spot")]],
      timeout = 5000,
      note = "the bang still asks once, naming how many spots and files",
    },
    { keys = "y" },
    {
      wait = [[_G.get("a.lua") == "local baz = 1\nprint(baz)\n"]],
      timeout = 5000,
      note = "the bang applies all",
    },
    { expect = [[_G.get("sub/b.txt") == "baz and baz\nbar\n"]], note = "both on one line" },
    {
      expect = [[_G.get("c.md") == "nothing here\n"]],
      note = "a file without a match is untouched",
    },
  },
}
