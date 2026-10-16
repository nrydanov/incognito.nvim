-- Self-contained init for the test harness:
--   nvim --headless --clean -u tests/minimal_init.lua -l tests/run.lua
-- Dependencies are looked up in $MRVIEW_DEPS (default: lazy.nvim's install dir).
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
local deps = vim.env.MRVIEW_DEPS or vim.fs.joinpath(vim.fn.stdpath("data"), "lazy")

vim.opt.rtp:prepend(root)
-- `require("tests.helpers")` resolves against the plugin root from any cwd.
package.path = root .. "/?.lua;" .. package.path

for _, name in ipairs({ "gitsigns.nvim", "snacks.nvim", "nvim-treesitter" }) do
    local dir = vim.fs.joinpath(deps, name)
    if vim.uv.fs_stat(dir) then
        vim.opt.rtp:append(dir)
    end
end
-- Parsers installed by nvim-treesitter (main branch) live in site/, which --clean drops.
local site = vim.fs.joinpath(vim.fn.stdpath("data"), "site")
if vim.uv.fs_stat(vim.fs.joinpath(site, "parser")) then
    vim.opt.rtp:append(site)
end

vim.o.swapfile = false
vim.o.shadafile = "NONE"

local ok_gs, gitsigns = pcall(require, "gitsigns")
if ok_gs then
    gitsigns.setup({
        linehl = false,
        on_attach = function(bufnr)
            -- Same routing as the README recipe; integration specs press ]g/[g.
            local function nav(dir)
                local sd = require("mrview.structdiff")
                if sd.active() then sd.nav(dir) else gitsigns.nav_hunk(dir) end
            end
            for key, dir in pairs({ ["]g"] = "next", ["[g"] = "prev" }) do
                vim.keymap.set("n", key, function() nav(dir) end, { buffer = bufnr })
            end
        end,
    })
end

local ok_snacks, snacks = pcall(require, "snacks")
if ok_snacks then
    _G.Snacks = snacks
end
