-- Structural diff signs driven by difftastic's JSON output.
--
-- While active, every buffer under the repo is diffed against `<base>:<path>`
-- with `difft --display=json`. Only lines with a *semantic* change get a sign,
-- a line highlight and an inline highlight on the changed tokens; pure
-- reformatting (reflows, indentation) produces no marks at all.
--
-- Doc: https://difftastic.wilfred.me.uk/json_output.html (needs DFT_UNSTABLE=yes)

local M = {}

local ns = vim.api.nvim_create_namespace("structdiff")
local group = vim.api.nvim_create_augroup("structdiff", { clear = true })
-- Overridden by require("incognito").setup().
M.config = { difft_cmd = "difft", debounce_ms = 300 }

-- state.base: commit to diff against
-- state.show_deleted: render deleted base lines as virtual lines
-- state.split: render the base file as a pane to the right of every line
-- state.bufs[bufnr] = { base, hunks, base_file, base_text, base_lines, captures, timer, run_id, generation, result }
-- (`base` overrides state.base for that buffer)
local state = { base = nil, show_deleted = false, split = false, wrap = {}, bufs = {} }
local resize_timer = vim.uv.new_timer()
local RESIZE_MS = 100

-- Lines git would flag but difft considers pure formatting. A default link
-- survives `:colorscheme`, so no ColorScheme hook is needed.
vim.api.nvim_set_hl(0, "StructDiffFormat", { link = "NonText", default = true })
-- Changed tokens: green for what the new side gained, red for what the old
-- side lost, as difft paints them. gitsigns' own *Inline groups share the
-- background of the line highlight in onedarkpro, so tokens would vanish.
vim.api.nvim_set_hl(0, "StructDiffAddInline", { link = "DiffAdd", default = true })
vim.api.nvim_set_hl(0, "StructDiffChangeInline", { link = "DiffAdd", default = true })
vim.api.nvim_set_hl(0, "StructDiffDeleteInline", { link = "DiffDelete", default = true })

local function git(args, cwd)
    local res = vim.system(vim.list_extend({ "git", "--no-pager" }, args), { cwd = cwd, text = true }):wait()
    if res.code ~= 0 then
        return nil
    end
    return res.stdout
end

-- difft picks the parser by file name, so temp copies keep the real basename.
local function temp_copy(name, lines)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = vim.fs.joinpath(dir, vim.fs.basename(name))
    vim.fn.writefile(lines, path)
    return path
end

-- Old path of `rel` if git sees it as renamed between the base and the
-- working tree (needs the new path to be tracked, which an MR commit is).
local function rename_source(rel, dir, base)
    local out = git({ "diff", "--name-status", "-M", "-z", "--diff-filter=R", base }, dir)
    local fields = vim.split(out or "", "\0", { trimempty = true })
    for i = 1, #fields - 2, 3 do
        if fields[i + 2] == rel then
            return fields[i + 1]
        end
    end
    return nil
end

-- Content of the file at its base, written once per buffer and cached.
local function base_file(bufnr)
    local buf = state.bufs[bufnr]
    if buf.base_file then
        return buf.base_file
    end
    local name = vim.api.nvim_buf_get_name(bufnr)
    local dir = vim.fs.dirname(name)
    -- `.git` is a directory in a clone and a file in a worktree; both match.
    local root = vim.fs.root(name, ".git")
    if not root then
        return nil
    end
    local rel = vim.fs.relpath(root, name)
    local base = buf.base or state.base
    local content = rel and git({ "show", base .. ":" .. rel }, dir)
    if rel and not content then
        -- Not at this path in the base: maybe it was renamed since.
        local old = rename_source(rel, dir, base)
        content = old and git({ "show", base .. ":" .. old }, dir)
    end
    buf.base_missing = content == nil
    buf.base_text = content or ""
    local lines = vim.split(buf.base_text, "\n")
    if lines[#lines] == "" then
        lines[#lines] = nil
    end
    buf.base_lines = lines
    buf.base_file = temp_copy(name, lines)
    return buf.base_file
end

-- Side by side the line tint goes: the tokens alone carry the difference.
local function mark_line(bufnr, lnum, kind)
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        sign_text = "┃",
        sign_hl_group = "GitSigns" .. kind,
        line_hl_group = not state.split and ("GitSigns" .. kind .. "Ln") or nil,
        priority = 6,
    })
