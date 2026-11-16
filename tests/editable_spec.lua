-- All destructive operations below are restricted to synthetic temporary repos.
local h = require("tests.helpers")
local mr = require("incognito.review")
local wsmod = require("incognito.workspace")
local M = {}
local function git(args, root)
    local out, err = mr.git(args, root)
    assert(out, err)
    return out
end
local function fixture()
    mr.off()
    vim.cmd("silent! %bwipeout!")
    mr.config.commit_mode.link = {}
    mr.config.commit_mode.worktree_dir = nil
    local dir = vim.uv.fs_realpath(h.repo({ ["a.lua"] = "v0\n", [".gitignore"] = "cache/\n" }))
    git({ "branch", "-M", "main" }, dir)
    git({ "checkout", "-qb", "feature" }, dir)
    h.commit(dir, { ["a.lua"] = "v1\n" })
    h.commit(dir, { ["a.lua"] = "v2\n", ["future.lua"] = "future\n" })
    vim.cmd("edit! " .. vim.fn.fnameescape(dir .. "/a.lua"))
    return dir
end
local function enter_first(dir)
    assert(mr._enter_commit_mode(dir, mr._mr_commits(dir), 1))
    return mr._commit_mode()
end
local function data(root, name)
    return table.concat(vim.fn.readfile(root .. "/" .. name), "\n")
end

function M.test_default_worktree_is_private_and_cannot_be_staged_in_source()
    local dir = fixture()
    local mode = enter_first(dir)
    local common = git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, dir)
    h.assert_eq(vim.fs.dirname(mode.worktree), common .. "/incognito")
    assert(vim.fs.basename(mode.worktree):match("^feature%-%x+$"), "readable owner name")
    assert(vim.startswith(mode.ws.data.gitdir, common .. "/worktrees/"), "Git owns the administrative directory")
    assert(wsmod.validate(mode.ws))
    assert(not vim.uv.fs_lstat(dir .. ".incognito"), "no sibling directory created")
    h.write(mode.worktree, "experiment.lua", "review only\n")
    git({ "add", "-A" }, dir)
    h.assert_eq(git({ "status", "--porcelain" }, dir), "", "Source cannot stage Review files")
    mr.off()
end

function M.test_worktree_names_distinguish_branches_with_the_same_slug()
    local dir = fixture()
    git({ "branch", "topic/name" }, dir)
    git({ "branch", "topic-name" }, dir)
    assert(mr.change_head("topic/name"))
    local first = mr._commit_mode().worktree
    assert(mr.change_head("topic-name"))
    local second = mr._commit_mode().worktree
    assert(vim.fs.basename(first):match("^topic%-name%-%x+$"))
    assert(vim.fs.basename(second):match("^topic%-name%-%x+$"))
    assert(first ~= second, "sanitized names cannot share a Review")
    mr.off()
end

function M.test_linked_source_uses_common_git_directory_for_review()
    local dir = fixture()
    local linked = vim.fn.tempname()
    git({ "worktree", "add", "--quiet", "-b", "linked-feature", linked, "feature" }, dir)
    linked = assert(vim.uv.fs_realpath(linked))
    vim.cmd("edit! " .. vim.fn.fnameescape(linked .. "/a.lua"))
    local mode = enter_first(linked)
    h.assert_eq(vim.fs.dirname(mode.worktree), dir .. "/.git/incognito")
    assert(wsmod.validate(mode.ws))
    mr.off()
end

function M.test_custom_worktree_cannot_use_checkout_or_git_administrative_paths()
    local dir = fixture()
    local range = mr._range_for(dir)
    for _, parent in ipairs({ dir .. "/reviews", dir .. "/.git", dir .. "/.git/worktrees", dir .. "/.git/objects" }) do
        local ws = wsmod.open(dir, range.owner, range, { worktree_dir = parent })
        assert(not ws, "unsafe Review parent accepted: " .. parent)
    end
    h.assert_eq(git({ "status", "--porcelain" }, dir), "")
end

function M.test_step_resets_index_untracked_and_undo_but_keeps_ignored()
    local dir = fixture()
    local cwd = vim.uv.cwd()
    local source_head = git({ "rev-parse", "HEAD" }, dir)
    local mode = enter_first(dir)
    local path = mode.worktree
    assert(not vim.uv.fs_stat(path .. "/future.lua"), "no later tracked files on N")
    h.write(path, "a.lua", "staged\n")
    git({ "add", "a.lua" }, path)
    h.write(path, "a.lua", "disk experiment\n")
    h.write(path, "untracked.lua", "discard\n")
    h.write(path, "cache/keep", "retained\n")
    local old = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(old, 0, -1, false, { "memory experiment" })
    mr.step_commit(0)
    h.assert_eq(data(path, "a.lua"), "disk experiment", "same N does not reset")
    mr.step_commit(-1)
    h.assert_eq(vim.api.nvim_buf_get_lines(old, 0, -1, false), { "memory experiment" })
    mr.step_commit(1)
    assert(not vim.api.nvim_buf_is_valid(old), "old buffer/undo history gone")
    h.assert_eq(data(path, "a.lua"), "v2")
    h.assert_eq(git({ "diff", "--cached", "--name-only" }, path), "")
    assert(not vim.uv.fs_lstat(path .. "/untracked.lua"))
    h.assert_eq(data(path, "cache/keep"), "retained")
    vim.cmd("silent! undo")
    h.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "v2" })
    h.assert_eq(git({ "rev-parse", "HEAD" }, dir), source_head)
    h.assert_eq(vim.uv.cwd(), cwd)
    mr.step_commit(-1)
    assert(not vim.uv.fs_stat(path .. "/future.lua"))
    mr.off()
