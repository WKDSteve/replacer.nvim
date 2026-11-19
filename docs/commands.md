# Commands

Fourteen user commands. This page is the grammar and the flag reference; for
the one-line-per-binding table see [BINDINGS.md](BINDINGS.md), and for what
each feature actually does see [FEATURES/](FEATURES/README.md).

## `:Replace`

```vim
:[range]Replace[!] {old} {new} [scope] [--flags]
```

`:Replacer` is an alias.

| Parameter | | |
| --- | --- | --- |
| `{old}` | required | Literal text, or a regex with `--regex` |
| `{new}` | required | Replacement text. `""` deletes the matches |
| `[scope]` | optional | `%` (current buffer) · `cwd` / `.` (working directory) · `root` (auto-detected project root) · a file or directory path. Defaults to `default_scope` (`%`) |
| `[range]` | optional | `:'<,'>Replace` restricts matching to the selected lines |
| `!` | optional | Shorthand for `--all` (non-interactive) |

Each occurrence on a line is its own selectable entry — several hits on one
line are all offered, not collapsed.

```vim
:Replace foo bar                             " picker over the current buffer
:Replace foo bar cwd                         " picker over the working directory
:Replace "very old" "brand new" ./src        " picker over ./src
:Replace foo "" %                            " delete every match in this buffer
:Replace foo bar cwd --all                   " apply to all, no picker
:Replace TODO DONE cwd --type=lua --exclude=node_modules
:'<,'>Replace foo bar                        " only within the visual selection
:Replace foo bar cwd --dry                   " stats + diff, no writes
:Replace foo bar cwd --export=changes.patch  " a git-applyable patch
:Replace foo bar cwd --changed=staged        " only staged files
```

### Flags

Forty-one of them, and they may appear anywhere in the line. A lone `--`
stops flag parsing, so a `{new}` that starts with dashes is still reachable.
Every `--x` boolean has a `--no-x` counterpart that switches the configured
default off for this run; only `--x` is listed below.

| Flag | Effect |
| --- | --- |
| `--literal` / `--regex` | Literal (default) or regex search |
| `--smart-case` | ripgrep smart-case |
| `--hidden` | Include dotfiles |
| `--ignore` | Respect `.gitignore` (`--no-ignore` to search anyway) |
| `--word` | Whole-word matches only |
| `--code-only` | Skip matches inside strings/comments (Tree-sitter, best-effort) |
| `--case-preserve` | Re-case the replacement per match: `foo→bar`, `Foo→Bar`, `FOO→BAR`, `fooBar→bazQux` |
| `--preserve-ws` | Keep the match's own leading/trailing whitespace around the replacement |
| `--type=<ft>` *(repeatable)* | Restrict to a ripgrep filetype |
| `--glob=<pat>` *(repeatable)* | Include glob |
| `--exclude=<pat>` *(repeatable)* | Exclude path or glob |
| `--changed[=<kinds>]` | Only git-changed files. Bare = modified+staged+untracked; or a comma-list subset |
| `--engine=<fzf｜telescope>` | Override the picker for this run |
| `--context=<n>` | Preview context lines |
| `--stream` | Incremental ripgrep `--json` parsing, for smoother progress |
| `--all` | Non-interactive: apply to every match |
| `--dry` | Plan only: stats and diff, no writes |
| `--export=<path>` | Write the planned diff (or `.json`) to a file. Implies `--dry` |
| `--to-quickfix` / `--to-loclist` | Send matches to the quickfix/location list and open it. Never writes |
| `--safe` | Skip read-only, oversized and binary files |
| `--max-filesize=<bytes>` | Override the safe-mode size threshold for this run |
| `--confirm-per-file` | ALL-mode: ask All/Skip/Only-some/Quit per file |
| `--checkpoint` | ALL-mode: snapshot every touched file first, for `:ReplaceUndo` |
| `--lsp` | Try an LSP rename for identifier-shaped matches, falling back to plain text |
| `--also-rename-file` | Single-file scope only: offer to rename the file itself the same way |