end

-- difft columns are byte offsets, same as extmarks; just keep them in range.
-- The background must sit above syntax and treesitter (priorities 50 and
-- 100, see `vim.hl.priorities`), or their attributes swallow it.
local function mark_tokens(bufnr, lnum, kind, changes)
    local len = #(vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or "")
    for _, ch in ipairs(changes) do
        local s, e = math.min(ch.start, len), math.min(ch["end"], len)
        if s < e then
            vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, s, {
                end_col = e,
                hl_group = "StructDiff" .. kind .. "Inline",
                priority = vim.hl.priorities.user,
            })
        end
    end
end

-- Buffer lines as the file holds them: an empty buffer still has one ""
-- line, but git stores it as zero bytes.
local function file_lines(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return (#lines == 1 and lines[1] == "") and {} or lines
end

-- Right-hand line numbers a plain line diff would flag, as a set.
local function text_changed_lines(bufnr)
    local lines = file_lines(bufnr)
    local new = #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
    local hunks = vim.diff(state.bufs[bufnr].base_text or "", new, { result_type = "indices" })
    local set = {}
    for _, h in ipairs(hunks or {}) do
        for lnum = h[3], h[3] + h[4] - 1 do
            set[lnum] = true
        end
    end
    return set
end

-- A sign alone, no line highlight: formatting-only lines and deletion stops.
local function mark_sign(bufnr, lnum, text, hl, priority)
    vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        sign_text = text,
        sign_hl_group = hl,
        priority = priority,
    })
end

-- A side of an aligned pair is null in the JSON where that side has no line.
local function present(v)
    return v ~= nil and v ~= vim.NIL
end

