local M = {}

M.config = {
    remote = "origin",
    -- Tried as <remote>/<name>, then as local branches.
    targets = { "main", "master" },
}

local function repo_dir()
    local name = vim.api.nvim_buf_get_name(0)
    if name == "" then
        return vim.uv.cwd()
    end
    return vim.fn.fnamemodify(name, ":h")
end

local function repo_root()
    local dir = repo_dir()
    return vim.fs.root(dir, ".git") or dir
end

local function have_snacks()
    if Snacks == nil then
        vim.notify("Incognito: snacks.nvim is required for pickers", vim.log.levels.ERROR)
        return false
    end
    return true
end

local function git(args, cwd, stdin)
    local opts = { cwd = cwd, text = true, stdin = stdin }
    local res = vim.system(vim.list_extend({ "git", "--no-pager" }, args), opts):wait()
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or "")
    end
    return vim.trim(res.stdout)
end

local function merge_base(target, root)
    local base, err = git({ "merge-base", target, "HEAD" }, root)
    if not base then
        vim.notify("Incognito: " .. (err or "merge-base failed"), vim.log.levels.ERROR)
    end
    return base
end

-- root -> state file path, false outside a git repo.
local state_paths = {}

-- In the git common dir, so worktrees share it and it moves with the clone.
local function state_path(root)
    if state_paths[root] == nil then
        local dir = vim.uv.fs_stat(vim.fs.joinpath(root, ".git"))
            and git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, root)
        state_paths[root] = dir and vim.fs.joinpath(dir, "incognito.json") or false
    end
    return state_paths[root] or nil
end

local function load_state(root)
    local path = state_path(root)
    if not path or not vim.uv.fs_stat(path) then
        return {}
    end
    local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
    if ok and type(decoded) == "table" then
        return decoded
    end
    -- Keep the broken file for the user instead of overwriting it later.
    vim.uv.fs_rename(path, path .. ".bad")
    vim.notify("Incognito: " .. path .. " is not valid JSON, moved to " .. path .. ".bad", vim.log.levels.ERROR)
    return {}
end

local function save_state(root, state)
    local path = state_path(root)
    if not path then
        return vim.notify("Incognito: " .. root .. " is not a git repository", vim.log.levels.ERROR)
    end
    -- Write and rename, so a crash never leaves half a file behind.
    local tmp = path .. ".tmp"
    if vim.fn.writefile({ vim.json.encode(state) }, tmp) ~= 0 then
        return vim.notify("Incognito: cannot write " .. tmp, vim.log.levels.ERROR)
    end
    local ok, err = vim.uv.fs_rename(tmp, path)
    if not ok then
        vim.notify("Incognito: " .. err, vim.log.levels.ERROR)
    end
end

local BASE_KEY = ".base"

local target_cache = {}

local function detect_target(root)
    local remote, targets = M.config.remote, M.config.targets
    local head = git({ "symbolic-ref", "--short", "refs/remotes/" .. remote .. "/HEAD" }, root)
    if head then
        return head
    end
    local candidates = vim.tbl_map(function(name)
        return remote .. "/" .. name
    end, targets)
    for _, name in ipairs(vim.list_extend(candidates, targets)) do
        if git({ "rev-parse", "--verify", "--quiet", name }, root) then
            return name
        end
    end
    return targets[1] or "main"
end

local function resolve_target(root)
    local saved = load_state(root)[BASE_KEY]
    if type(saved) == "string" then
        return saved
    end
    target_cache[root] = target_cache[root] or detect_target(root)
    return target_cache[root]
end

-- Set one top-level key of the state file.
local function update_state(root, key, value)
    local state = load_state(root)
    state[key] = value
    save_state(root, state)
end

-- A reviewed mark: { blob = id of the file content, head = HEAD sha }, both
-- taken when it was marked. Old marks were just the HEAD sha.
local function mark_of(marks, file)
    local mark = marks[file]
    return type(mark) == "string" and { head = mark } or mark