end

function M.test_off_reopen_preserves_disk_index_unsaved_and_last_N()
    local dir = fixture()
    local mode = enter_first(dir)
    h.write(mode.worktree, "a.lua", "saved experiment\n")
    git({ "add", "a.lua" }, mode.worktree)
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "unsaved experiment" })
    mr.off()
    assert(vim.api.nvim_buf_is_valid(b) and vim.bo[b].modified)
    h.assert_eq(data(mode.worktree, "a.lua"), "saved experiment", "no autosave")
    assert(mr.change_head("feature"))
    local next_mode = mr._commit_mode()
    h.assert_eq(next_mode.worktree, mode.worktree)
    h.assert_eq(next_mode.selected, mode.selected, "reopens last N, not R")
    h.assert_eq(data(mode.worktree, "a.lua"), "saved experiment")
    assert(git({ "diff", "--cached", "--name-only" }, mode.worktree) ~= "")
    h.assert_eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "unsaved experiment" })
    mr.off()
end

function M.test_head_branch_expression_hash_and_invalid_cancel_are_isolated()
    local dir = fixture()
    local source = git({ "rev-parse", "HEAD" }, dir)
    assert(mr.change_head("feature"))
    local mode = mr._commit_mode()
    local path = mode.worktree
    h.write(path, "a.lua", "experiment\n")
    assert(mr.change_head("feature"))
    h.assert_eq(data(path, "a.lua"), "experiment")
    assert(not mr.change_head("Head~X"), "no token normalization")
    assert(not mr.change_head("--all"), "no revision option injection")
    assert(not mr.change_head(""))
    h.assert_eq(data(path, "a.lua"), "experiment")
    assert(mr.change_head("HEAD~1"))
    h.assert_eq(mr._commit_mode().worktree, path)
    h.assert_eq(data(path, "a.lua"), "v1")
    h.assert_eq(git({ "rev-parse", "HEAD" }, dir), source)
    -- SHA outside the old N list is a valid new R under the Source owner.
    assert(mr.change_head(source:sub(1, 12)))
    h.assert_eq(mr._commit_mode().range.R, source)
    git({ "branch", "other", "HEAD~1" }, dir)
    h.write(path, "a.lua", "owner A experiment\n")
    assert(mr.change_head("other"))
    local other = mr._commit_mode().worktree
    assert(other ~= path)
    h.assert_eq(vim.api.nvim_buf_get_name(0), other .. "/a.lua", "windows follow new owner")
    h.assert_eq(data(path, "a.lua"), "owner A experiment", "other owner disk retained")
    assert(mr.change_head("feature"))
    h.assert_eq(mr._commit_mode().worktree, path)
    h.assert_eq(data(path, "a.lua"), "owner A experiment")
    mr.off()
end

function M.test_ambiguous_ref_preserves_experiment_even_when_git_warnings_are_disabled()
    local dir = fixture()
    local mode = enter_first(dir)
    git({ "tag", "feature", "HEAD~1" }, dir)
    git({ "config", "core.warnAmbiguousRefs", "false" }, dir)
    h.write(mode.worktree, "a.lua", "staged experiment\n")
    git({ "add", "a.lua" }, mode.worktree)
    h.write(mode.worktree, "untracked.lua", "keep\n")
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "unsaved experiment" })
    local index = git({ "write-tree" }, mode.worktree)
    local manifest = vim.fn.readfile(mode.ws.manifest)
    local range = vim.deepcopy(mode.range)
    for _, rev in ipairs({ "feature", "feature~1", "feature^{commit}" }) do
        assert(not mr.change_head(rev), "ambiguous ref must not select Git's preferred match: " .. rev)
    end
    mr._use_base(dir, "feature")
    h.assert_eq(mode.range, range, "ambiguous target must also be refused")
    h.assert_eq(vim.fn.readfile(mode.ws.manifest), manifest)
    h.assert_eq(git({ "write-tree" }, mode.worktree), index)
    h.assert_eq(data(mode.worktree, "a.lua"), "staged experiment")
    h.assert_eq(data(mode.worktree, "untracked.lua"), "keep")
    h.assert_eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "unsaved experiment" })
    assert(mr.change_head("refs/heads/feature"), "fully qualified branch disambiguates")
    h.assert_eq(vim.fn.readfile(mode.ws.manifest), manifest, "same R keeps the experiment")
    assert(mr.change_head("refs/tags/feature"), "explicit tag is still a valid head")
    h.assert_eq(mr._commit_mode().range.R, git({ "rev-parse", "refs/tags/feature" }, dir))
    h.assert_eq(data(mode.worktree, "a.lua"), "v1")
    mr.off()
