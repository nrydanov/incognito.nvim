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
        vim.notify("MR review: snacks.nvim is required for pickers", vim.log.levels.ERROR)
        return false
    end
    return true
end

local function git(args, cwd)
    local res = vim.system(vim.list_extend({ "git", "--no-pager" }, args), { cwd = cwd, text = true }):wait()
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or "")
    end
    return vim.trim(res.stdout)
end

local function merge_base(target, root)
    local base, err = git({ "merge-base", target, "HEAD" }, root)
    if not base then
        vim.notify("MR review: " .. (err or "merge-base failed"), vim.log.levels.ERROR)
        return nil
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
        state_paths[root] = dir and vim.fs.joinpath(dir, "mr-review.json") or false
    end
    return state_paths[root] or nil
end

local function load_state(root)
    local path = state_path(root)
    if not path or not vim.uv.fs_stat(path) then
        return {}
    end
    local content = table.concat(vim.fn.readfile(path), "\n")
    local ok, decoded = pcall(vim.json.decode, content)
    if ok and type(decoded) == "table" then
        return decoded
    end
    -- Keep the broken file for the user instead of overwriting it later.
    vim.uv.fs_rename(path, path .. ".bad")
    vim.notify("MR review: " .. path .. " is not valid JSON, moved to " .. path .. ".bad", vim.log.levels.ERROR)
    return {}
end

local function save_state(root, state)
    local path = state_path(root)
    if not path then
        vim.notify("MR review: " .. root .. " is not a git repository", vim.log.levels.ERROR)
        return
    end
    -- Write and rename, so a crash never leaves half a file behind.
    local tmp = path .. ".tmp"
    if vim.fn.writefile({ vim.json.encode(state) }, tmp) ~= 0 then
        vim.notify("MR review: cannot write " .. tmp, vim.log.levels.ERROR)
        return
    end
    local ok, err = vim.uv.fs_rename(tmp, path)
    if not ok then
        vim.notify("MR review: " .. err, vim.log.levels.ERROR)
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
    local candidates = {}
    for _, name in ipairs(targets) do
        candidates[#candidates + 1] = remote .. "/" .. name
    end
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
    if not target_cache[root] then
        target_cache[root] = detect_target(root)
    end
    return target_cache[root]
end

local function store_target(root, target)
    local state = load_state(root)
    state[BASE_KEY] = target
    save_state(root, state)
end

-- A reviewed mark: { blob = id of the file content, head = HEAD sha }, both
-- taken when it was marked. Old marks were just the HEAD sha.
local function mark_of(marks, file)
    local mark = marks[file]
    if type(mark) == "string" then
        return { head = mark }
    end
    return mark
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
    if #present == 0 then
        return ids
    end
    local res = vim.system({ "git", "hash-object", "--stdin-paths" },
        { cwd = root, text = true, stdin = table.concat(present, "\n") .. "\n" }):wait()
    if res.code == 0 then
        local out = vim.split(res.stdout, "\n", { trimempty = true })
        for i, file in ipairs(present) do
            ids[file] = out[i]
        end
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

-- Commit mode: HEAD is detached at one commit of the MR and diffed against
-- its parent, so the buffers show exactly what that commit changed.
-- { ref = ref to return to, root, commits = { {sha, short, subject} } oldest
-- first, index = current commit, base = its parent }
---@type table?
local commit_mode = nil

local COMMIT_KEY = ".commit_mode"

-- Base to diff against and its name: the commit's parent in commit mode,
-- the merge base with `target` otherwise.
local function current_base(root, target)
    if commit_mode and commit_mode.root == root then
        return commit_mode.base, "the commit parent"
    end
    return merge_base(target, root), target
end

local stale_warned = false

-- A session that died in commit mode leaves HEAD detached; say how to go back.
local function warn_stale_commit_mode(root)
    if commit_mode or stale_warned then
        return
    end
    local state = load_state(root)
    local saved = state[COMMIT_KEY]
    if type(saved) ~= "table" or type(saved.ref) ~= "string" then
        return
    end
    if git({ "symbolic-ref", "-q", "HEAD" }, root) then
        state[COMMIT_KEY] = nil -- HEAD is back on a branch
        save_state(root, state)
        return
    end
    stale_warned = true
    vim.notify("MR review: HEAD is still detached by an earlier commit mode, run `git checkout "
        .. saved.ref .. "`", vim.log.levels.WARN)
end

function M.on(target)
    local root = repo_root()
    warn_stale_commit_mode(root)
    target = target or resolve_target(root)
    local base, name = current_base(root, target)
    if not base then
        return
    end

    local gs = require("gitsigns")
    gs.change_base(base, true)
    gs.toggle_linehl(true)
    vim.notify("MR review: diffing against " .. name)
end

--- Same as `on`, but marks come from difftastic: lines that only changed
--- formatting stay clean. gitsigns keeps the base for stage/reset, its own
--- signs go quiet so the two don't disagree in the sign column.
function M.on_structural(target)
    local root = repo_root()
    target = target or resolve_target(root)
    local base, name = current_base(root, target)
    if not base then
        return
    end

    local gs = require("gitsigns")
    gs.change_base(base, true)
    gs.toggle_linehl(false)
    gs.toggle_signs(false)
    require("mrview.structdiff").enable(base)
    vim.notify("MR review (structural): diffing against " .. name)
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

-- Checkout rewrites files under open buffers, so nothing may be unsaved
-- or uncommitted when HEAD starts moving.
local function can_enter(root)
    if git({ "status", "--porcelain", "--untracked-files=no" }, root) ~= "" then
        vim.notify("MR review: commit the changes in the working tree first", vim.log.levels.ERROR)
        return false
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].modified and vim.bo[bufnr].buftype == "" then
            vim.notify("MR review: save the modified buffers first", vim.log.levels.ERROR)
            return false
        end
    end
    return true
