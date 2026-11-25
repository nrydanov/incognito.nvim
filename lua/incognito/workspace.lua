-- Persistent Review worktrees; never removed automatically.
local M = {}
local uv = vim.uv
local held = {}

local function git(args, root, opts)
    local r = vim.system(
        vim.list_extend({ "git", "--no-pager", "-c", "core.hooksPath=/dev/null" }, args),
        vim.tbl_extend("force", { cwd = root, text = not vim.tbl_contains(args, "-z") }, opts or {})
    ):wait()
    if r.code ~= 0 then
        local reason = vim.trim((r.stderr or "") .. "\n" .. (r.stdout or ""))
        return nil, reason ~= "" and reason or ("git %s exited with %d"):format(args[1], r.code)
    end
    -- Leading/trailing whitespace belongs to NUL-delimited path names.
    local out = r.stdout
    if not vim.tbl_contains(args, "-z") then
        out = out:gsub("\n$", "")
    end
    return out
end

local function read(path)
    local ok, data = pcall(function()
        return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    end)
    return ok and type(data) == "table" and data or nil
end

local function write(path, data)
    local tmp = path .. ".tmp"
    if uv.fs_lstat(tmp) then
        return nil, "temporary metadata already exists: " .. tmp
    end
    if vim.fn.writefile({ vim.json.encode(data) }, tmp) ~= 0 then
        return nil, "cannot write " .. tmp
    end
    return uv.fs_rename(tmp, path)
end

local function inside(root, path)
    return path == root or vim.startswith(path, root .. "/")
end

local function safe_layout(source, common, path)
    -- Only our dedicated checkout directory may be nested in Git metadata.
    -- In particular, never use Git's administrative `worktrees/` directory.
    local private = vim.fs.dirname(path) == vim.fs.joinpath(common, "incognito")
    return not inside(path, source) and (private or (not inside(source, path) and not inside(common, path)))
end

local function plain_path(path)
    if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
        return nil, "Review path must be absolute"
    end
    local p = path
    while p and p ~= "/" do
        local s = uv.fs_lstat(p)
        if s and s.type == "link" then
            return nil, "symlink in Review path: " .. p
        end
        p = vim.fs.dirname(p)
    end
    return true
end

local function identity(pid)
    local ok, value = pcall(function()
        local stat = table.concat(vim.fn.readfile("/proc/" .. pid .. "/stat"), "")
        local fields = vim.split(assert(stat:match("^%d+ %b() (.*)$")), " ")
        return vim.fn.readfile("/proc/sys/kernel/random/boot_id")[1] .. ":" .. fields[20]
    end)
    return ok and value or nil
end

local function acquire_inner(path)
    local ok = uv.fs_mkdir(path, 448)
    if not ok then
        local old = read(path .. "/owner.json")
        if not old or old.host ~= uv.os_gethostname() or type(old.pid) ~= "number" then
            return nil, "Review lock is unverified; inspect manually: " .. path
        end
        local _, _, code = uv.kill(old.pid, 0)
        local actual = identity(old.pid)
        if code ~= "ESRCH" and not (actual and old.identity and actual ~= old.identity) then
            return nil, "Review is in use (or owner inaccessible): " .. path
        end
        if not plain_path(path) then
            return nil, "symlink lock refused"
        end
        if not uv.fs_unlink(path .. "/owner.json") or not uv.fs_rmdir(path) or not uv.fs_mkdir(path, 448) then
            return nil, "cannot reclaim Review lock: " .. path
        end
    end
    local owner = { pid = vim.fn.getpid(), host = uv.os_gethostname(), identity = identity(vim.fn.getpid()) }
    local saved, err = write(path .. "/owner.json", owner)
    if not saved then
        return nil, err
    end
    return owner
end

local function acquire(path)
    local gate = path .. ".gate"
    if not uv.fs_mkdir(gate, 448) then
        return nil, "Review lock gate busy; inspect if stale: " .. gate
    end
    local ok, owner, err = pcall(acquire_inner, path)
    uv.fs_rmdir(gate)
    if not ok then
        return nil, owner
    end
    return owner, err
end

local function release(ws)
    if not ws or not ws.lock then
        return
    end
    local owner = read(ws.lock .. "/owner.json")
    if owner and vim.deep_equal(owner, ws.lock_owner) and plain_path(ws.lock) then
        uv.fs_unlink(ws.lock .. "/owner.json")
        uv.fs_rmdir(ws.lock)
    end
    held[ws.manifest] = nil
    ws.lock = nil
end

