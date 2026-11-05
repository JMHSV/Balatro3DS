--- Load Lab, LÖVE driver: what boot reads, compiles and decodes, as the console would do it.
---
---   love . --load-lab --stage <dir> [--out <dir>]
---
--- `--stage` is the directory `stage.py` wrote: game Lua is compiled from there, not from the
--- working tree, so the run sees what the build would ship.
---
--- Installed from the first statement of main.lua, so everything main.lua requires is seen. It
--- records two phases:
---
---   boot   main.lua's first line to the end of the first frame drawn on the main menu, which
---          is the first frame that takes input;
---   hand   from that menu to the first hand dealt (`to_hand.lua`, the Pixel Lab tour's path).
---
--- Everything is recorded in the console's terms (`view.lua`): a .png the game names is counted
--- as the .t3x the runtime opens, a cue as the .wav the build ships, a per-size font sheet as the
--- .bcfnt that exists only in a console build. Where the desktop lacks such a file the lab loads
--- the desktop source instead, so the game takes the console's branch.
---
--- Like the Pixel Lab: time is a fixed 1/60 s step, the save directory is a throwaway identity
--- wiped at start, and the console is an Old 3DS. Desktop only; `dev/` is never staged.
---
--- Output: `<out>/trace.txt`, read by `score.py`. Timing here is LuaJIT's and only informational;
--- `puc_boot.lua` times the same boot under PUC Lua 5.1.
local Trace = require("dev.load_lab.trace")
local View = require("dev.load_lab.view")

local Lab = {}

local DT = 1 / 60
local MANIFEST = "dev/load_lab/package_baseline.tsv"

function Lab.requested(argv)
    for _, a in ipairs(argv or {}) do
        if a == "--load-lab" then return true end
    end
    return false
end

local function parse_args(argv)
    local opts = { out = "dev/load_lab/out/latest" }
    for i = 1, #argv do
        if argv[i] == "--out" then opts.out = assert(argv[i + 1], "--out needs a directory") end
        if argv[i] == "--stage" then opts.stage = assert(argv[i + 1], "--stage needs a directory") end
    end
    assert(opts.stage, "load lab: --stage <dir> is required (dev/load_lab/run.sh writes one)")
    return opts
end

local function mkdir_p(path)
    local sep = package.config:sub(1, 1)
    local native = path:gsub("/", sep)
    if sep == "\\" then
        os.execute('if not exist "' .. native .. '" mkdir "' .. native .. '"')
    else
        os.execute("mkdir -p '" .. native .. "'")
    end
end

local function wipe_save_dir(fs, dir)
    for _, name in ipairs(fs.getDirectoryItems(dir)) do
        local p = (dir == "" and name) or (dir .. "/" .. name)
        local info = fs.getInfo(p)
        if info and info.type == "directory" then wipe_save_dir(fs, p) end
        fs.remove(p)
    end
end

--- Desktop file to load in place of a console-only one, so the game's call succeeds the way it
--- does on the console. nil when there is no stand-in (the call then fails, as it would there).
local function desktop_stand_in(console_path, exists_locally)
    if console_path:match("^resources/sounds/.+%.wav$") then
        local ogg = console_path:sub(1, -5) .. ".ogg"
        if exists_locally(ogg) then return ogg end
    end
    if console_path:match("^resources/fonts/m6x11plus_h%d+%.bcfnt$") then
        return "resources/fonts/m6x11plus.ttf"
    end
    local lang = console_path:match("^resources/fonts/lang/([%w_]+)_h%d+%.bcfnt$")
    if lang and exists_locally("resources/fonts/" .. lang .. ".ttf") then
        return "resources/fonts/" .. lang .. ".ttf"
    end
    return nil
end

--- Wrap the love functions that touch the game package. `raw` holds the originals.
local function install_wrappers(view, raw)
    local fs, gfx = love.filesystem, love.graphics
    local save_dir = raw.getSaveDirectory()

    local function exists_locally(path)
        return raw.getInfo(path, "file") ~= nil
    end
    local function in_save_dir(path)
        local real = raw.getRealDirectory(path)
        return real ~= nil and real == save_dir
    end

    fs.getInfo = function(path, a, b)
        if not Trace.recording() then return raw.getInfo(path, a, b) end
        if in_save_dir(path) then
            Trace.event("stat", path, "save")
            return raw.getInfo(path, a, b)
        end
        local filter = type(a) == "string" and a or nil
        local info = view.info(path)
        if info and filter and info.type ~= filter then info = nil end
        Trace.event("stat", path, info and "hit" or "miss")
        if not info then return nil end
        local out = (type(a) == "table" and a) or (type(b) == "table" and b) or {}
        out.type, out.size, out.modtime = info.type, info.size, info.modtime
        return out
    end

    fs.read = function(a, b, c)
        local path = (type(a) == "string" and (a == "string" or a == "data") and type(b) == "string") and b or a
        if Trace.recording() then
            if in_save_dir(path) then
                Trace.event("save_read", path)
            else
                local size = view.size(path)
                Trace.event(size and "open" or "stat", path, size or "miss", "read")
            end
        end
        return raw.read(a, b, c)
    end

    fs.load = function(path)
        if not Trace.recording() then return raw.load(path) end
        if in_save_dir(path) then
            Trace.event("save_read", path, "", "load")
            return raw.load(path)
        end
        local src = view.read(path)
        if not src then
            -- The desktop would load the tree's copy, but the console has no such file.
            assert(not (view.bundle and view.bundle.index[path]),
                "load lab: love.filesystem.load of " .. path .. ", which ships only inside the module bundle")
            Trace.event("stat", path, "miss")
            return raw.load(path)
        end
        Trace.event("open", path, #src, "compile")
        return Trace.compile(path, path, src)
    end

    for _, name in ipairs({ "newFileData", "lines", "newFile" }) do
        local original = raw[name]
        fs[name] = function(path, ...)
            if Trace.recording() and type(path) == "string" then
                local size = view.size(path)
                Trace.event(size and "open" or "stat", path, size or "miss", name)
            end
            return original(path, ...)
        end
    end

    fs.getDirectoryItems = function(dir)
        if Trace.recording() then Trace.event("list", dir) end
        return raw.getDirectoryItems(dir)
    end
    for _, name in ipairs({ "write", "append" }) do
        local original = raw[name]
        fs[name] = function(path, data, ...)
            if Trace.recording() then
                Trace.event("save_write", path, type(data) == "string" and #data or "")
            end
            return original(path, data, ...)
        end
    end

    gfx.newImage = function(arg, ...)
        if not Trace.recording() or type(arg) ~= "string" then
            if Trace.recording() then
                local image = raw.newImage(arg, ...)
                Trace.event("texture_data", "(from data)", image:getWidth(), image:getHeight())
                return image
            end
            return raw.newImage(arg, ...)
        end
        local cpath = View.console_path(arg)
        local image = raw.newImage(arg, ...)
        Trace.event("open", cpath, view.size(cpath) or "missing", "image")
        Trace.event("texture", cpath, image:getWidth(), image:getHeight())
        return image
    end

    gfx.newFont = function(a, ...)
        if not Trace.recording() then return raw.newFont(a, ...) end
        if type(a) ~= "string" then
            Trace.event("font_builtin", tostring(a))
            return raw.newFont(a, ...)
        end
        local cpath = View.console_path(a)
        if not view.exists(cpath) then
            Trace.event("stat", cpath, "miss")
            return raw.newFont(a, ...)
        end
        Trace.event("open", cpath, view.size(cpath), "font")
        Trace.event("font", cpath, view.size(cpath))
        if exists_locally(a) then return raw.newFont(a, ...) end
        local stand_in = assert(desktop_stand_in(cpath, exists_locally),
            "load lab: no desktop stand-in for " .. cpath)
        return raw.newFont(stand_in, ...)
    end

    love.image.newImageData = function(a, ...)
        if Trace.recording() and type(a) == "string" then
            local cpath = View.console_path(a)
            local data = raw.newImageData(a, ...)
            Trace.event("open", cpath, view.size(cpath) or "missing", "imagedata")
            Trace.event("texture", cpath, data:getWidth(), data:getHeight())
            return data
        end
        return raw.newImageData(a, ...)
    end

    --- Sound by path: open the console's file, load the desktop's.
    local function sound_path(path, kind)
        if not view.exists(path) then
            Trace.event("stat", path, "miss")
            return path
        end
        Trace.event("open", path, view.size(path), kind)
        if exists_locally(path) then return path end
        return assert(desktop_stand_in(path, exists_locally), "load lab: no desktop stand-in for " .. path)
    end

    love.sound.newSoundData = function(a, ...)
        if Trace.recording() and type(a) == "string" then
            return raw.newSoundData(sound_path(a, "sound"), ...)
        end
        return raw.newSoundData(a, ...)
    end
    love.sound.newDecoder = function(a, ...)
        if Trace.recording() and type(a) == "string" then
            return raw.newDecoder(sound_path(a, "stream"), ...)
        end
        return raw.newDecoder(a, ...)
    end
    love.audio.newSource = function(a, kind, ...)
        if Trace.recording() and type(a) == "string" then
            return raw.newSource(sound_path(a, kind == "static" and "sound" or "stream"), kind, ...)
        end
        return raw.newSource(a, kind, ...)
    end
end

--- The deterministic clock every timing read in the game resolves to (as in the Pixel Lab).
local clock = { t = 0, frame = 0 }
local function install_clock()
    love.timer.getTime = function() return clock.t end
    love.timer.step = function() return DT end
    love.timer.getDelta = function() return DT end
    love.timer.getFPS = function() return 60 end
    love.timer.getAverageDelta = function() return DT end
end

local function write_file(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

function Lab.install(argv)
    local opts = parse_args(argv)
    local fs = love.filesystem

    fs.setIdentity("Balatro3DS_load_lab")
    wipe_save_dir(fs, "")
    math.randomseed(1)
    if love.math and love.math.setRandomSeed then love.math.setRandomSeed(1) end
    install_clock()

    local raw = {
        getInfo = fs.getInfo, read = fs.read, load = fs.load, newFileData = fs.newFileData,
        lines = fs.lines, newFile = fs.newFile, getDirectoryItems = fs.getDirectoryItems,
        write = fs.write, append = fs.append, getRealDirectory = fs.getRealDirectory,
        getSaveDirectory = fs.getSaveDirectory,
        newImage = love.graphics.newImage, newFont = love.graphics.newFont,
        newImageData = love.image.newImageData, newSoundData = love.sound.newSoundData,
        newDecoder = love.sound.newDecoder, newSource = love.audio.newSource,
    }
    local view = View.new(function() return raw.read(MANIFEST) end, function(path)
        local f = io.open(opts.stage .. "/" .. path, "rb")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end)
    assert(view.read("main.lua"), "load lab: no main.lua in the stage " .. opts.stage)

    -- nest emulates the 3DS screens on desktop; on the console `require("nest")` compiles
    -- nest/init.lua and returns at once. Load it now, outside the trace, and record only the
    -- console's part of it below. Its desktop setup in `init` is lab plumbing.
    local nest = require("nest")
    local nest_init = nest.init
    nest.init = function(...)
        local result = Trace.untraced(nest_init, ...)
        Lab.install_run(opts)
        return result
    end

    Trace.on_loaded("console", function(Console)
        -- An Old 3DS, as the Pixel Lab runs by default.
        Console.is_new_3ds = function() return false end
    end)
    Trace.install_searcher(view, fs.getRequirePath())
    install_wrappers(view, raw)

    Trace.phase("boot")
    Lab.gc0 = collectgarbage("count")
    -- Compiled by the runtime before any lab code exists, so recorded by size.
    for _, path in ipairs({ "conf.lua", "main.lua" }) do
        Trace.event("open", path, view.size(path), "compile")
        Trace.compiled_elsewhere(path, assert(view.size(path), path .. " not in the console view"))
    end
    -- main.lua installs the module bundle before it requires nest, so with a bundle the console
    -- reads nest from it.
    if view.bundle then
        Trace.event("bundle_read", "nest/init.lua")
        Trace.compiled_elsewhere("nest/init.lua", #assert(view.bundle.read("nest/init.lua"), "nest not bundled"))
    else
        Trace.event("stat", "nest.lua", "miss")
        Trace.event("stat", "nest/init.lua", "hit")
        Trace.event("open", "nest/init.lua", view.size("nest/init.lua"), "compile")
        Trace.compiled_elsewhere("nest/init.lua", view.size("nest/init.lua"))
    end
end

--- Replace nest's run loop with a deterministic one that drives the two phases.
function Lab.install_run(opts)
    local framebuffers = require("nest.modules.video").getFramebuffers()
    local script = require("dev.load_lab.to_hand")

    love.run = function()
        if love.audio then love.audio.setVolume(0) end
        love.window.setVSync(0)
        if love.graphics.set3D then love.graphics.set3D(false) end
        love.load()

        local co
        local lab = setmetatable({}, { __index = function(_, k) if k == "G" then return G end end })
        function lab.wait(seconds)
            for _ = 1, math.max(1, math.floor(seconds / DT + 0.5)) do coroutine.yield() end
        end
        local frames = { boot = 0, hand = 0 }

        return function()
            love.event.pump()
            for name, a, b, c, d, e, f in love.event.poll() do
                if name == "quit" then return a or 0 end
                if name ~= "keypressed" and name ~= "keyreleased" and name ~= "mousepressed"
                    and name ~= "mousereleased" and name ~= "touchpressed" and name ~= "touchreleased"
                    and name ~= "mousemoved" and name ~= "touchmoved" and name ~= "gamepadpressed"
                    and name ~= "gamepadreleased" and name ~= "gamepadaxis" and name ~= "joystickpressed"
                    and name ~= "joystickreleased" and name ~= "joystickaxis" then
                    love.handlers[name](a, b, c, d, e, f)
                end
            end
            clock.frame = clock.frame + 1
            clock.t = clock.t + DT

            if co then
                local ok, err = coroutine.resume(co)
                if not ok then error(err, 0) end
                if coroutine.status(co) == "dead" then
                    Trace.phase_stat("hand", "frames", frames.hand)
                    Trace.phase_stat("hand", "luajit_gc_kb_delta", string.format("%.1f", collectgarbage("count") - Lab.gc1))
                    Trace.phase(nil)
                    mkdir_p(opts.out)
                    write_file(opts.out .. "/trace.txt", Trace.serialize())
                    io.write("[load-lab] trace written to ", opts.out, "/trace.txt\n")
                    return 0
                end
            end

            love.update(DT)
            for _, fb in ipairs(framebuffers) do
                local name = fb:getName()
                love.graphics.setActiveScreen(name)
                fb:renderTo(function()
                    love.graphics.clear(love.graphics.getBackgroundColor())
                    if love.draw then love.draw(name) end
                end)
                love.graphics.origin()
                fb:draw()
            end
            love.graphics.present()

            if not co then
                frames.boot = frames.boot + 1
                assert(G and G.STATE == G.STATES.MENU, "load lab: first frame is not the main menu")
                Trace.phase_stat("boot", "frames", frames.boot)
                Lab.gc1 = collectgarbage("count")
                Trace.phase_stat("boot", "luajit_gc_kb_delta", string.format("%.1f", Lab.gc1 - Lab.gc0))
                Trace.phase("hand")
                co = coroutine.create(function() script(lab) end)
            else
                frames.hand = frames.hand + 1
            end
        end
    end
end

return Lab