end

--- Blob ids of the working-tree files (not HEAD: an uncommitted edit after
--- the review still counts as a change). Missing files are left out.
local function blob_ids(root, files)
    local present = {}
    for _, file in ipairs(files) do
        local stat = vim.uv.fs_stat(vim.fs.joinpath(root, file))
        if stat and stat.type == "file" then
            present[#present + 1] = file
        end
    end
    local ids = {}
    local out = #present > 0 and git({ "hash-object", "--stdin-paths" }, root, table.concat(present, "\n") .. "\n")
    for i, id in ipairs(out and vim.split(out, "\n") or {}) do
        ids[present[i]] = id
    end
    return ids
end

function M.status_symbol(mark, blob)
    if not mark then
        return " "
    end
    if not mark.blob or not blob then
        return "?"
    end
    return mark.blob == blob and "✓" or "~"
end

local function reviewed_status(root, target, files)
    local marks = load_state(root)[target] or {}
    local marked = vim.tbl_filter(function(file)
        return marks[file] ~= nil
    end, files)
    local ids = blob_ids(root, marked)

    local status = {}
    for _, file in ipairs(files) do
        status[file] = M.status_symbol(mark_of(marks, file), ids[file])
    end
    return status
end

local function rel_path(root)
    local name = vim.api.nvim_buf_get_name(0)
    if name == "" then
        return nil
    end
    return vim.fs.relpath(root, name)
end

-- Commit mode: one commit of the MR is checked out in a worktree of its own
-- and diffed against its parent, so the buffers show exactly what that
-- commit changed while the user's checkout (HEAD, index, files) stays put.
-- { root = the user's checkout, worktree, commits = { {sha, short, subject} }
-- oldest first, index = current commit, base = its parent }
---@type table?
local commit_mode = nil

-- In commit mode the review runs in the worktree, also when the current
-- buffer is a file of the user's checkout.
local function review_root()
    local root = repo_root()
    if commit_mode and root == commit_mode.root then
        return commit_mode.worktree
    end
    return root
end

-- Base to diff against and its name: the commit's parent in commit mode,
-- the merge base with `target` otherwise.
local function current_base(root, target)
    if commit_mode and commit_mode.worktree == root then
        return commit_mode.base, "the commit parent"
    end
    return merge_base(target, root), target
end

-- Point gitsigns at the review base; returns the base and its name.
-- gitsigns changes the base of every attached buffer, so a buffer from
-- another repository makes it fail on a revision it does not have.
local function gitsigns_error(err)
    if err then
        vim.notify("Incognito: gitsigns: " .. err, vim.log.levels.ERROR)
    end
end

local function change_base(target)
    local root = review_root()
    local base, name = current_base(root, target or resolve_target(root))
    if base then
        require("gitsigns").change_base(base, true, gitsigns_error)
    end
    return base, name
end

function M.on(target)
    local base, name = change_base(target)
    if base then
        require("gitsigns").toggle_linehl(true)
        vim.notify("Incognito: diffing against " .. name)
    end
end

--- Same as `on`, but marks come from difftastic: lines that only changed
--- formatting stay clean. gitsigns keeps the base for stage/reset, its own
--- signs go quiet so the two don't disagree in the sign column.
function M.on_structural(target)
    local base, name = change_base(target)
    if base then
        local gs = require("gitsigns")
        gs.toggle_linehl(false)
        gs.toggle_signs(false)
        require("incognito.structdiff").enable(base)
        vim.notify("Incognito (structural): diffing against " .. name)
    end
end

local function mr_commits(root)
    local base = merge_base(resolve_target(root), root)
    if not base then
        return nil
    end
    local out = git({ "log", "--reverse", "--format=%H%x09%h%x09%s", base .. "..HEAD" }, root) or ""
    local commits = {}
    for _, line in ipairs(vim.split(out, "\n", { trimempty = true })) do
        local sha, short, subject = line:match("^(%x+)\t(%x+)\t(.*)$")
        commits[#commits + 1] = { sha = sha, short = short, subject = subject }
    end
    return commits
end

-- Commit mode worktrees live outside the repository, so tools that watch
-- it never see them: <cache>/incognito/<repo>-<hash>-<pid>, one per
-- repository and Neovim process. Resolved, as git records it.
local function worktree_prefix(root)
    local common = git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, root)
    local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "incognito")
    vim.fn.mkdir(dir, "p")
    dir = vim.uv.fs_realpath(dir)
    if not (common and dir) then
        return nil
    end
    return vim.fs.joinpath(dir, ("%s-%s-"):format(vim.fs.basename(root), vim.fn.sha256(common):sub(1, 8)))
