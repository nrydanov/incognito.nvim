local M = {}
-- Source owns the UI; Review is a persistent detached experiment on N.
-- range.R stays fixed while N moves. Off/exit retain the disk, never autosave.
---@type table?
local commit_mode = nil
local workspace = require("incognito.workspace")
local ranges = {}
local sources = {}

M.config = {
    remote = "origin",
    -- Tried as <remote>/<name>, then as local branches.
    targets = { "main", "master" },
    -- Ignored directories of the checkout (at any depth) linked into the
    -- commit mode worktree, and the lockfiles that tell whether they fit.
    commit_mode = {
        link = {},
        lockfiles = {
            "package-lock.json",
            "npm-shrinkwrap.json",
            "pnpm-lock.yaml",
            "yarn.lock",
            "bun.lock",
            "bun.lockb",
        },
    },
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

local function source_root()
    if commit_mode then
        return commit_mode.root
    end
    local root = repo_root()
    return sources[root] or root
end

local function have_snacks()
    if Snacks == nil then
        vim.notify("Incognito: snacks.nvim is required for pickers", vim.log.levels.ERROR)
        return false
    end
    return true
end

local function git(args, cwd, stdin)
    local opts = { cwd = cwd, text = not vim.tbl_contains(args, "-z"), stdin = stdin }
    local res = vim.system(vim.list_extend({ "git", "--no-pager" }, args), opts):wait()
    if res.code ~= 0 then
        return nil, vim.trim(res.stderr or "")
    end
    if vim.tbl_contains(args, "-z") then
        return res.stdout
    end
    return vim.trim(res.stdout)
end

local function resolve_commit(root, rev)
    -- Git can resolve an ambiguous ref successfully; never discard that warning.
    local res = vim.system({
        "git",
        "-c",
        "core.warnAmbiguousRefs=true",
        "rev-parse",
        "--verify",
        "--end-of-options",
        rev .. "^{commit}",
    }, { cwd = root, text = true, env = { LC_ALL = "C" } }):wait()
    if res.code ~= 0 or (res.stderr or ""):find("ambiguous", 1, true) then
        return nil
    end
    return vim.trim(res.stdout)
end

local function merge_base(target, root, head)
    local base, err = git({ "merge-base", target, head or "HEAD" }, root)
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

local function range_for(root)
    if ranges[root] then
        return ranges[root]
    end
    local saved = (load_state(root)[".ranges"] or {})[root]
    if saved then
        ranges[root] = saved
        return saved
    end
    local R = git({ "rev-parse", "--verify", "HEAD^{commit}" }, root)
    local target = resolve_target(root)
    local L = R and merge_base(target, root, R)
    if not L then
        return nil
    end
    return { target = target, L = L, R = R, owner = git({ "symbolic-ref", "-q", "HEAD" }, root) }
end

local function save_range(root, range)
    ranges[root] = range
    local state = load_state(root)
    state[".ranges"] = state[".ranges"] or {}
    state[".ranges"][root] = range
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

-- Commit review marks share the state file, but not the MR-wide file records.
local function marks_for(state, target, sha)
    if not sha then
        return state[target] or {}
    end
    local commits = (state[".commits"] or {})[target] or {}
    if commits[sha] then
        return commits[sha]
    end
    -- Keep existing marks only for the commit at which they were recorded.
    local marks = {}
    for file in pairs(state[target] or {}) do
        local mark = mark_of(state[target], file)
        if mark.head == sha then
            marks[file] = mark
        end
    end
    return marks
end

local function review_sha(root)
    if commit_mode and root == commit_mode.worktree then
        return commit_mode.selected
    end
end

local function reviewed_status(root, target, files)
    local marks = marks_for(load_state(root), target, review_sha(root))
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

-- Compare reviewed content with the commit, independently of the working tree.
local function commit_reviewed(root, sha, marks)
    local out = git({
        "diff-tree",
        "--root",
        "--no-commit-id",
        "--raw",
        "--no-abbrev",
        "-M",
        "--first-parent",
        "-m",
        "-r",
        "-z",
        sha,
    }, root)
    if not out or out == "" then
        return false
    end
    local fields = vim.split(out, "\0", { trimempty = true })
    local i = 1
    while i < #fields do
        local blob, status = fields[i]:match("^:%d+ %d+ %x+ (%x+) (%a)%d*$")
        local paths = (status == "R" or status == "C") and 2 or 1
        local mark = mark_of(marks, fields[i + paths])
        i = i + 1 + paths
        if not blob or not mark then
            return false
        end
        if status == "D" then
            if mark.blob or mark.head ~= sha then
                return false
            end
        elseif M.status_symbol(mark, blob) ~= "✓" then
            return false
        end
    end
    return true
end

local function rel_path(root)
    local name = vim.api.nvim_buf_get_name(0)
    if name == "" then
        return nil
    end
    return vim.fs.relpath(root, name)
end

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
        require("incognito.structdiff").disable()
        local gs = require("gitsigns")
        gs.toggle_signs(true)
        gs.toggle_linehl(true)
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

local function mr_commits(root, range)
    range = range or range_for(root)
    if not range then
        return nil
    end
    local out, err = git({ "log", "--reverse", "--format=%H%x09%h%x09%s", range.L .. ".." .. range.R }, root)
    if not out then
        vim.notify("Incognito: " .. err, vim.log.levels.ERROR)
        return nil
    end
    local commits = {}
    for _, line in ipairs(vim.split(out, "\n", { trimempty = true })) do
        local sha, short, subject = line:match("^(%x+)\t(%x+)\t(.*)$")
        commits[#commits + 1] = { sha = sha, short = short, subject = subject }
    end
    return commits
end

-- Stable Review ownership and Git lifecycle live in incognito.workspace.
local function commit_base(root, sha)
    return git({ "rev-parse", "--verify", sha .. "^1" }, root)
        or git({ "hash-object", "-t", "tree", "--stdin", "-w" }, root, "")
end

-- Dependencies are not in git, so the worktree borrows them from the
-- checkout: every ignored directory named in `link` gets a symlink at the
-- same place. Returns the linked paths.
local function link_ignored(root, worktree)
    local names = {}
    for _, name in ipairs(M.config.commit_mode.link or {}) do
        names[name] = true
    end
    if vim.tbl_isempty(names) then
        return {}
    end
    local out = git({ "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory" }, root) or ""
    local linked = {}
    for _, line in ipairs(vim.split(out, "\0", { trimempty = true })) do
        local rel = line:gsub("/$", "")
        local dest = vim.fs.joinpath(worktree, rel)
        local source = vim.fs.joinpath(root, rel)
        if
            names[vim.fs.basename(rel)]
            and vim.uv.fs_realpath(vim.fs.dirname(dest)) == vim.fs.dirname(dest)
            and vim.uv.fs_stat(vim.fs.dirname(dest))
            and (vim.uv.fs_readlink(dest) == source or (not vim.uv.fs_lstat(dest) and vim.uv.fs_symlink(source, dest)))
        then
            linked[#linked + 1] = rel
        end
    end
    return linked
end

-- Lockfiles that differ between the commit and the checkout: the linked
-- dependencies were installed for the latter, so LSP errors may be false.
local function lockfile_drift(root, sha)
    local specs = vim.tbl_map(function(name)
        return ":(glob)**/" .. name
    end, M.config.commit_mode.lockfiles or {})
    if #specs == 0 then
        return {}
    end
    local out = git(vim.list_extend({ "diff", "--name-only", sha, "--" }, specs), root) or ""
    return vim.split(out, "\n", { trimempty = true })
end

-- Buffers of files under `dir`.
local function buffers_in(dir)
    return vim.tbl_filter(function(bufnr)
        return vim.fs.relpath(dir, vim.api.nvim_buf_get_name(bufnr)) ~= nil
    end, vim.api.nvim_list_bufs())
end

-- Every window showing a file under `from` switches to the same file under
-- `to`, if it exists there, at the same cursor position. A window that
-- cannot leave its modified buffer ('nohidden') stays, as do those showing
-- a buffer in `keep`.
local function move_windows(from, to, keep)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        local rel = vim.bo[bufnr].buftype == ""
            and not (keep and keep[bufnr] ~= nil)
            and vim.fs.relpath(from, vim.api.nvim_buf_get_name(bufnr))
        local path = rel and vim.fs.joinpath(to, rel)
        if path and sources[to] and not workspace.safe_file(to, path) then
            vim.notify("Incognito: refusing to open Review symlink: " .. path, vim.log.levels.WARN)
        elseif path and vim.uv.fs_stat(path) then
            local cursor = vim.api.nvim_win_get_cursor(win)
            local target = vim.fn.bufadd(path)
            if
                pcall(vim.api.nvim_win_call, win, function()
                    vim.cmd("hide buffer " .. target)
                end)
            then
                vim.bo[target].buflisted = true
                pcall(vim.api.nvim_win_set_cursor, win, cursor)
            end
        end
    end
end

-- Move gitsigns (for every buffer when `global`) and, if on, structdiff to
-- `base`; `done` runs once gitsigns is through.
local function move_base(base, global, done)
    require("gitsigns").change_base(base, global, function(err)
        gitsigns_error(err)
        if done then
            vim.schedule(done)
        end
    end)
    local sd = require("incognito.structdiff")
    if sd.active() then
        sd.enable(base)
    end
end

-- Diff one buffer against `base` in gitsigns and structdiff. gitsigns
-- ignores a buffer it has not attached to yet, and has no public way to
-- tell, so its cache is asked; returns whether it took the base.
local function set_buf_base(bufnr, base)
    require("incognito.structdiff").set_buf_base(bufnr, base)
    local ok, cache = pcall(require, "gitsigns.cache")
    if not (ok and cache.cache[bufnr]) then
        return false
    end
    vim.api.nvim_buf_call(bufnr, function()
        require("gitsigns").change_base(base, false, gitsigns_error)
    end)
    return true
end

-- A checkout buffer next to a commit shows what changed after the commit.
-- Until gitsigns attaches, the GitSignsUpdate autocmd retries.
local function apply_tip_base(bufnr)
    local mode = assert(commit_mode)
    local sha = mode.selected
    mode.tip[bufnr] = set_buf_base(bufnr, sha) and sha or false
end

local function discard_buffers(path)
    -- Wipe the old buffer and undo history; never let old-N undo resurrect edits.
    local windows = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(win)
        local rel = vim.fs.relpath(path, vim.api.nvim_buf_get_name(b))
        if rel then
            windows[win] = { rel = rel, cursor = vim.api.nvim_win_get_cursor(win) }
        end
    end
    for _, b in ipairs(buffers_in(path)) do
        vim.api.nvim_buf_delete(b, { force = true })
    end
    return windows
end

local function restore_windows(path, windows)
    for win, old in pairs(windows or {}) do
        if vim.api.nvim_win_is_valid(win) then
            local file = vim.fs.joinpath(path, old.rel)
            if vim.uv.fs_stat(file) and workspace.safe_file(path, file) then
                local b = vim.fn.bufadd(file)
                vim.fn.bufload(b)
                vim.bo[b].buflisted = true
                vim.api.nvim_win_set_buf(win, b)
                pcall(vim.api.nvim_win_set_cursor, win, old.cursor)
            end
        end
    end
end

local function commit_info(root, sha)
    local out = git({ "show", "-s", "--format=%h%x09%s", sha }, root) or ""
    local short, subject = out:match("^(%x+)\t(.*)$")
    return { sha = sha, short = short or sha:sub(1, 7), subject = subject or "" }
end

local function show_commit(index, range, selected)
    local mode = assert(commit_mode)
    local commit = selected or mode.commits[index]
    if not commit then
        return false
    end
    if commit.sha ~= mode.ws.data.N then
        for _, buf in ipairs(buffers_in(mode.worktree)) do
            if vim.bo[buf].modified then
                vim.notify(
                    "Incognito: save unsaved Review edits with :w before switching: " .. vim.api.nvim_buf_get_name(buf),
                    vim.log.levels.WARN
                )
                return false
            end
        end
    end
    local windows
    local ok, err = workspace.transition(mode.ws, commit.sha, range or mode.range, function()
        windows = discard_buffers(mode.worktree)
    end)
    if not ok then
        restore_windows(mode.worktree, windows)
        vim.notify("Incognito: " .. err, vim.log.levels.ERROR)
        return false
    end
    mode.index, mode.selected, mode.current = index, commit.sha, commit
    mode.outside = index == nil
    mode.base = commit_base(mode.root, commit.sha)
    mode.generation = (mode.generation or 0) + 1
    local generation = mode.generation
    restore_windows(mode.worktree, windows)
    move_base(mode.base, true, function()
        if commit_mode == mode and mode.generation == generation then
            for bufnr in pairs(mode.tip) do
                if vim.api.nvim_buf_is_valid(bufnr) then
                    apply_tip_base(bufnr)
                end
            end
        end
    end)
    move_windows(mode.root, mode.worktree, mode.tip)
    vim.notify(
        ("Incognito: %s/%d %s %s; Review %s; ignored artifacts retained"):format(
            index or "outside range",
            #mode.commits,
            commit.short,
            commit.subject,
            mode.worktree
        )
    )
    if err then
        vim.notify("Incognito: " .. err, vim.log.levels.WARN)
    end
    local drift = #mode.linked > 0 and lockfile_drift(mode.root, commit.sha) or {}
    if #drift > 0 then
        vim.notify(
            "Incognito: " .. table.concat(drift, ", ") .. " differs from Source; linked dependencies may not fit N",
            vim.log.levels.WARN
        )
    end
    return true
end

local function enter_commit_mode(root, commits, index, range)
    range = range or range_for(root)
    if not range then
        return false
    end
    if not range.owner then
        vim.notify("Incognito: detached Source needs an explicit owner branch in head picker", vim.log.levels.ERROR)
        return false
    end
    local ws, err = workspace.open(root, range.owner, range, M.config.commit_mode)
    if not ws then
        vim.notify("Incognito: " .. err, vim.log.levels.ERROR)
        return false
    end
    -- Reopening preserves last N. Out-of-range N is explicit state, not a fake list entry.
    local selected
    if not index and ws.data.R == range.R then
        for i, c in ipairs(commits) do
            if c.sha == ws.data.N then
                index = i
            end
        end
        if not index then
            selected = commit_info(root, ws.data.N)
        end
    end
    if not index and not selected then
        for i, c in ipairs(commits) do
            if c.sha == range.R then
                index = i
            end
        end
        if not index then
            selected = commit_info(root, range.R)
        end
    end
    sources[ws.data.path] = root
    commit_mode = {
        root = root,
        worktree = ws.data.path,
        ws = ws,
        range = range,
        commits = commits,
        linked = {},
        tip = {},
    }
    if not show_commit(index, range, selected) then
        commit_mode = nil
        return false
    end
    ws.data.target, ws.data.L = range.target, range.L
    local persisted, persist_err = workspace.save(ws)
    if not persisted then
        vim.notify("Incognito: " .. persist_err, vim.log.levels.ERROR)
    end
    commit_mode.linked = link_ignored(root, ws.data.path)
    if #(M.config.commit_mode.link or {}) > 0 then
        vim.notify(
            "Incognito: opt-in dependency links are NOT isolated; external writes can modify Source",
            vim.log.levels.WARN
        )
    end
    local drift = #commit_mode.linked > 0 and lockfile_drift(root, commit_mode.selected) or {}
    if #drift > 0 then
        vim.notify(
            "Incognito: " .. table.concat(drift, ", ") .. " differs from Source; linked dependencies may not fit N",
            vim.log.levels.WARN
        )
    end
    local mode = commit_mode
    local group = vim.api.nvim_create_augroup("incognito", { clear = true })
    vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "GitSignsUpdate",
        callback = function(ev)
            local b = ev.data and ev.data.buffer
            if commit_mode == mode and b and mode.tip[b] == false then
                apply_tip_base(b)
            end
        end,
    })
    if not require("incognito.structdiff").active() then
        require("gitsigns").toggle_linehl(true)
    end
    save_range(root, range)
    return true
end

local function leave_commit_mode()
    local mode = assert(commit_mode)
    commit_mode = nil
    vim.api.nvim_clear_autocmds({ group = "incognito" })
    -- Keep modified buffers accessible and avoid nohidden errors; no autosave.
    local keep = {}
    for _, b in ipairs(buffers_in(mode.worktree)) do
        if vim.bo[b].modified then
            keep[b] = true
        end
    end
    move_windows(mode.worktree, mode.root, keep)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(win)
        if not vim.bo[b].modified and vim.fs.relpath(mode.worktree, vim.api.nvim_buf_get_name(b)) then
            vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
        end
    end
end

-- Where line `lnum` of `from` is in `to`, and whether it changed on the way:
-- a changed or deleted line lands on what took its place.
local function map_line(from, to, lnum)
    local a = table.concat(from, "\n") .. "\n"
    local b = table.concat(to, "\n") .. "\n"
    local offset = 0
    for _, hunk in ipairs(vim.diff(a, b, { result_type = "indices" })) do
        local sa, ca, sb, cb = unpack(hunk)
        -- A pure insertion (ca == 0) goes after line sa.
        if lnum < sa or (ca == 0 and lnum == sa) then
            break
        end
        if lnum < sa + ca then
            local target = cb > 0 and sb + math.min(lnum - sa, cb - 1) or sb + 1
            return math.max(1, math.min(target, #to)), true
        end
        offset = offset + cb - ca
    end
    return math.max(1, math.min(lnum + offset, #to)), false
end

-- Path of `rel` on the other side: from the commit to the working tree
-- (`to_tip`) or back. Same path, else a rename git sees; nil if absent.
local function counterpart(mode, rel, to_tip)
    if vim.uv.fs_stat(vim.fs.joinpath(to_tip and mode.root or mode.worktree, rel)) then
        return rel
    end
    local sha = mode.selected
    local out = git({ "diff", "-M", "--name-status", "-z", "--diff-filter=R", sha }, mode.root) or ""
    local fields = vim.split(out, "\0", { trimempty = true })
    for i = 1, #fields - 2, 3 do
        local old, new = fields[i + 1], fields[i + 2]
        if to_tip and old == rel then
            return new
        elseif not to_tip and new == rel then
            return old
        end
    end
    return nil
end

local function missing_message(mode, rel, to_tip)
    if not to_tip then
        return rel .. " is not in this commit yet"
    end
    local sha = mode.selected
    local gone = git({ "log", "-1", "--diff-filter=D", "--format=%h %s", sha .. "..HEAD", "--", rel }, mode.root)
    return rel .. (gone and gone ~= "" and " was deleted in " .. gone or " is not in your working tree")
end

--- In commit mode, switch the current window between the file at the
--- commit and the same file in the working tree, keeping the cursor on
--- the same line of code.
function M.toggle_tip()
    local mode = commit_mode
    if not mode then
        return vim.notify("Incognito: commit mode is off, enter it from the MR commits picker", vim.log.levels.WARN)
    end
    local bufnr = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(bufnr)
    local in_worktree = vim.fs.relpath(mode.worktree, name)
    local rel = in_worktree or vim.fs.relpath(mode.root, name)
    if not rel or vim.bo[bufnr].buftype ~= "" then
        return vim.notify("Incognito: current buffer is not a file of the review", vim.log.levels.WARN)
    end
    local to_tip = in_worktree ~= nil
    local other = counterpart(mode, rel, to_tip)
    if not other then
        return vim.notify("Incognito: " .. missing_message(mode, rel, to_tip), vim.log.levels.WARN)
    end

    local file = vim.fs.joinpath(to_tip and mode.root or mode.worktree, other)
    if not to_tip then
        local safe, why = workspace.safe_file(mode.worktree, file)
        if not safe then
            return vim.notify("Incognito: refusing Review symlink: " .. why, vim.log.levels.ERROR)
        end
    end
    local target = vim.fn.bufadd(file)
    vim.fn.bufload(target)
    local view = vim.fn.winsaveview()
    local lnum, changed = map_line(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        vim.api.nvim_buf_get_lines(target, 0, -1, false),
        view.lnum
    )
    local ok, err = pcall(vim.api.nvim_win_set_buf, 0, target)
    if not ok then
        return vim.notify("Incognito: " .. err, vim.log.levels.ERROR)
    end
    vim.bo[target].buflisted = true
    -- The line stays at the same height in the window.
    vim.fn.winrestview({ lnum = lnum, col = view.col, topline = math.max(1, lnum - (view.lnum - view.topline)) })

    local commit = mode.current
    local where
    if to_tip then
        apply_tip_base(target)
        where = "working tree"
        if not git({ "merge-base", "--is-ancestor", commit.sha, "HEAD" }, mode.root) then
            vim.notify(
                "Incognito: HEAD of your checkout no longer contains "
                    .. commit.short
                    .. ", so this is not its later state",
                vim.log.levels.WARN
            )
        end
    else
        -- Back with the other checkout buffers, against the commit parent.
        mode.tip[bufnr] = nil
        set_buf_base(bufnr, mode.base)
        where = ("%s/%d %s"):format(mode.index or "outside range", #mode.commits, commit.short)
    end
    vim.notify("Incognito: " .. where .. (changed and ", this line was changed after the commit" or ""))
end

--- Picker over the MR commits; confirming one enters commit mode on it
--- (or jumps there if commit mode is already on).
function M.commits()
    if not have_snacks() then
        return
    end
    local root = source_root()
    local commits = commit_mode and commit_mode.commits or mr_commits(root)
    if not commits then
        return
    end
    if #commits == 0 then
        return vim.notify("Incognito: no commits on top of " .. resolve_target(root), vim.log.levels.WARN)
    end

    local state = load_state(root)
    local target = resolve_target(root)
    local items = {}
    for i, c in ipairs(commits) do
        items[i] = {
            text = c.short .. " " .. c.subject,
            index = i,
            sha = c.sha,
            cwd = root,
            reviewed = commit_reviewed(root, c.sha, marks_for(state, target, c.sha)),
        }
    end
    local current_index = commit_mode and commit_mode.index
    if not current_index then
        local range = range_for(root)
        local saved = range and workspace.peek(root, range.owner)
        if saved then
            for i, c in ipairs(commits) do
                if c.sha == saved.N then
                    current_index = i
                end
            end
        end
    end
    current_index = current_index or #commits
    Snacks.picker.pick({
        source = "mr_commits",
        title = ("Review commits: target %s; L %s → R %s"):format(
            resolve_target(root),
            (range_for(root) or {}).L or "?",
            (range_for(root) or {}).R or "?"
        ),
        items = items,
        on_show = function(picker)
            picker.list:view(current_index)
        end,
        format = function(item)
            local c = commits[item.index]
            local current = commit_mode and commit_mode.index == item.index
            return {
                { item.reviewed and "✓ " or "  ", "SnacksPickerGitStatusAdded" },
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
    if not commit_mode.index then
        return vim.notify("Incognito: N is outside range; choose a commit or off", vim.log.levels.WARN)
    end
    local index = commit_mode.index + delta
    if index < 1 or index > #commit_mode.commits then
        return vim.notify("Incognito: no more commits", vim.log.levels.INFO)
    end
    show_commit(index)
end

-- Target is always resolved in Source. Changing only L never discards N.
local function use_base(root, rev)
    root = sources[root] or root
    local sha = resolve_commit(root, rev)
    if not sha then
        return vim.notify("Incognito: unknown/ambiguous revision " .. rev, vim.log.levels.ERROR)
    end
    local range = range_for(root)
    if not range then
        return
    end
    local L = merge_base(sha, root, range.R)
    if not L then
        return
    end
    range = vim.tbl_extend("force", range, { target = rev, L = L })
    update_state(root, BASE_KEY, rev)
    save_range(root, range)
    if commit_mode then
        local mode = commit_mode
        mode.range = range
        local commits = mr_commits(root, range)
        local index
        for i, c in ipairs(commits) do
            if c.sha == mode.selected then
                index = i
            end
        end
        if not index then
            vim.notify(
                "Incognito: N is outside the new range; choose a commit or off (experiment retained)",
                vim.log.levels.WARN
            )
            mode.outside = true
        else
            mode.outside = false
        end
        mode.commits, mode.index = commits, index
        mode.ws.data.target, mode.ws.data.L = rev, L
        local ok, err = workspace.save(mode.ws)
        if not ok then
            vim.notify("Incognito: " .. err, vim.log.levels.ERROR)
        end
    end
    if require("incognito.structdiff").active() then
        M.on_structural(rev)
    else
        M.on(rev)
    end
end

function M.change_head(rev, owner)
    local root = source_root()
    if not rev or rev == "" then
        return false
    end
    local R = resolve_commit(root, rev)
    if not R then
        vim.notify("Incognito: unknown/ambiguous revision " .. rev, vim.log.levels.ERROR)
        return false
    end
    local branch = git({ "rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", rev }, root)
    if branch and branch:match("^refs/heads/") then
        owner = branch
    end
    if branch and branch:match("^refs/remotes/") then
        owner = branch
    end
    owner = owner or git({ "symbolic-ref", "-q", "HEAD" }, root)
    if not owner then
        vim.notify("Incognito: select an owner branch for detached Source", vim.log.levels.ERROR)
        return false
    end
    if not owner:match("^refs/heads/") and not owner:match("^refs/remotes/") then
        owner = "refs/heads/" .. owner
    end
    if not git({ "show-ref", "--verify", owner }, root) then
        vim.notify("Incognito: invalid owner branch", vim.log.levels.ERROR)
        return false
    end
    local target = resolve_target(root)
    local L = merge_base(target, root, R)
    if not L then
        return false
    end
    local range = { target = target, L = L, R = R, owner = owner }
    local mode = commit_mode
    if mode and mode.range.owner == owner then
        if mode.range.R == R then
            return true
        end
        local commits = mr_commits(root, range)
        if not commits then
            return false
        end
        local old, index = mode.commits, mode.index
        mode.commits = commits
        local at
        for i, c in ipairs(commits) do
            if c.sha == R then
                at = i
            end
        end
        if not show_commit(at, range, not at and commit_info(root, R) or nil) then
            mode.commits, mode.index = old, index
            return false
        end
        mode.range = range
        save_range(root, range)
        return true
    end
    -- Prepare the other owner first; on failure the old mode and lock survive.
    commit_mode = nil
    local ok = enter_commit_mode(root, mr_commits(root, range), nil, range)
    local next_mode = commit_mode
    if not ok then
        commit_mode = mode
        return false
    end
    if mode then
        move_windows(mode.worktree, next_mode.worktree)
    end
    commit_mode = next_mode
    return true
end

function M.set_head()
    if not have_snacks() then
        return
    end
    local root = source_root()
    local items = {}
    local branches = git({ "for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes" }, root) or ""
    for _, ref in ipairs(vim.split(branches, "\n", { trimempty = true })) do
        items[#items + 1] = { text = ref, rev = ref, owner = ref }
    end
    -- Search all reachable commits, not merely the current review range.
    local log = git({ "log", "--all", "--format=%H%x09%s" }, root) or ""
    for _, line in ipairs(vim.split(log, "\n", { trimempty = true })) do
        local sha, subject = line:match("^(%x+)\t(.*)$")
        items[#items + 1] = { text = sha .. " " .. subject, rev = sha }
    end
    Snacks.picker.pick({
        source = "incognito_head",
        title = "Review head R: branch / revision / SHA",
        format = "text",
        items = items,
        confirm = function(picker, item)
            local typed = vim.trim(picker:filter().search)
            picker:close()
            local rev = item and item.rev or typed
            if rev == "" then
                return
            end
            local owner = item and item.owner or git({ "symbolic-ref", "-q", "HEAD" }, root)
            if owner then
                M.change_head(rev, owner)
            else
                local owners = {}
                for _, ref in ipairs(vim.split(branches, "\n", { trimempty = true })) do
                    owners[#owners + 1] = ref
                end
                vim.ui.select(owners, { prompt = "Review owner (Source remains detached):" }, function(choice)
                    if choice then
                        M.change_head(rev, choice)
                    end
                end)
            end
        end,
    })
end

function M.range()
    if not have_snacks() then
        return
    end
    local root = source_root()
    local range = range_for(root)
    if not range then
        return
    end
    Snacks.picker.pick({
        source = "incognito_range",
        title = "Clean range L → R (no experiments)",
        format = "text",
        items = { { text = ("target %s; L %s → R %s"):format(range.target, range.L, range.R), cwd = root } },
        preview = function(ctx)
            Snacks.picker.preview.cmd(
                { "git", "--no-pager", "diff", "--no-ext-diff", range.L, range.R },
                ctx,
                { ft = "diff" }
            )
        end,
    })
end

--- Branch picker for the review base. Typed text that matches no branch is
--- taken as a revision, so `HEAD~1` or a hash work as well.
function M.set_base()
    if not have_snacks() then
        return
    end
    local root = source_root()
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
            use_base(root, rev)
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
    local sha = review_sha(root)
    local marks = marks_for(state, target, sha)
    for file, on in pairs(reviewed) do
        marks[file] = on and { blob = ids[file], head = head } or nil
    end
    if sha then
        state[".commits"] = state[".commits"] or {}
        state[".commits"][target] = state[".commits"][target] or {}
        -- Keep an empty entry so removing a mark cannot revive a legacy mark.
        state[".commits"][target][sha] = marks
    else
        state[target] = not vim.tbl_isempty(marks) and marks or nil
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
    vim.notify("Incognito: " .. (on and "reviewed " or "unmarked ") .. vim.fs.basename(file))
end

function M.since_review(target)
    local root = repo_root()
    target = target or resolve_target(root)
    local file = rel_path(root)
    local mark = file and mark_of(marks_for(load_state(root), target, review_sha(root)), file)
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
    local items, seen = {}, {}
    local i = 1
    while i < #fields do
        local kind = fields[i]:sub(1, 1)
        local paths = (kind == "R" or kind == "C") and 2 or 1
        local file = fields[i + paths]
        i = i + 1 + paths
        items[#items + 1] = { cwd = root, file = file, text = file, status = " " .. kind }
        seen[file] = items[#items]
    end
    local untracked, untracked_err = git({ "ls-files", "--others", "--exclude-standard", "-z" }, root)
    if not untracked then
        return vim.notify("Incognito: " .. untracked_err, vim.log.levels.ERROR)
    end
    local base_files = {}
    if untracked ~= "" then
        local tree, why = git({ "ls-tree", "-r", "-z", base }, root)
        if not tree then
            return vim.notify("Incognito: " .. why, vim.log.levels.ERROR)
        end
        for _, entry in ipairs(vim.split(tree, "\0", { trimempty = true })) do
            local file = entry:match("^%d+ blob %x+\t(.*)$")
            if file then
                base_files[file] = true
            end
        end
    end
    for _, file in ipairs(vim.split(untracked, "\0", { trimempty = true })) do
        local item = seen[file]
        if not item then
            item = { cwd = root, file = file, text = file }
            items[#items + 1] = item
        end
        item.untracked, item.status = true, " A"
        local blob = base .. ":" .. file
        if base_files[file] then
            -- An untracked file can restore a path deleted or renamed since base.
            item.base_blob = blob
            local status, why =
                git({ "--literal-pathspecs", "diff", "--no-ext-diff", "--name-status", "-z", blob, "--", file }, root)
            if not status then
                return vim.notify("Incognito: " .. why, vim.log.levels.ERROR)
            end
            item.unchanged = status == ""
            item.status = " " .. status:sub(1, 1)
        end
    end
    items = vim.tbl_filter(function(item)
        return not item.unchanged
    end, items)
    return items, vim.tbl_map(function(item)
        return item.file
    end, items)
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

    local function guarded_jump(p, _, action)
        for _, item in ipairs(p:selected({ fallback = true })) do
            if sources[root] then
                local safe, why = workspace.safe_file(root, vim.fs.joinpath(root, item.file))
                if not safe then
                    vim.notify("Incognito: refusing Review symlink: " .. why, vim.log.levels.ERROR)
                    return
                end
            end
        end
        require("snacks.picker.actions").jump(p, nil, action or {})
    end

    local picker = Snacks.picker.pick({
        source = "mr_files",
        confirm = guarded_jump,
        title = (
            commit_mode and ("Commit + edits vs parent " .. base)
            or ("Source + edits vs L " .. base .. " (target " .. target .. ")")
        ) .. (structural and " (structural)" or ""),
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
            if sources[root] and not workspace.safe_file(root, vim.fs.joinpath(root, ctx.item.file)) then
                ctx.preview:set_lines({ "Review symlink: open Source explicitly; not an isolated writable file" })
                return
            end
            -- `git diff` runs GIT_EXTERNAL_DIFF unless told --no-ext-diff.
            local ext = structural and "--ext-diff" or "--no-ext-diff"
            local opts = structural and { env = difft_env({ DFT_DISPLAY = "inline", DFT_COLOR = "always" }) }
                or { ft = "diff" }
            if ctx.item.base_blob then
                Snacks.picker.preview.cmd(
                    { "git", "--no-pager", "--literal-pathspecs", "diff", ext, ctx.item.base_blob, "--", ctx.item.file },
                    ctx,
                    opts
                )
            elseif ctx.item.untracked then
                Snacks.picker.preview.cmd(
                    { "git", "--no-pager", "diff", "--no-index", ext, "--", "/dev/null", ctx.item.file },
                    ctx,
                    opts
                )
            else
                Snacks.picker.preview.cmd({ "git", "--no-pager", "diff", ext, base, "--", ctx.item.file }, ctx, opts)
            end
        end,
        actions = {
            jump = guarded_jump,
            edit = guarded_jump,
            -- Quickfix/location export must not bypass the lexical-path guard.
            qflist = function(p)
                for _, item in ipairs(p:items()) do
                    if sources[root] and not workspace.safe_file(root, vim.fs.joinpath(root, item.file)) then
                        return vim.notify(
                            "Incognito: Review symlink cannot be exported as an isolated writable file",
                            vim.log.levels.ERROR
                        )
                    end
                end
                require("snacks.picker.actions").qflist(p)
            end,
            qflist_all = function(p)
                for _, item in ipairs(p:items()) do
                    if sources[root] and not workspace.safe_file(root, vim.fs.joinpath(root, item.file)) then
                        return vim.notify("Incognito: Review symlink export refused", vim.log.levels.ERROR)
                    end
                end
                require("snacks.picker.actions").qflist_all(p)
            end,
            loclist = function(p)
                for _, item in ipairs(p:items()) do
                    if sources[root] and not workspace.safe_file(root, vim.fs.joinpath(root, item.file)) then
                        return vim.notify("Incognito: Review symlink export refused", vim.log.levels.ERROR)
                    end
                end
                require("snacks.picker.actions").loclist(p)
            end,
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
        local mode, generation = commit_mode, commit_mode and commit_mode.generation
        M.structural_status(base, root, function(result)
            if commit_mode ~= mode or (mode and mode.generation ~= generation) then
                return
            end
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
M._commit_reviewed = commit_reviewed
M._use_base = use_base
M._mr_commits = mr_commits
M._enter_commit_mode = enter_commit_mode
M._map_line = map_line
M._range_for = range_for
M._changed_items = changed_items
M._commit_base = commit_base
M._commit_mode = function()
    return commit_mode
end

return M
