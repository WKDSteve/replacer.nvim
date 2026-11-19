# Bindings Cheatsheet

Every user command, keymap, and autocommand replacer.nvim registers, in one
place.

---

## User commands

| Command | File | Description |
| --- | --- | --- |
| `:Replace` | [command.lua](../lua/replacer/command.lua) | Search-and-replace with scope/flags/range; see `:help replacer-commands` |
| `:Replacer` | [command.lua](../lua/replacer/command.lua) | Alias for `:Replace` |
| `:Surround` | [surround.lua](../lua/replacer/surround.lua) | Wrap every match of a pattern with a delimiter; see `:help :Surround` |
| `:Wrap` | [surround.lua](../lua/replacer/surround.lua) | Alias for `:Surround` |
| `:ReplaceEscape {text}` | [regex.lua](../lua/replacer/regex.lua) | Escape `{text}` for use as a Vim regex pattern; echoes it and copies it to the unnamed register |
| `:ReplaceTest [pattern] [sample]` | [regex.lua](../lua/replacer/regex.lua) | Small floating live pattern-test panel: line 1 is the pattern, line 2 the sample text, matches highlight as you type; `<Esc>`/`q` closes |
| `:ReplaceRoot[!] {old} {new} [--flags]` | [root.lua](../lua/replacer/root.lua) | Like `:Replace`, but the scope is an auto-detected project root; prompts when detection finds more than one candidate |
| `:ReplaceUndo [id]` | [checkpoint.lua](../lua/replacer/checkpoint.lua) | Restore files from a `--checkpoint` snapshot (most recent when `[id]` omitted) |
| `:ReplaceHistory` | [history.lua](../lua/replacer/history.lua) | A chooser (`ui.kit` select) over the last `history_max_entries` applies (default 50); re-runs the chosen one |
| `:ReplaceSavePreset {name} {old} {new} [scope] [--flags]` | [presets.lua](../lua/replacer/presets.lua) | Save a named, reusable replace request |
| `:ReplacePreset {name}` | [presets.lua](../lua/replacer/presets.lua) | Run a saved preset exactly as saved; `<Tab>` completes names |
| `:ReplaceBatch[!] {source} [scope] [--flags]` | [batch.lua](../lua/replacer/batch.lua) | Run multiple `{old → new}` pairs from a file/clipboard/quickfix, one full `:Replace` dispatch per pair |
| `:ReplaceFNames[!] {old} {new} [scope] [--dry]` | [fnames.lua](../lua/replacer/fnames.lua) | Rename every file/directory under scope whose basename contains `{old}`; a nested match is skipped in favor of its renamed ancestor |
| `:ReplaceDebug` | [debug.lua](../lua/replacer/debug.lua) | Developer utility: `on`/`off`/`status`/`inspect`/`analyze <line> <pattern>`; registered on first use, not at load. See [troubleshooting.md](troubleshooting.md) |

All support `[range]` and the bang form (`!`) where documented in `:help replacer-commands`.

### `<Tab>` completion on `:Replace`/`:Replacer`/`:Surround`/`:Wrap`

| Position | Completes to |
| --- | --- |
| `{scope}` | `%`, `cwd`, `.`, `root` |
| `--` | every one of the 41 flags (43 on `:Surround`) |
| `--type=` | ripgrep's own type names, read live from `rg --type-list` |
| `--changed=` | `modified`/`staged`/`untracked`, comma-joinable — a second `<Tab>` after a comma offers only the kinds not yet named |
| `--engine=` | `fzf`, `telescope` |
| `--export=` | file paths |

`{old}`/`{new}` are arbitrary text and have nothing to complete against.
A quoted run counts as one argument here, as it does for the command itself:
after `:Replace "foo bar" ` the slot is `{new}`, not `[scope]` (for
`:Surround`/`:Wrap` it is `[delim]`; the four verbs
set composer's `quotes = true`, so `<Tab>` and the option float cut the line
the way `ctx.raw.args` is cut).
`--glob=`/`--exclude=` deliberately do not complete: they take *patterns*, and
offering existing paths would suggest `lua/replacer/command.lua` where the flag
wants `**/*.lua` — a candidate that is accepted, matches a single file, and
silently narrows the replacement. `--context=`/`--max-filesize=` are integers.

See [`lua/replacer/argtypes.lua`](../lua/replacer/argtypes.lua).

---

## Picker keymaps

Set inside the picker window only (buffer-local) — never global. Configurable
via `require("replacer").setup({ keymaps = { ... } })`, see
[`RP_Keymaps`](../lua/replacer/types/config.lua).