function M.save(ws)
    return write(ws.manifest, ws.data)
end

function M.validate(ws)
    local d = ws.data
    local disk = read(ws.manifest)
    if not disk or disk.phase ~= d.phase or disk.N ~= d.N or disk.R ~= d.R then
        return nil, "Review manifest changed or transition persistence failed; inspect manually"
    end
    local ok, err = plain_path(d.path)
    if not ok then
        return nil, err
    end
    if not ws.lock or not vim.deep_equal(read(ws.lock .. "/owner.json"), ws.lock_owner) then
        return nil, "Review lock changed"
    end
    if not plain_path(ws.manifest) or not plain_path(d.gitdir or "") then
        return nil, "symlink in Review metadata"
    end
    if uv.fs_realpath(d.path) ~= d.path or not safe_layout(d.source, d.common, d.path) then
        return nil, "unsafe Review/Source paths"
    end
    local common = git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, d.path)
    if git({ "rev-parse", "--show-toplevel" }, d.path) ~= d.path or uv.fs_realpath(common or "") ~= d.common then
        return nil, "Review Git registration no longer matches its manifest"
    end
    local admin = git({ "rev-parse", "--absolute-git-dir" }, d.path)
    local source_admin = git({ "rev-parse", "--absolute-git-dir" }, d.source)
    local dotgit = vim.fs.joinpath(d.path, ".git")
    local read_ok, back = pcall(vim.fn.readfile, (d.gitdir or "") .. "/gitdir")
    back = read_ok and back or {}
    if not d.gitdir or admin ~= d.gitdir or admin == source_admin or back[1] ~= dotgit then
        return nil, "Review administrative directory ownership mismatch"
    end
    local registered = git({ "worktree", "list", "--porcelain", "-z" }, d.source) or ""
    if not registered:find("worktree " .. d.path .. "\0", 1, true) then
        return nil, "Review is not registered"
    end
    if git({ "symbolic-ref", "-q", "HEAD" }, d.path) then
        return nil, "Review HEAD is no longer detached"
    end
    if git({ "rev-parse", "HEAD" }, d.path) ~= d.N then
        return nil, "Review HEAD changed externally; resolve manually"
    end
    local unmerged = git({ "ls-files", "--unmerged", "-z" }, d.path)
    if not unmerged or unmerged ~= "" then
        return nil, "Review has an unmerged index; resolve manually"
    end
    for _, name in ipairs({
        "rebase-merge",
        "rebase-apply",
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "BISECT_LOG",
    }) do
        local path = git({ "rev-parse", "--path-format=absolute", "--git-path", name }, d.path)
        if not path then
            return nil, "cannot inspect external Git operation state"
        end
        if uv.fs_stat(path) then
            return nil, "Review has an external Git operation: " .. name
        end
    end
    if d.phase ~= "ready" then
        return nil, "interrupted Review transition; inspect " .. ws.manifest
    end
    return true
end

local function scan(root)
    local device = assert(uv.fs_stat(root)).dev
    local function visit(dir)
        local iter = uv.fs_scandir(dir)
        if not iter then
            return nil, "cannot inspect " .. dir
        end
        while true do
            local name = uv.fs_scandir_next(iter)
            if not name then
                break
            end
            local path = vim.fs.joinpath(dir, name)
            local st = uv.fs_lstat(path)
            if not st then
                return nil, "cannot inspect " .. path
            end
            if name == ".git" and dir ~= root then
                return nil, "nested Git/submodule: " .. dir
            end
            if st.dev ~= device then
                return nil, "mount in Review: " .. path
            end
            if st.type == "directory" and name ~= ".git" then
                local ok, err = visit(path)
                if not ok then
                    return nil, err
                end
            end
        end
        return true
    end
    local ok, mounts = pcall(vim.fn.readfile, "/proc/self/mountinfo")
    if ok then
        for _, line in ipairs(mounts) do
            local path = vim.split(line, " ")[5]
            path = path
                and path:gsub("\\(%d%d%d)", function(n)
                    return string.char(tonumber(n, 8))
                end)
            if path and path ~= root and inside(root, path) then
                return nil, "mount in Review: " .. path
            end
        end
    end
    return visit(root)
end

local function ignored_collision(ignored, target)
    local files, dirs = {}, {}
    for _, path in ipairs(target) do
        files[path] = true
        for slash in path:gmatch("()/") do
            dirs[path:sub(1, slash - 1)] = true
        end
    end
    for _, path in ipairs(ignored) do
        if files[path] or dirs[path] then
            return path
        end
        for slash in path:gmatch("()/") do
            if files[path:sub(1, slash - 1)] then
                return path
            end
        end
    end
