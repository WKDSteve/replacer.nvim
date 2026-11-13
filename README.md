![replacer-nvim](assets/icons/replacer-nvim/png/replacer-nvim-128.png)

> **Beta stage — active development.** This repository is past its first shape and in
> active use, but the surface is not frozen: breaking changes are still possible. Pin a
> commit or tag if you depend on it.

# replacer.nvim

```
  ____             _
 |  _ \ ___ _ __ | | __ _  ___ ___ _ __
 | |_) / _ \ '_ \| |/ _` |/ __/ _ \ '__|
 |  _ <  __/ |_) | | (_| | (_|  __/ |
 |_| \_\___| .__/|_|\__,_|\___\___|_|
           |_|                     .nvim
```

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Lua-5.1%2FLuaJIT-2C2D72?logo=lua&logoColor=white)](https://www.lua.org)
![Status](https://img.shields.io/badge/status-beta-orange)
[![CI](https://github.com/WKDSteve/replacer.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/WKDSteve/replacer.nvim/actions/workflows/ci.yml)
[![wkd](https://img.shields.io/badge/wkd-family-c6ff3d)](https://wkdsteve.github.io/wkd/p/replacer/)

> Part of the [wkd](https://wkdsteve.github.io/wkd/) family — see this plugin's [page](https://wkdsteve.github.io/wkd/p/replacer/) on the site.

Project-wide search-and-replace where every occurrence is its own decision.
ripgrep finds the matches, a picker — fzf-lua or Telescope — lets you select
them one by one with the hit highlighted in the preview, and nothing is written
before you have had the chance to look at a diff.

---

## Around it

> **[fileops.nvim](https://github.com/WKDSteve/fileops.nvim)** — the same
> job one level up: moving, copying, deleting and creating the files
> themselves, where replacer renames what is inside them.
>
> **[pickers.nvim](https://github.com/WKDSteve/pickers.nvim)** — provides
> the stacked path and content clauses `<C-f>` filters the result list with.
>
> **[recommender.nvim](https://github.com/WKDSteve/recommender.nvim)** —
> finds the repetition worth renaming in the first place, and drives `:Replace`
> to carry the rename out.
>
> All of the above are soft: without them everything else works unchanged.
> [lib.nvim](https://github.com/WKDSteve/lib.nvim),
> [ui.nvim](https://github.com/WKDSteve/ui.nvim) and a picker are the real
> dependencies — see [Requirements](docs/installation.md#requirements).

---

## Documentation

Start at [docs/README.md](docs/README.md) — the README is the shop window, that
is the reference, one file per question.

### The Basics

- [Requirements](docs/installation.md#requirements) — Neovim version, required plugins and CLI tools.
- [Installation](docs/installation.md) — the spec, and the declared-CLI-tools popup.
- [Quickstart](docs/quickstart.md) — the first thing to run after installing.

### Configuration

- [What you get with the defaults](docs/what-you-get.md) — the picker keymaps at a glance.
- [All options](docs/configuration.md) — every `setup()` option with its default, plus hooks and message templates.
- [Command reference](docs/commands.md) — all fourteen commands, their grammar, and all 41 flags.
- [Bindings cheatsheet](docs/BINDINGS.md) — commands, picker keymaps and the single autocommand, on one page.

### The Rest

- [Features](docs/FEATURES/README.md) — the catalog: every shipped feature against the module, command and config option that implements it, split into [search](docs/FEATURES/SEARCH.md), [apply](docs/FEATURES/APPLY.md), [commands and UI](docs/FEATURES/COMMANDS_UI.md), and [batch and presets](docs/FEATURES/BATCH_AND_PRESETS.md) — plus [where this sits](docs/FEATURES/README.md#where-this-sits) against nvim-spectre and grug-far.nvim.
- [Workflow](docs/WORKFLOW.md) — not what each feature is, but how they combine into habits worth keeping.
- [Progress indicator](docs/progress-indicator.md) — the six `progress_style` values, with recordings, and how to drive the headless one from your own statusline.
- [Lua API](docs/api.md) — `setup`, `run`, `config.get`, `hooks.on`: the surface meant for scripting.
- [Health check](docs/health.md) — what `:checkhealth replacer` checks, and which of its warnings are supposed to be warnings.
- [Troubleshooting](docs/troubleshooting.md) — symptom-first, plus what `:ReplaceDebug` can tell you.
- [Contributing](docs/CONTRIBUTING.md) — repository layout, the checks CI runs, and where documentation belongs.
- [Feedback](https://github.com/WKDSteve/replacer.nvim/issues) — bugs, feature requests and usage questions; broader discussion in [Discussions](https://github.com/WKDSteve/replacer.nvim/discussions).

`:help replacer` is the same reference inside the editor.

---

## License

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

replacer.nvim is released under the [MIT License](https://opensource.org/licenses/MIT).
