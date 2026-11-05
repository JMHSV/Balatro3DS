local T = require("tests.testlib")
local Bundle = require("bundle")

local suite = T.suite("game bundle")

--- A bundle laid out by hand from the format in bundle.lua's header.
local function bundle(entries)
    local index, data = {}, {}
    for _, e in ipairs(entries) do
        index[#index + 1] = e[1] .. "\t" .. #e[2] .. "\n"
        data[#data + 1] = e[2]
    end
    local text = table.concat(index)
    return string.format("BNDL1 %09d\n", #text) .. text .. table.concat(data)
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

--- Install against `bundle_bytes`, run `fn`, then put package.loaders, package.loaded,
--- love.filesystem and the bundle module back the way they were.
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
    Bundle._reset()
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
    local bytes = "BNDL1 000000021\nbundle_probe_x.lua\t8\nreturn 7"
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

suite.test("a file without the BNDL1 header is refused at install", function()
    local err = T.assert_error(function()
        with_bundle("return 'not a bundle at all'", function() end)
    end)
    T.assert_true(tostring(err):find("BNDL1", 1, true) ~= nil, tostring(err))
end)

suite.test("an index whose lines do not add up to its stated length is refused", function()
    -- 12 bytes of index claimed, but "a.lua\tx\n" is not an index line.
    local err = T.assert_error(function()
        with_bundle("BNDL1 000000012\na.lua\tx\nxxxx", function() end)
    end)
    T.assert_true(tostring(err):find("malformed", 1, true) ~= nil, tostring(err))
end)

suite.test("hands out the exact bytes of a bundled file that is not a module", function()
    local wav = "RIFF\0\0\0\0WAVEfmt \255\1\2"
    local bytes = bundle({
        { "bundle_probe_a.lua", "return 1" },
        { "resources/sounds/probe.wav", wav },
        { "bundle_probe_b.lua", "return 2" },
    })
    with_bundle(bytes, function()
        T.assert_true(Bundle.has("resources/sounds/probe.wav"), "the cue is in the bundle")
        T.assert_eq(Bundle.read("resources/sounds/probe.wav"), wav)
        T.assert_false(Bundle.has("resources/sounds/absent.wav"), "an unlisted file is not")
        T.assert_eq(Bundle.read("resources/sounds/absent.wav"), nil)
        -- Reading a cue between modules leaves the modules intact.
        T.assert_eq(require("bundle_probe_b"), 2)
    end)
end)

suite.test("without a bundle, no file is bundled", function()
    with_bundle(nil, function()
        T.assert_false(Bundle.has("resources/sounds/probe.wav"), "has")
        T.assert_eq(Bundle.read("resources/sounds/probe.wav"), nil)
    end)
end)

--- Run `fn(Sfx, calls)` with a fresh sfx.lua against a bundle, with love.sound and love.audio
--- replaced by recorders. `calls` lists every probe, FileData, SoundData and Source made.
local function with_bundled_sfx(bundle_bytes, fn)
    local saved_sfx, saved_sound, saved_audio = package.loaded.sfx, love.sound, love.audio
    local calls = {}
    local function record(kind, a, b) calls[#calls + 1] = { kind, a, b } end
    local ok, err = pcall(with_bundle, bundle_bytes, function()
        local fs = love.filesystem
        local get_info = fs.getInfo
        fs.getInfo = function(path, filter)
            record("probe", path)
            return get_info(path, filter)
        end
        fs.newFileData = function(contents, name)
            record("filedata", contents, name)
            return { filedata = true, contents = contents, name = name }
        end
        love.sound = {
            newSoundData = function(file)
                record("sounddata", file)
                return { sounddata = true, file = file }
            end,
        }
        love.audio = {
            newSource = function(from, kind)
                record("source", from, kind)
                return { isPlaying = function() return false end, setPitch = function() end,
                         setVolume = function() end, play = function() end, stop = function() end }
            end,
        }
        package.loaded.sfx = nil
        fn(require("sfx"), calls)
    end)
    package.loaded.sfx, love.sound, love.audio = saved_sfx, saved_sound, saved_audio
    if not ok then error(err, 0) end
end

suite.test("sfx decodes a bundled cue from the bundle's bytes, with no probe for its file", function()
    local wav = "RIFF probe cue bytes"
    with_bundled_sfx(bundle({ { "resources/sounds/button.wav", wav } }), function(Sfx, calls)
        T.assert_true(Sfx.play("button"), "the bundled cue plays")
        local made = {}
        for _, c in ipairs(calls) do
            T.assert_true(c[1] ~= "probe" or not tostring(c[2]):find("resources/sounds/", 1, true),
                "no probe for a bundled cue, got one for " .. tostring(c[2]))
            made[#made + 1] = c[1]
        end
        T.assert_eq(table.concat(made, ","), "filedata,sounddata,source")
        T.assert_eq(calls[1][2], wav, "the FileData holds the bundled bytes")
        T.assert_eq(calls[1][3], "resources/sounds/button.wav", "and is named for the cue's file")
        T.assert_true(calls[2][2].filedata and calls[2][2].contents == wav,
            "the SoundData is decoded from that FileData")
        T.assert_true(calls[3][2].sounddata and calls[3][3] == "static", "a static Source of it")
    end)
end)

suite.test("sfx still loads a cue the bundle lacks from its file", function()
    with_bundled_sfx(bundle({ { "bundle_probe_a.lua", "return 1" } }), function(Sfx, calls)
        Sfx.play("button")
        local probed, decoded = false, nil
        for _, c in ipairs(calls) do
            if c[1] == "probe" and c[2] == "resources/sounds/button.wav" then probed = true end
            if c[1] == "sounddata" then decoded = c[2] end
        end
        T.assert_true(probed, "the .wav file is probed for")
        -- The fake filesystem holds only the bundle, so the probe misses and sfx falls back to
        -- the .ogg path, as on a desktop tree.
        T.assert_eq(decoded, "resources/sounds/button.ogg")
    end)
end)

suite.test("a bundle cut short is refused rather than loading part of a module", function()
    local bytes = bundle({ { "bundle_probe_cut.lua", "return 'whole module'" } })
    with_bundle(bytes:sub(1, -5), function()
        T.assert_error(function() require("bundle_probe_cut") end)
    end)
end)

return suite
