local h = require("tests.helpers")
local review = require("mrview.review")

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
    h.assert_eq(vim.uv.fs_stat(vim.fs.joinpath(dir, ".git", "mr-review.json")) ~= nil, true,
        "state lives in the git dir")

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

function M.test_migrate_imports_old_state_file()
    local dir = open_repo()
    local head = review.git({ "rev-parse", "HEAD" }, dir)
    local old = vim.fs.joinpath(vim.fn.stdpath("state"), "mr-review", (dir:gsub("[^%w]", "_")) .. ".json")
    vim.fn.mkdir(vim.fs.dirname(old), "p")
    vim.fn.writefile({ vim.json.encode({
        [".base"] = "main",
        HEAD = { ["a.lua"] = head, ["gone.lua"] = head },
        [".comments"] = { { path = "a.lua", start_line = 1, line = 1, body = "hi", head = head } },
    }) }, old)

    review.migrate(dir)
    local state = review.load_state(dir)
    h.assert_eq(state[".base"], "main")
    h.assert_eq(state.HEAD["a.lua"].head, head)
    h.assert_eq(status(dir), "✓", "an untouched file stays current after migration")
    h.assert_eq(state.HEAD["gone.lua"].blob, nil, "a file missing at the commit has no blob")
    h.assert_eq(#state[".comments"], 1)
    h.assert_eq(vim.uv.fs_stat(old), nil, "old file renamed")
    h.assert_eq(vim.uv.fs_stat(old .. ".migrated") ~= nil, true)
    vim.fn.delete(old .. ".migrated")
end

return M