end

function M.test_target_changes_preserve_experiment_even_outside_range()
    local dir = fixture()
    local mode = enter_first(dir)
    h.write(mode.worktree, "a.lua", "keep me\n")
    mr._use_base(dir, "HEAD~1")
    h.assert_eq(mr._commit_mode().selected, mode.selected)
    h.assert_eq(data(mode.worktree, "a.lua"), "keep me")
    mr._use_base(dir, "HEAD")
    assert(mr._commit_mode().outside)
    h.assert_eq(data(mode.worktree, "a.lua"), "keep me")
    h.assert_eq(mr._commit_mode().range.L, git({ "rev-parse", "HEAD" }, dir))
    mr.off()
end

function M.test_new_files_and_clean_range_preview_do_not_stage()
    local dir = fixture()
    local mode = enter_first(dir)
    h.write(mode.worktree, "new.lua", "new\n")
    h.write(mode.worktree, "cache/ignored.lua", "not listed\n")
    local index = git({ "write-tree" }, mode.worktree)
    local items, files = mr._changed_items(mode.base, mode.worktree)
    assert(vim.tbl_contains(files, "new.lua"))
    assert(not vim.tbl_contains(files, "cache/ignored.lua"))
    assert(vim.tbl_contains(
        vim.tbl_map(function(i)
            return i.untracked == true and i.file or ""
        end, items),
        "new.lua"
    ))
    h.assert_eq(git({ "write-tree" }, mode.worktree), index)
    local previous, captured = Snacks
    Snacks = { picker = {
        pick = function(opts)
            captured = opts
        end,
    } }
    mr.range()
    Snacks = previous
    assert(captured.title:find("Clean range", 1, true))
    h.assert_eq(git({ "write-tree" }, mode.worktree), index)
    mr.off()
end

function M.test_recreated_deleted_file_preview_compares_disk_with_parent_without_staging()
    for _, staged in ipairs({ false, true }) do
        local dir = fixture()
        if not staged then
            git({ "rm", "a.lua" }, dir)
            h.commit(dir, {})
        end
        assert(mr.change_head("feature"))
        local mode = mr._commit_mode()
        if staged then
            git({ "rm", "--cached", "a.lua" }, mode.worktree)
        end
        h.write(mode.worktree, "a.lua", "recreated content\n")
        local index = git({ "write-tree" }, mode.worktree)
        local parent = git({ "show", mode.base .. ":a.lua" }, mode.worktree)
        local items = mr._changed_items(mode.base, mode.worktree)
        local matches = vim.tbl_filter(function(item)
            return item.file == "a.lua"
        end, items)
        h.assert_eq(#matches, 1, "one row must combine deletion and untracked replacement")
        local item = matches[1]
        h.assert_eq(item.status, " M")

        local previous, captured, preview = Snacks
        Snacks = {
            picker = {
                pick = function(opts)
                    captured = opts
                    return { closed = false }
                end,
                preview = {
                    cmd = function(cmd, ctx)
                        preview = vim.system(cmd, { cwd = ctx.item.cwd, text = true }):wait()
                    end,
                },
            },
        }
        local ok, err = pcall(function()
            mr.files()
            captured.preview({ item = item })
        end)
        Snacks = previous
        assert(ok, err)
        h.assert_eq(preview.code, 0, preview.stderr)
        assert(preview.stdout:find("-" .. parent .. "\n", 1, true), preview.stdout)
        assert(preview.stdout:find("+recreated content\n", 1, true), preview.stdout)
        h.assert_eq(git({ "write-tree" }, mode.worktree), index, "preview must leave staging alone")

        h.write(mode.worktree, "a.lua", parent .. "\n")
        local _, files = mr._changed_items(mode.base, mode.worktree)
        assert(not vim.tbl_contains(files, "a.lua"), "restoring the parent's content leaves no diff")
        h.assert_eq(git({ "write-tree" }, mode.worktree), index)
        mr.off()
    end
end

function M.test_cleanup_does_not_follow_links_and_plugin_open_refuses_links()
    local dir = fixture()
    local mode = enter_first(dir)
    assert(vim.uv.fs_symlink(dir, mode.worktree .. "/outside"))
    local safe = wsmod.safe_file(mode.worktree, mode.worktree .. "/outside/a.lua")
    assert(not safe)
    local source = data(dir, "a.lua")
    mr.step_commit(1)
    h.assert_eq(data(dir, "a.lua"), source)
    assert(not vim.uv.fs_lstat(mode.worktree .. "/outside"), "link removed, not target")
    assert(vim.uv.fs_symlink(dir .. "/a.lua", mode.worktree .. "/link.lua"))
    local previous, captured = Snacks
    Snacks = {
        picker = {
            pick = function(opts)
                captured = opts
                return { closed = false }
            end,
        },
    }
    mr.files()
    Snacks = previous
    local jump = require("snacks.picker.actions").jump
    local called = false
    require("snacks.picker.actions").jump = function()
        called = true
    end
    captured.confirm({
        selected = function()
            return { { file = "link.lua" } }
        end,
    })
    require("snacks.picker.actions").jump = jump
    assert(not called, "must reject lexical link before Neovim canonicalizes it")
    h.assert_eq(data(dir, "a.lua"), source)
    mr.off()
end

function M.test_nested_git_and_external_git_state_block_before_buffer_loss()
    local dir = fixture()
    local mode = enter_first(dir)
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "keep unsaved" })
    git({ "init", "-q", "nested" }, mode.worktree)
    mr.step_commit(1)
    h.assert_eq(mode.index, 1)
    h.assert_eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "keep unsaved" })
    vim.fn.delete(mode.worktree .. "/nested", "rf")
    git({ "checkout", "--quiet", "--detach", mode.range.R }, mode.worktree)
    mr.step_commit(1)
    h.assert_eq(mode.index, 1, "external HEAD not reset")
    h.assert_eq(git({ "rev-parse", "HEAD" }, mode.worktree), mode.range.R)
    mr.off()
