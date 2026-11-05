--- The game bundle: one file holding the game's modules and short sound cues, so the console
--- opens one file at boot instead of one per module and one per cue.
---
--- Each `require` through the runtime's own loader, and each cue loaded by path, costs a probe
--- of the save directory and an open, and PhysFS reopens the package for every file it opens:
--- on an Old 3DS that is about ten milliseconds a file before a byte is read, and boot loads
--- over seventy modules and forty-odd cues. A console build (`dev/bundle.py`) moves every module
--- except this one, main.lua and conf.lua into `game.bundle`, with the files `dev/build.sh`
--- names (the short .wav cues), stored uncompressed so a seek in it is a plain file seek. This
--- keeps the file open, serves `require` from it, and hands out the other files' bytes through
--- `Bundle.read`.
---
--- A desktop run, or any tree without a bundle, has nothing to install: `install` returns false,
--- `require` behaves as it always has, and `Bundle.read` returns nil for every path.
---
--- The format, written by `dev/bundle.py`:
---
---   "BNDL1 " .. the index's length in bytes, as 9 decimal digits .. "\n"
---   the index: one "<path>\t<size>\n" line per file
---   the files' bytes, concatenated in index order
local Bundle = {}

Bundle.PATH = "game.bundle"

--- LövePotion's require path, tried in this order (as its loader tries them).
Bundle.TEMPLATES = { "?.lua", "?/init.lua" }

local HEADER_BYTES = 16

--- Set by `install`: the index and a reader on the open bundle.
local index, read_at = nil, nil

--- Parse a bundle's index.
---@param read fun(offset: integer, size: integer): string exactly `size` bytes from `offset`
---@return table<string, { offset: integer, size: integer }> index
function Bundle.read_index(read)
    local digits = read(0, HEADER_BYTES):match("^BNDL1 (%d%d%d%d%d%d%d%d%d)\n$")
    if not digits then error("bundle: " .. Bundle.PATH .. " has no BNDL1 header", 0) end
    local length = tonumber(digits)
    local text = read(HEADER_BYTES, length)
    local parsed_index, offset, parsed = {}, HEADER_BYTES + length, 0
    for line, path, size in text:gmatch("(([^\t\n]+)\t(%d+)\n)") do
        size = tonumber(size)
        parsed_index[path] = { offset = offset, size = size }
        offset = offset + size
        parsed = parsed + #line
    end
    if parsed ~= length then error("bundle: malformed index in " .. Bundle.PATH, 0) end
    return parsed_index
end

--- The bundled file `require(name)` resolves to, or nil.
---@param bundle_index table<string, table>
---@param name string
---@return string|nil path
function Bundle.find(bundle_index, name)
    local rel = name:gsub("%.", "/")
    for _, template in ipairs(Bundle.TEMPLATES) do
        local path = template:gsub("%?", function() return rel end)
        if bundle_index[path] then return path end
    end
    return nil
end

--- Whether the installed bundle holds `path`. False when no bundle is installed.
---@param path string
---@return boolean
function Bundle.has(path)
    return index ~= nil and index[path] ~= nil
end

--- The bytes of a bundled file, or nil when no bundle is installed or it does not hold `path`.
---@param path string
---@return string|nil
function Bundle.read(path)
    local entry = index and index[path]
    if not entry then return nil end
    return read_at(entry.offset, entry.size)
end

--- Open the bundle and put a searcher for it ahead of the runtime's file loader.
---@return boolean installed false when there is no bundle
function Bundle.install()
    if index then error("bundle: installed twice", 0) end
    local fs = love.filesystem
    if not fs.getInfo(Bundle.PATH, "file") then return false end

    local file = fs.newFile(Bundle.PATH)
    local opened, err = file:open("r")
    if not opened then error("bundle: cannot open " .. Bundle.PATH .. ": " .. tostring(err), 0) end
    local function read(offset, size)
        if not file:seek(offset) then error("bundle: cannot seek to " .. offset, 0) end
        local data = file:read(size)
        if type(data) ~= "string" or #data ~= size then
            error("bundle: short read at " .. offset .. " in " .. Bundle.PATH, 0)
        end
        return data
    end
    local parsed_index = Bundle.read_index(read)

    local loaders = package.loaders or package.searchers
    table.insert(loaders, 2, function(name)
        local path = Bundle.find(parsed_index, name)
        if not path then return "\n\tno module '" .. name .. "' in " .. Bundle.PATH end
        local entry = parsed_index[path]
        local chunk, load_err = loadstring(read(entry.offset, entry.size), "@" .. path)
        if not chunk then error(load_err, 0) end
        return chunk
    end)
    index, read_at = parsed_index, read
    return true
end

--- Forget the installed bundle. For tests, which install fakes; the game never calls it.
function Bundle._reset()
    index, read_at = nil, nil
end

return Bundle
