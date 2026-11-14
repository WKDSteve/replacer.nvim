# TESTS

Standalone Lua scripts, not a `plenary`/`busted` suite. Each file is a
self-contained headless test that runs itself, counts its own checks and ends
in `cquit 1` when one failed. They are run by
[testing.nvim](https://github.com/WKDSteve/testing.nvim) (configured in
`.testing.lua`; dialect `script`, one editor per file): the exit code and the
printed `[FAIL]` lines are the verdict. There is no `run.lua` aggregator and
no `_spec` suffix convention; the files are named in `spec_pattern` of
`.testing.lua`, so a new script has to be added there. `spec_coverage.lua`
turns a forgotten entry into a red run: every `TESTS/*.lua` must be matched
by `spec_pattern` or be one of the helpers it lists.

## Running the suites

```sh
bash scripts/test.sh                    # every script under TESTS/
bash scripts/test.sh --file feature     # script files whose name contains "feature"
bash scripts/test.sh --json ir.json     # also write the machine-readable result
```

`make test` is the same call. `testing.nvim`, `lib.nvim` and `ui.nvim` are
required; each is looked up in `$<NAME>_DIR` (e.g. `$LIB_NVIM_DIR`),
`.deps/<name>`, a sibling checkout (`../<name>`) and `stdpath("data")/lazy`,
and a missing one is a fatal error naming all four places. `pickers.nvim` is
a soft dependency of `refine_wiring.lua` only: its checks are skipped with a
note when it is absent.

A script that dies halfway on an uncaught Lua error is an `error` case and a
script that ends in `cquit 1` is a failed one; both make the run red (exit 1).
This replaces `TESTS/ci_guard.lua`, which did the same for the old
`nvim -c "luafile ..." -c "qa"` call, whose exit code is 0 after a crash.

`TESTS/resolve_lib_nvim.lua`/`resolve_ui_nvim.lua` are shared helpers each
suite `dofile()`s at the top (never `require`d). They look for
`$LIB_NVIM_PATH`/`$UI_NVIM_PATH` first, then a sibling checkout
(`../lib.nvim`, `../ui.nvim`), then the lazy.nvim-managed copy under
`stdpath("data")/lazy`; `.testing.lua` lets these variables through to the
child editor (`env_allow`). `$PICKERS_NVIM_PATH` follows the same pattern for
`refine_wiring.lua` (resolved inline there, not via a shared helper -- it is
soft, not hard).

See `.github/workflows/ci.yml` for the CI call.

## Suites (CI-run)

- `feature_smoke.lua` — the bulk of the plugin: request parsing, native
  (vimgrep) search incl. word-boundary/safe-mode/encoding, root detection,
  `--changed` (gitfiles), per-file confirm, checkpoints, hooks, history,
  presets, batch mode, i18n messages, filename/directory rename (`fnames`),
  `--also-rename-file`, soft LSP rename, `--stream`, pure edit computation,
  dry-run/export/patch/JSON, real apply (incl. the wide/chunked async path),
  and quickfix export.
- `gitfiles_equivalence.lua` — `--changed` against git itself: for every kind
  combination the selection must equal raw `git … -z` (unstaged/staged/both,
  added, deleted, renamed, nested and space-named untracked, ignored, non-ASCII
  names, unmerged paths, byte-order sorting), one `git status` process for all
  three kinds, and failure reporting for a broken repository.
- `surround_smoke.lua` — `:Surround`/`:Wrap`: delimiter resolution, the
  shared command tokenizer/flag helpers, the real user command end-to-end
  (buffer/dir scope, no-delimiter prompt via `ui.kit`), and idempotency
  (skip-already-wrapped vs. `--nested`).
- `async_utf8.lua` — the async ripgrep collection path, and UTF-8 (umlauts +
  emoji) byte-offset correctness through search/compute/apply.
- `rg_partial_failure.lua` — ripgrep exit 2 from unreadable paths only (broken
  symlinks) is a partial success (matches kept); a real rg error still fails.
- `tree_action_spec.lua` — the action `replacer.replace` at
  `lib.nvim.tree.registry`: what `setup()` registers (`tree` option, key,
  `false`), the two questions and the `:Replace` it runs on a node.
- `spec_coverage.lua` — every script under `TESTS/` is matched by
  `spec_pattern` of `.testing.lua` (or is a listed helper, which must not be).
- `refine_wiring.lua` — `replacer.pickers.common`'s `without()` and the
  `pickers.refine` handle (`new_refine()`) stacked path/content filters.