`<Tab>` completes at every slot — scope keywords, every flag name at a bare
`--`, and the values of `--type=`, `--changed=`, `--engine=` and `--export=`.
`--glob=`/`--exclude=` deliberately do not complete; see
[BINDINGS.md](BINDINGS.md#tab-completion-on-replacereplacersurroundwrap).

## `:Surround` / `:Wrap`

```vim
:[range]Surround[!] {pattern} [delim] [scope] [--flags]
```

Wraps every occurrence of `{pattern}` with a delimiter. Search is always
literal; every `:Replace` flag applies, plus `--nested` (alias
`--allow-nested`).

`[delim]` is a literal string (`` ` `` `"` `'` `*` `**` `_`), a named alias,
or a bracket opener that pairs with its closer (`(` `[` `{` `<`). Omit it to
be prompted.

Aliases: `b`→`` ` `` · `q`→`"` · `s`→`'` · `star`→`*` · `bold`→`**` ·
`italic`→`_` · `paren`→`( )` · `bracket`→`[ ]` · `brace`→`{ }` ·
`angle`→`< >`.

**Idempotent by default.** A match already wrapped by the chosen delimiter is
skipped, so `:Surround test **` on `**test**` leaves it alone rather than
producing `****test****`. `--nested` forces another layer.

```vim
:Surround word `                 " `word` in the current buffer
:Surround "foo bar" ** cwd       " **foo bar** across the working directory
:Surround TODO ( .               " (TODO) project-wide
:Surround! name q %              " "name" everywhere in the buffer, no picker
:Surround word                   " prompts: "Surround with: "
:Surround word ** --nested       " wrap even already-**bold** matches
```

A **charwise** range on a **single line** narrows to the columns of the
selection; a linewise or multi-line range keeps the whole-line behaviour.

```vim
" "foo bar foo baz", only the FIRST foo charwise-selected:
:'<,'>Surround foo *             " *foo* bar foo baz
" the same line with a linewise V selection:
:'<,'>Surround foo *             " *foo* bar *foo* baz
```

## Scope and project root

`root` as a scope walks up from the current buffer's directory looking for
markers (`.git`, `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, …)
and deterministically prefers the outermost `.git` candidate, without
prompting — except the home directory itself, which is never picked just
because it happens to hold a dotfiles `.git`; the nearest marker match wins
instead.

```vim
:Replace old new root
```

`:ReplaceRoot[!] {old} {new} [--flags]` is the interactive counterpart: same
grammar minus the scope positional, and it *prompts* when detection finds
more than one candidate.

## Regex helpers

| Command | |
| --- | --- |
| `:ReplaceEscape {text}` | Escape `{text}` for use as a Vim regex pattern; echoes it and copies it to the unnamed register |
| `:ReplaceTest [pattern] [sample]` | A floating live test panel — line 1 the pattern, line 2 the sample, matches highlight as you type. `<Esc>` or `q` closes |

In regex mode, `{new}` may use `\0`–`\9` to reference `\(...\)` groups from
`{old}`:

```vim
:Replace "\(\w\+\)=\(\w\+\)" "\2_\1" % --regex   " foo=bar → bar_foo
```

## History, presets and batch

| Command | |
| --- | --- |
| `:ReplaceHistory` | A chooser (`ui.kit` select) over the last `history_max_entries` real applies (never dry-run/export/quickfix); picking one re-runs it |
| `:ReplaceSavePreset {name} {old} {new} [scope] [--flags]` | Save a named, reusable request including its flags |
| `:ReplacePreset {name}` | Run a saved preset exactly as saved. `<Tab>` completes names |
| `:ReplaceBatch[!] {source} [scope] [--flags]` | Run multiple `{old → new}` pairs, one full `:Replace` dispatch each |

```vim
:ReplaceSavePreset fix-imports "import old" "import new" src/ --type=ts
:ReplacePreset fix-imports
```

`{source}` for `:ReplaceBatch` is a file path, or one of `clipboard`/`+`,
`unnamed`/`"`, `qf`/`quickfix`. Pairs are one `old => new` per line (`#`
comments and blank lines ignored), or a `[{"old":"…","new":"…"}, …]` JSON
array, auto-detected from a leading `[`.

```vim
:ReplaceBatch pairs.txt src/          " from a file
:ReplaceBatch clipboard cwd --dry     " from the clipboard, plan-only first
```

History and presets are stored as JSON under `stdpath("data")/replacer/`.

## Renaming files

| Command | |
| --- | --- |
| `:ReplaceFNames[!] {old} {new} [scope] [--dry]` | Rename every file/directory under scope whose **basename** contains `{old}` — names, not contents |

Renames are computed from one snapshot of the tree; a match nested inside
another match is skipped in favour of its already-renamed ancestor. It does
**not** follow the rename through source references. For the narrow case of a
single file whose contents and name change together, use
`--also-rename-file` on `:Replace` instead.

## Checkpoints

| Command | |
| --- | --- |
| `:ReplaceUndo [id]` | Restore files from a `--checkpoint` snapshot. Most recent when `[id]` is omitted; `<Tab>` completes existing ids |

`--checkpoint` snapshots every file an ALL-mode apply is about to touch
(byte-exact, buffer content preferred over disk) into
`stdpath("data")/replacer/checkpoints/<id>/`. It is a plain file snapshot,
not a git stash, so it never touches unrelated uncommitted work.

## Debugging

| Command | |
| --- | --- |
| `:ReplaceDebug on｜off｜status｜inspect｜analyze <line> <pattern>` | Developer diagnostics, registered on first use rather than at load |

See [troubleshooting.md](troubleshooting.md).

## Safety notes

- `--dry` (or `--export=`) first, on anything past a single-file scope. It
  computes exactly what the real apply would.
- Edits are applied bottom-up per file, each guarded with `pcall`, so an
  index shift or one bad edit cannot corrupt the rest.
- Every occurrence is verified against the original text before the edit;
  a mismatch is skipped and reported rather than written blind.
- A multi-file replace is **not atomic**. If it fails halfway, earlier files
  stay changed — which is what `--checkpoint` exists for.
- With `write_changes = false` the buffers stay modified and unsaved; review
  and `:write` yourself, or stage hunks in your VCS.