| Action | Config key | Default | fzf-lua | Telescope |
| --- | --- | --- | --- | --- |
| Apply to selection (multi if present, else single) | *(fixed)* | `<CR>` | fzf's own default key | Telescope's own default key |
| Toggle select + move to next | `keymaps.toggle_select` | `<Tab>` | Yes (fzf's native multi-select toggle) | Yes real Neovim keymap |
| Toggle select + move to previous | `keymaps.toggle_select_prev` | `<S-Tab>` | Yes (fzf's native multi-select toggle) | Yes real Neovim keymap |
| Apply to ALL matches (respects `confirm_all`) | `keymaps.apply_all` | `<C-a>` | Yes via fzf action/`--bind` | Yes real Neovim keymap |
| Apply entry under cursor, reopen with the rest | `keymaps.replace_and_reopen` | `<C-r>` | Yes via fzf action/`--bind` | Yes real Neovim keymap |
| Filter results (stacked path / content clauses) | `keymaps.filter` | `<C-f>` | Yes via fzf action | Yes real Neovim keymap |
| Close the picker | `keymaps.quit` | `<Esc>` | Yes (2nd `<Esc>`; 1st leaves terminal-insert, fixed) | Yes (2nd `<Esc>`; 1st leaves insert mode, fixed) |

`replace_and_reopen` defaults to a modifier key (`<C-r>`), not a bare letter
like `r`: both pickers' query line is live text input, so a bare letter
would swallow that character instead of reaching the search box.

`filter` opens a small `vim.ui.select` → `vim.ui.input` flow to add a filter
clause — *path contains*, *content excludes*, … — that narrows the match
list; clauses stack and are removable, a term in `/…/` is a Lua pattern.
It is backed by [pickers.nvim](https://github.com/WKDSteve/pickers.nvim)'s
`pickers.refine` module: **with pickers.nvim not installed the key reports
that and does nothing else.** On Telescope the list refreshes in place; on
fzf-lua the picker reopens with the filtered set. The active filter shows in
the prompt title (`Select matches — path~src · ¬content~test (42/380)`).

**which-key:** if [which-key.nvim](https://github.com/folke/which-key.nvim) is
installed, its popup shows labels for these keys — with one caveat: fzf-lua's
`toggle_select`/`apply_all`/`replace_and_reopen`/`filter` are fzf's own
terminal-native bindings (consumed by the fzf binary itself, never passing
through Neovim's keymap layer), so which-key cannot see or label those for the
fzf backend.
Telescope's keys are real `vim.keymap.set` calls and are fully labeled.
`quit` is labeled for both backends.

### Preview navigation (engine-native, not replacer's own)

replacer.nvim only sets the keys in the table above; scrolling and inspecting
the preview pane itself is entirely the picker engine's own doing. Both ship
more than it looks like at a glance:

| Action | fzf-lua | Telescope |
| --- | --- | --- |
| Scroll preview up/down a page | `<S-Up>` / `<S-Down>` | — |
| Scroll preview up/down a line | `<M-S-Up>` / `<M-S-Down>` | `<C-u>` / `<C-d>` |
| Scroll preview left/right | *(none built in — see below)* | `<C-f>` / `<C-k>` |
| Toggle line-wrap in the preview | `<F3>` | — |
| Full keymap cheatsheet, on demand | `<F1>` | — |

fzf-lua has no horizontal preview-scroll action, which is exactly what makes
a long unwrapped line (a URL, a long import path) run off the right edge with
no way to see the rest — `<F3>` (`toggle-preview-wrap`) is the fix: it wraps
the preview instead, so the full line becomes visible without scrolling at
all. `<F1>` (`toggle-help`) opens fzf-lua's own floating cheatsheet, listing
every key active in the current picker, replacer's own included — this *is*
the "what can I press here" popup, no separate one is needed.

**Known caveat, both backends:** `keymaps.filter` defaults to `<C-f>`, and on
both engines that shadows an existing default: Telescope's own `<C-f>` is
`preview_scrolling_left` (so horizontal preview scroll-left becomes
unreachable), and fzf-lua's own `ctrl-f` is `half-page-down` on the *results
list* (a provider's `actions` entry for a key always overrides the matching
`keymap.fzf` default for it). Neither loses anything essential — the list is
still fully navigable with the arrows, and Telescope's `<C-k>`
(scroll-right) is unaffected — but it is worth knowing if `<C-f>` ever seems
to do the wrong thing. Rebinding `keymaps.filter` sidesteps both.

---

## `:ReplaceTest` panel keymaps

The floating pattern-test panel binds two close keys, buffer-locally on its
own scratch buffer. Not configurable: a scratch panel with no other bindings
has no key worth arguing about.

| Key | Mode | Effect |
| --- | --- | --- |
| `<Esc>` | n | Close the panel |
| `q` | n | Close the panel |

See [`bindings/keymaps.lua`](../lua/replacer/bindings/keymaps.lua).

---

## Autocommands

Exactly one, and it is buffer-local.

| Event | Group | Buffer | Effect |
| --- | --- | --- | --- |
| `TextChanged`, `TextChangedI` | `ReplacerTestPanel` | the `:ReplaceTest` panel only | Re-highlight the sample line as the pattern is typed |

It dies with the panel buffer (`bufhidden = "wipe"`), so it can neither stack
across reloads nor fire anywhere else. replacer.nvim registers **no global
autocommand and no global keymap** — everything it binds is buffer-local to a
window it opened itself.

See [`bindings/autocmds.lua`](../lua/replacer/bindings/autocmds.lua).
