# Workflow — getting real use out of replacer.nvim day to day

Every feature here is documented on its own in
[`docs/FEATURES/`](FEATURES/README.md), and the exact grammar in
[`docs/commands.md`](commands.md). This is the different question: once
several features exist, *how do they actually combine* into something worth
reaching for regularly, rather than once after install and never again.

## Pick a backend once, then stop thinking about it

`opts.search_engine = "auto"` (the default) uses ripgrep when it's on `$PATH`
and falls back to the native vimgrep collector in `rg.lua` otherwise — you
don't need `--regex`/`--literal` gymnastics to make that choice yourself.
The only time to override it explicitly:

- `search_engine = "vimgrep"` on a machine/CI image without ripgrep, so a
  missing binary never silently changes behavior between runs.
- `--engine=fzf`/`--engine=telescope` is a *different* knob — that overrides
  the **picker UI**, not the search backend. Don't confuse the two when
  reading `:Replace` flags.

Practically: leave `search_engine` on `"auto"` project-wide, and only pin it
in `setup()` for a repo where you know ripgrep isn't guaranteed to be
installed (shared VM, minimal container). See [`SEARCH.md`](FEATURES/SEARCH.md#native-vimgrep-backend-with-automatic-fallback).

## Dry-run before every wide-scope apply

The single habit that prevents the most damage: never let the first
`Enter`/`--all` on a multi-file pattern be the one that writes to disk.

```vim
:Replace 'oldName' 'newName' . --dry
```

`--dry` computes the same stats/diff the real apply would produce and writes
nothing (`export.lua`, `M.build_results`/`M.build_patch`). Once the numbers
look right, drop `--dry` (or re-run with `--all`/`!`) to actually apply — the
pattern and scope don't need retyping if you pull the dry run back out of
`:ReplaceHistory` first (see below).

For a change you want to hand to someone else, or archive before applying,
add `--export`:

```vim
:Replace 'oldName' 'newName' . --dry --export=/tmp/rename.patch
```

`--export=<path>.json` instead of `.patch` gets you structured output for
tooling. `--dry` and `--export` compose — export never implies apply.

## Dry-run prevents; checkpoints recover

These two are not redundant — they guard against different failure modes:

| Guards against | Tool |
| --- | --- |
| "I'm about to change the wrong things" | `--dry` (inspect *before* writing) |
| "I already wrote the wrong things" | `--checkpoint` + `:ReplaceUndo` (recover *after* writing) |

`--dry` costs nothing and should be your default for anything past a
single-file scope. `--checkpoint` costs a snapshot of every touched file
under `stdpath("data")/replacer/checkpoints/<id>/` (`checkpoint.lua`) and is
for the case dry-run *can't* cover: you reviewed the diff, it looked
correct, and something about the actual write still went wrong — a hook
half-applied, you picked the wrong file in `--confirm-per-file`, or the
pattern matched one more file on the real run than it did in the preview
because of an unstaged edit. `:ReplaceUndo` with no argument restores the
most recent checkpoint; `:ReplaceUndo {id}` (tab-completes over
`checkpoint.lua`'s `M.list()`) restores a specific one. Restoration is a
byte-exact write-back, not a git operation — it doesn't touch your git
index or stash, so it's safe to combine with actual git work in the same
session.

Use both together on anything that touches more than a couple of files:
`--dry` first, then the real apply with `--checkpoint` attached.

## Git-changed scope + batch: a safe large-repo sweep

The combination that makes replacer usable on a big repo without babysitting
every match: intersect the search with git's own idea of "files I'm already
touching," then run several pairs against just that set.

```vim
:ReplaceBatch pairs.txt --changed=modified,staged --dry
" review, then:
:ReplaceBatch! pairs.txt --changed=modified,staged --checkpoint
```

`--changed[=<kinds>]` (`gitfiles.lua`) restricts matching to files git
reports as modified/staged/untracked — it *intersects* with the resolved
scope, it never widens it, so `--changed` on `.` still respects any
`--type`/`--glob`/`--exclude` filters you've also set. `:ReplaceBatch`
(`batch.lua`) then runs every `{old → new}` pair in `pairs.txt` (or the
clipboard, or the quickfix list) through one full `:Replace` dispatch each,
inheriting the same `--changed`/`--dry`/`--checkpoint` flags on every pair.

This is the shape for "I renamed a bunch of things across a feature branch
and want the rest of the repo's references cleaned up without re-touching
files outside my branch's diff." Without `--changed`, the same batch would
search the whole scope and risk rewriting unrelated files that happen to
share a token.

## Quickfix first, apply second

`--to-quickfix` / `--to-loclist` (`export.lua`) send the match list to the
quickfix/location list and open it — no write happens. This is the review
step for people who think in quickfix rather than in the picker:

```vim
:Replace 'TODO(old-owner)' 'TODO(new-owner)' . --to-quickfix
" walk :cnext/:cprev, delete lines you don't want with :cdo/manual edits
```

Two ways to turn a reviewed quickfix list back into an apply:

- Re-run the same `:Replace` without `--to-quickfix` (drop the flag, keep
  everything else) once you've confirmed the list by eye.
- Feed the quickfix list itself as a `:ReplaceBatch` source when you were
  reviewing multiple distinct pairs collected via `--to-quickfix` runs, per
  [`BATCH_AND_PRESETS.md`](FEATURES/BATCH_AND_PRESETS.md#batch-replace).

`--to-quickfix` and `--dry` overlap in intent (both are "don't write yet")
but differ in surface: `--dry` gives you a diff/stats summary, `--to-quickfix`
gives you a navigable list in the location most useful if your review
workflow is already quickfix-centric (jump-to-match, `:cdo`, etc).

## LSP rename vs plain search-replace

`--lsp` (`lsp_rename.lua`) is worth reaching for only when both are true:

- the old/new text on each match is a **plain identifier**
  (`M.looks_like_identifier`: letters/digits/underscore only) — not a
  phrase, not partial-token, not containing punctuation: `oldFn` → `newFn`
  qualifies, `"old-fn-name"` or `old fn` does not.
- the buffer already has an attached LSP client that advertises
  `textDocument/rename` support.

When both hold, `--lsp` gets you a real workspace-wide symbol rename —
correctly scoped to the *symbol*, not the literal text, so it won't touch an
unrelated string or comment that happens to contain the same characters.
Every non-qualifying match (multi-word, punctuation, no LSP client, request
failure/timeout) **silently falls back** to the plain text edit for that one
match — `--lsp` never partially fails a run, it just downgrades per-match.
That also means `--lsp` is safe to leave on by default for identifier-shaped
renames across a mixed codebase; it costs nothing on matches it can't
handle.

Plain search-replace (no `--lsp`) is still the right tool when you're
renaming something that isn't a symbol at all — a config key in JSON, a
string literal, a comment convention, a file path fragment — since LSP
rename has nothing to attach to there anyway.

## Hooks live around the write, not around the search

`config.hooks` / `require("replacer.hooks").on(event, fn)` register
`before_apply` / `after_apply` / `before_write` / `after_write` callbacks
(`hooks.lua`). Useful compositions:

- **`before_apply` as a gate**: return `false` from a `before_apply` hook to
  veto (skip) that one file — e.g. skip anything under `vendor/` even if it
  matched scope/filters, or skip a file that fails a lint check first.
- **`after_write` as a formatter**: run `stylua`/`gofmt`/etc on the
  just-written file so a mechanical rename doesn't leave formatting drift
  behind for you to clean up separately.
- **`after_apply` as a notifier**: invalidate an LSP cache, kick a test
  runner, or log the run to your own history alongside `:ReplaceHistory`.

A hook error is caught and warned, never allowed to abort the apply — so a
broken formatter hook degrades to "your files got renamed but not
reformatted," not "the whole apply silently stopped halfway through." Config
hooks (`setup()`) run before programmatically-registered ones
(`hooks.on()`), so a project-wide hook in your config always sees a match
first, before any session-local hook you register from a keymap or command.

## History and presets: don't retype what you've already gotten right

Once a `:Replace`/`:ReplaceBatch` invocation is dialed in — the right scope,
the right flags, the right pattern — you have two ways to avoid retyping it:

- `:ReplaceHistory` (`history.lua`) re-opens a chooser (`ui.kit` select) over
  your last 50 applies and re-runs the one you pick. Good for "I want to run
  that exact thing again" without remembering the flags.
- `:ReplaceSavePreset {name} {old} {new} [scope] [--flags]` /
  `:ReplacePreset {name}` (`presets.lua`) is the named, durable version —
  worth it for a pattern you'll reuse across sessions or hand to a
  teammate, with `<Tab>` completion over saved names so the name itself
  doesn't need to be memorized either.

History is ephemeral and automatic (every apply gets recorded); presets are
explicit and permanent. Reach for history right after a run you want to
repeat once; reach for a preset for anything you'd otherwise be tempted to
paste into a README as "run this when X happens."

## Renaming files alongside their contents

Content search-replace and filename-rename are deliberately two different
commands, because they don't share a safe default scope:

- `:ReplaceFNames[!] {old} {new} [scope] [--dry]` (`fnames.lua`) renames
  every file/directory under scope whose **basename** matches — a directory
  tree operation, with `--dry` to preview first the same way as `:Replace`.
  A nested match is skipped in favor of its already-renamed ancestor, so
  renaming a directory doesn't also try (and fail) to rename its now-stale
  children path.
- `--also-rename-file` (`rename_assist.lua`) is the narrower, single-file
  version: pairs one file's *content* replace with renaming that file, only
  when the old/new text also matches the file's own basename, and only for
  single-file replaces. It will not rename a directory tree — that's
  `:ReplaceFNames`'s job by design.

Typical combo for a module rename (`old_module.lua` → `new_module.lua`, plus
every `require("old_module")` reference): content replace with
`--also-rename-file` on the module file itself, then a separate
scope-wide `:Replace` (no `--also-rename-file`, since the other files aren't
being renamed) for the `require(...)` references elsewhere.

## Tab at a bare `--` is the fastest way through forty-one flags

Flag names complete, including at a bare `--`, which is the one keystroke where
*what does this take?* is the actual question. Three values complete too:

- **`--type=`** offers ripgrep's own type names, probed once per session from
  `rg --type-list`. Validation accepts anything you type, deliberately —
  checking against the probed list would reject a type from your own
  `--type-add`.
- **`--changed=`** offers comma-joinable kinds and drops the ones already
  named, so a second `<Tab>` cannot produce `staged,staged`.
- **`--export=`** completes as a path rather than as a file, because it names
  an output file that normally does not exist yet.

**`--glob=` and `--exclude=` stay uncompleted on purpose.** They take patterns,
so offering an existing path would suggest `lua/replacer/command.lua` where the
flag wants `**/*.lua` — a candidate that is accepted, matches one file, and
silently narrows the replacement. That is worse than no completion.

`:Replace a b --changed` in its bare form (documented as "all kinds") works
again; it used to be rejected before it reached the apply path, and the bare
form is guaranteed not to swallow a following scope positional. `:Surround` and
`:Wrap` inherit all of this — they copy the same flag table.

## Composing scope, filters, and safety flags without fighting each other

A few flags look like they'd conflict but are designed to stack:

- `--changed` intersects with `--type`/`--glob`/`--exclude`, it doesn't
  bypass them — `--changed --type=lua` still only matches changed `.lua`
  files.
- `--safe` (skip read-only/oversized/binary files) and `--confirm-per-file`
  (prompt All/Skip/Only-some/Quit per file) can run together: `--safe`
  removes files from consideration before `--confirm-per-file` ever prompts
  on them, so you're not asked to confirm a file that was going to be
  skipped anyway. Note `--confirm-per-file` **supersedes** the global
  `confirm_all`/`confirm_wide_scope` config once enabled — don't expect both
  prompt styles in the same run.
- `[range]` (`:'<,'>Replace`) restricts to a visual selection independent of
  scope — combine it with `--dry` for a quick "what would this match in just
  these lines" check before committing to a buffer-wide or project-wide
  version of the same pattern.

When in doubt about how two flags interact, `--dry` is cheap enough to just
try the combination and read the stats before deciding whether to add
`--checkpoint` and go live.

---

Cross-references: [`FEATURES/SEARCH.md`](FEATURES/SEARCH.md) for backend and
matching details, [`FEATURES/APPLY.md`](FEATURES/APPLY.md) for the full apply
pipeline, [`FEATURES/BATCH_AND_PRESETS.md`](FEATURES/BATCH_AND_PRESETS.md) for
batch/history/preset/rename mechanics, [`FEATURES/COMMANDS_UI.md`](FEATURES/COMMANDS_UI.md)
for the picker and command surface itself, and [`BINDINGS.md`](BINDINGS.md)
for the full command/keymap reference.