end

function M.test_admin_dir_substitution_cannot_reset_Source()
    local dir = fixture()
    local mode = enter_first(dir)
    local source_head = git({ "rev-parse", "HEAD" }, dir)
    git({ "checkout", "--quiet", "--detach", mode.selected }, dir)
    local index = git({ "write-tree" }, dir)
    local dotgit = mode.worktree .. "/.git"
    local original = vim.fn.readfile(dotgit)
    vim.fn.writefile({ "gitdir: " .. dir .. "/.git" }, dotgit)
    local ok, why = wsmod.validate(mode.ws)
    assert(not ok and why:find("administrative", 1, true), why)
    mr.step_commit(1)
    h.assert_eq(git({ "rev-parse", "HEAD" }, dir), mode.selected)
    h.assert_eq(git({ "write-tree" }, dir), index)
    vim.fn.writefile(original, dotgit)
    git({ "checkout", "--quiet", "feature" }, dir)
    h.assert_eq(git({ "rev-parse", "HEAD" }, dir), source_head)
    mr.off()
end

function M.test_unmerged_index_and_interrupted_phase_are_not_reset()
    local dir = fixture()
    local mode = enter_first(dir)
    local blob = git({ "rev-parse", mode.selected .. ":a.lua" }, dir)
    local input = ("100644 %s 1\ta.lua\n100644 %s 2\ta.lua\n100644 %s 3\ta.lua\n"):format(blob, blob, blob)
    assert(mr.git({ "update-index", "--index-info" }, mode.worktree, input))
    mr.step_commit(1)
    h.assert_eq(mode.index, 1)
    assert(git({ "ls-files", "--unmerged" }, mode.worktree) ~= "")
    git({ "reset", "--quiet", mode.selected }, mode.worktree)
    mode.ws.data.phase = "transition"
    assert(wsmod.save(mode.ws))
    mr.step_commit(1)
    h.assert_eq(mode.index, 1)
    mode.ws.data.phase = "ready"
    assert(wsmod.save(mode.ws))
    mr.off()
end

function M.test_custom_path_symlink_parent_and_collision_are_refused()
    local dir = fixture()
    local configured = vim.fn.tempname()
    mr.config.commit_mode.worktree_dir = configured
    local mode = enter_first(dir)
    assert(vim.startswith(mode.worktree, configured .. "/"))
    mr.off()
    local other = fixture()
    local target = vim.fn.tempname()
    vim.fn.mkdir(target, "p")
    local link = target .. "-link"
    assert(vim.uv.fs_symlink(target, link, { dir = true }))
    mr.config.commit_mode.worktree_dir = link
    assert(not mr.change_head("feature"))
    assert(not mr._commit_mode())
    mr.config.commit_mode.worktree_dir = nil
    vim.fn.delete(link)
    assert(vim.uv.fs_stat(other))
end

function M.test_root_and_merge_use_empty_tree_and_first_parent()
    local dir = fixture()
    local root = git({ "rev-list", "--max-parents=0", "HEAD" }, dir)
    local empty = mr._commit_base(dir, root)
    h.assert_eq(git({ "cat-file", "-t", empty }, dir), "tree")
    git({ "checkout", "-qb", "side", "main" }, dir)
    h.commit(dir, { ["side.lua"] = "side\n" })
    git({ "checkout", "--quiet", "feature" }, dir)
    local parent = git({ "rev-parse", "HEAD" }, dir)
    git({ "-c", "user.email=t@t", "-c", "user.name=t", "merge", "--no-ff", "-qm", "merge", "side" }, dir)
    h.assert_eq(mr._commit_base(dir, git({ "rev-parse", "HEAD" }, dir)), parent)
end

local function child_script(dir, body)
    local script = vim.fn.tempname() .. ".lua"
    local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
    vim.fn.writefile(
        vim.split(
            ([[
local root = %q
vim.opt.rtp:prepend(root)
package.path = root .. "/?.lua;" .. package.path
vim.cmd("edit " .. vim.fn.fnameescape(%q .. "/a.lua"))
local mr = require("incognito.review")
%s
]]):format(root, dir, body),
            "\n"
        ),
        script
    )
    return script, root
