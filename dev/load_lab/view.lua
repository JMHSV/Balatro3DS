--- The console's view of the game package, for the Load Lab.
---
--- A 3DS build does not ship the repository: `dev/build.sh` stages it (dropping dev/, tests/,
--- docs-only files...), converts every .png to .t3x and .ttf to .bcfnt, bakes per-size font
--- sheets, and turns sound cues into .wav. The runtime then rewrites .png/.ttf paths to the
--- converted names when the game opens them. So "does this file exist, and how big is it" has
--- a different answer on the console than on the desktop running the lab.
---
--- Non-Lua entries come from `package_baseline.tsv`, the listing of a real CI-built .3dsx; those
--- files are converted by devkitPro tools this machine does not have, and no load-time change
--- alters them. Lua entries come from a stage directory that `stage.py` writes from the working
--- tree under the build's own staging rules, so both drivers run exactly the Lua that ships.
---
--- When the build bundles, the stage holds `game.bundle` instead of most .lua files and the
--- bundled cues, as the package does. The view then reads the bundle with the stage's own
--- bundle.lua, and a bundled file exists only through `view.bundle`: as a file, it is absent, as
--- on the console. The stage's bundled cues are placeholders of the shipped size, not sound.
local View = {}

--- The path the runtime opens for a path the game names (`include/utilities/functions.hpp`
--- in LövePotion rewrites these two extensions on load).
function View.console_path(path)
    if path:sub(-4) == ".png" then return path:sub(1, -5) .. ".t3x" end
    if path:sub(-4) == ".ttf" then return path:sub(1, -5) .. ".bcfnt" end
    return path
end

--- The stage's bundle, or nil: { path, size, index, find, read(path) -> bytes|nil }.
local function open_bundle(read_stage)
    local loader_src = read_stage("bundle.lua")
    if not loader_src then return nil end
    local Bundle = assert(loadstring(loader_src, "@bundle.lua"))()
    local data = read_stage(Bundle.PATH)
    if not data then return nil end
    local function read(offset, size)
        local s = data:sub(offset + 1, offset + size)
        assert(#s == size, "load lab: " .. Bundle.PATH .. " is cut short")
        return s
    end
    local index = Bundle.read_index(read)
    return {
        path = Bundle.PATH,
        size = #data,
        index = index,
        find = function(name) return Bundle.find(index, name) end,
        read = function(path)
            local e = index[path]
            return e and read(e.offset, e.size)
        end,
    }
end

--- Build a view.
---@param read_manifest fun(): string the text of package_baseline.tsv
---@param read_stage fun(path: string): string|nil a staged file's bytes, or nil
---@return table view
function View.new(read_manifest, read_stage)
    local assets, dirs = {}, { [""] = true }
    local function add_dirs(path)
        local dir = path:match("^(.*)/[^/]+$")
        while dir and not dirs[dir] do
            dirs[dir] = true
            dir = dir:match("^(.*)/[^/]+$")
        end
    end
    local text = read_manifest()
    assert(text, "load lab: package_baseline.tsv is missing")
    for line in text:gmatch("[^\n]+") do
        if line:sub(1, 1) ~= "#" then
            local path, size = line:match("^([^\t]+)\t(%d+)\t")
            assert(path, "load lab: bad manifest line: " .. line)
            if path:sub(-4) ~= ".lua" then
                assets[path] = tonumber(size)
                add_dirs(path)
            end
        end
    end

    local lua_cache = {}
    local function lua_source(path)
        if path:sub(-4) ~= ".lua" then return nil end
        local hit = lua_cache[path]
        if hit == nil then
            hit = read_stage(path) or false
            lua_cache[path] = hit
            if hit then add_dirs(path) end
        end
        return hit or nil
    end

    local view = {}

    --- nil when the build does not bundle.
    view.bundle = open_bundle(read_stage)
    if view.bundle then
        add_dirs(view.bundle.path)
        for path in pairs(view.bundle.index) do
            if path:sub(-4) ~= ".lua" then
                assert(assets[path], "load lab: the bundle holds " .. path .. ", which the package baseline lacks")
                assets[path] = nil
            end
        end
    end

    --- Size of a shipped file, or nil when the console package has no such file.
    function view.size(path)
        if assets[path] then return assets[path] end
        if view.bundle and path == view.bundle.path then return view.bundle.size end
        local src = lua_source(path)
        return src and #src or nil
    end

    --- The bytes the console loads for a module at `path`, loose or bundled.
    function view.module(path)
        return lua_source(path) or (view.bundle and view.bundle.read(path))
    end

    function view.exists(path)
        return view.size(path) ~= nil
    end

    --- The bytes the console would compile for a shipped .lua file.
    function view.read(path)
        return lua_source(path)
    end

    --- `love.filesystem.getInfo`-shaped answer.
    function view.info(path)
        local size = view.size(path)
        if size then return { type = "file", size = size, modtime = 0 } end
        if dirs[path] then return { type = "directory", size = 0, modtime = 0 } end
        return nil
    end

    return view
end

return View