end

-- Build a stash without pushing to refs/stash, which is shared with Source.
-- Git's stash create captures both tracked trees. Like stash push -u, add a
-- third parent for untracked files, using a temporary, initially empty index.
local function save_stash(d)
    local index = vim.fn.tempname()
    local paths
    local function run(args, opts)
        local out, err = git(args, d.path, opts)
        if not out then
            error(err, 0)
        end
        return out
    end
    local function commit(tree, parents)
        return run(vim.list_extend({
            "-c",
            "user.name=Incognito",
            "-c",
            "user.email=incognito@localhost",
            "commit-tree",
            tree,
            "-m",
            "Incognito Review edits",
        }, parents))
    end
    local ok, result = pcall(function()
        if run({ "status", "--porcelain=v1", "--untracked-files=all", "-z" }) == "" then
            return nil
        end
        local stash = run({ "stash", "create", "Incognito Review edits" })
        paths = run({ "ls-files", "--others", "--exclude-standard", "-z" })
        if paths ~= "" then
            local env = { GIT_INDEX_FILE = index }
            run({ "update-index", "--add", "-z", "--stdin" }, { env = env, stdin = paths })
            if run({ "ls-files", "-z" }, { env = env }) ~= paths then
                error("Git could not capture every untracked Review file", 0)
            end
            local untracked = commit(run({ "write-tree" }, { env = env }), {})
            local tree = run({ "rev-parse", (stash ~= "" and stash or d.N) .. "^{tree}" })
            local staged = stash ~= "" and run({ "rev-parse", stash .. "^2" }) or commit(tree, { "-p", d.N })
            stash = commit(tree, { "-p", d.N, "-p", staged, "-p", untracked })
        end
        if stash == "" then
            return nil
        end
        local ref = "refs/worktree/incognito-stashes/" .. stash
        run({ "update-ref", ref, stash })
        return ref
    end)
    uv.fs_unlink(index)
    if not ok then
        return nil, result
    end
    return result, nil, paths
end

