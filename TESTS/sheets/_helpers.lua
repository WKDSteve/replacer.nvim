-- TESTS/sheets/_helpers.lua -- what the replacer.nvim test sheets need in their child editor. Not a sheet
-- (`testing.sheet` only reads *.sheet.lua); a sheet's first step runs it with `dofile` while the child's cwd is
-- still the project root. The directory is in the spec's @cache-inputs, so a change here re-runs the sheets.
--
-- Every sheet works in a throwaway project below the child's temp directory and `:cd`s into it before the first
-- `:Replace`: the plugin writes files, and the checkout must never be one of them. ripgrep and git run for real.

vim.opt.shortmess:append("I")
vim.o.swapfile = false
vim.o.more = false

-- Every notification, for the steps that look at the wording.
_G.notes = {}
vim.notify = function(msg)
  _G.notes[#_G.notes + 1] = tostring(msg)
end

---Whether a notification so far holds `text` (plain).
---@param text string
---@return boolean
function _G.noted(text)
  for _, n in ipairs(_G.notes) do
    if n:find(text, 1, true) then
      return true
    end
  end
  return false
end

---A fresh, empty project directory below the child's temp dir; the editor's cwd moves there.
---@return string root
function _G.sandbox()
  local root = vim.fs.normalize(vim.fn.tempname()) .. "-proj"
  vim.fn.mkdir(root, "p")
  vim.cmd.cd(vim.fn.fnameescape(root))
  _G.root = root
  return root
end

---Write `text` to `rel` below the sandbox (parents created).
---@param rel string
---@param text string
function _G.put(rel, text)
  local path = _G.root .. "/" .. rel
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---The content of `rel` below the sandbox, nil when it does not exist.
---@param rel string
---@return string|nil
function _G.get(rel)
  local f = io.open(_G.root .. "/" .. rel, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

---Run git in the sandbox (for building the fixture repository); raises on a failure.
---@param ... string
function _G.git(...)
  local argv = {
    "git",
    "-c",
    "user.name=sheet",
    "-c",
    "user.email=sheet@example.test",
    "-c",
    "commit.gpgsign=false",
  }
  vim.list_extend(argv, { ... })
  local r = vim.system(argv, { cwd = _G.root, text = true }):wait()
  assert(r.code == 0, table.concat(argv, " ") .. ": " .. tostring(r.stderr))
end

---The quickfix list as sorted `basename:lnum` entries.
---@return string
function _G.qf()
  local names = {}
  for _, e in ipairs(vim.fn.getqflist()) do
    names[#names + 1] = vim.fs.basename(vim.fs.normalize(vim.fn.bufname(e.bufnr))) .. ":" .. e.lnum
  end
  table.sort(names)
  return table.concat(names, " ")
end

---Whether `text` (plain) is in a line of any window of the current tab: the floats of a dialog too.
---@param text string
---@return boolean
function _G.screen_has(text)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    if table.concat(lines, "\n"):find(text, 1, true) then
      return true
    end
  end
  return false
end