end

local function show_commit(index)
    local mode = assert(commit_mode)
    local commit = mode.commits[index]
    local _, err = git({ "checkout", "--quiet", "--detach", commit.sha }, mode.root)
    if err then
        vim.notify("MR review: " .. err, vim.log.levels.ERROR)
        return false
    end
    mode.index = index
    mode.base = git({ "rev-parse", commit.sha .. "^" }, mode.root)
    vim.cmd.checktime()

    require("gitsigns").change_base(mode.base, true)
    local sd = require("mrview.structdiff")
    if sd.active() then
        sd.enable(mode.base)
    end
    vim.notify(("MR review: %d/%d %s %s"):format(index, #mode.commits, commit.short, commit.subject))
    return true
end

-- Remember the ref to return to, in the state file and for :qa.
local function enter_commit_mode(root, ref, commits, index)
    commit_mode = { ref = ref, root = root, commits = commits }
    if not show_commit(index) then
        commit_mode = nil
        return
    end
    local state = load_state(root)
    state[COMMIT_KEY] = { ref = ref, root = root }
    save_state(root, state)
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("mr_review", { clear = true }),
        callback = function()
            if commit_mode then
                git({ "checkout", "--quiet", commit_mode.ref }, commit_mode.root)
            end
        end,
    })
    -- Without a review mode on, fall back to the gitsigns one.
    if not require("mrview.structdiff").active() then
        require("gitsigns").toggle_linehl(true)
    end
end

--- Picker over the MR commits; confirming one enters commit mode on it
--- (or jumps there if commit mode is already on).
function M.commits()
    if not have_snacks() then
        return
    end
    local root = commit_mode and commit_mode.root or repo_root()
    warn_stale_commit_mode(root)
    local commits = commit_mode and commit_mode.commits or mr_commits(root)
    if not commits then
        return
    end
    if #commits == 0 then
        vim.notify("MR review: no commits on top of " .. resolve_target(root), vim.log.levels.WARN)
        return
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
                { ("%d/%d"):format(item.index, #commits), current and "SnacksPickerGitBranchCurrent" or "SnacksPickerComment" },
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
            elseif can_enter(root) then
                local ref = git({ "symbolic-ref", "--short", "-q", "HEAD" }, root) or git({ "rev-parse", "HEAD" }, root)
                enter_commit_mode(root, ref, commits, item.index)
            end
        end,
    })
end

--- Step to the next (1) or previous (-1) commit in commit mode.
function M.step_commit(delta)
    if not commit_mode then
        vim.notify("MR review: commit mode is off, enter it from the MR commits picker", vim.log.levels.WARN)
        return
    end
    local index = commit_mode.index + delta
    if index < 1 or index > #commit_mode.commits then
        vim.notify("MR review: no more commits", vim.log.levels.INFO)
        return
    end
    show_commit(index)
end

