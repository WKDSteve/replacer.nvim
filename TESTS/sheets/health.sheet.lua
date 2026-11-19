-- Feature sheet: :checkhealth replacer probes the real ripgrep (its version, a --json test run) and the tools
-- declared through lib.nvim.deps.
return {
  id = "replacer.health",
  feature = "replacer.health",
  title = "replacer.nvim: :checkhealth replacer finds ripgrep, its version and a working --json output",
  steps = {
    { lua = [[dofile(vim.fn.getcwd() .. "/TESTS/sheets/_helpers.lua")]] },
    { keys = ":checkhealth replacer<CR>", ignore_errmsg = true },
    {
      wait = [[vim.bo.filetype == "checkhealth"
        and table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Summary", 1, true)]],
      timeout = 15000,
      note = "the report is written",
    },
    {
      expect = [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Found ripgrep", 1, true)]],
      note = "rg --version was run",
    },
    {
      expect = [[table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("JSON output working", 1, true)]],
      note = "the --json test run answered",
    },
  },
}
