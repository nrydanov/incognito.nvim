local h = require("tests.helpers")
local review = require("incognito.review")

local M = {}

local function status(dir)
    return review._reviewed_status(dir, "HEAD", { "a.lua" })["a.lua"]
end

-- Resolved so the root matches buffer names (/var -> /private/var on macOS).
local function open_repo()
    local dir = vim.fn.resolve(h.repo({ ["a.lua"] = "local a = 1\n" }))
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(dir, "a.lua")))
    return dir
end

function M.test_mark_follows_file_content()
    local dir = open_repo()
    h.assert_eq(status(dir), " ")

    review.toggle_reviewed("HEAD")
    h.assert_eq(status(dir), "✓")
    h.assert_eq(
        vim.uv.fs_stat(vim.fs.joinpath(dir, ".git", "incognito.json")) ~= nil,
        true,
        "state lives in the git dir"
    )

    h.write(dir, "a.lua", "local a = 2\n")
    h.assert_eq(status(dir), "~", "uncommitted edit makes the mark stale")
    h.write(dir, "a.lua", "local a = 1\n")
    h.assert_eq(status(dir), "✓", "reverting the edit makes it current again")

    h.write(dir, "a.lua", "local a = 2\n")
    review.toggle_reviewed("HEAD")
    h.assert_eq(status(dir), "✓", "a stale mark is refreshed")
    review.toggle_reviewed("HEAD")
    h.assert_eq(status(dir), " ", "a current mark is taken back")
end

function M.test_old_sha_mark_is_unknown_until_remarked()
    local dir = open_repo()
    local head = review.git({ "rev-parse", "HEAD" }, dir)
    review.save_state(dir, { HEAD = { ["a.lua"] = head } })
    h.assert_eq(status(dir), "?")

    review.toggle_reviewed("HEAD")
    h.assert_eq(status(dir), "✓")
    h.assert_eq(review.load_state(dir).HEAD["a.lua"].head, head)
end

function M.test_commit_reviewed_requires_every_changed_file_at_its_committed_content()
    local dir = vim.fn.resolve(h.repo({ ["a.lua"] = "a\n", ["b.lua"] = "b\n" }))
    local sha = review.git({ "rev-parse", "HEAD" }, dir)
    local a = review.git({ "rev-parse", "HEAD:a.lua" }, dir)
    local b = review.git({ "rev-parse", "HEAD:b.lua" }, dir)
    local marks = { ["a.lua"] = { blob = a, head = sha } }
    h.assert_eq(review._commit_reviewed(dir, sha, marks), false)
    marks["b.lua"] = { blob = b, head = sha }
    h.assert_eq(review._commit_reviewed(dir, sha, marks), true)
    h.write(dir, "a.lua", "uncommitted edit\n")
    h.assert_eq(review._commit_reviewed(dir, sha, marks), true)
    marks["a.lua"].blob = b
    h.assert_eq(review._commit_reviewed(dir, sha, marks), false)
    marks["a.lua"] = sha
    h.assert_eq(review._commit_reviewed(dir, sha, marks), false, "legacy marks are unknown")
end

function M.test_commit_reviewed_handles_renames_and_deletions()
    local dir = vim.fn.resolve(h.repo({ ["old.lua"] = "a\n" }))
    local parent = review.git({ "rev-parse", "HEAD" }, dir)
    assert(review.git({ "mv", "old.lua", "new.lua" }, dir))
    h.commit(dir, {})
    local sha = review.git({ "rev-parse", "HEAD" }, dir)
    local blob = review.git({ "rev-parse", "HEAD:new.lua" }, dir)
    local marks = { ["new.lua"] = { blob = blob, head = sha } }
    h.assert_eq(review._commit_reviewed(dir, sha, marks), true, "renames use the destination mark")
    assert(review.git({ "rm", "new.lua" }, dir))
    h.commit(dir, {})
    sha = review.git({ "rev-parse", "HEAD" }, dir)
    marks = {}
    h.assert_eq(review._commit_reviewed(dir, sha, marks), false)
    marks["new.lua"] = { head = parent }
    h.assert_eq(review._commit_reviewed(dir, sha, marks), false)
    marks["new.lua"] = { head = sha }
    h.assert_eq(review._commit_reviewed(dir, sha, marks), true)
end

function M.test_commit_reviewed_empty_commit_is_unmarked()
    local dir = vim.fn.resolve(h.repo({ ["a.lua"] = "a\n" }))
    h.commit(dir, {})
    local sha = review.git({ "rev-parse", "HEAD" }, dir)
    h.assert_eq(review._commit_reviewed(dir, sha, {}), false)
end

function M.test_commits_picker_shows_derived_review_marks()
    local dir = open_repo()
    local base = review.git({ "rev-parse", "HEAD" }, dir)
    h.commit(dir, { ["a.lua"] = "changed\n" })
    local sha = review.git({ "rev-parse", "HEAD" }, dir)
    local blob = review.git({ "rev-parse", "HEAD:a.lua" }, dir)
    review.save_state(dir, { [".base"] = base, [base] = { ["a.lua"] = { blob = blob, head = sha } } })
    local previous, captured = Snacks
    Snacks = { picker = {
        pick = function(opts)
            captured = opts
        end,
    } }
    local ok, err = pcall(function()
        review.commits()
        h.assert_eq(captured.items[1].reviewed, true)
        h.assert_eq(captured.format(captured.items[1])[1][1], "✓ ")
        review.save_state(dir, { [".base"] = base })
        review.commits()
        h.assert_eq(captured.items[1].reviewed, false)
        h.assert_eq(captured.format(captured.items[1])[1][1], "  ")
    end)
    Snacks = previous
    assert(ok, err)
end

return M