function M.transition(ws, sha, range, before_reset)
    local ok, err = M.validate(ws)
    if not ok then
        return nil, err
    end
    local d = ws.data
    if sha == d.N then
        if range and range.R ~= d.R then
            d.R, d.L, d.target = range.R, range.L, range.target
            return M.save(ws)
        end
        return true
    end
    if git({ "rev-parse", "--verify", "--end-of-options", sha .. "^{commit}" }, d.source) ~= sha then
        return nil, "invalid transition commit"
    end
    ok, err = scan(d.path)
    if not ok then
        return nil, err
    end
    local flags, flags_err = git({ "ls-files", "-v", "-z" }, d.path)
    local sparse, sparse_err =
        git({ "config", "--default", "false", "--type=bool", "--get", "core.sparseCheckout" }, d.path)
    if not flags or not sparse then
        return nil, "cannot inspect sparse/index state: " .. (flags_err or sparse_err)
    end
    if sparse == "true" then
        return nil, "sparse Review requires manual Git handling"
    end
    for _, entry in ipairs(vim.split(flags, "\0", { trimempty = true })) do
        local flag = entry:sub(1, 1)
        if flag == "S" or flag:match("%l") then
            return nil, "skip-worktree/assume-unchanged Review paths require manual handling"
        end
    end
    local ignored, ignored_err = git({ "ls-files", "--others", "--ignored", "--exclude-standard", "-z" }, d.path)
    local target, target_err = git({ "ls-tree", "-r", "--name-only", "-z", sha }, d.path)
    if not ignored or not target then
        return nil, "preflight failed: " .. (ignored_err or target_err or "Git read failed")
    end
    local current_modes, modes_err = git({ "ls-files", "--stage" }, d.path)
    local next_modes, next_err = git({ "ls-tree", "-r", sha }, d.path)
    if not current_modes or not next_modes then
        return nil, "preflight failed: " .. (modes_err or next_err)
    end
    if
        current_modes:match("^160000 ")
        or current_modes:find("\n160000 ")
        or next_modes:match("^160000 ")
        or next_modes:find("\n160000 ")
    then
        return nil, "submodule transition requires manual Git handling"
    end
    target = vim.split(target, "\0", { trimempty = true })
    local collision = ignored_collision(vim.split(ignored, "\0", { trimempty = true }), target)
    if collision then
        return nil, "ignored artifact collides with target: " .. collision
    end
    for _, rel in ipairs(target) do
        local p = vim.fs.dirname(vim.fs.joinpath(d.path, rel))
        while p ~= d.path do
            local st = uv.fs_lstat(p)
            if st and st.type == "link" then
                return nil, "symlink target ancestor: " .. p
            end
            p = vim.fs.dirname(p)
        end
    end
    local stash, stash_err, untracked = save_stash(d)
    if stash_err then
        return nil, "could not save Review edits: " .. stash_err
    end
    d.phase, d.pending, d.stash = "transition", sha, stash
    ok, err = M.save(ws)
    if not ok then
        return nil, err
    end
    if before_reset then
        before_reset()
    end
    -- Remove just the files saved in the third parent so apply can restore them.
    for _, rel in ipairs(vim.split(untracked or "", "\0", { trimempty = true })) do
        local path = vim.fs.joinpath(d.path, rel)
        local safe, why = plain_path(vim.fs.dirname(path))
        if not safe then
            return nil, why
        end
        local removed, remove_err = uv.fs_unlink(path)
        if not removed then
            return nil, "Review edits saved at " .. stash .. ": " .. remove_err
        end
    end
    local _, checkout_err =
        git({ "checkout", "--quiet", stash and "--force" or "--no-overwrite-ignore", "--detach", sha }, d.path)
    if checkout_err then
        return nil, "transition interrupted (no rollback): " .. checkout_err
    end
    if git({ "rev-parse", "HEAD" }, d.path) ~= sha or git({ "diff", "--name-only", sha }, d.path) ~= "" then
        return nil, "transition verification failed; inspect manually"
    end
    local warning
    if stash then
        local _, apply_err = git({ "stash", "apply", "--index", stash }, d.path)
        if apply_err and git({ "status", "--porcelain=v1", "--untracked-files=all", "-z" }, d.path) == "" then
            -- An index patch can fail before Git starts its three-way merge.
            -- Retry on the pristine target so conflicting edits appear in the file.
            local _, merge_err = git({ "-c", "stash.index=false", "stash", "apply", stash }, d.path)
            apply_err = merge_err or ("Staging could not be restored: " .. apply_err)
        end
        if apply_err then
            warning = "Could not fully apply Review edits. Inspect git status in "
                .. d.path
                .. ". Original stash retained at "
                .. stash
                .. ": "
                .. apply_err
        end
    end
    d.N, d.phase, d.pending, d.stash = sha, "ready", nil, nil
    if range then
        d.R, d.L, d.target = range.R, range.L, range.target
    end
    ok, err = M.save(ws)
    if not ok then
        return nil, err
    end
    if stash and not warning then
        local _, drop_err = git({ "update-ref", "-d", stash, vim.fs.basename(stash) }, d.path)
        if drop_err then
            warning = "Review edits applied; backup retained at " .. stash .. ": " .. drop_err
        end
    end
    return true, warning
end

local guarded = {}

function M.safe_file(root, path)
    if not inside(root, path) then
        return nil, "path outside Review"
    end
    return plain_path(path)
end
local group = vim.api.nvim_create_augroup("incognito_review_write", { clear = true })
-- Persistent undo is never loaded/written for Review buffers: a previous N's
-- undo file must not resurrect discarded experiments after a transition.
vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
    group = group,
    callback = function(ev)
        local name = vim.api.nvim_buf_get_name(ev.buf)
        for root in pairs(guarded) do
            if inside(root, name) then
                vim.bo[ev.buf].undofile = false
            end
        end
    end,
})
vim.api.nvim_create_autocmd("BufWritePre", {
    group = group,
    callback = function(ev)
        local name = vim.api.nvim_buf_get_name(ev.buf)
        for root in pairs(guarded) do
            if inside(root, name) then
                vim.bo[ev.buf].undofile = false
                local ok, err = plain_path(name)
                if not ok then
                    error("Incognito: refusing write through Review symlink: " .. err)
                end
            end
        end
    end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
        -- Off/owner switches retain writable buffers, so keep their locks until exit.
        local all = vim.tbl_values(held)
        for _, ws in ipairs(all) do
            release(ws)
        end
    end,
})

