if vim.g.loaded_mrview then
    return
end
vim.g.loaded_mrview = true

-- Each handler gets the optional argument after the subcommand.
local subcommands = {
    on = function(arg) require("mrview").on(arg) end,
    structural = function(arg) require("mrview").structural(arg) end,
    off = function() require("mrview").off() end,
    base = function() require("mrview").base() end,
    files = function(arg) require("mrview").files(arg) end,
    commits = function() require("mrview").commits() end,
    next = function() require("mrview").next_commit() end,
    prev = function() require("mrview").prev_commit() end,
    reviewed = function(arg) require("mrview").toggle_reviewed(arg) end,
    since = function(arg) require("mrview").since_review(arg) end,
    deleted = function() require("mrview").toggle_deleted() end,
    split = function() require("mrview").toggle_split() end,
}

vim.api.nvim_create_user_command("MRView", function(opts)
    local handler = subcommands[opts.fargs[1]]
    if not handler then
        return vim.notify("MRView: unknown subcommand " .. (opts.fargs[1] or ""), vim.log.levels.ERROR)
    end
    handler(opts.fargs[2], opts)
end, {
    nargs = "+",
    desc = "MR review",
    complete = function(lead, line)
        if #vim.split(line, "%s+", { trimempty = false }) > 2 then
            return {}
        end
        local names = vim.tbl_keys(subcommands)
        table.sort(names)
        return vim.tbl_filter(function(name) return vim.startswith(name, lead) end, names)
    end,
})
