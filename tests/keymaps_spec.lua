local h = require("tests.helpers")
local incognito = require("incognito")
local M = {}

local function mapping(lhs)
    return vim.fn.maparg(lhs, "n", false, true)
end

local function isolated(test)
    local config = vim.deepcopy(incognito.config)
    local leader, loaded = vim.g.mapleader, vim.g.loaded_incognito
    incognito.setup({ keymaps = false })
    vim.g.mapleader = " "
    local user_maps = {}
    local function user_map(lhs, callback, opts)
        user_maps[#user_maps + 1] = { lhs = lhs, buffer = opts and opts.buffer }
        vim.keymap.set("n", lhs, callback, opts)
    end
    local ok, err = xpcall(function()
        test(user_map)
    end, debug.traceback)
    incognito.setup({ keymaps = false })
    for _, map in ipairs(user_maps) do
        pcall(vim.keymap.del, "n", map.lhs, { buffer = map.buffer })
    end
    vim.g.mapleader, vim.g.loaded_incognito = leader, loaded
    incognito.config = config
    incognito.setup({})
    assert(ok, err)
end

function M.test_runtime_installs_defaults_without_setup()
    isolated(function()
        incognito.config.keymaps = { prefix = "<leader>i" }
        vim.g.loaded_incognito = nil
        vim.cmd("runtime plugin/incognito.lua")
        for _, suffix in ipairs({ "o", "s", "q", "b", "h", "f", "c", "r", "n", "p", "t", "v", "V", "d", "w" }) do
            local map = mapping(" i" .. suffix)
            assert(type(map.callback) == "function", "missing default: " .. suffix)
            assert(map.desc:find("Incognito: ", 1, true) == 1)
        end
    end)
end

function M.test_head_and_base_keys_dispatch_to_their_public_actions()
    isolated(function()
        incognito.setup({ keymaps = { prefix = "<leader>i" } })
        for _, entry in ipairs({ { "ih", "change_head" }, { "ib", "change_base" } }) do
            local original, called = incognito[entry[2]], false
            incognito[entry[2]] = function()
                called = true
            end
            local ok, err = pcall(mapping(" " .. entry[1]).callback)
            incognito[entry[2]] = original
            assert(ok, err)
            assert(called, entry[1] .. " must call " .. entry[2])
        end
    end)
end

function M.test_defaults_keep_existing_global_and_buffer_mappings()
    isolated(function(user_map)
        local global, buffer = function() end, function() end
        user_map("<leader>ih", global)
        user_map("<leader>ib", buffer, { buffer = 0 })
        user_map("<Space>", "<Nop>")
        incognito.setup({ keymaps = { prefix = "<leader>i" } })
        h.assert_eq(mapping(" ih").callback, global)
        h.assert_eq(mapping(" ib").callback, buffer)
        assert(type(mapping(" if").callback) == "function", "a leader Nop must not block defaults")
        incognito.setup({ keymaps = false })
        h.assert_eq(mapping(" ih").callback, global)
        h.assert_eq(mapping(" ib").callback, buffer)
        assert(vim.tbl_isempty(mapping(" if")))
    end)
end

function M.test_prefix_change_and_disable_keep_user_replacements()
    isolated(function(user_map)
        incognito.setup({ keymaps = { prefix = "<leader>i" } })
        local custom = function() end
        user_map("<leader>ih", custom)
        incognito.setup({ keymaps = { prefix = "<leader>m" } })
        h.assert_eq(mapping(" ih").callback, custom)
        assert(vim.tbl_isempty(mapping(" ib")))
        assert(type(mapping(" mh").callback) == "function")
        incognito.setup({})
        assert(type(mapping(" mh").callback) == "function", "repeated setup retains defaults")
        incognito.setup({ keymaps = false })
        assert(vim.tbl_isempty(mapping(" mh")))
        h.assert_eq(mapping(" ih").callback, custom)
    end)
end

function M.test_changing_leader_removes_old_owned_keys_even_when_shadowed()
    isolated(function(user_map)
        incognito.setup({ keymaps = { prefix = "<leader>i" } })
        local custom = function() end
        user_map(" ih", custom, { buffer = 0 })
        vim.g.mapleader = ","
        incognito.setup({})
        h.assert_eq(mapping(" ih").callback, custom)
        assert(type(mapping(",ih").callback) == "function")
        for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
            assert(map.desc ~= "Incognito: Choose head" or map.lhs == ",ih", "old global mapping survived")
        end
    end)
end

function M.test_disabled_defaults_stay_disabled_when_runtime_loads()
    isolated(function()
        incognito.setup({ keymaps = false })
        vim.g.loaded_incognito = nil
        vim.cmd("runtime plugin/incognito.lua")
        assert(vim.tbl_isempty(mapping(" ih")))
        assert(vim.tbl_isempty(mapping(" ib")))
    end)
end

return M
