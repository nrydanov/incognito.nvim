local M = {}

local KNOWN_DIFFT = { ["0.70"] = true, ["0.71"] = true }

local function check_difft_json(cmd)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local a, b = vim.fs.joinpath(dir, "a.lua"), vim.fs.joinpath(dir, "b.lua")
    vim.fn.writefile({ "local x = 1" }, a)
    vim.fn.writefile({ "local x = 2" }, b)
    local ok, res = pcall(function()
        return vim.system({ cmd, "--display=json", "--color=never", a, b },
            { text = true, env = { DFT_UNSTABLE = "yes" } }):wait(5000)
    end)
    vim.fn.delete(dir, "rf")
    if not ok then
        return vim.health.error("difft JSON run failed: " .. tostring(res))
    end
    local decoded_ok, decoded = pcall(vim.json.decode, res.stdout or "")
    if decoded_ok and type(decoded) == "table" and decoded.chunks then
        vim.health.ok("difft --display=json returns chunks")
    else
        vim.health.error("difft --display=json output has no chunks (DFT_UNSTABLE=yes is required)",
            { vim.trim(res.stderr or ""), (res.stdout or ""):sub(1, 200) })
    end
end

function M.check()
    vim.health.start("incognito")
    if vim.fn.has("nvim-0.11") == 1 then
        vim.health.ok("Neovim " .. tostring(vim.version()))
    else
        vim.health.error("Neovim >= 0.11 required")
    end

    if pcall(require, "gitsigns") then
        vim.health.ok("gitsigns.nvim found")
    else
        vim.health.error("gitsigns.nvim not found")
    end
    if pcall(require, "snacks") then
        vim.health.ok("snacks.nvim found")
    else
        vim.health.warn("snacks.nvim not found: files and commits pickers are unavailable")
    end

    vim.health.start("incognito: difftastic (structural mode)")
    local cmd = require("incognito").config.difft.cmd
    if vim.fn.executable(cmd) ~= 1 then
        return vim.health.error(cmd .. " not found in PATH")
    end
    local out = vim.system({ cmd, "--version" }, { text = true }):wait(5000).stdout or ""
    local version = out:match("Difftastic (%d+%.%d+[%.%d]*)")
    if not version then
        vim.health.warn("could not parse `" .. cmd .. " --version`: " .. vim.trim(out))
    elseif KNOWN_DIFFT[version:match("^%d+%.%d+")] then
        vim.health.ok("difft " .. version)
    else
        vim.health.warn("difft " .. version .. " is untested (known good: 0.70, 0.71); the JSON format is unstable")
    end
    check_difft_json(cmd)
end

return M
