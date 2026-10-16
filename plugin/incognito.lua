if vim.g.loaded_incognito then
    return
end
vim.g.loaded_incognito = true

-- Each handler gets the optional argument after the subcommand.
local subcommands = {
    on = function(arg)
        require("incognito").on(arg)
    end,
    structural = function(arg)
        require("incognito").structural(arg)
    end,
    off = function()
        require("incognito").off()
    end,
    base = function()
        require("incognito").base()
    end,
    files = function(arg)
        require("incognito").files(arg)
    end,
    commits = function()
        require("incognito").commits()
    end,
    next = function()
        require("incognito").next_commit()
    end,
    prev = function()
        require("incognito").prev_commit()
    end,
    reviewed = function(arg)
        require("incognito").toggle_reviewed(arg)
    end,
    since = function(arg)
        require("incognito").since_review(arg)
    end,
    deleted = function()
        require("incognito").toggle_deleted()
    end,
    split = function()
        require("incognito").toggle_split()
    end,
}

vim.api.nvim_create_user_command("Incognito", function(opts)
    local handler = subcommands[opts.fargs[1]]
    if not handler then
        return vim.notify("Incognito: unknown subcommand " .. (opts.fargs[1] or ""), vim.log.levels.ERROR)
    end
    handler(opts.fargs[2], opts)
end, {
    nargs = "+",
    desc = "Incognito: MR review",
    complete = function(lead, line)
        if #vim.split(line, "%s+", { trimempty = false }) > 2 then
            return {}
        end
        local names = vim.tbl_keys(subcommands)
        table.sort(names)
        return vim.tbl_filter(function(name)
            return vim.startswith(name, lead)
        end, names)
    end,
})