function M.open(source, owner, range, config)
    source = uv.fs_realpath(source)
    local common = source and git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, source)
    common = common and uv.fs_realpath(common)
    if not common or not owner then
        return nil, "Source and branch owner are required"
    end
    -- JSON keeps path/owner boundaries unambiguous without passing a NUL-containing
    -- Lua string as a Blob to sha256() on Neovim 0.11.
    local id = vim.fn.sha256(vim.json.encode({ common, owner }))
    local meta = vim.fs.joinpath(common, "incognito-reviews")
    local ok, err = plain_path(meta)
    if not ok then
        return nil, err
    end
    local manifest = vim.fs.joinpath(meta, id .. ".json")
    local private = vim.fs.joinpath(common, "incognito")
    local parent = config.worktree_dir or private
    local name = id:sub(1, 24)
    if not config.worktree_dir then
        local branch = owner:gsub("^refs/heads/", ""):gsub("[^%w._-]", "-"):sub(1, 64)
        name = branch .. "-" .. id:sub(1, 12)
        -- Keep earlier default locations accessible without moving saved experiments.
        -- The manifest and Git ownership are fully validated below before use.
        local saved = read(manifest)
        for _, legacy in ipairs({
            source .. ".incognito",
            vim.fs.joinpath(vim.fn.stdpath("data"), "incognito", "worktrees"),
        }) do
            if saved and saved.path == vim.fs.joinpath(legacy, id:sub(1, 24)) then
                parent, name = legacy, id:sub(1, 24)
                break
            end
        end
    end
    parent = vim.fs.normalize(vim.fn.fnamemodify(parent, ":p")):gsub("/$", "")
    local path = vim.fs.joinpath(parent, name)
    ok, err = plain_path(path)
    if not ok then
        return nil, err
    end
    if (parent ~= private and vim.fs.root(parent, ".git")) or uv.fs_lstat(vim.fs.joinpath(parent, ".git")) then
        return nil, "Review parent must be outside any Git checkout"
    end
    if not safe_layout(source, common, path) then
        return nil, "Review must be outside Source and Git metadata, except <git-common-dir>/incognito"
    end
    vim.fn.mkdir(meta, "p")
    local ws = { manifest = manifest, lock = vim.fs.joinpath(meta, id .. ".lock") }
    local cached = held[ws.manifest]
    if cached then
        if cached.data.path ~= path or cached.data.source ~= source then
            return nil, "Review configuration changed; reopen editor or restore configuration"
        end
        local valid, why = M.validate(cached)
        if not valid then
            return nil, why
        end
        return cached
    end
    ws.lock_owner, err = acquire(ws.lock)
    if not ws.lock_owner then
        return nil, err
    end
    local function fail(message)
        release(ws)
        return nil, message
    end
    local exists = uv.fs_lstat(ws.manifest)
    ws.data = exists and read(ws.manifest) or nil
    if exists and (exists.type ~= "file" or not ws.data) then
        return fail("invalid Review manifest; inspect manually")
    end
    if ws.data then
        local d = ws.data
        if d.version ~= 1 or d.common ~= common or d.owner ~= owner or d.source ~= source or d.path ~= path then
            return fail("Review manifest identity/path mismatch; no automatic migration")
        end
        ok, err = M.validate(ws)
        if not ok then
            return fail(err)
        end
    else
        if uv.fs_lstat(path) then
            return fail("unowned Review directory exists: " .. path)
        end
        vim.fn.mkdir(parent, "p")
        if uv.fs_realpath(parent) ~= parent then
            return fail("noncanonical Review parent")
        end
        ws.data = {
            version = 1,
            common = common,
            owner = owner,
            source = source,
            path = path,
            target = range.target,
            L = range.L,
            R = range.R,
            N = range.R,
            phase = "creating",
        }
        ok, err = M.save(ws)
        if not ok then
            return fail(err)
        end
        local _, add_err = git({ "worktree", "add", "--quiet", "--detach", path, range.R }, source)
        if add_err then
            return fail("Review creation interrupted; inspect manifest: " .. add_err)
        end
        ws.data.gitdir = git({ "rev-parse", "--absolute-git-dir" }, path)
        ws.data.phase = "ready"
        ok, err = M.save(ws)
        if not ok then
            return fail(err)
        end
    end
    guarded[path] = true
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if inside(path, vim.api.nvim_buf_get_name(b)) then
            vim.bo[b].undofile = false
        end
    end
    held[ws.manifest] = ws
    return ws
end

function M.peek(source, owner)
    if not owner then
        return nil
    end
    local common = git({ "rev-parse", "--path-format=absolute", "--git-common-dir" }, source)
    common = common and uv.fs_realpath(common)
    if not common then
        return nil
    end
    local id = vim.fn.sha256(vim.json.encode({ common, owner }))
    return read(vim.fs.joinpath(common, "incognito-reviews", id .. ".json"))
end

M.git = git
M._ignored_collision = ignored_collision
return M