end

function M.test_legacy_sibling_review_reopens_without_moving_saved_edits()
    local dir = fixture()
    local script, root = child_script(
        dir,
        ([[
mr.config.commit_mode.worktree_dir = %q
assert(mr.change_head("feature"))
local m = mr._commit_mode()
vim.fn.writefile({"legacy experiment"}, m.worktree .. "/a.lua")
assert(mr.git({"add", "a.lua"}, m.worktree))
vim.cmd("qa!")
]]):format(dir .. ".incognito")
    )
    local result = vim.system(
        { vim.v.progpath, "--headless", "--clean", "-u", root .. "/tests/minimal_init.lua", "-l", script },
        { text = true }
    ):wait(15000)
    h.assert_eq(result.code, 0, result.stderr)
    assert(mr.change_head("feature"))
    local path = mr._commit_mode().worktree
    h.assert_eq(vim.fs.dirname(path), dir .. ".incognito")
    h.assert_eq(data(path, "a.lua"), "legacy experiment")
    assert(git({ "diff", "--cached", "--name-only" }, path) ~= "", "staged edit survives")
    mr.off()
end

function M.test_exit_crash_reopen_and_exclusive_lock_across_processes()
    for _, crash in ipairs({ false, true }) do
        local dir = fixture()
        local result = vim.fn.tempname()
        local body = ([[
assert(mr.change_head("feature"))
local m = mr._commit_mode()
mr.step_commit(-1)
vim.fn.writefile({"child saved"}, m.worktree .. "/a.lua")
assert(mr.git({"add", "a.lua"}, m.worktree))
vim.fn.writefile({m.worktree}, %q)
%s
]]):format(result, crash and 'vim.uv.kill(vim.fn.getpid(), "sigkill")' or 'vim.cmd("qa!")')
        local script, root = child_script(dir, body)
        local res = vim.system(
            { vim.v.progpath, "--headless", "--clean", "-u", root .. "/tests/minimal_init.lua", "-l", script },
            { text = true }
        ):wait(15000)
        assert(crash and res.signal ~= 0 or (not crash and res.code == 0), res.stderr)
        local path = vim.fn.readfile(result)[1]
        assert(mr.change_head("feature"))
        h.assert_eq(mr._commit_mode().worktree, path)
        h.assert_eq(data(path, "a.lua"), "child saved", "disk survives exit/crash/reopen")
        assert(git({ "diff", "--cached", "--name-only" }, path) ~= "", "staged edit survives")
        -- Off retains writable buffers and its editor lock; another editor cannot switch N.
        mr.off()
        local blocked, blocked_root = child_script(dir, 'assert(not mr.change_head("feature")); vim.cmd("qa!")')
        local check = vim.system(
            { vim.v.progpath, "--headless", "--clean", "-u", blocked_root .. "/tests/minimal_init.lua", "-l", blocked },
            { text = true }
        ):wait(15000)
        h.assert_eq(check.code, 0, check.stderr)
        h.assert_eq(data(path, "a.lua"), "child saved")
    end
end

function M.test_ignored_collision_preflight_preserves_buffers_and_files()
    local dir = fixture()
    -- Add a later tracked file under the earlier commit's ignored directory.
    h.write(dir, "cache/collision", "tracked future\n")
    git({ "add", "-f", "cache/collision" }, dir)
    git({ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "collision" }, dir)
    local mode = enter_first(dir)
    h.write(mode.worktree, "cache/collision", "ignored experiment\n")
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "unsaved" })
    mr.step_commit(2)
    h.assert_eq(mode.index, 1)
    h.assert_eq(data(mode.worktree, "cache/collision"), "ignored experiment")
    h.assert_eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "unsaved" })
    h.assert_eq(mode.ws.data.phase, "ready")
    mr.off()
end

function M.test_ignored_collisions_check_path_boundaries_in_both_directions()
    for _, paths in ipairs({
        { "cache/a", "cache/a" },
        { "cache/a", "cache/a/child" },
        { "cache/a/child", "cache/a" },
        { " space\r\n/child", " space\r\n" },
    }) do
        h.assert_eq(wsmod._ignored_collision({ paths[1] }, { paths[2] }), paths[1])
    end
    h.assert_eq(wsmod._ignored_collision({}, { "cache" }), nil)
    h.assert_eq(wsmod._ignored_collision({ "cache" }, {}), nil)
    h.assert_eq(wsmod._ignored_collision({ "cache/a", "cache-b" }, { "cache/ab", "cache-bb/file" }), nil)
    h.assert_eq(wsmod._ignored_collision({ "a" }, { "a-", "a/child" }), "a")
    h.assert_eq(wsmod._ignored_collision({ "a-", "a/child" }, { "a" }), "a/child")
end

