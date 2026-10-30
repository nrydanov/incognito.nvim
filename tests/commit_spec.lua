-- Commit mode reviews in a worktree of its own; the user's checkout stays put.
local h = require("tests.helpers")
local mr = require("incognito.review")

local M = {}

local function git(args, cwd)
    local out, err = mr.git(args, cwd)
    assert(out, table.concat(args, " ") .. " failed: " .. (err or ""))
    return out
end

local function commit(dir, name, text, message)
    h.write(dir, name, text)
    git({ "add", "-A" }, dir)
    git({ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", message }, dir)
end

-- main: a.lua = v0; feature: two commits on top. Resolved so the root
-- matches buffer names (/var -> /private/var on macOS).
local function feature_repo()
    vim.cmd("silent! %bwipeout!")
    mr.off()
    local dir = vim.fn.resolve(h.repo({ ["a.lua"] = "v0\n" }))
    git({ "branch", "-M", "main" }, dir)
    git({ "checkout", "-qb", "feature" }, dir)
    commit(dir, "a.lua", "v1\n", "one")
    commit(dir, "a.lua", "v2\n", "two")
    return dir
end

local function lines(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false)
end

local function worktrees(dir)
    return #vim.split(git({ "worktree", "list", "--porcelain" }, dir), "\n\n", { trimempty = true })
end

local function enter(dir)
    local commits = mr._mr_commits(dir)
    h.assert_eq(#commits, 2)
    mr._enter_commit_mode(dir, commits, 1)
    return assert(mr._commit_mode(), "commit mode is on").worktree
end

function M.test_commit_mode_leaves_the_checkout_alone()
    local dir = feature_repo()
    -- Neither uncommitted nor unsaved changes stop commit mode now.
    h.write(dir, "a.lua", "dirty\n")
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(dir, "a.lua")))
    local user_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "unsaved" })

    local worktree = enter(dir)
    h.assert_eq(vim.api.nvim_buf_get_name(0), vim.fs.joinpath(worktree, "a.lua"), "window shows the commit")
    h.assert_eq(lines(), { "v1" })
    h.assert_eq(vim.fs.relpath(dir, worktree), nil, "worktree is outside the repository")

    mr.step_commit(1)
    h.assert_eq(lines(), { "v2" }, "stepping checks out the next commit in the worktree")

    h.assert_eq(git({ "symbolic-ref", "HEAD" }, dir), "refs/heads/feature", "HEAD stays on the branch")
    h.assert_eq(vim.fn.readfile(vim.fs.joinpath(dir, "a.lua")), { "dirty" }, "working tree untouched")
    h.assert_eq(lines(user_buf), { "unsaved" }, "user buffer untouched")

    -- From a buffer of the checkout, the review still means the commit.
    vim.api.nvim_set_current_buf(user_buf)
    local notify, messages = vim.notify, {}
    vim.notify = function(msg)
        messages[#messages + 1] = msg
    end
    mr.on()
    vim.notify = notify
    h.assert_eq(messages, { "Incognito: diffing against the commit parent" })

    mr.off()
    h.assert_eq(mr._commit_mode(), nil)
    h.assert_eq(vim.api.nvim_get_current_buf(), user_buf, "window is back on the user's file")
    h.assert_eq(lines(user_buf), { "unsaved" })
    h.assert_eq(vim.uv.fs_stat(worktree), nil, "worktree removed")
    h.assert_eq(worktrees(dir), 1, "worktree unregistered")
end

function M.test_worktree_of_a_dead_session_is_removed()
    local dir = feature_repo()
    local prefix = enter(dir):gsub("%d+$", "")
    mr.off()

    -- A pid that just exited stands for a session that died in commit mode.
    local proc = vim.system({ "true" })
    proc:wait()
    local stale = prefix .. proc.pid
    git({ "worktree", "add", "--quiet", "--detach", stale, "HEAD" }, dir)

    enter(dir)
    h.assert_eq(vim.uv.fs_stat(stale), nil, "stale worktree removed")
    h.assert_eq(worktrees(dir), 2, "only the user's checkout and the live worktree")
    mr.off()
end

function M.test_worktree_with_inaccessible_live_pid_is_kept()
    local dir = feature_repo()
    local prefix = enter(dir):gsub("%d+$", "")
    mr.off()

    local proc = vim.system({ "true" })
    proc:wait()
    local other = prefix .. proc.pid
    git({ "worktree", "add", "--quiet", "--detach", other, "HEAD" }, dir)

    local kill = vim.uv.kill
    vim.uv.kill = function(pid, signal)
        if pid == proc.pid and signal == 0 then
            return nil, "EPERM: operation not permitted", "EPERM"
        end
        return kill(pid, signal)
    end
    local ok, err = pcall(enter, dir)
    vim.uv.kill = kill
    assert(ok, err)
    assert(vim.uv.fs_stat(other), "an inaccessible process may still be alive")
    mr.off()
    git({ "worktree", "remove", "--force", other }, dir)
end

function M.test_off_moves_window_when_commit_file_is_missing_from_checkout()
    local dir = feature_repo()
    commit(dir, "temporary.lua", "here\n", "add temporary file")
    git({ "rm", "-q", "temporary.lua" }, dir)
    git({ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "remove temporary file" }, dir)
    local commits = mr._mr_commits(dir)
    mr._enter_commit_mode(dir, commits, 3)
    local worktree = mr._commit_mode().worktree
    vim.cmd("edit " .. vim.fn.fnameescape(vim.fs.joinpath(worktree, "temporary.lua")))

    mr.off()
    h.assert_eq(vim.api.nvim_buf_get_name(0), "", "window falls back to an empty buffer")
    h.assert_eq(lines(), { "" })
    h.assert_eq(vim.uv.fs_stat(worktree), nil, "worktree removed")
end

function M.test_commit_buffers_with_unsaved_edits_block_stepping()
    local dir = feature_repo()
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(dir, "a.lua")))
    enter(dir)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited" })

    mr.step_commit(1)
    h.assert_eq(mr._commit_mode().index, 1, "stays on the commit")
    h.assert_eq(lines(), { "edited" })
    mr.off()
