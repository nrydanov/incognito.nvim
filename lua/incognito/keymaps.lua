local M = {}
local owned = {}

local defaults = {
    { "o", "on", "Review on" },
    { "s", "structural", "Structural review" },
    { "q", "off", "Review off" },
    { "b", "change_base", "Choose base" },
    { "h", "change_head", "Choose head" },
    { "f", "files", "Changed files" },
    { "c", "commits", "Commits" },
    { "r", "range", "Clean range diff" },
    { "n", "next_commit", "Next commit" },
    { "p", "prev_commit", "Previous commit" },
    { "t", "toggle_tip", "Switch Review / Source" },
    { "v", "toggle_reviewed", "Toggle reviewed" },
    { "V", "since_review", "Changes since review" },
    { "d", "toggle_deleted", "Toggle deleted lines" },
    { "w", "toggle_split", "Toggle diff window" },
}

function M.setup(config)
    -- A later setup may change the prefix or disable defaults; keep user replacements.
    for _, map in ipairs(vim.api.nvim_get_keymap("n")) do
        if owned[map.callback] then
            vim.keymap.del("n", map.lhs)
        end
    end
    owned = {}
    if config == false then
        return
    end
    local prefix = config.prefix or "<leader>i"
    for _, mapping in ipairs(defaults) do
        local lhs, action, desc = prefix .. mapping[1], mapping[2], mapping[3]
        if vim.fn.maparg(lhs, "n") == "" then
            local callback = function()
                require("incognito")[action]()
            end
            vim.keymap.set("n", lhs, callback, { silent = true, desc = "Incognito: " .. desc })
            owned[callback] = true
        end
    end
end

return M
