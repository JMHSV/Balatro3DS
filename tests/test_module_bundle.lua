local T = require("tests.testlib")
local Bundle = require("module_bundle")

local suite = T.suite("module bundle")

--- A bundle laid out by hand from the format in module_bundle.lua's header.
local function bundle(entries)
    local index, data = {}, {}
    for _, e in ipairs(entries) do
        index[#index + 1] = e[1] .. "\t" .. #e[2] .. "\n"
        data[#data + 1] = e[2]
    end
    local text = table.concat(index)
    return string.format("LUAB1 %09d\n", #text) .. text .. table.concat(data)
end

--- A love.filesystem holding at most one file, the bundle, with LÖVE's File semantics:
--- `read(n)` returns up to n bytes from the position, `seek` fails past the end.
local function fake_fs(bundle_bytes)
    return {
        getInfo = function(path, filter)
            if path ~= Bundle.PATH or bundle_bytes == nil then return nil end
            if filter and filter ~= "file" then return nil end
            return { type = "file", size = #bundle_bytes }
        end,
        newFile = function(path)
            assert(path == Bundle.PATH and bundle_bytes, "no such file " .. path)
            local pos, open = 0, false
            return {
                open = function(_, mode) open = mode == "r"; return open end,
                seek = function(_, p)
                    if not open or p < 0 or p > #bundle_bytes then return false end
                    pos = p
                    return true
                end,
                read = function(_, n)
                    assert(open, "read before open")
                    local s = bundle_bytes:sub(pos + 1, pos + n)
                    pos = pos + #s
                    return s, #s
                end,
            }
        end,
    }
end

--- Install against `bundle_bytes`, run `fn`, then put package.loaders, package.loaded and
--- love.filesystem back the way they were.
local function with_bundle(bundle_bytes, fn)
    local loaders = package.loaders or package.searchers
    local saved_loaders = {}
    for i, l in ipairs(loaders) do saved_loaders[i] = l end
    local saved_loaded = {}
    for k in pairs(package.loaded) do saved_loaded[k] = true end
    local saved_fs = love.filesystem
    love.filesystem = fake_fs(bundle_bytes)
    local ok, err = pcall(function() fn(Bundle.install()) end)
    love.filesystem = saved_fs
    for i = #loaders, 1, -1 do loaders[i] = nil end
    for i, l in ipairs(saved_loaders) do loaders[i] = l end
    for k in pairs(package.loaded) do
        if not saved_loaded[k] then package.loaded[k] = nil end
    end
    if not ok then error(err, 0) end
end

suite.test("without a bundle, install leaves require alone", function()
    local loaders = package.loaders or package.searchers
    local before = #loaders
    with_bundle(nil, function(installed)
        T.assert_false(installed, "install should report no bundle")
        T.assert_eq(#loaders, before, "no searcher should be added")
    end)
end)

suite.test("requires a module from a bundle written out byte by byte", function()
    -- index line "bundle_probe_x.lua\t8\n" is 21 bytes; the module is "return 7".
    local bytes = "LUAB1 000000021\nbundle_probe_x.lua\t8\nreturn 7"
    with_bundle(bytes, function(installed)
        T.assert_true(installed, "install should find the bundle")
        T.assert_eq(require("bundle_probe_x"), 7)
    end)
end)

suite.test("resolves names like the runtime's loader: dots, ?.lua before ?/init.lua", function()
    local bytes = bundle({
        { "bundle_probe_pkg.lua", "return 'file'" },
        { "bundle_probe_pkg/init.lua", "return 'init'" },
        { "bundle_probe_dir/init.lua", "return 'dir'" },
        { "bundle_probe_dir/sub.lua", "return 'sub'" },
    })
    with_bundle(bytes, function()
        T.assert_eq(require("bundle_probe_pkg"), "file")
        T.assert_eq(require("bundle_probe_dir"), "dir")
        T.assert_eq(require("bundle_probe_dir.sub"), "sub")
    end)
end)

suite.test("a bundled module runs under its own file name, as it would from a file", function()
    local bytes = bundle({
        { "bundle_probe_a.lua", "return 1" },
        { "bundle_probe_src/where.lua", "return debug.getinfo(1, 'S').source" },
    })
    with_bundle(bytes, function()
        T.assert_eq(require("bundle_probe_src.where"), "@bundle_probe_src/where.lua")
    end)
end)

suite.test("the module receives its name, as require passes it", function()
    local bytes = bundle({ { "bundle_probe_name.lua", "return (...)" } })
    with_bundle(bytes, function()
        T.assert_eq(require("bundle_probe_name"), "bundle_probe_name")
    end)
end)

suite.test("a module the bundle lacks is left to the next searcher", function()
    local bytes = bundle({ { "bundle_probe_a.lua", "return 1" } })
    with_bundle(bytes, function()
        local searcher = (package.loaders or package.searchers)[2]
        local result = searcher("bundle_probe_absent")
        T.assert_eq(type(result), "string", "a searcher reports a miss with a message")
        T.assert_true(result:find("bundle_probe_absent", 1, true) ~= nil, "the message names the module")
    end)
end)

suite.test("a file without the LUAB1 header is refused at install", function()
    local err = T.assert_error(function()
        with_bundle("return 'not a bundle at all'", function() end)
    end)
    T.assert_true(tostring(err):find("LUAB1", 1, true) ~= nil, tostring(err))
end)

suite.test("an index whose lines do not add up to its stated length is refused", function()
    -- 12 bytes of index claimed, but "a.lua\tx\n" is not an index line.
    local err = T.assert_error(function()
        with_bundle("LUAB1 000000012\na.lua\tx\nxxxx", function() end)
    end)
    T.assert_true(tostring(err):find("malformed", 1, true) ~= nil, tostring(err))
end)

suite.test("a bundle cut short is refused rather than loading part of a module", function()
    local bytes = bundle({ { "bundle_probe_cut.lua", "return 'whole module'" } })
    with_bundle(bytes:sub(1, -5), function()
        T.assert_error(function() require("bundle_probe_cut") end)
    end)
end)

return suite
