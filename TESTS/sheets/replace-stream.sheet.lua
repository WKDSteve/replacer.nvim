-- Feature sheet: :Replace --stream, the incremental ripgrep --json parser (lua/replacer/rg.lua,
-- collect_streaming), with the real ripgrep in a throwaway project.
return {
  id = "replacer.replace-stream",
  feature = "replacer.replace-stream",
  title = "replacer.nvim: :Replace --stream parses ripgrep's output as it arrives and finds the same matches",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.sandbox()
      for i = 1, 30 do
        _G.put(("f%02d.txt"):format(i), ("line %d with foo\nfoo again\n"):format(i))
      end
      _G.put("no.txt", "nothing\n")]],
      note = "thirty files with two matches each",
    },
    { keys = ":Replace foo baz cwd --stream --to-quickfix<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 60]],
      timeout = 5000,
      note = "every match of the streamed output arrives",
    },
    {
      expect = [[_G.qf():find("f01.txt:1 f01.txt:2", 1, true) and not _G.qf():find("no.txt", 1, true)]],
      note = "real file:line entries, not the file without a match",
    },
    {
      expect = [[_G.get("f01.txt") == "line 1 with foo\nfoo again\n"]],
      note = "nothing is written",
    },
  },
}