end

-- Worktrees left by sessions that died in commit mode: their process is gone.
local function remove_stale_worktrees(root, prefix)
    git({ "worktree", "prune" }, root)
    local out = git({ "worktree", "list", "--porcelain" }, root) or ""
    for path in out:gmatch("worktree ([^\n]+)") do
        local pid = vim.startswith(path, prefix) and tonumber(path:sub(#prefix + 1))
        if pid and pid ~= vim.fn.getpid() and vim.uv.kill(pid, 0) ~= 0 then
            git({ "worktree", "remove", "--force", path }, root)
        end
    end
end

-- A fresh detached worktree of `root` at `sha`; returns its path.
local function add_worktree(root, sha)
    local prefix = worktree_prefix(root)
    if not prefix then
        return nil, root .. " is not a git repository"
    end
    remove_stale_worktrees(root, prefix)
    local path = prefix .. vim.fn.getpid()
    if vim.uv.fs_stat(path) then
        -- An earlier commit mode of this session failed to remove it.
        git({ "worktree", "remove", "--force", path }, root)
        vim.fn.delete(path, "rf")
    end
    local _, err = git({ "worktree", "add", "--quiet", "--detach", path, sha }, root)
    if err then
        return nil, err
    end
    return path
end

local function remove_worktree(root, path)
    local _, err = git({ "worktree", "remove", "--force", path }, root)
    if err then
        vim.notify("Incognito: " .. err, vim.log.levels.WARN)
    end
end

-- Buffers of files under `dir`.
local function buffers_in(dir)
    return vim.tbl_filter(function(bufnr)
        return vim.fs.relpath(dir, vim.api.nvim_buf_get_name(bufnr)) ~= nil
    end, vim.api.nvim_list_bufs())
end

-- Every window showing a file under `from` switches to the same file under
-- `to`, if it exists there, at the same cursor position. A window that
-- cannot leave its modified buffer ('nohidden') stays.
local function move_windows(from, to)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        local rel = vim.bo[bufnr].buftype == "" and vim.fs.relpath(from, vim.api.nvim_buf_get_name(bufnr))
        local path = rel and vim.fs.joinpath(to, rel)
        if path and vim.uv.fs_stat(path) then
            local cursor = vim.api.nvim_win_get_cursor(win)
            local target = vim.fn.bufadd(path)
            if pcall(vim.api.nvim_win_set_buf, win, target) then
                vim.bo[target].buflisted = true
                pcall(vim.api.nvim_win_set_cursor, win, cursor)
            end
        end
    end
end

-- Move gitsigns (for every buffer when `global`) and, if on, structdiff to `base`.
local function move_base(base, global)
    require("gitsigns").change_base(base, global, gitsigns_error)
    local sd = require("incognito.structdiff")
    if sd.active() then
        sd.enable(base)
    end
end

-- The checkout rewrites the worktree files, so their buffers may hold no
-- unsaved edits. The worktree is scratch: saved edits are discarded.
local function show_commit(index)
    local mode = assert(commit_mode)
    for _, bufnr in ipairs(buffers_in(mode.worktree)) do
        if vim.bo[bufnr].modified then
            vim.notify("Incognito: save or undo the changes in the commit buffers first", vim.log.levels.ERROR)
            return false
        end
    end
    local commit = mode.commits[index]
    local _, err = git({ "checkout", "--quiet", "--force", "--detach", commit.sha }, mode.worktree)
    if err then
        vim.notify("Incognito: " .. err, vim.log.levels.ERROR)
        return false
    end
    mode.index = index
    mode.base = git({ "rev-parse", commit.sha .. "^" }, mode.worktree)
    vim.cmd.checktime()
    move_base(mode.base, true)
    move_windows(mode.root, mode.worktree)
    vim.notify(("Incognito: %d/%d %s %s"):format(index, #mode.commits, commit.short, commit.subject))
    return true
end

local function enter_commit_mode(root, commits, index)
    local worktree, err = add_worktree(root, commits[index].sha)
    if not worktree then
        return vim.notify("Incognito: " .. err, vim.log.levels.ERROR)
    end
    commit_mode = { root = root, worktree = worktree, commits = commits }
    if not show_commit(index) then
        commit_mode = nil
        return remove_worktree(root, worktree)
    end
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("incognito", { clear = true }),
        callback = function()
            if commit_mode then
                git({ "worktree", "remove", "--force", commit_mode.worktree }, commit_mode.root)
            end
        end,
    })
    -- Without a review mode on, fall back to the gitsigns one.
    if not require("incognito.structdiff").active() then
        require("gitsigns").toggle_linehl(true)
    end
end

-- Windows go back to the user's files, the commit buffers and the worktree away.
local function leave_commit_mode()
    local mode = assert(commit_mode)
    commit_mode = nil
    vim.api.nvim_clear_autocmds({ group = "incognito" })
    move_windows(mode.worktree, mode.root)
    for _, bufnr in ipairs(buffers_in(mode.worktree)) do
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    remove_worktree(mode.root, mode.worktree)
end

--- Picker over the MR commits; confirming one enters commit mode on it
--- (or jumps there if commit mode is already on).
function M.commits()
    if not have_snacks() then
        return
    end
    local root = commit_mode and commit_mode.root or repo_root()
    local commits = commit_mode and commit_mode.commits or mr_commits(root)
    if not commits then
        return
    end
    if #commits == 0 then
        return vim.notify("Incognito: no commits on top of " .. resolve_target(root), vim.log.levels.WARN)
    end

    local items = {}
    for i, c in ipairs(commits) do
        items[i] = { text = c.short .. " " .. c.subject, index = i, sha = c.sha, cwd = root }
    end
    Snacks.picker.pick({
        source = "mr_commits",
        title = "MR commits",
        items = items,
        format = function(item)
            local c = commits[item.index]
            local current = commit_mode and commit_mode.index == item.index
            return {
                {
                    ("%d/%d"):format(item.index, #commits),
                    current and "SnacksPickerGitBranchCurrent" or "SnacksPickerComment",
                },
                { " " },
                { c.short, "SnacksPickerGitCommit" },
                { " " },
                { c.subject, "SnacksPickerGitMsg" },
            }
        end,
        preview = function(ctx)
            Snacks.picker.preview.cmd({ "git", "--no-pager", "show", "--stat", ctx.item.sha }, ctx, { ft = "git" })
        end,
        confirm = function(picker, item)
            picker:close()
            if not item then
                return
            end
            if commit_mode then
                show_commit(item.index)
            else
                enter_commit_mode(root, commits, item.index)
            end
        end,
    })
end

--- Step to the next (1) or previous (-1) commit in commit mode.
function M.step_commit(delta)
    if not commit_mode then
        return vim.notify("Incognito: commit mode is off, enter it from the MR commits picker", vim.log.levels.WARN)
    end
    local index = commit_mode.index + delta
    if index < 1 or index > #commit_mode.commits then
        return vim.notify("Incognito: no more commits", vim.log.levels.INFO)
    end
    show_commit(index)
end

--- Branch picker for the review base. Typed text that matches no branch is
--- taken as a revision, so `HEAD~1` or a hash work as well.
function M.set_base()
    if not have_snacks() then
        return
    end
    local root = repo_root()
    Snacks.picker.git_branches({
        all = true,
        cwd = root,
        title = "Incognito: review base",
        win = { input = { keys = { ["<c-a>"] = false, ["<c-x>"] = false } } },
        confirm = function(picker, item)
            local typed = vim.trim(picker:filter().search)
            picker:close()
            local rev = item and (item.branch or item.commit) or typed
            if rev == "" then
                return
            end
            if not git({ "rev-parse", "--verify", "--quiet", rev }, root) then
                return vim.notify("Incognito: unknown revision " .. rev, vim.log.levels.ERROR)
            end
            update_state(root, BASE_KEY, rev)
            M.on(rev)
        end,
    })
end

function M.off()
    if commit_mode then
        leave_commit_mode()
    end
    require("incognito.structdiff").disable()
    local gs = require("gitsigns")
    gs.change_base(nil, true, gitsigns_error)
    gs.toggle_linehl(false)
    gs.toggle_signs(true)
    vim.notify("Incognito: off")
end

--- Mark files as reviewed at their present content (true) or unmark them (false).
--- @param reviewed table<string, boolean>
local function set_reviewed(root, target, reviewed)
    if vim.tbl_isempty(reviewed) then
        return
    end
    local head = git({ "rev-parse", "HEAD" }, root)
    local ids = blob_ids(root, vim.tbl_keys(reviewed))
    local state = load_state(root)
    state[target] = state[target] or {}
    for file, on in pairs(reviewed) do
        state[target][file] = on and { blob = ids[file], head = head } or nil
    end
    if vim.tbl_isempty(state[target]) then
        state[target] = nil
    end
    save_state(root, state)
end

function M.toggle_reviewed(target)
    local root = repo_root()
    target = target or resolve_target(root)
    local file = rel_path(root)
    if not file then
        return vim.notify("Incognito: current buffer is not a file in " .. root, vim.log.levels.WARN)
    end

    -- Only a current mark (✓) is taken back; a stale (~) or unknown (?) one
    -- is refreshed to the present content, since re-reading the file is what
    -- one just did.
    local on = reviewed_status(root, target, { file })[file] ~= "✓"
    set_reviewed(root, target, { [file] = on })
    vim.notify("Incognito: " .. file .. (on and " reviewed" or " unmarked"))
end

function M.since_review(target)
    local root = repo_root()
    target = target or resolve_target(root)
    local file = rel_path(root)
    local mark = file and mark_of(load_state(root)[target] or {}, file)
    local sha = mark and mark.head
    if not sha then
        return vim.notify("Incognito: " .. (file or "buffer") .. " was never reviewed", vim.log.levels.WARN)
    end

    move_base(sha, false)
    vim.notify("Incognito: showing changes since your review")
end

local function changed_items(base, root)
    local out, err = git({ "diff", "--name-status", "-z", base }, root)
    if not out then
        return vim.notify("Incognito: " .. (err or "diff failed"), vim.log.levels.ERROR)
    end
    -- Status, then the path; renames and copies give the old path first.
    local fields = vim.split(out, "\0", { trimempty = true })
    local items, files = {}, {}
    local i = 1
    while i < #fields do
        local kind = fields[i]:sub(1, 1)
        local paths = (kind == "R" or kind == "C") and 2 or 1
        local file = fields[i + paths]
        i = i + 1 + paths
        items[#items + 1] = { cwd = root, file = file, text = file, status = " " .. kind }
        files[#files + 1] = file
    end
    return items, files
end

-- difft as git's external diff engine: one process for the whole MR, and git
-- handles renames and new files for us.
local function difft_env(extra)
    local cmd = require("incognito.structdiff").config.difft_cmd
    return vim.tbl_extend("force", { GIT_EXTERNAL_DIFF = cmd, DFT_UNSTABLE = "yes" }, extra)
end

--- Per-file difft status ("changed" | "unchanged" | "created" | "deleted")
--- for everything between `base` and the working tree, delivered async.
--- @param cb fun(status: table<string, string>)
function M.structural_status(base, root, cb)
    vim.system(
        { "git", "--no-pager", "diff", base },
        { cwd = root, text = true, env = difft_env({ DFT_DISPLAY = "json" }) },
        vim.schedule_wrap(function(res)
            local status = {}
            for _, line in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
                local ok, decoded = pcall(vim.json.decode, line)
                if ok and type(decoded) == "table" and decoded.path then
                    status[decoded.path] = decoded.status
                end
            end
            cb(status)
        end)
    )
end

function M.files(target)
    if not have_snacks() then
        return
    end
    local root = review_root()
    target = target or resolve_target(root)
    -- In commit mode the worktree sits at the commit, so diffing its
    -- parent against it lists that commit's files only.
    local base = current_base(root, target)
    if not base then
        return
    end

    local items, files = changed_items(base, root)
    if not items then
        return
    end
    local status = reviewed_status(root, target, files)

    -- In structural mode the list and the preview follow difft: files that
    -- only changed formatting are kept, but dimmed, so nothing disappears.
    local structural = require("incognito.structdiff").active()
    local semantic = {}

    local picker = Snacks.picker.pick({
        source = "mr_files",
        title = "MR files vs " .. target .. (structural and " (structural)" or ""),
        items = items,
        format = function(item, picker)
            local symbol = status[item.file] or " "
            local hl = symbol == "✓" and "SnacksPickerGitStatusAdded" or "SnacksPickerGitStatusModified"
            local ret = { { symbol, hl }, { " " } }
            local rest = Snacks.picker.format.git_status(item, picker)
            if semantic[item.file] == "unchanged" then
                -- Same row (icon included), just dimmed and with "=" for status.
                rest[1] = { " =", "StructDiffFormat" }
                for i = 2, #rest do
                    if rest[i][2] then
                        rest[i][2] = "StructDiffFormat"
                    end
                end
            end
            return vim.list_extend(ret, rest)
        end,
        preview = function(ctx)
            -- `git diff` runs GIT_EXTERNAL_DIFF unless told --no-ext-diff.
            local ext = structural and "--ext-diff" or "--no-ext-diff"
            local opts = structural and { env = difft_env({ DFT_DISPLAY = "inline", DFT_COLOR = "always" }) }
                or { ft = "diff" }
            Snacks.picker.preview.cmd({ "git", "--no-pager", "diff", ext, base, "--", ctx.item.file }, ctx, opts)
        end,
        actions = {
            toggle_reviewed = function(picker)
                -- Toggle each file on its own: current marks (✓) come off,
                -- stale (~), unknown (?) and missing ones get the present content.
                local reviewed = {}
                for _, item in ipairs(picker:selected({ fallback = true })) do
                    reviewed[item.file] = status[item.file] ~= "✓"
                end
                set_reviewed(root, target, reviewed)
                status = reviewed_status(root, target, files)
                picker.list:update({ force = true })
            end,
        },
        win = {
            input = { keys = { ["<c-r>"] = { "toggle_reviewed", mode = { "i", "n" } } } },
            list = { keys = { ["<c-r>"] = "toggle_reviewed" } },
        },
    })

    if structural then
        M.structural_status(base, root, function(result)
            semantic = result
            if not picker.closed then
                picker.list:update({ force = true })
            end
        end)
    end
end

-- Exported for tests and for other modules that share the state file.
M.git = git
M.repo_root = repo_root
M.rel_path = rel_path
M.load_state = load_state
M.save_state = save_state
M.have_snacks = have_snacks
M._reviewed_status = reviewed_status
M._mr_commits = mr_commits
M._enter_commit_mode = enter_commit_mode
M._commit_mode = function()
    return commit_mode
end

return M