function M.test_ignored_collisions_with_large_dependency_and_source_lists()
    local ignored, target = {}, {}
    for i = 1, 10000 do
        ignored[i] = "node_modules/package" .. i .. "/index.js"
        target[i] = "src/module" .. i .. "/index.lua"
    end
    h.assert_eq(wsmod._ignored_collision(ignored, target), nil)
    target[#target + 1] = "node_modules/package10000"
    h.assert_eq(wsmod._ignored_collision(ignored, target), ignored[#ignored])
end

function M.test_failed_preflight_and_checkout_are_not_reported_as_success()
    local dir = fixture()
    local mode = enter_first(dir)
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "unsaved preflight" })
    h.write(mode.worktree, "untracked", "before reset\n")
    local system = vim.system
    vim.system = function(cmd, opts, cb)
        if cmd[1] == "git" and vim.tbl_contains(cmd, "ls-tree") then
            return {
                wait = function()
                    return { code = 1, stderr = "injected ls-tree failure" }
                end,
            }
        end
        return system(cmd, opts, cb)
    end
    local ok, err = pcall(mr.step_commit, 1)
    vim.system = system
    assert(ok, err)
    h.assert_eq(mode.ws.data.phase, "ready")
    h.assert_eq(mode.index, 1)
    h.assert_eq(data(mode.worktree, "untracked"), "before reset")
    h.assert_eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "unsaved preflight" })
    -- A failure after destructive phase must leave an interrupted manifest,
    -- never retry/reset on the next step or silently claim N changed.
    vim.system = function(cmd, opts, cb)
        if cmd[1] == "git" and vim.tbl_contains(cmd, "checkout") then
            return {
                wait = function()
                    return { code = 1, stderr = "injected checkout failure" }
                end,
            }
        end
        return system(cmd, opts, cb)
    end
    ok, err = pcall(mr.step_commit, 1)
    vim.system = system
    assert(ok, err)
    h.assert_eq(mode.index, 1)
    h.assert_eq(mode.ws.data.phase, "transition")
    h.assert_eq(git({ "rev-parse", "HEAD" }, mode.worktree), mode.selected)
    mr.step_commit(1)
    h.assert_eq(mode.ws.data.phase, "transition")
    h.assert_eq(git({ "rev-parse", "HEAD" }, mode.worktree), mode.selected)
    -- Explicit fixture repair only, not plugin recovery behavior.
    mode.ws.data.phase, mode.ws.data.pending = "ready", nil
    assert(wsmod.save(mode.ws))
    mr.off()
end

function M.test_mount_and_submodule_preflight_refuse_discard()
    local dir = fixture()
    local mode = enter_first(dir)
    h.write(mode.worktree, "cache/keep", "keep\n")
    local readfile = vim.fn.readfile
    vim.fn.readfile = function(path, ...)
        if path == "/proc/self/mountinfo" then
            -- Deliberate mountinfo fixture, no privileged mount is needed.
            return { "1 2 3:4 / " .. mode.worktree .. "/cache rw - tmpfs tmpfs rw" }
        end
        return readfile(path, ...)
    end
    local ok, err = pcall(mr.step_commit, 1)
    vim.fn.readfile = readfile
    assert(ok, err)
    h.assert_eq(mode.index, 1)
    h.assert_eq(data(mode.worktree, "cache/keep"), "keep")
    git({ "update-index", "--add", "--cacheinfo", "160000," .. mode.selected .. ",sub" }, mode.worktree)
    mr.step_commit(1)
    h.assert_eq(mode.index, 1)
    assert(git({ "ls-files", "--stage" }, mode.worktree):find("160000", 1, true))
    mr.off()
end

function M.test_empty_range_detached_owner_and_fixed_R()
    local dir = fixture()
    assert(mr.change_head("feature"))
    local mode = mr._commit_mode()
    local R = mode.range.R
    -- External movement of the owner's ref does not move selected R.
    h.commit(dir, { ["a.lua"] = "v3\n" })
    h.assert_eq(mr._range_for(dir).R, R)
    h.assert_eq(mr._mr_commits(dir)[2].sha, R)
    mr.off()
    -- Empty ranges have no invented row, but retain physical N=R.
    assert(mr.change_head("main"))
    h.assert_eq(#mr._commit_mode().commits, 0)
    h.assert_eq(mr._commit_mode().index, nil)
    mr.step_commit(1)
    mr.off()
    git({ "checkout", "--quiet", "--detach", "feature" }, dir)
    assert(not mr.change_head("HEAD~1"), "detached Source needs explicit owner")
    assert(mr.change_head("HEAD~1", "feature"))
    h.assert_eq(mr._commit_mode().range.owner, "refs/heads/feature")
    assert(not mr.git({ "symbolic-ref", "-q", "HEAD" }, dir))
    mr.off()
end

function M.test_unowned_path_collision_and_pid_reuse_are_safe()
    if vim.uv.os_uname().sysname ~= "Linux" then
        return
    end -- start identity is Linux-specific
    local dir = fixture()
    local range = mr._range_for(dir)
    local common = git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, dir)
    local id = vim.fn.sha256(vim.json.encode({ common, range.owner }))
    local path = vim.fs.joinpath(common, "incognito", "feature-" .. id:sub(1, 12))
    h.write(path, "foreign", "do not remove\n")
    assert(not mr.change_head("feature"))
    h.assert_eq(data(path, "foreign"), "do not remove")
    vim.fn.delete(path, "rf") -- isolated fixture data only
    -- Existing same-host PID with different boot/start identity is reclaimable.
    local lock = common .. "/incognito-reviews/" .. id .. ".lock"
    vim.fn.mkdir(lock, "p")
    vim.fn.writefile(
        { vim.json.encode({ pid = vim.fn.getpid(), host = vim.uv.os_gethostname(), identity = "old-boot:start" }) },
        lock .. "/owner.json"
    )
    assert(mr.change_head("feature"))
    h.assert_eq(mr._commit_mode().worktree, path)
    mr.off()