- `config_merge.lua` — `replacer.config`/`replacer.config.DEFAULTS`: every
  coercer (`as_bool`/`as_pos_int`/`as_engine`/`as_search_engine`/
  `as_progress_style`/`as_string_list`/`as_keymaps`), the nested `fzf`/
  `telescope` deep-merge, and `setup()`/`get()`/`resolve()`'s merge
  semantics (`setup()` is cumulative, not a reset — see the file's own
  comments).
- `argtypes_debug_error.lua` — `replacer.argtypes`'s two custom composer
  argument types (`RP_RG_TYPE`/`RP_CHANGED_KINDS`, fetched back through
  `lib.nvim`'s own argtype registry), `replacer.debug`'s `:ReplaceDebug`
  dispatch, and `replacer.error`'s structured errors / `safe_call` envelope.
- `health_pickers_tscode.lua` — `replacer.health` (`vim.health` stubbed to
  capture the report regardless of which optional tools happen to be
  installed; the required lib.nvim modules each in the "not found" and the
  "installed but throws on load" state, plus the matching row of
  `docs/health.md`), the picker-engine-agnostic halves of
  `replacer.pickers.common`/`replacer.pickers.utils`, `replacer.tscode`'s
  real Tree-sitter string/comment classification, and a smoke check of
  `replacer.util.notify`.
- `bindings_wiring.lua` — `replacer.bindings.{init,usrcmds,keymaps,
  autocmds}`: the command registry/`names()`, `bindings.setup()`
  end-to-end, both `:ReplaceTest` panel close keys, the panel's
  `TextChanged`/`TextChangedI` re-highlight autocmd, and the real
  `:ReplaceTest` float driving both.
- `init_dispatch.lua` — `replacer/init.lua`'s orchestration: the legacy
  positional `run(old, new, scope, all)` form, the dry-run/export "plan"
  path (incl. the `[replacer-plan]` diff scratch buffer), the
  "no picker available" fallback when neither fzf-lua nor telescope.nvim is
  installed, the post-collection `request.filter` hook, the real
  (non-stubbed-apply) confirm-before-ALL flow, `confirm_wide_scope` vs.
  single-file scope, and dispatch's own `cfg.checkpoint`/
  `cfg.confirm_per_file` wiring (as opposed to those two modules' isolated
  unit tests in `feature_smoke.lua`, which drive them with a fake
  `apply_func`).
- `pickers_backends.lua` — `replacer.pickers.fzf`/`replacer.pickers.telescope`'s
  `run()`, with the actual backend (`fzf-lua` / `telescope.nvim`) stubbed at
  `package.loaded` instead of skipped: candidate/entry-maker construction,
  the id-tag lookup both reopen paths use, every `attach_mappings`/`actions`
  entry (default apply, multi-select, apply-all incl. the real
  `confirm_all` → `ui.kit.confirm` flow, replace-and-reopen's recursive
  re-run with the match removed, and the `<C-f>` filter guard when
  pickers.nvim is absent), the telescope previewer's highlight-extmark math,
  and fzf's `<C-a>`/`<S-Tab>`/`<M-x>`/bare-`<CR>` → `ctrl-a`/`shift-tab`/
  `alt-x`/`enter` key-notation translator. Only the one call each adapter
  makes into the real rendering UI (`fzf.fzf_exec`/`picker:find()`) is
  replaced with a capture stub; everything upstream of it is this plugin's
  own logic, not the backend's.

- `usrcmd_option_help.lua` — the option cheatsheet (composer's help float) of
  `:Replace`/`:Replacer`/`:Surround`/`:Wrap`: `composer.help.undocumented()`
  must list no flag for any of the four verbs (a `--no-x` twin counts as
  described when `--x` is), the texts stay one line / at most 70 chars, the
  positional arguments (`{old}`, `{new}`, `[scope]`, `{pattern}`, `[delim]`)
  show a text too (`undocumented(verb, { args = true })` is empty, `enum_desc`
  keys are real values), and `:Surround` carries its own `--nested`/`--allow-nested` texts plus the
  corrected "no effect" text for `--regex`/`--no-literal` without touching
  `:Replace`'s copy. It also pins `spec.quotes = true` on all four verbs and
  its effect: `parse_line` counts `"foo bar"` as one token, the float asks for
  `{new}` (`[{delim}]` for `:Surround`) after a quoted pattern and shows the
  `[{scope}]` row after the next argument, and `getcompletion()` offers the
  scopes only from there on. Also pins that `command.tokenize` and composer's `split_quoted` cut a corpus of lines identically and that `<Tab>` inside an open quote offers nothing; `surround_smoke.lua` drives a quoted, flag-looking pattern through the real commands.

## Present but not run by CI

- `resolve_lib_nvim.lua` / `resolve_ui_nvim.lua` — shared `dofile()` helpers,
  not test files themselves.
- `health_debug.lua` — a pre-existing standalone diagnostic script
  (`:lua require('test.health_debug').diagnose()` style), never wired into
  `.github/workflows/ci.yml`. Left as-is; its real assertions now live in
  `argtypes_debug_error.lua` (`:ReplaceDebug`). The legacy
  `utf8_offsets.lua` (and the `:ReplaceDebug test` subcommand that ran it)
  was deleted: `async_utf8.lua` and `feature_smoke.lua` cover the UTF-8
  offsets, and two of its checks had been failing for a long time.

## Deliberately excluded from any suite

- The actual rendering call inside `pickers/fzf.lua` (`fzf.fzf_exec`) and
  `pickers/telescope.lua` (`picker:find()`'s real floating window / keypress
  loop) — a live picker UI genuinely rendering is the one part of those two
  files `pickers_backends.lua` does not (and should not) exercise. Everything
  else in both `run()` functions is covered there; see that suite's entry
  above. (An earlier round excluded both files outright on the premise that
  they "hard-require an actual picker backend... neither of which is a CI
  sibling checkout" — true of the literal `require`, but that require only
  needs *something* in `package.loaded`, which doesn't need a real plugin
  checkout, in CI or anywhere else.)
- `@types`/`types/*.lua` — pure `---@meta` annotations, no runtime code.
- `pickers/utils.lua`'s `setup_highlight_groups`/`ansi_snippets` — not a
  backend-availability exclusion: as of this audit neither function has any
  caller anywhere in the codebase (see the "NOTE: nothing calls this today"
  comment on `setup_highlight_groups` itself). Each function is still tested
  directly by `health_pickers_tscode.lua`; there is no caller left to cover.

## Known bugs (pinned as regression tests, not fixed)

- `replacer.health.check()`: `check_lib_nvim()` already handles
  `lib.nvim.bindings.usercmd.composer` being unavailable — it reports
  `health.error("lib.nvim not found — commands will fail to register", ...)`
  and lets `M.check()` carry on. But `M.check()` itself then unconditionally
  calls `require("lib.nvim.bindings.usercmd.composer").checkhealth("Replace")`
  / `.checkhealth("Surround")` a few lines later (the "composer route
  pre-flight"), with no guard — so on a lib.nvim checkout old enough to be
  missing just that one submodule, `:checkhealth replacer` reports the clean
  warning and then crashes on the exact same missing dependency instead of
  degrading to it. Pinned in `health_pickers_tscode.lua` (section 6, via
  `hide_module()`, which wraps every package loader so the require genuinely
  fails with Lua's own "module ... not found" rather than swapping in a fake
  module) rather than fixed here, per this campaign's rule
  for a real behavior bug that isn't a trivial, zero-risk infra fix — the
  right degradation (skip the pre-flight entirely? report a third error
  section instead?) is a product decision, not this audit's to make quietly.

## Bugs found while writing these suites (since fixed)

- `replacer.config.get()`'s docstring promised "a deep copy, to avoid
  accidental mutation by callers", but it was implemented as
  `vim.tbl_deep_extend("force", {}, state)`. That call only deep-merges a
  sub-table when *both* sides being merged already have a table at that key —
  a key that exists on only one side (every key here, since the first
  argument is `{}`) was assigned by reference. Every nested table `get()`
  returned (`keymaps`, `fzf`, `telescope`, `hooks`, `messages`,
  `file_types`/`globs`/`exclude`) was therefore the *same table object*
  backing the module's private `state`; mutating what looked like a
  read-only snapshot silently corrupted persistent config for the rest of
  the session. Fixed to `vim.deepcopy(state)`; `config_merge.lua` asserts
  nested tables are no longer aliased.
- `replacer.debug`'s `enable()`/`disable()`/`status()` wrote/read
  `require("replacer").options.ext_highlight_opts.debug` — a field
  `init.lua` never exposed, so the config-echo half of `status()`'s message
  always reported "OFF" regardless of real state. Removed (dead code with
  no consumer); `status()` now only reports the module-local flag.
  Separately, `M.test()` required `"test.utf8_offsets"`, which resolves to
  `lua/test/utf8_offsets.lua` on the runtimepath — but the real suite lives
  at `TESTS/utf8_offsets.lua`, outside `lua/`'s search path, so `:ReplaceDebug
  test` always reported "Test suite not found". Fixed to load the suite by
  file path (relative to `debug.lua`'s own location) instead of `require()`.
  Both pinned and verified fixed in `argtypes_debug_error.lua`. (Since then
  the `test` subcommand and the suite it loaded are gone altogether.)
