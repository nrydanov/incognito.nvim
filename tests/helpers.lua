local M = {}

function M.assert_eq(actual, expected, message)
    if not vim.deep_equal(actual, expected) then
        error(
            (message or "assert_eq failed")
                .. "\nexpected: "
                .. vim.inspect(expected)
                .. "\nactual: "
                .. vim.inspect(actual),
            2
        )
    end
end

local function sh(args, cwd)
    local res = vim.system(args, { cwd = cwd, text = true }):wait()
    assert(res.code == 0, table.concat(args, " ") .. " failed: " .. (res.stderr or ""))
    return res.stdout
end

--- Fresh git repo with `files` (name -> text) committed as HEAD.
function M.repo(files)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    sh({ "git", "init", "-q" }, dir)
    for name, text in pairs(files) do
        M.write(dir, name, text)
    end
    sh({ "git", "add", "-A" }, dir)
    sh({ "git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init", "--allow-empty" }, dir)
    return dir
end

function M.write(dir, name, text)
    local path = vim.fs.joinpath(dir, name)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local lines = vim.split(text, "\n")
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    vim.fn.writefile(lines, path)
    return path
end

--- Open `name` from `dir`, enable structdiff against HEAD and wait for marks.
function M.open(dir, name)
    local sd = require("incognito.structdiff")
    sd.disable()
    sd.toggle_deleted(false) -- every test starts from the default
    vim.cmd("edit! " .. vim.fn.fnameescape(vim.fs.joinpath(dir, name)))
    local bufnr = vim.api.nvim_get_current_buf()
    sd.enable("HEAD")
    M.wait_run(bufnr)
    return bufnr
end

function M.wait_run(bufnr)
    local sd = require("incognito.structdiff")
    local before = sd._generation(bufnr)
    assert(
        vim.wait(3000, function()
            return sd._generation(bufnr) > before
        end, 20),
        "difft run did not finish"
    )
end

--- Signs by line: { [lnum] = "Add" | "Change" | "Delete" | "Format" }, inline
--- ranges, and virtual (deleted) lines as { [lnum] = { above = bool, text = {...} } }.
function M.marks(bufnr)
    local ns = vim.api.nvim_create_namespace("structdiff")
    local signs, inline, virt = {}, {}, {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        local d = m[4]
        if d.sign_text then
            signs[m[2] + 1] = d.sign_hl_group:gsub("^GitSigns", ""):gsub("^StructDiff", "")
        elseif d.virt_lines then
            local text = {}
            for _, line in ipairs(d.virt_lines) do
                local parts = {}
                for _, seg in ipairs(line) do
                    parts[#parts + 1] = seg[1]
                end
                text[#text + 1] = table.concat(parts)
            end
            virt[m[2] + 1] = { above = d.virt_lines_above or false, text = text }
        elseif d.hl_group then
            inline[#inline + 1] = { m[2] + 1, m[3], d.end_col }
        end
    end
    return signs, inline, virt
end

return M
