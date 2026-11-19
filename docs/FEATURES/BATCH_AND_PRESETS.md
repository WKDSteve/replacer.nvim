# Batch, history & presets

Running more than one replace in a single command, reusing an invocation you
already got right, and extending replace to file and directory names instead
of file contents.

## Batch replace

`:ReplaceBatch[!] {source} [scope] [--flags]` runs multiple `{old → new}`
pairs in one command, sourced from a file, the clipboard, or the quickfix
list — one full `:Replace` dispatch per pair. With `confirm_all` on and no
`--dry`, the whole batch is confirmed once up front, not once per pair; a
"no" cancels the batch before anything is dispatched.

- **Module:** `batch.lua` (`M.parse`, `M.run`, `M.register`)
- **Usercmds:** `:ReplaceBatch[!] {source} [scope] [--flags]` (see
  [BINDINGS.md](../BINDINGS.md#user-commands))

## History

`:ReplaceHistory` shows a chooser (`ui.kit` select) over the last 50 applies
and re-runs the chosen one.

- **Module:** `history.lua` (`M.add`, `M.pick`, `M.register`)
- **Usercmds:** `:ReplaceHistory` (see
  [BINDINGS.md](../BINDINGS.md#user-commands))

## Named presets

`:ReplaceSavePreset {name} {old} {new} [scope] [--flags]` saves a named,
reusable replace request; `:ReplacePreset {name}` re-runs it exactly as
saved, with `<Tab>` completion over saved names.

- **Module:** `presets.lua` (`M.save`, `M.as_request`, `M.names`,
  `M.register`)
- **Usercmds:** `:ReplaceSavePreset {name} {old} {new} [scope] [--flags]`,
  `:ReplacePreset {name}` (see [BINDINGS.md](../BINDINGS.md#user-commands))

## Rename files/directories by name

`:ReplaceFNames[!] {old} {new} [scope] [--dry]` renames every file/directory
under scope whose basename matches `{old}` — a nested match is skipped in
favor of its already-renamed ancestor, instead of content search-and-replace.

- **Module:** `fnames.lua` (`M.collect`, `M.filter_nested`, `M.apply`,
  `M.register`)
- **Usercmds:** `:ReplaceFNames[!] {old} {new} [scope] [--dry]` (see
  [BINDINGS.md](../BINDINGS.md#user-commands))

## Pair content replace with file rename

`--also-rename-file` pairs a single-file content replace with renaming that
file, when the old/new text also matches the file's own basename. Scoped to
single-file replaces only — a directory tree is `:ReplaceFNames`' job.

- **Module:** `rename_assist.lua` (`M.maybe_rename`)
- **Usercmds:** `--also-rename-file` flag on `:Replace`
