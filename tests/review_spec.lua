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

return M
