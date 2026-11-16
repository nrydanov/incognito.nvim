# incognito.nvim

> К нам едет ревизор. Инкогнито.
>
> An inspector is coming to see us. Incognito.
>
> Gogol, *The Government Inspector*, 1836

The review arrives the same way: no review tab, no diff window. You open the
files of a merge request as you open any file, with LSP and your usual
motions, and the review is there, in the gutter.

- Line signs come from gitsigns against the merge-base of the MR target.
- Structural mode asks [difftastic](https://github.com/Wilfred/difftastic)
  which lines changed; lines that changed only in formatting are dimmed.
- Deleted lines are shown as virtual lines; a side-by-side pane shows the
  base version of the file.
- A files picker lists the changed files with reviewed marks: `✓` reviewed,
  `~` changed since it was marked.
- Commit mode steps through the MR one commit at a time in a separate
  worktree; your checkout, its HEAD and uncommitted changes stay as they are.
  One key switches between a file at the commit and the same file in your
  working tree, on the same line of code, to see whether a later commit
  already changed it.

## Requirements

- Neovim >= 0.11
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)
- [snacks.nvim](https://github.com/folke/snacks.nvim) for the files and
  commits pickers
- `difft` (difftastic) on `PATH` for structural mode; tested with 0.70 and 0.71

Run `:checkhealth incognito` to check them.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "nrydanov/incognito.nvim",
    dependencies = { "lewis6991/gitsigns.nvim", "folke/snacks.nvim" },
    lazy = false, -- Install the default keys at startup.
    opts = {},
}
```

### Default keys

Normal-mode mappings use `<leader>i` for Incognito. Set `vim.g.mapleader`
before loading the plugin; with Space as leader, head selection is `Space ih`.

| Keys | Action |
|------|--------|
| `<leader>io` / `<leader>iq` | Turn review on / off |
| `<leader>is` | Structural review |
| `<leader>ib` / `<leader>ih` | Choose base / head |
| `<leader>if` / `<leader>ic` | Changed files / commits |
| `<leader>ir` | Clean range diff |
| `<leader>in` / `<leader>ip` | Next / previous commit |
| `<leader>it` | Switch between Review and Source |
| `<leader>iv` / `<leader>iV` | Toggle reviewed / changes since review |
| `<leader>id` / `<leader>iw` | Toggle deleted lines / diff window (structural mode) |

Existing mappings on those keys are kept. All defaults have descriptions for
keymap pickers. The commands and Lua functions remain available for custom keys.

```lua
require("incognito").setup({ keymaps = { prefix = "<leader>m" } })
-- Or disable the entire default set:
require("incognito").setup({ keymaps = false })
```

Calling `setup()` again updates only mappings still owned by Incognito; user
replacements are kept. If you use command-only lazy loading, the defaults become
available only after the plugin loads. Use `lazy = false` as above for startup keys,
or disable defaults and provide your own lazy.nvim `keys` entries.

### Hunk navigation with gitsigns

While structural mode is on, its marks replace gitsigns hunks for navigation
and deleted lines. Route the keys in gitsigns' `on_attach`:

```lua
require("gitsigns").setup({
    on_attach = function(bufnr)
        local gs = require("gitsigns")
        local sd = require("incognito.structdiff")
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

`:Incognito {sub} [target]`

| Subcommand   | Action                                                         |
|--------------|----------------------------------------------------------------|
| `on`         | Review against the merge-base with the target (gitsigns signs) |
| `structural` | Same, with difftastic signs                                    |
| `off`        | Leave review mode, restore gitsigns                            |
| `base` / `change_base` | Pick the left target (not the computed merge-base L) |
| `head` / `change_head [rev]` | Pick a branch, Git expression or SHA as head R |
| `range`      | Read-only clean L → R preview, without experimental edits      |
| `files`      | Picker of changed files with reviewed marks                    |
| `commits`    | Picker of MR commits; selecting one enters commit mode         |
| `next`       | Next commit in commit mode                                     |
| `prev`       | Previous commit in commit mode                                 |
| `tip`        | Switch between the file at the commit and in the working tree  |
| `reviewed`   | Toggle the reviewed mark of the current file                   |
| `since`      | Diff the current file against the commit it was reviewed at    |
| `deleted`    | Toggle deleted lines (structural mode)                         |
| `split`      | Toggle the side-by-side base pane (structural mode)            |

`on`, `structural`, `files`, `reviewed` and `since` accept an optional target
(for example `:Incognito on origin/develop`).

## Configuration

Defaults:

```lua
require("incognito").setup({
    remote = "origin",               -- remote whose HEAD names the target
    targets = { "main", "master" },  -- fallback target names
    keymaps = { prefix = "<leader>i" }, -- false disables default mappings
    commit_mode = {
        -- Default: <git-common-dir>/incognito/<branch>-<hash>.
        -- worktree_dir = "/absolute/canonical/path/to/reviews",
        -- Optional shared dependencies: NOT a sandbox; external writes hit Source.
        link = {},
        -- A commit whose lockfiles differ from your checkout gets a warning:
        -- the linked dependencies may not fit it.
        lockfiles = { "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml",
                      "yarn.lock", "bun.lock", "bun.lockb" },
    },
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

## Mental model and editable review

Start in **Source**, your ordinary checkout. Ask five questions: which range,
which commit, which files am I editing, what is the diff base, and what survives
my next action? No GitLab connection is needed.

- **target** is the left revision chosen with `base` / `change_base`.
- **L** is `merge-base(target, R)`, not necessarily target itself.
- **R** is the pinned full SHA chosen with `head` / `change_head`. It defaults
  to Source HEAD, independently of **N**, the inspected commit. Later external
  movement of a branch does not silently move R; choose the head again to refresh.
- **Review** is one persistent detached worktree per common repository and
  owner branch. Choosing a branch owns its Review; an expression or SHA uses
  the current Source branch as owner. Detached Source prompts for an owner.
  The Lua API also accepts `change_head(rev, owner)` explicitly. Choosing an
  owner does not check out that branch in Source.
- **N** is selected with `commits` / `next` / `prev`; physical Review HEAD is N.
  Source HEAD, index and process cwd do not change. Initially N is R; reopening
  the same R resumes the last N and its disk/index, not a fresh checkout.

Try `:Incognito change_head`, search a branch or a full/abbreviated SHA, or
enter a Git expression with no matching row, such as `HEAD~2`. The picker
searches commits reachable from all refs, not only the previous range; an
explicit full SHA can also address an existing unreachable commit. Invalid or
ambiguous input is rejected unchanged, never normalized or guessed. A chosen
row disambiguates the search. `Head~X` is not silently rewritten to `HEAD~2`.

The commits list is `git log --reverse L..R` (reachability, L excluded, R
included), not an inclusive mathematical interval or a first-parent walk.
`base` resolves revisions in Source. Changing only target/L retains the
experiment; if N falls outside the range, this is reported and stepping asks
you to select a listed commit or turn review off. An empty range stays empty.

### What is compared

On N, `files` and its preview show **first-parent(N) → N + disk edits**,
including staged, unstaged and new non-ignored files, without secretly staging
anything. Root commits use an empty tree. Structural signs use the current
buffer, including unsaved text; the files picker and Git preview use disk.
Ignored artifacts are not code-diff entries. Use `:Incognito range` for the
separate, explicitly clean **L → R** overview; it does not aggregate experiments.
Outside commit mode, the existing `on` / `files` view remains **Source + edits**
against its merge-base, not a clean copy of R.

`tip` opens the **real Source file**, possibly dirty, against N; editing it
edits Source. It is not a clean R snapshot. Reviewed marks mean “read at this
content”, not acceptance, commits or saved experiments. `since` uses the Git
commit recorded at marking time, not a snapshot of arbitrary uncommitted text.
Existing commands, Lua APIs and reviewed-state JSON remain supported.

### What survives

- A real N change, or a new R for the same owner, deliberately discards Review
  staged/unstaged changes, non-ignored untracked files and unsaved Review text,
  without a save dialog. Old buffer undo history is wiped; persistent undo is disabled for Review
  buffers so an older N cannot be resurrected. **Ignored artifacts
  remain**, so tracked code matches N but dependencies/build output may be stale.
- Selecting the same N/R, cancelling a picker or reaching a list boundary does
  not discard anything. Returning via `tip` does not reset Review.
- Another owner uses its own Review and leaves the previous owner's disk alone.
- `off` and editor exit **do not reset or delete Review** and do not autosave.
  Modified Review buffers remain accessible after `off`; `:wqa` writes, normal
  `:qa` uses Neovim's protection, `:qa!` or a crash can lose unsaved text.
  Only already-written disk/index changes are promised across exit/crash.

### Safety and external tools

New Reviews live in `<git-common-dir>/incognito/<branch>-<hash>`, normally
`.git/incognito/feature-name-a1b2c3d4e5f6/`. Branch names are sanitized and
shortened; the hash distinguishes owners with similar names. Git's own
`.git/worktrees/` remains reserved for administrative files. Review files under
`.git` cannot be staged in Source, and no sibling directories are created.
For linked Source worktrees, the common Git directory belongs to the shared repository.
`git worktree list` shows the full Review paths; the editor's working directory
is unchanged, so launch agents explicitly in the desired Review directory.

Existing Reviews at `<Source>.incognito/<repository+owner hash>` or
`stdpath("data")/incognito/worktrees/<repository+owner hash>` are reopened in
place when no custom directory is configured; they are not moved automatically.
`commit_mode.worktree_dir` selects a custom parent and retains hash-only names.
It must be a canonical, non-symlink path outside any checkout and Git metadata,
with `<git-common-dir>/incognito` as the sole exception.
Changing this setting never migrates or deletes
an old Review. A manifest under `<git-common-dir>/incognito-reviews/` records
identity, Source/Review paths, target/L/R/N and transition phase. Old scratch
worktrees and unknown directories are not adopted or garbage-collected.

One Neovim holds the Review lock until exit, including after `off` or owner
switch while old buffers can remain writable. Another editor is refused.
After crash, only verified dead locks are reclaimed, never their Review data.
On Linux the lock also checks boot/process-start identity to handle PID reuse;
elsewhere a live/inaccessible PID is conservatively kept locked. An interrupted
lock acquisition can leave a `.lock.gate` requiring manual inspection/removal
when all owners are stopped. No background lock cleanup runs.

Before a destructive transition, ownership, worktree registration and its own
Git administrative directory, detached HEAD, index and external Git-operation
state are verified. External HEAD movement, conflicts, rebase/cherry-pick,
nested repositories/submodules, mounted directories, ignored/target collisions
or unsafe link ancestors stop the operation before buffer discard. Submodule and sparse/skip-worktree/assume-unchanged transitions
conservatively require manual Git handling. Git hooks are disabled for these
plugin-owned workspace operations; manual Git is unaffected. A Git/FS error after
transition starts is reported without rollback promises; the manifest retains
an interrupted phase for manual inspection, never an automatic retry/reset.

Dependency links default to `{}`. Opting into `link = { "node_modules" }`
warns that shared dependencies are **not isolated**. Cleanup unlinks rather
than follows links. Plugin opening/writing a Review symlink is refused before
Neovim can canonicalize it into Source. This is not a sandbox against an
external shell, manual Source opens, hardlinks, user autocmds or another tool
racing filesystem mutations. Stop external writers yourself before switching N.
External editor/agent conflicts use ordinary Neovim `checktime`/write checks;
there is no automatic merge or force-reload of modified text.

Run agents, builds and Git manually in the appropriate Review directory (the
path is shown on entry). Commands started in Source are **not redirected**.
There is no Codex context generator, agent launcher, build runner or built-in
amend/rebase/apply. External commits must be anchored manually; if HEAD changes,
the plugin stops rather than erasing them. No Source branch is rewritten.

## Limitations

- difftastic JSON is unstable and needs `DFT_UNSTABLE=yes` (set by the plugin).
- Recorded review directories consume disk until you inspect/remove them
  manually with Git while no editor owns them; `off` is not cleanup.
- A transition is intentionally destructive, not a filesystem transaction or
  backup. Partial errors require manual inspection of disk and manifest.
- Ignored environment artifacts remain; a matching tracked tree does not
  guarantee reproducible dependencies or builds.
- Linux is covered by automated exit/crash tests; platform-specific mount and
  symlink behavior should also be checked on the user's OS.
- There is no forge integration.

## Verification

With dependencies under `$INCOGNITO_DEPS` (gitsigns.nvim, snacks.nvim and
optionally nvim-treesitter), and Neovim/difft/StyLua on PATH:

```sh
make test
make lint
git diff --check
# subset:
SPEC=tests.editable_spec make test
```

The regression suite uses isolated temporary Git repos and child Neovim
processes for normal exit, SIGKILL/reopen, persistence and exclusive ownership;
it never runs a user-project build. For a manual check, use a disposable repo
with two feature commits: choose `head`, inspect the older `commits` entry,
edit/write a file, inspect `files` and `range`, then `off` and reopen the same
head. The written experiment should remain. Step to another N only when ready
to discard it; confirm Source HEAD/index/files/cwd are unchanged and late tracked
files disappear on the older N. Test unsaved loss only in that disposable repo.

## Comparison

[difftsigns.nvim](https://github.com/janbuchar/difftsigns.nvim) dims
formatting-only lines inside the gitsigns gutter using difftastic, without a
review workflow. [review-mode.nvim](https://github.com/adrianmross/review-mode.nvim)
reviews GitHub and GitLab pull requests in ordinary buffers through `gh` and
`glab`, including posting comments.

## License

MIT
