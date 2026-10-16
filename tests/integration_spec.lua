-- Runs with the full config: real gitsigns, Snacks and the keymaps.
local h = require("tests.helpers")
local mr = require("incognito.review")
local sd = require("incognito.structdiff")
local gs_config = require("gitsigns.config").config

local M = {}

local BASE = "local function f(a, b)\n    return a + b\nend\nprint(f(1, 2))\n"
local REFLOWED = "local function f(\n    a,\n    b\n)\n    return a + b\nend\nprint(f(1, 3))\n"

local function gitsigns_signs(bufnr)
    local ns = vim.api.nvim_create_namespace("gitsigns_signs_")
    return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

--- Open the sample file and wait until gitsigns has attached and drawn.
local function open_sample()
    -- Wipe the previous repo's buffers first: gitsigns changes the base
    -- asynchronously across every attached buffer.
    vim.cmd("silent! %bwipeout!")
    mr.off()
    local dir = h.repo({ ["a.lua"] = BASE })
    h.write(dir, "a.lua", REFLOWED)
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(dir, "a.lua")))
    local bufnr = vim.api.nvim_get_current_buf()
    assert(
        vim.wait(5000, function()
            return vim.b[bufnr].gitsigns_head ~= nil and gitsigns_signs(bufnr) > 0
        end, 50),
        "gitsigns did not attach"
    )
    return bufnr
end

local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    vim.wait(200)
end

function M.test_gm_keeps_gitsigns_signs_and_linehl()
    local bufnr = open_sample()
    mr.on("HEAD")
    vim.wait(500)

    h.assert_eq(gs_config.linehl, true)
    h.assert_eq(gs_config.signcolumn, true)
    h.assert_eq(gitsigns_signs(bufnr) > 0, true, "gitsigns still draws")
    h.assert_eq(sd.active(), false)
    h.assert_eq(h.marks(bufnr), {})
end

function M.test_gd_silences_gitsigns_and_draws_structdiff()
    local bufnr = open_sample()
    mr.on_structural("HEAD")
    h.wait_run(bufnr)
    assert(
        vim.wait(2000, function()
            return gitsigns_signs(bufnr) == 0
        end, 50),
        "gitsigns signs should be gone"
    )

    h.assert_eq(gs_config.linehl, false)
    h.assert_eq(gs_config.signcolumn, false)
    h.assert_eq(sd.active(), true)
    local signs = h.marks(bufnr)
    h.assert_eq(signs[7], "Change", "the real change is bright")
    h.assert_eq(signs[1], "Format", "the reflow is dim")
end

function M.test_gM_restores_gitsigns_after_either_mode()
    local bufnr = open_sample()
    mr.on("HEAD")
    mr.on_structural("HEAD")
    h.wait_run(bufnr)
    mr.off()
    assert(
        vim.wait(2000, function()
            return gitsigns_signs(bufnr) > 0
        end, 50),
        "gitsigns signs should be back"
    )

    h.assert_eq(gs_config.linehl, false)
    h.assert_eq(gs_config.signcolumn, true)
    h.assert_eq(sd.active(), false)
    h.assert_eq(h.marks(bufnr), {})
end

-- From an untouched line, [g lands on the reflow hunk under gitsigns but
-- wraps to the only semantic change under structdiff.
function M.test_bracket_g_follows_the_active_mode()
    local bufnr = open_sample()
    mr.on("HEAD")
    vim.wait(500)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    press("[g")
    -- Exact hunk start depends on gitsigns diff_opts; it must stay in the reflow.
    h.assert_eq(vim.api.nvim_win_get_cursor(0)[1] < 5, true, "gitsigns: previous hunk is the reflow")

    mr.on_structural("HEAD")
    h.wait_run(bufnr)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    press("[g")
    h.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 7, "structdiff: wraps to the real change")
end

function M.test_user_command_lists_subcommands()
    h.assert_eq(vim.fn.exists(":Incognito"), 2, ":Incognito is defined")
    local completions = vim.fn.getcompletion("Incognito ", "cmdline")
    h.assert_eq(vim.tbl_contains(completions, "structural"), true, "subcommands complete")
end

return M
