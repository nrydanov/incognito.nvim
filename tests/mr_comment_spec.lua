local h = require("tests.helpers")

local mc = require("mrview.comments")
local review = require("mrview.review")

local M = {}

local function signs(bufnr)
    local ns = vim.api.nvim_create_namespace("mr_comment")
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})) do
        out[#out + 1] = m[2] + 1
    end
    return out
end

local function open(dir, name)
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(dir, name)))
    return vim.api.nvim_get_current_buf()
end

-- Buffer names come back through realpath (/var -> /private/var on macOS),
-- and the root must match them for rel_path to work.
local function repo(files)
    return vim.fn.resolve(h.repo(files))
end

function M.test_add_queues_cursor_line_and_marks_it()
    local dir = repo({ ["a.lua"] = "local a = 1\nlocal b = 2\nlocal c = 3\n" })
    local bufnr = open(dir, "a.lua")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    mc.add()
    local compose = vim.api.nvim_get_current_buf()
    h.assert_eq(vim.bo[compose].buftype, "acwrite")
    vim.api.nvim_buf_set_lines(compose, 1, -1, false, { "why?", "", "explain" })
    vim.cmd("write")

    h.assert_eq(vim.api.nvim_get_current_buf(), bufnr, "split closes after :w")
    local head = vim.trim(review.git({ "rev-parse", "HEAD" }, dir))
    h.assert_eq(mc.list(dir), {
        { path = "a.lua", start_line = 2, line = 2, body = "why?\n\nexplain", head = head },
    })
    h.assert_eq(signs(bufnr), { 2 })
end

function M.test_empty_body_is_not_queued()
    local dir = repo({ ["a.lua"] = "local a = 1\n" })
    open(dir, "a.lua")
    mc.add()
    local compose = vim.api.nvim_get_current_buf()
    vim.cmd("write")
    h.assert_eq(vim.api.nvim_get_current_buf(), compose, "split stays open")
    h.assert_eq(mc.list(dir), {})
    vim.api.nvim_buf_delete(compose, { force = true })
end

function M.test_remove_updates_signs_and_survives_reload()
    local dir = repo({ ["a.lua"] = "local a = 1\nlocal b = 2\n" })
    local bufnr = open(dir, "a.lua")
    mc.queue(dir, { path = "a.lua", start_line = 1, line = 2, body = "x", head = "h" })
    mc.queue(dir, { path = "a.lua", start_line = 2, line = 2, body = "y", head = "h" })
    h.assert_eq(signs(bufnr), { 2, 2 })

    mc.remove(dir, 1)
    h.assert_eq(#mc.list(dir), 1)
    h.assert_eq(signs(bufnr), { 2 })

    vim.cmd("bwipeout!")
    bufnr = open(dir, "a.lua")
    h.assert_eq(signs(bufnr), { 2 }, "BufWinEnter restores signs from the state file")
end

return M
