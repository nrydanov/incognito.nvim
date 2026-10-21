local M = {}

M.config = {
    remote = "origin",
    targets = { "main", "master" },
    commit_mode = {
        link = { "node_modules" },
        lockfiles = {
            "package-lock.json",
            "npm-shrinkwrap.json",
            "pnpm-lock.yaml",
            "yarn.lock",
            "bun.lock",
            "bun.lockb",
        },
    },
    difft = { cmd = "difft", debounce_ms = 300 },
}

-- Modules load on first use, so this file works before they exist and without setup().
local function mod(name)
    return function()
        return require("incognito." .. name)
    end
end
local review, structdiff = mod("review"), mod("structdiff")

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.config, opts or {})
    local c = M.config
    local push = {
        review = { remote = c.remote, targets = c.targets, commit_mode = c.commit_mode },
        structdiff = { difft_cmd = c.difft.cmd, debounce_ms = c.difft.debounce_ms },
    }
    for name, fields in pairs(push) do
        local ok, m = pcall(require, "incognito." .. name)
        if ok and type(m.config) == "table" then
            for k, v in pairs(fields) do
                m.config[k] = v
            end
        end
    end
end

function M.on(target)
    review().on(target)
end
function M.structural(target)
    review().on_structural(target)
end
function M.off()
    review().off()
end
function M.base()
    review().set_base()
end
function M.files(target)
    review().files(target)
end
function M.commits()
    review().commits()
end
function M.next_commit()
    review().step_commit(1)
end
function M.prev_commit()
    review().step_commit(-1)
end
function M.toggle_tip()
    review().toggle_tip()
end
function M.toggle_reviewed(target)
    review().toggle_reviewed(target)
end
function M.since_review(target)
    review().since_review(target)
end
function M.nav(dir)
    structdiff().nav(dir)
end
function M.toggle_deleted(value)
    structdiff().toggle_deleted(value)
end
function M.toggle_split(value)
    structdiff().toggle_split(value)
end

return M