end

local function capture_notify(fn)
    local notify, messages = vim.notify, {}
    vim.notify = function(msg, level)
        messages[#messages + 1] = { msg = msg, level = level }
    end
    local ok, err = pcall(fn)
    vim.notify = notify
    assert(ok, err)
    return messages
end

local function warnings(messages)
    return vim.tbl_filter(function(m)
        return m.level == vim.log.levels.WARN
    end, messages)
end

function M.test_ignored_dependencies_are_linked_and_survive()
    local dir = feature_repo()
    h.write(dir, ".gitignore", "node_modules/\n")
    commit(dir, "packages/a/index.js", "x\n", "package")
    h.write(dir, "node_modules/dep/index.js", "dep\n")
    h.write(dir, "packages/a/node_modules/local/index.js", "local\n")

    local commits = mr._mr_commits(dir)
    mr._enter_commit_mode(dir, commits, 1)
    local worktree = mr._commit_mode().worktree
    -- Commit 1 has no packages/a to hold the nested link.
    h.assert_eq(mr._commit_mode().linked, { "node_modules" })
    h.assert_eq(vim.uv.fs_lstat(vim.fs.joinpath(worktree, "node_modules")).type, "link")
    h.assert_eq(vim.fn.readfile(vim.fs.joinpath(worktree, "node_modules/dep/index.js")), { "dep" })
    mr.off()

    mr._enter_commit_mode(dir, commits, #commits)
    h.assert_eq(mr._commit_mode().linked, { "node_modules", "packages/a/node_modules" }, "nested ones too")
    mr.off()
    h.assert_eq(vim.fn.readfile(vim.fs.joinpath(dir, "node_modules/dep/index.js")), { "dep" }, "real dir survives")
    h.assert_eq(vim.fn.readfile(vim.fs.joinpath(dir, "packages/a/node_modules/local/index.js")), { "local" })
end

function M.test_lockfile_drift_warns_while_dependencies_are_linked()
    local dir = feature_repo()
    commit(dir, ".gitignore", "node_modules/\n", "ignore")
    commit(dir, "package-lock.json", "{}\n", "lock")
    h.write(dir, "node_modules/dep/index.js", "dep\n")
    local commits = mr._mr_commits(dir)

    local messages = capture_notify(function()
        mr._enter_commit_mode(dir, commits, 1)
    end)
    local warns = warnings(messages)
    h.assert_eq(#warns, 1, "commit 1 predates the lockfile")
    assert(warns[1].msg:find("package-lock.json", 1, true), warns[1].msg)

    messages = capture_notify(function()
        mr.step_commit(#commits - 1)
    end)
    h.assert_eq(warnings(messages), {}, "the last commit has the checkout's lockfile")
    mr.off()
end

return M
