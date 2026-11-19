-- Feature sheet: :ReplaceHistory offers the last applies in a chooser and runs the picked one again (the real
-- ripgrep). The history lives below the child's sandboxed stdpath('data').
return {
  id = "replacer.history",
  feature = "replacer.history",
  title = "replacer.nvim: :ReplaceHistory lists the applies and re-runs the one picked",
  prompts = "real",
  steps = {
    {
      lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")
      _G.sandbox()
      _G.put("a.txt", "foo\n")]],
    },
    { keys = ":Replace! foo bar cwd<CR>" },
    {
      wait = [[_G.screen_has("Apply ALL")]],
      timeout = 5000,
    },
    { keys = "y" },
    { wait = [[_G.get("a.txt") == "bar\n"]], timeout = 5000, note = "the first apply" },
    {
      lua = [[_G.put("a.txt", "foo again\n"); vim.cmd("silent! %bwipeout!")]],
      note = "the text comes back",
    },
    { keys = ":ReplaceHistory<CR>" },
    {
      wait = [[_G.screen_has("foo -> bar")]],
      timeout = 5000,
      note = "the chooser lists the apply",
    },
    { input = "<CR>", note = "pick it" },
    {
      wait = [[_G.screen_has("Apply ALL")]],
      timeout = 5000,
      note = "it asks as the first run did",
    },
    { keys = "y" },
    {
      wait = [[_G.get("a.txt") == "bar again\n"]],
      timeout = 5000,
      note = "the same replace ran again",
    },
  },
}
