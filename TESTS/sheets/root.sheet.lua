-- Feature sheet: :ReplaceRoot detects the project root from the current buffer and searches all of it.
return {
  id = "replacer.root",
  feature = "replacer.root",
  title = "replacer.nvim: :ReplaceRoot searches the project root of the current file, not only its folder",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.sandbox()
      vim.fn.mkdir(_G.root .. "/.git", "p")
      _G.put("top.txt", "foo top\n")
      _G.put("deep/er/inner.txt", "foo inner\n")
      vim.cmd.edit(vim.fn.fnameescape(_G.root .. "/deep/er/inner.txt"))
      vim.cmd.cd(vim.fn.fnameescape(_G.root .. "/deep"))]],
      note = "a project with a .git marker; the file is two folders down, the cwd one",
    },
    { keys = ":ReplaceRoot foo baz --to-quickfix<CR>" },
    { wait = [[#vim.fn.getqflist() == 2]], timeout = 5000, note = "ripgrep over the whole root" },
    {
      expect = [[_G.qf() == "inner.txt:1 top.txt:1"]],
      note = "the file above the cwd is found too",
    },
  },
}