end

function M.test_stale_structural_callback_is_ignored_after_step()
    local dir = fixture()
    local mode = enter_first(dir)
    local sd = require("incognito.structdiff")
    sd.enable(mode.base)
    local previous, captured, callback = Snacks, nil, nil
    local structural = mr.structural_status
    mr.structural_status = function(_, _, cb)
        callback = cb
    end
    Snacks = {
        picker = {
            pick = function(opts)
                captured = opts
                return {
                    closed = false,
                    list = {
                        update = function()
                            error("stale callback updated picker")
                        end,
                    },
                }
            end,
        },
    }
    local ok, err = pcall(function()
        mr.files()
        assert(captured and callback)
        mr.step_commit(1)
        callback({ ["a.lua"] = "unchanged" })
    end)
    mr.structural_status, Snacks = structural, previous
    mr.off()
    assert(ok, err)
end

function M.test_root_commit_structural_signs_use_empty_tree()
    local dir = fixture()
    local root = git({ "rev-list", "--max-parents=0", "HEAD" }, dir)
    assert(mr.change_head(root))
    local sd = require("incognito.structdiff")
    sd.enable(mr._commit_mode().base)
    h.wait_run(vim.api.nvim_get_current_buf())
    local signs = h.marks(vim.api.nvim_get_current_buf())
    h.assert_eq(signs[1], "Add")
    mr.off()
end

function M.test_write_after_file_is_replaced_with_symlink_is_refused()
    local dir = fixture()
    local mode = enter_first(dir)
    local source = data(dir, "a.lua")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "must not reach Source" })
    assert(vim.uv.fs_unlink(mode.worktree .. "/a.lua"))
    assert(vim.uv.fs_symlink(dir .. "/a.lua", mode.worktree .. "/a.lua"))
    local ok = pcall(vim.cmd, "write!")
    assert(not ok, "BufWritePre must refuse newly introduced Review symlink")
    h.assert_eq(data(dir, "a.lua"), source)
    mr.off()
end

function M.test_ignored_whitespace_paths_are_preserved_byte_for_byte()
    mr.off()
    vim.cmd("silent! %bwipeout!")
    mr.config.commit_mode.link = {}
    local dir = vim.uv.fs_realpath(h.repo({ ["a.lua"] = "v0\n", [".gitignore"] = " b/\n" }))
    git({ "branch", "-M", "main" }, dir)
    git({ "checkout", "-qb", "feature" }, dir)
    h.commit(dir, { ["a.lua"] = "v1\n" })
    h.commit(dir, { [" a"] = "first sorted path\n", [" b"] = "tracked file\n" })
    vim.cmd("edit! " .. vim.fn.fnameescape(dir .. "/a.lua"))
    local mode = enter_first(dir)
    h.write(mode.worktree, " b/keep", "ignored whitespace artifact\n")
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "unsaved" })
    mr.step_commit(1)
    h.assert_eq(mode.index, 1, "ignored whitespace collision must block")
    h.assert_eq(mode.ws.data.phase, "ready")
    h.assert_eq(data(mode.worktree, " b/keep"), "ignored whitespace artifact")
    h.assert_eq(vim.api.nvim_buf_get_lines(b, 0, -1, false), { "unsaved" })
    mr.off()
end

local function unchanged_file_fixture()
    local dir = fixture()
    git({ "reset", "--hard", "HEAD~1" }, dir)
    h.commit(dir, { ["other.lua"] = "next commit leaves a.lua unchanged\n" })
    return dir
end

function M.test_skip_worktree_and_assume_unchanged_refuse_before_discard()
    for _, flag in ipairs({ "--skip-worktree", "--assume-unchanged" }) do
        local dir = unchanged_file_fixture()
        local mode = enter_first(dir)
        git({ "update-index", flag, "a.lua" }, mode.worktree)
        h.write(mode.worktree, "a.lua", "EXPERIMENT\n")
        mr.step_commit(1)
        h.assert_eq(mode.index, 1, "hidden-index state needs manual handling, not false success")
        h.assert_eq(data(mode.worktree, "a.lua"), "EXPERIMENT")
        h.assert_eq(mode.ws.data.phase, "ready")
        mr.off()
    end
end

