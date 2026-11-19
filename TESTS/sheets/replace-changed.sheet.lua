-- Feature sheet: :Replace --changed narrows the search to the files git reports as changed (lua/replacer/gitfiles.lua,
-- lib.nvim's status_porcelain_async), in a throwaway git repository; git and ripgrep run for real.
return {
  id = "replacer.replace-changed",
  feature = "replacer.replace-changed",
  title = "replacer.nvim: :Replace --changed searches only the modified, staged or untracked files of the repository",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.sandbox()
      _G.put("clean.txt", "foo clean\n")
      _G.put("mod.txt", "foo before\n")
      _G.put("staged.txt", "foo before\n")
      _G.git("init", "-q")
      _G.git("add", ".")
      _G.git("commit", "-q", "-m", "init")
      _G.put("mod.txt", "foo modified\n")
      _G.put("staged.txt", "foo staged\n")
      _G.git("add", "staged.txt")
      _G.put("new.txt", "foo untracked\n")]],
      note = "a repository with one clean, one modified, one staged and one untracked file",
    },
    { keys = ":Replace foo baz cwd --changed=modified --to-quickfix<CR>" },
    { wait = [[#vim.fn.getqflist() == 1]], timeout = 5000, note = "git was asked, then ripgrep" },
    { expect = [[_G.qf() == "mod.txt:1"]], note = "only the modified file" },
    { lua = [[vim.cmd("cclose"); vim.fn.setqflist({}, "r")]] },

    { keys = ":Replace foo baz cwd --changed --to-quickfix<CR>" },
    {
      wait = [[#vim.fn.getqflist() == 3]],
      timeout = 5000,
      note = "the bare flag means every kind",
    },
    {
      expect = [[_G.qf() == "mod.txt:1 new.txt:1 staged.txt:1"]],
      note = "modified, staged and untracked; the clean file is left out",
    },
  },
}