-- For every deleted base line (0-based), the 1-based buffer line it sits
-- above; `last + 1` when the deletion happened at the end of the file.
local function deletion_anchors(aligned, last)
    local anchors, pending = {}, {}
    for _, pair in ipairs(aligned or {}) do
        local lhs, rhs = pair[1], pair[2]
        if not present(rhs) then
            if present(lhs) then
                pending[#pending + 1] = lhs
            end
        else
            for _, l in ipairs(pending) do
                anchors[l] = math.min(rhs + 1, last + 1)
            end
            pending = {}
        end
    end
    for _, l in ipairs(pending) do
        anchors[l] = last + 1
    end
    return anchors
end

-- Syntax captures of the base text, per line: { {start, end, group}, ... }
-- with byte offsets, in query order (later ones win, as in the highlighter).
-- Parsed from the string, no buffer involved; cached with the base text.
local function base_captures(bufnr)
    local buf = state.bufs[bufnr]
    if buf.captures then
        return buf.captures
    end
    buf.captures = {}
    local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
    local ok, parser = pcall(vim.treesitter.get_string_parser, buf.base_text, lang)
    local query = ok and vim.treesitter.query.get(lang, "highlights")
    if not query then
        return buf.captures
    end
    for _, tree in ipairs(parser:parse(true)) do
        for id, node in query:iter_captures(tree:root(), buf.base_text) do
            local name = query.captures[id]
            if name:sub(1, 1) ~= "_" then
                local srow, scol, erow, ecol = node:range()
                for row = srow, math.min(erow, #buf.base_lines - 1) do
                    local s = row == srow and scol or 0
                    local e = row == erow and ecol or #buf.base_lines[row + 1]
                    buf.captures[row + 1] = buf.captures[row + 1] or {}
                    table.insert(buf.captures[row + 1], { s, e, "@" .. name .. "." .. lang })
                end
            end
        end
    end
    return buf.captures
end

-- One virtual line of base text: syntax colours from the captures, and the
-- deleted tokens emphasised on top. Every chunk carries `hl` (the row's
-- background) and, where it applies, the syntax group and the token group.
local function deleted_segments(text, changes, hl, captures)
    hl = hl or "GitSignsDeleteVirtLn"
    -- Per byte: the syntax group and whether difft marked it as removed.
    local syntax, changed = {}, {}
    for _, cap in ipairs(captures or {}) do
        for i = cap[1] + 1, math.min(cap[2], #text) do
            syntax[i] = cap[3]
        end
    end
    for _, ch in ipairs(changes) do
        for i = ch.start + 1, math.min(ch["end"], #text) do
            changed[i] = true
        end
    end
    -- One chunk per run of bytes that share both.
    local segs, from = {}, 1
    for i = 1, #text do
        if i == #text or syntax[i + 1] ~= syntax[from] or changed[i + 1] ~= changed[from] then
            local groups = { hl }
            groups[#groups + 1] = syntax[from]
            groups[#groups + 1] = changed[from] and "StructDiffDeleteInline" or nil
            segs[#segs + 1] = { text:sub(from, i), groups }
            from = i + 1
        end
    end
    if #segs == 0 then
        segs[1] = { "", hl }
    end
    return segs
end

-- Side-by-side pane: the base line sits before the buffer line as inline
-- virtual text, cut or padded to `width` cells so the buffer text always
-- starts in the same column. Number column and separator are part of it.
local NUM_W = 5

local function fit(segs, width, pad_hl, tabstop)
    local expanded, total = {}, 0
    for _, seg in ipairs(segs) do
        local text = seg[1]:gsub("\t", string.rep(" ", tabstop))
        expanded[#expanded + 1] = { text, seg[2] }
        total = total + vim.fn.strdisplaywidth(text)
    end
    if total <= width then
        if total < width then
            expanded[#expanded + 1] = { string.rep(" ", width - total), pad_hl }
        end
        return expanded
    end
    -- Too long: keep `width - 1` cells and end with an ellipsis.
    local out, budget = {}, width - 1
    for _, seg in ipairs(expanded) do
        local text = seg[1]
        while text ~= "" and vim.fn.strdisplaywidth(text) > budget do
            text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
        end
        if text ~= "" then
            out[#out + 1] = { text, seg[2] }
        end
        budget = budget - vim.fn.strdisplaywidth(text)
        if budget <= 0 then
            break
        end
    end
    -- A wide character cut short can leave a cell; pad it before the mark.
    if budget > 0 then
        out[#out + 1] = { string.rep(" ", budget), pad_hl }
    end
    out[#out + 1] = { "…", pad_hl }
    return out
end

local function pane_row(old_lnum, segs, width, pad_hl, tabstop)
    local row = {
        { "│ ", "WinSeparator" },
        { old_lnum and string.format("%4d ", old_lnum) or string.rep(" ", NUM_W), "LineNr" },
    }
    return vim.list_extend(row, fit(segs, width - NUM_W - 2, pad_hl, tabstop))
end

-- Where the pane starts (window column) and how many cells it gets, from a
-- window showing the buffer: the buffer keeps the left half.
local function pane_geometry(bufnr)
    local win = vim.fn.bufwinid(bufnr)
    if win == -1 then
        win = vim.api.nvim_get_current_win()
    end
    local info = vim.fn.getwininfo(win)[1]
    local text = info.width - info.textoff
    local left = math.floor(text / 2)
    return left, text - left
end

-- Deleted lines render as virtual lines above their anchor (or below the
-- last line) when `state.show_deleted` is on; either way the anchor becomes
-- a navigation stop with a "▁" sign unless it already carries a bright mark.
-- The old text of a changed line is shown the same way, right above it, so
-- a yellow line comes with what it replaced, as in gitsigns.
local function mark_deletions(bufnr, result, last, marked)
    local buf = state.bufs[bufnr]
    local anchors = deletion_anchors(result.aligned_lines, last)
    local tabstop = vim.bo[bufnr].tabstop
    local left, right = pane_geometry(bufnr)
    -- anchor -> { {old line (0-based), virtual line}, ... }
    local groups = {}
    local function add(anchor, old, changes)
        local text, caps = buf.base_lines[old + 1], base_captures(bufnr)[old + 1]
        local virt = deleted_segments(text, changes, state.split and "Normal" or nil, caps)
        if state.split then
            local row = { { string.rep(" ", left), "Normal" } }
            virt = vim.list_extend(row, pane_row(old + 1, virt, right, "Normal", tabstop))
        end
        groups[anchor] = groups[anchor] or {}
        table.insert(groups[anchor], { old, virt })
    end
    if result.status == "deleted" then
        -- Buffer emptied: difft sends no chunks, every base line is gone.
        for i = 1, #buf.base_lines do
            add(last + 1, i - 1, {})
        end
    end
    for _, chunk in ipairs(result.chunks or {}) do
        for _, pair in ipairs(chunk) do
            local lhs, rhs = pair.lhs, pair.rhs
            -- In split mode the old text of a changed line lives in the pane.
            if lhs and buf.base_lines[lhs.line_number + 1] and not (rhs and state.split) then
                local anchor = rhs and math.min(rhs.line_number + 1, last + 1) or anchors[lhs.line_number] or last + 1
                add(anchor, lhs.line_number, lhs.changes or {})
            end
        end
    end
    for anchor, items in pairs(groups) do
        table.sort(items, function(a, b)
            return a[1] < b[1]
        end)
        local above = anchor <= last
        local stop = above and anchor or last
        if state.show_deleted or state.split then
            vim.api.nvim_buf_set_extmark(bufnr, ns, stop - 1, 0, {
                virt_lines = vim.tbl_map(function(item)
                    return item[2]
                end, items),
                virt_lines_above = above,
            })
        end
        if not marked[stop] then
            marked[stop] = true
            mark_sign(bufnr, stop, "▁", "GitSignsDelete", 6)
        end
    end
end

-- The base file as a pane to the right of every buffer line, drawn over
-- the window from a fixed column: the aligned base line in syntax colours
-- with the removed tokens emphasised, or blank space.
local function mark_pane(bufnr, result, last)
    local buf = state.bufs[bufnr]
    local old_of, changes = {}, {}
    for _, pair in ipairs(result.aligned_lines or {}) do
        local lhs, rhs = pair[1], pair[2]
        if present(lhs) and present(rhs) then
            old_of[rhs + 1] = lhs + 1
        end
    end
    for _, chunk in ipairs(result.chunks or {}) do
        for _, pair in ipairs(chunk) do
            if pair.lhs then
                changes[pair.lhs.line_number + 1] = pair.lhs.changes or {}
            end
        end
    end
    local left, right = pane_geometry(bufnr)
    local tabstop = vim.bo[bufnr].tabstop
    local captures = base_captures(bufnr)
    for lnum = 1, last do
        local old = old_of[lnum]
        local text = old and buf.base_lines[old]
        local segs = text and deleted_segments(text, changes[old] or {}, "Normal", captures[old]) or {}
        vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
            virt_text = pane_row(text and old or nil, segs, right, "Normal", tabstop),
            virt_text_win_col = left,
            right_gravity = false,
        })
    end
end

--- Consecutive marked lines form one hunk, like gitsigns.
--- @param lines integer[] sorted, unique
--- @return { start: integer, stop: integer }[]
local function group_hunks(lines)
    local hunks = {}
    for _, l in ipairs(lines) do
        local h = hunks[#hunks]
        if h and l == h.stop + 1 then
            h.stop = l
        else
            hunks[#hunks + 1] = { start = l, stop = l }
        end
    end
    return hunks
end

local function apply(bufnr, result)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local marked = {} -- set of buffer lines that got a sign
    local last = vim.api.nvim_buf_line_count(bufnr)
    local textual = text_changed_lines(bufnr)

    if result.status == "created" or state.bufs[bufnr].base_missing then
        for lnum = 1, last do
            mark_line(bufnr, lnum, "Add")
            marked[lnum] = true
        end
    else
        for _, chunk in ipairs(result.chunks or {}) do
            for _, pair in ipairs(chunk) do
                local rhs = pair.rhs
                if rhs and rhs.line_number + 1 <= last then
                    local lnum = rhs.line_number + 1
                    local kind = pair.lhs and "Change" or "Add"
                    mark_line(bufnr, lnum, kind)
                    mark_tokens(bufnr, lnum, kind, rhs.changes or {})
                    marked[lnum] = true
                    textual[lnum] = nil
                end
            end
        end
        mark_deletions(bufnr, result, last, marked)
        -- Whatever git flagged that difft did not: formatting only. Keeping
        -- these visible (dimly) is what makes a missed real change noticeable.
        for lnum in pairs(textual) do
            if lnum <= last then
                mark_sign(bufnr, lnum, "┃", "StructDiffFormat", 5)
            end
        end
    end
    if state.split then
        mark_pane(bufnr, result, last)
    end
    -- difft emits chunks in its own order; navigation wants buffer order.
    local lines = vim.tbl_keys(marked)
    table.sort(lines)
    state.bufs[bufnr].hunks = group_hunks(lines)
    state.bufs[bufnr].generation = (state.bufs[bufnr].generation or 0) + 1
end

local function run(bufnr)
    if not (state.base and vim.api.nvim_buf_is_valid(bufnr) and state.bufs[bufnr]) then
        return
    end
    local old = base_file(bufnr)
    if not old then
        return
    end
    local new = temp_copy(vim.api.nvim_buf_get_name(bufnr), file_lines(bufnr))
    -- Runs may overlap; only the latest one is allowed to paint.
    local buf = state.bufs[bufnr]
    buf.run_id = (buf.run_id or 0) + 1
    local run_id = buf.run_id

    vim.system(
        { M.config.difft_cmd, "--display=json", "--color=never", old, new },
        { text = true, env = { DFT_UNSTABLE = "yes" } },
        vim.schedule_wrap(function(res)
            vim.fn.delete(vim.fs.dirname(new), "rf")
            local ok, decoded = pcall(vim.json.decode, res.stdout or "")
            if not ok or type(decoded) ~= "table" then
                return vim.notify("structdiff: difft failed: " .. vim.trim(res.stderr or ""), vim.log.levels.WARN)
            end
            local cur = state.bufs[bufnr]
            if cur and cur.run_id == run_id and vim.api.nvim_buf_is_valid(bufnr) then
                cur.result = decoded -- kept so display toggles can repaint without difft
                apply(bufnr, decoded)
            end
        end)
    )
end

function M.refresh(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not state.base or vim.api.nvim_buf_get_name(bufnr) == "" or vim.bo[bufnr].buftype ~= "" then
        return
    end
    state.bufs[bufnr] = state.bufs[bufnr] or { timer = vim.uv.new_timer() }
    -- Restarting the one timer of the buffer is the debounce.
    state.bufs[bufnr].timer:start(
        M.config.debounce_ms,
        0,
        vim.schedule_wrap(function()
            run(bufnr)
        end)
    )
end

local function detach(bufnr)
    local buf = state.bufs[bufnr]
    if not buf then
        return
    end
    buf.timer:close()
    if buf.base_file then
        vim.fn.delete(vim.fs.dirname(buf.base_file), "rf")
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
    state.bufs[bufnr] = nil
end

--- Number of completed difft runs for a buffer (tests wait on it).
function M._generation(bufnr)
    local buf = state.bufs[bufnr or vim.api.nvim_get_current_buf()]
    return buf and buf.generation or 0
end

--- Diff one buffer against `base` instead of the common base; nil goes
--- back to it. `enable()` drops these.
function M.set_buf_base(bufnr, base)
    if not state.base then
        return
    end
    detach(bufnr)
    M.refresh(bufnr)
    if state.bufs[bufnr] then
        state.bufs[bufnr].base = base
    end
end

function M.active()
    return state.base ~= nil
end

local function repaint_all()
    for bufnr, buf in pairs(state.bufs) do
        if buf.result and vim.api.nvim_buf_is_valid(bufnr) then
            apply(bufnr, buf.result) -- repaint from the last difft run: instant
        else
            M.refresh(bufnr)
        end
    end
end

--- Show/hide deleted base lines as virtual lines; signs and ]g stops stay.
--- @param value boolean? explicit state, flips when nil
function M.toggle_deleted(value)
    if value == nil then
        value = not state.show_deleted
    end
    state.show_deleted = value
    repaint_all()
    return value
end

--- Show/hide the base file as a pane before every line (side by side).
--- Wrapping is turned off for every window showing a diffed buffer while
--- the pane is on.
--- @param value boolean? explicit state, flips when nil
function M.toggle_split(value)
    if value == nil then
        value = not state.split
    end
    state.split = value
    if value then
        for bufnr in pairs(state.bufs) do
            for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
                if state.wrap[win] == nil then
                    state.wrap[win] = vim.wo[win].wrap
                    vim.wo[win].wrap = false
                end
            end
        end
    else
        for w, wrap in pairs(state.wrap) do
            if vim.api.nvim_win_is_valid(w) then
                vim.wo[w].wrap = wrap
            end
        end
        state.wrap = {}
    end
    repaint_all()
    return value
end

-- Drop autocmds and buffers; display toggles (split, deleted) survive.
local function reset()
    vim.api.nvim_clear_autocmds({ group = group })
    resize_timer:stop()
    for bufnr in pairs(state.bufs) do
        detach(bufnr)
    end
end

function M.enable(base)
    if vim.fn.executable(M.config.difft_cmd) ~= 1 then
        return vim.notify("structdiff: difft not found in PATH", vim.log.levels.ERROR)
    end
    reset()
    state.base = base

    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
        group = group,
        callback = function()
            if state.split then
                resize_timer:start(RESIZE_MS, 0, vim.schedule_wrap(repaint_all))
            end
        end,
    })
    vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "TextChanged", "InsertLeave" }, {
        group = group,
        callback = function(ev)
            M.refresh(ev.buf)
        end,
    })
    vim.api.nvim_create_autocmd("BufDelete", {
        group = group,
        callback = function(ev)
            detach(ev.buf)
        end,
    })
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            M.refresh(bufnr)
        end
    end
end

function M.disable()
    reset()
    M.toggle_split(false) -- restores wrap; no buffers left to repaint
    state.base = nil
end

--- Jump to the start of the next/previous hunk, wrapping around like gitsigns,
--- and report the position the same way ("Hunk N of M").
--- @param dir "next" | "prev"
--- @return integer? index of the hunk landed on
function M.nav(dir)
    local buf = state.bufs[vim.api.nvim_get_current_buf()]
    local hunks = buf and buf.hunks or {}
    if #hunks == 0 then
        return vim.notify("structdiff: no changes", vim.log.levels.INFO)
    end
    local cur = vim.api.nvim_win_get_cursor(0)[1]
    -- Hunks are sorted: the first one after the cursor, or the last one before.
    local index = dir == "next" and 1 or #hunks
    for i, h in ipairs(hunks) do
        if dir == "next" and h.start > cur then
            index = i
            break
        elseif dir ~= "next" and h.start < cur then
            index = i
        end
    end
    vim.api.nvim_win_set_cursor(0, { hunks[index].start, 0 })
    vim.api.nvim_echo({ { ("Hunk %d of %d"):format(index, #hunks), "None" } }, false, {})
    return index
end

return M