--- Refs (branches, remotes, tags), then the last commits of HEAD as HEAD~k.
local function base_items(root)
    local items = {}
    local function add(rev, subject)
        items[#items + 1] = { text = rev .. " " .. subject, rev = rev, subject = subject, cwd = root }
    end

    local refs = git({ "for-each-ref", "--format=%(refname)%09%(refname:short)%09%(subject)",
        "refs/heads", "refs/remotes", "refs/tags" }, root) or ""
    for _, line in ipairs(vim.split(refs, "\n", { trimempty = true })) do
        local full, short, subject = line:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
        if full and not full:match("/HEAD$") then
            add(short, subject)
        end
    end

    local log = git({ "log", "-n", "20", "--skip=1", "--format=%s", "HEAD" }, root) or ""
    for k, subject in ipairs(vim.split(log, "\n", { trimempty = true })) do
        add("HEAD~" .. k, subject)
    end
    return items
end

function M.set_base()
    if not have_snacks() then
        return
    end
    local root = repo_root()
    Snacks.picker.pick({
        source = "mr_base",
        title = "MR review base",
        items = base_items(root),
        format = function(item)
            return { { item.rev, "SnacksPickerGitBranch" }, { " " }, { item.subject, "SnacksPickerComment" } }
        end,
        preview = function(ctx)
            Snacks.picker.preview.cmd(
                { "git", "--no-pager", "log", "--oneline", "--decorate", "-n", "30", ctx.item.rev },
                ctx,
                { ft = "git" }
            )
        end,
        confirm = function(picker, item)
            -- Nothing matched: take the typed text as a revision, e.g. a hash.
            local typed = vim.trim(picker:filter().search)
            picker:close()
            local branch = item and item.rev
            if not branch and typed ~= "" then
                if not git({ "rev-parse", "--verify", "--quiet", typed }, root) then
                    vim.notify("MR review: unknown revision " .. typed, vim.log.levels.ERROR)
                    return
                end
                branch = typed
            end
            if not branch then
                return
            end
            store_target(root, branch)
            M.on(branch)
        end,
    })
end

function M.off()
    if commit_mode then
        local root = commit_mode.root
        local _, err = git({ "checkout", "--quiet", commit_mode.ref }, root)
        if err then
            -- Stay in commit mode: the ref to return to is still needed.
            vim.notify("MR review: " .. err, vim.log.levels.ERROR)
            return
        end
        commit_mode = nil
        vim.api.nvim_clear_autocmds({ group = "mr_review" })
        local state = load_state(root)
        state[COMMIT_KEY] = nil
        save_state(root, state)
        vim.cmd.checktime()
    end
    require("mrview.structdiff").disable()
    local gs = require("gitsigns")
    gs.change_base(nil, true)
    gs.toggle_linehl(false)
    gs.toggle_signs(true)
    vim.notify("MR review: off")
end

--- Mark `files` as reviewed at their present content, or unmark them.
local function set_reviewed(root, target, files, reviewed)
    local head = reviewed and git({ "rev-parse", "HEAD" }, root)
    local ids = reviewed and blob_ids(root, files) or {}
    local state = load_state(root)
    state[target] = state[target] or {}
    for _, file in ipairs(files) do
        state[target][file] = reviewed and { blob = ids[file], head = head } or nil
    end
    if vim.tbl_isempty(state[target]) then
        state[target] = nil
    end
    save_state(root, state)
end

--- Import the state file of the pre-plugin version, which lived under
--- stdpath("state") keyed by a slug of the repo path and stored marks as
--- the HEAD sha alone. Marks get the blob of the file at that commit, so a
--- file untouched since the review stays current; comments are appended.
--- The old file is renamed to .migrated afterwards.
function M.migrate(root)
    root = root or repo_root()
    local old_path = vim.fs.joinpath(vim.fn.stdpath("state"), "mr-review", (root:gsub("[^%w]", "_")) .. ".json")
    if not vim.uv.fs_stat(old_path) then
        return vim.notify("MR review: nothing to migrate for " .. root, vim.log.levels.WARN)
    end
    local ok, old = pcall(vim.json.decode, table.concat(vim.fn.readfile(old_path), "\n"))
    if not ok or type(old) ~= "table" then
        return vim.notify("MR review: " .. old_path .. " is not valid JSON", vim.log.levels.ERROR)
    end

    local state = load_state(root)
    local marks, comments = 0, 0
    for key, value in pairs(old) do
        if key == ".comments" then
            state[key] = vim.list_extend(state[key] or {}, value)
            comments = #value
        elseif key:sub(1, 1) == "." then
            state[key] = state[key] == nil and value or state[key]
        else
            state[key] = state[key] or {}
            for file, sha in pairs(value) do
                if type(sha) == "string" and not state[key][file] then
                    state[key][file] = { blob = git({ "rev-parse", "--verify", "--quiet", sha .. ":" .. file }, root), head = sha }
                    marks = marks + 1
                end
            end
        end
    end
    save_state(root, state)
    vim.uv.fs_rename(old_path, old_path .. ".migrated")
    vim.notify(("MR review: migrated %d marks and %d comments from %s"):format(marks, comments, old_path))
end

function M.toggle_reviewed(target)
    local root = repo_root()
    target = target or resolve_target(root)
    local file = rel_path(root)
    if not file then
        vim.notify("MR review: current buffer is not a file in " .. root, vim.log.levels.WARN)
        return
    end

    -- Only a current mark (✓) is taken back; a stale (~) or unknown (?) one
    -- is refreshed to the present content, since re-reading the file is what
    -- one just did.
    if reviewed_status(root, target, { file })[file] == "✓" then
        set_reviewed(root, target, { file }, false)
        vim.notify("MR review: " .. file .. " unmarked")
    else
        set_reviewed(root, target, { file }, true)
        vim.notify("MR review: " .. file .. " reviewed")
    end
end

function M.since_review(target)
    local root = repo_root()
    target = target or resolve_target(root)
    local file = rel_path(root)
    local mark = file and mark_of(load_state(root)[target] or {}, file)
    local sha = mark and mark.head
    if not sha then
        vim.notify("MR review: " .. (file or "buffer") .. " was never reviewed", vim.log.levels.WARN)
        return
    end

    require("gitsigns").change_base(sha, false)
    local sd = require("mrview.structdiff")
    if sd.active() then
        sd.enable(sha)
    end
    vim.notify("MR review: showing changes since your review")
end

local function changed_items(base, root)
    local out, err = git({ "diff", "--name-status", "-z", base }, root)
    if not out then
        vim.notify("MR review: " .. (err or "diff failed"), vim.log.levels.ERROR)
        return nil
    end

    local fields = vim.split(out, "\0", { trimempty = true })
    local items, files = {}, {}
    local i = 1
    while i < #fields do
        local status, file = fields[i], fields[i + 1]
        i = i + 2
        local kind = status:sub(1, 1)
        if kind == "R" or kind == "C" then
            file = fields[i]
            i = i + 1
        end
        items[#items + 1] = { cwd = root, file = file, text = file, status = " " .. kind }
        files[#files + 1] = file
    end
    return items, files
end

-- difft as git's external diff engine: one process for the whole MR, and git
-- handles renames and new files for us.
local function difft_env(extra)
    local cmd = require("mrview.structdiff").config.difft_cmd
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
    local root = repo_root()
    target = target or resolve_target(root)
    -- In commit mode the working tree sits at the commit, so diffing its
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
    local structural = require("mrview.structdiff").active()
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
            if structural then
                Snacks.picker.preview.cmd(
                    { "git", "--no-pager", "diff", base, "--", ctx.item.file },
                    ctx,
                    { env = difft_env({ DFT_DISPLAY = "inline", DFT_COLOR = "always" }) }
                )
                return
            end
            Snacks.picker.preview.cmd(
                { "git", "--no-pager", "diff", "--no-ext-diff", base, "--", ctx.item.file },
                ctx,
                { ft = "diff" }
            )
        end,
        actions = {
            toggle_reviewed = function(picker)
                local selected = picker:selected({ fallback = true })

                -- Toggle each file on its own: current marks (✓) come off,
                -- stale (~), unknown (?) and missing ones get the present content.
                local to_mark, to_unmark = {}, {}
                for _, item in ipairs(selected) do
                    local bucket = status[item.file] == "✓" and to_unmark or to_mark
                    bucket[#bucket + 1] = item.file
                end

                if #to_mark > 0 then
                    set_reviewed(root, target, to_mark, true)
                end
                if #to_unmark > 0 then
                    set_reviewed(root, target, to_unmark, false)
                end

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

-- Shared with config.mr_comment, which keeps its queue in the same state file.
M.git = git
M.repo_root = repo_root
M.rel_path = rel_path
M.load_state = load_state
M.save_state = save_state
M.have_snacks = have_snacks
M._reviewed_status = reviewed_status

return M
