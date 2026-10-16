-- Review comments for the current MR, queued locally until submitted.
--
-- `add` opens a scratch split for one comment on the cursor line (or the
-- visual range); `:w` puts it in the queue, `:q` drops it. Queued lines get a
-- sign so a second pass over the file shows what is already covered. `pick`
-- lists the queue. Nothing talks to GitHub/GitLab here.

local M = {}

M.config = {
    sign = "c", -- plain ASCII, renders without a patched font
}

local review = require("mrview.review")

local ns = vim.api.nvim_create_namespace("mr_comment")
local group = vim.api.nvim_create_augroup("mr_comment", { clear = true })
local KEY = ".comments"

vim.api.nvim_set_hl(0, "MRComment", { link = "DiagnosticInfo", default = true })

--- @class MRComment
--- @field path string repo-relative
--- @field start_line integer
--- @field line integer last line of the range (== start_line for one line)
--- @field body string
--- @field head string HEAD sha when the comment was written

-- root -> MRComment[], read from the state file once per session.
local cache = {}

--- @return MRComment[]
function M.list(root)
    if not cache[root] then
        cache[root] = review.load_state(root)[KEY] or {}
    end
    return vim.deepcopy(cache[root])
end

local function store(root, comments)
    local state = review.load_state(root)
    state[KEY] = #comments > 0 and comments or nil
    review.save_state(root, state)
    cache[root] = comments
end

local function refresh_signs(bufnr, root)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local rel = name ~= "" and vim.fs.relpath(root, name)
    if not rel then
        return
    end
    local last = vim.api.nvim_buf_line_count(bufnr)
    for _, c in ipairs(M.list(root)) do
        if c.path == rel and c.line <= last then
            vim.api.nvim_buf_set_extmark(bufnr, ns, c.line - 1, 0, { sign_text = M.config.sign, sign_hl_group = "MRComment" })
        end
    end
end

local function refresh_all_signs(root)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            refresh_signs(bufnr, root)
        end
    end
end

vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
        if vim.bo[ev.buf].buftype ~= "" then
            return
        end
        -- Cached after the first look, so most windows cost no file read.
        local root = review.repo_root()
        if #M.list(root) > 0 then
            refresh_signs(ev.buf, root)
        end
    end,
})

function M.queue(root, comment)
    local comments = M.list(root)
    comments[#comments + 1] = comment
    store(root, comments)
    refresh_all_signs(root)
end

function M.remove(root, index)
    local comments = M.list(root)
    table.remove(comments, index)
    store(root, comments)
    refresh_all_signs(root)
end

--- Bottom split for writing text; `:w` hands the body to `on_write` and
--- closes, `:q` discards. The first line is a header and is not part of the body.
--- @param header string
--- @param on_write fun(body: string)
function M.compose(header, on_write)
    vim.cmd("botright 10new")
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "markdown"
    vim.api.nvim_buf_set_name(bufnr, "mr-comment://" .. bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "<!-- " .. header .. " · :w to queue, :q to drop -->", "" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        group = group,
        buffer = bufnr,
        callback = function()
            local lines = vim.api.nvim_buf_get_lines(bufnr, 1, -1, false)
            local body = vim.trim(table.concat(lines, "\n"))
            if body == "" then
                vim.notify("MR comment: empty, not queued", vim.log.levels.WARN)
                return
            end
            vim.bo[bufnr].modified = false
            on_write(body)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end,
    })
    return bufnr
end

--- Lines covered by the cursor or, in visual mode, by the selection.
local function range()
    if vim.fn.mode():match("^[vV]") then
        local a, b = vim.fn.line("v"), vim.fn.line(".")
        vim.cmd("normal! \27") -- leave visual mode before the split steals the window
        return math.min(a, b), math.max(a, b)
    end
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    return cur, cur
end

--- @param lines { [1]: integer, [2]: integer }? explicit range, e.g. from a :command
function M.add(lines)
    local root = review.repo_root()
    local path = review.rel_path(root)
    if not path then
        vim.notify("MR comment: current buffer is not a file in " .. root, vim.log.levels.WARN)
        return
    end
    local head = review.git({ "rev-parse", "HEAD" }, root)
    local start_line, line
    if lines then
        start_line, line = lines[1], lines[2]
    else
        start_line, line = range()
    end
    local where = path .. ":" .. start_line .. (line ~= start_line and ("-" .. line) or "")
    M.compose(where, function(body)
        M.queue(root, { path = path, start_line = start_line, line = line, body = body, head = head })
        vim.notify("MR comment: queued " .. where .. " (" .. #M.list(root) .. " pending)")
    end)
end

function M.pick()
    if not review.have_snacks() then
        return
    end
    local root = review.repo_root()
    local function items()
        local out = {}
        for i, c in ipairs(M.list(root)) do
            local where = c.path .. ":" .. c.start_line
            out[i] = {
                index = i,
                file = vim.fs.joinpath(root, c.path),
                pos = { c.start_line, 0 },
                text = where .. " " .. c.body,
                where = where,
                body = c.body,
            }
        end
        return out
    end

    Snacks.picker.pick({
        source = "mr_comments",
        title = "MR comments pending",
        items = items(),
        format = function(item)
            local first = item.body:match("^[^\n]*")
            return { { item.where, "SnacksPickerFile" }, { " " }, { first } }
        end,
        actions = {
            remove = function(picker, item)
                if not item then
                    return
                end
                M.remove(root, item.index)
                picker.opts.items = items()
                picker:find()
            end,
        },
        win = {
            input = { keys = { ["<c-x>"] = { "remove", mode = { "i", "n" } } } },
            list = { keys = { ["<c-x>"] = "remove" } },
        },
    })
end

return M
