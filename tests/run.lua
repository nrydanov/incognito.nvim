-- SPEC=tests.foo_spec[,tests.bar_spec] runs a subset; default is every tests/*_spec.lua.
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))))
local specs = {}
if vim.env.SPEC then
    specs = vim.split(vim.env.SPEC, ",", { trimempty = true })
else
    for _, path in ipairs(vim.fn.glob(vim.fs.joinpath(root, "tests", "*_spec.lua"), false, true)) do
        specs[#specs + 1] = "tests." .. vim.fn.fnamemodify(path, ":t:r")
    end
    table.sort(specs)
end

local failures, total = {}, 0

for _, spec_name in ipairs(specs) do
    local ok, spec = pcall(require, spec_name)
    if not ok then
        failures[#failures + 1] = spec_name .. " failed to load: " .. spec
    else
        local names = {}
        for name, fn in pairs(spec) do
            if type(fn) == "function" and name:match("^test_") then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            total = total + 1
            local test_ok, err = xpcall(spec[name], debug.traceback)
            print((test_ok and "ok " or "not ok ") .. total .. " - " .. name)
            if not test_ok then
                failures[#failures + 1] = name .. "\n" .. err
            end
        end
    end
end

if #failures > 0 then
    print("\nFailures:")
    for _, failure in ipairs(failures) do
        print("---\n" .. failure)
    end
    vim.cmd("cquit! 1")
end
print("\nAll " .. total .. " tests passed")
vim.cmd("qa!")
