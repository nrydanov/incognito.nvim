# mrview.nvim

Review a merge request in ordinary Neovim buffers, with LSP, treesitter and
your usual motions, instead of a dedicated diff UI.

- Line signs come from gitsigns against the merge-base of the MR target.
- Structural mode asks [difftastic](https://github.com/Wilfred/difftastic)
  which lines changed; lines that changed only in formatting are dimmed.
- Deleted lines are shown as virtual lines; a side-by-side pane shows the
  base version of the file.
- A files picker lists the changed files with reviewed marks: `✓` reviewed,
  `~` changed since it was marked.
- Commit mode steps through the MR one commit at a time by detaching HEAD
  at each commit.

## Requirements

- Neovim >= 0.11
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)
- [snacks.nvim](https://github.com/folke/snacks.nvim) for the files and
  commits pickers
- `difft` (difftastic) on `PATH` for structural mode; tested with 0.70 and 0.71

Run `:checkhealth mrview` to check them.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "<name>/mrview.nvim",
    dependencies = { "lewis6991/gitsigns.nvim", "folke/snacks.nvim" },
    opts = {},
    keys = {
        { "<leader>gm", function() require("mrview").on() end, desc = "MR review on" },
        { "<leader>gd", function() require("mrview").structural() end, desc = "MR review on (structural)" },
        { "<leader>gM", function() require("mrview").off() end, desc = "MR review off" },
        { "<leader>gb", function() require("mrview").base() end, desc = "MR review base" },
        { "<leader>gf", function() require("mrview").files() end, desc = "MR changed files" },
        { "<leader>gk", function() require("mrview").commits() end, desc = "MR commits" },
        { "]C", function() require("mrview").next_commit() end, desc = "MR next commit" },
        { "[C", function() require("mrview").prev_commit() end, desc = "MR previous commit" },
        { "<leader>gv", function() require("mrview").toggle_reviewed() end, desc = "MR toggle reviewed" },
        { "<leader>gV", function() require("mrview").since_review() end, desc = "MR diff since review" },
    },
}
```

### Hunk navigation with gitsigns

While structural mode is on, its marks replace gitsigns hunks for navigation
and deleted lines. Route the keys in gitsigns' `on_attach`:

```lua
require("gitsigns").setup({
    on_attach = function(bufnr)
        local gs = require("gitsigns")
        local sd = require("mrview.structdiff")
        local function map(l, r, desc)
            vim.keymap.set("n", l, r, { buffer = bufnr, desc = desc })
        end
        local function nav(dir)
            if sd.active() then sd.nav(dir) else gs.nav_hunk(dir) end
        end
        map("]g", function() nav("next") end, "next hunk")
        map("[g", function() nav("prev") end, "previous hunk")
        map("<leader>td", function()
            if sd.active() then sd.toggle_deleted() else gs.toggle_deleted() end
        end, "deleted lines")
        map("<leader>ts", function()
            if sd.active() then sd.toggle_split() end
        end, "side-by-side base pane")
    end,
})
```

## Commands

`:MRView {sub} [target]`

| Subcommand   | Action                                                         |
|--------------|----------------------------------------------------------------|
| `on`         | Review against the merge-base with the target (gitsigns signs) |
| `structural` | Same, with difftastic signs                                    |
| `off`        | Leave review mode, restore gitsigns                            |
| `base`       | Pick the target branch or commit                               |
| `files`      | Picker of changed files with reviewed marks                    |
| `commits`    | Picker of MR commits; selecting one enters commit mode         |
| `next`       | Next commit in commit mode                                     |
| `prev`       | Previous commit in commit mode                                 |
| `reviewed`   | Toggle the reviewed mark of the current file                   |
| `since`      | Diff the current file against the commit it was reviewed at    |
| `deleted`    | Toggle deleted lines (structural mode)                         |
| `split`      | Toggle the side-by-side base pane (structural mode)            |

`on`, `structural`, `files`, `reviewed` and `since` accept an optional target
(for example `:MRView on origin/develop`).

## Configuration

Defaults:

```lua
require("mrview").setup({
    remote = "origin",               -- remote whose HEAD names the target
    targets = { "main", "master" },  -- fallback target names
    difft = {
        cmd = "difft",
        debounce_ms = 300,           -- delay before rerunning difft after an edit
    },
})
```

`setup()` is optional; without it the defaults apply.

## Highlight groups

| Group                    | Default link     | Used for                                 |
|--------------------------|------------------|------------------------------------------|
| `StructDiffFormat`       | `NonText`        | Lines changed only in formatting         |
| `StructDiffAddInline`    | `DiffAdd`        | Added tokens                             |
| `StructDiffChangeInline` | `DiffAdd`        | Changed tokens                           |
| `StructDiffDeleteInline` | `DiffDelete`     | Deleted tokens in virtual lines and pane |

Line signs in structural mode reuse the `GitSignsAdd`, `GitSignsChange` and
`GitSignsDelete` groups.

## How it works

The review base is `git merge-base HEAD <target>`, where the target is
`<remote>/HEAD` or the first existing name from `targets`. gitsigns is pointed
at that base with `change_base`. Reviewed marks and the chosen target are
kept in a JSON state file in the git common directory, so they
are shared between worktrees and are not tracked by git. In structural mode
each buffer is compared with its base version by `difft --display=json`, and
the chunks are turned into signs, inline highlights and virtual lines.

## Limitations

- difftastic's JSON output is unstable and needs `DFT_UNSTABLE=yes`; a new
  difftastic release can change it.
- Commit mode checks out each commit with a detached HEAD, so it refuses to
  start while tracked files have uncommitted changes. If Neovim exits during
  commit mode, HEAD stays detached until you check the branch out again.
- There is no forge integration.

## Comparison

[difftsigns.nvim](https://github.com/janbuchar/difftsigns.nvim) dims
formatting-only lines inside the gitsigns gutter using difftastic, without a
review workflow. [review-mode.nvim](https://github.com/adrianmross/review-mode.nvim)
reviews GitHub and GitLab pull requests in ordinary buffers through `gh` and
`glab`, including posting comments.

## License

MIT
