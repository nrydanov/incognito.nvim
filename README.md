# incognito.nvim

> К нам едет ревизор. Инкогнито.
>
> An inspector is coming to see us. Incognito.
> — Gogol, *The Government Inspector*

Review Git changes in ordinary Neovim buffers, with your LSP and motions.
[gitsigns](https://github.com/lewis6991/gitsigns.nvim) marks changed lines;
[difftastic](https://github.com/Wilfred/difftastic) dims formatting-only changes.
Browse files, track what you have reviewed, or step through commits in an
editable worktree while keeping your checkout intact. No forge connection needed.

## Install

Requires **Neovim 0.11+**. With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "nrydanov/incognito.nvim",
    dependencies = { "lewis6991/gitsigns.nvim", "folke/snacks.nvim" },
    lazy = false,
    opts = {},
}
```

For structural review, install `difft` (difftastic) on `PATH`.
Run `:checkhealth incognito` to check dependencies.

## Start reviewing

Open a file on your feature branch and run:

```vim
:Incognito on origin/main
```

Changes are shown against the merge-base with the target. Use `<leader>if` to
browse changed files and `<leader>iv` to mark a file reviewed. For commit-by-commit
review, open `<leader>ic`; choose another branch or revision with `<leader>ih`.

### Keys

Set `vim.g.mapleader` before loading the plugin. Existing mappings are preserved.

| Keys | Action |
|------|--------|
| `<leader>io` / `<leader>iq` | Review on / off |
| `<leader>is` | Structural review |
| `<leader>ib` / `<leader>ih` | Choose base / head |
| `<leader>if` / `<leader>ic` | Changed files / commits |
| `<leader>ir` | Clean range diff |
| `<leader>in` / `<leader>ip` | Next / previous commit |
| `<leader>it` | Switch between review and original checkout |
| `<leader>iv` / `<leader>iV` | Mark reviewed / changes since review |
| `<leader>id` / `<leader>iw` | Deleted lines / diff window (structural mode) |

Change the prefix with `opts = { keymaps = { prefix = "<leader>m" } }`, or
use `opts = { keymaps = false }` for your own mappings.

## Editable reviews

Commit reviews live in `.git/incognito/<branch>-<hash>/` (the common Git directory
for linked worktrees). They stay out of commits in the original checkout.
Saved edits survive leaving review and restarting Neovim; there is no autosave.

**Switching commits or selecting a new head commit for the same review discards
its staged, unstaged, untracked and unsaved changes without a dialog.** Ignored
files remain. Switching to the original checkout with `<leader>it` opens the real
file: edits there affect your original checkout.

The editor's working directory stays unchanged. Launch agents and builds in the
review directory explicitly; find it with `git worktree list`.

## Reference

[Full help](doc/incognito.txt) is also available as `:help incognito`:

- `:help incognito-commands` — commands and review behavior
- `:help incognito-config` — settings and custom worktree locations
- `:help incognito-navigation` — gitsigns hunk navigation in structural mode
- `:help incognito-highlights` — colors
- `:help incognito-limitations` — persistence, locks and external tools
- `:help incognito-development` — tests and linting

[MIT](LICENSE)