function M.test_persistent_undo_cannot_resurrect_previous_N_experiment()
    local dir = unchanged_file_fixture()
    local old_undo, old_dir = vim.o.undofile, vim.o.undodir
    local undo_dir = vim.fn.tempname()
    vim.fn.mkdir(undo_dir, "p")
    vim.o.undodir = undo_dir
    vim.o.undofile = true
    local ok, err = pcall(function()
        local mode = enter_first(dir)
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "OLD EXPERIMENT" })
        vim.cmd("write")
        vim.cmd("undo")
        vim.cmd("write")
        mr.step_commit(1)
        h.assert_eq(mode.index, 2)
        vim.cmd("silent! redo")
        h.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "v1" }, "old persistent undo must not load on new N")
        -- Wipe/reopen later at N must not reimport an older undofile either.
        vim.cmd("bwipeout!")
        vim.cmd("edit " .. vim.fn.fnameescape(mode.worktree .. "/a.lua"))
        vim.cmd("silent! redo")
        h.assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "v1" })
        mr.off()
    end)
    vim.o.undofile, vim.o.undodir = old_undo, old_dir
    assert(ok, err)
end

function M.test_head_picker_formats_search_and_cancel()
    local dir = fixture()
    local mode = enter_first(dir)
    h.write(mode.worktree, "a.lua", "keep until actual selection\n")
    local previous, captured = Snacks
    Snacks = { picker = {
        pick = function(opts)
            captured = opts
        end,
    } }
    mr.set_head()
    Snacks = previous
    assert(vim.tbl_contains(
        vim.tbl_map(function(i)
            return i.rev
        end, captured.items),
        mode.range.R
    ))
    -- Cancel/empty confirm must not mutate state.
    captured.confirm({
        filter = function()
            return { search = "" }
        end,
        close = function() end,
    }, nil)
    h.assert_eq(data(mode.worktree, "a.lua"), "keep until actual selection")
    captured.confirm({
        filter = function()
            return { search = "HEAD~1" }
        end,
        close = function() end,
    }, nil)
    h.assert_eq(mr._commit_mode().range.R, git({ "rev-parse", "HEAD~1" }, dir))
    -- Assert rendered text, not just items: the file formatter leaves text-only rows blank.
    local function wait_for_visible_item(picker)
        assert(
            vim.wait(2000, function()
                local item, buf = picker:current(), picker.list.win.buf
                if not item or not buf or not vim.api.nvim_buf_is_valid(buf) then
                    return false
                end
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                return table.concat(lines, "\n"):find(item.text, 1, true) ~= nil
            end, 20),
            "picker has items but does not render their text"
        )
    end
    mr.set_head()
    local picker = Snacks.picker.get({ source = "incognito_head" })[1]
    assert(picker)
    wait_for_visible_item(picker)
    picker:close()
    mr.range()
    picker = Snacks.picker.get({ source = "incognito_range" })[1]
    assert(picker)
    wait_for_visible_item(picker)
    picker:close()
    mr.off()
end

function M.test_ambiguous_commit_prefix_requires_explicit_choice()
    local dir = fixture()
    local mode = enter_first(dir)
    h.write(mode.worktree, "a.lua", "keep ambiguous\n")
    local tree = git({ "rev-parse", "HEAD^{tree}" }, dir)
    local prefixes, ambiguous, chosen = {}
    for i = 1, 2000 do
        local sha, err = mr.git(
            { "-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", tree, "-p", "HEAD" },
            dir,
            "collision fixture " .. i .. "\n"
        )
        assert(sha, err)
        local short = sha:sub(1, 4)
        if prefixes[short] then
            ambiguous, chosen = short, sha
            break
        end
        prefixes[short] = sha
    end
    assert(ambiguous, "fixture did not produce a commit-prefix collision")
    assert(not mr.change_head(ambiguous))
    h.assert_eq(data(mode.worktree, "a.lua"), "keep ambiguous")
    h.assert_eq(mr._commit_mode().selected, mode.selected)
    assert(mr.change_head(chosen), "explicit SHA outside ref/range is allowed")
    h.assert_eq(mr._commit_mode().range.R, chosen)
    mr.off()
end

function M.test_plugin_owned_checkout_does_not_run_repository_hooks()
    local dir = fixture()
    local sentinel = dir .. "/hook-ran"
    local script =
        h.write(dir, ".git/hooks/post-checkout", "#!/bin/sh\nprintf changed > " .. vim.fn.shellescape(sentinel) .. "\n")
    assert(vim.uv.fs_chmod(script, 493))
    local mode = enter_first(dir)
    mr.step_commit(1)
    assert(not vim.uv.fs_lstat(sentinel), "plugin checkout hooks must not mutate Source")
    h.assert_eq(data(mode.worktree, "a.lua"), "v2")
    mr.off()
end

function M.test_NUL_path_lists_preserve_CRLF_in_filenames()
    local dir = fixture()
    local name = " a\r\nb "
    h.write(dir, name, "x\n")
    local expected = name .. "\0"
    h.assert_eq(mr.git({ "ls-files", "--others", "--exclude-standard", "-z" }, dir), expected)
    h.assert_eq(wsmod.git({ "ls-files", "--others", "--exclude-standard", "-z" }, dir), expected)
end

return M
