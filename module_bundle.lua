--- Serves `require` from one file holding the game's modules, so the console opens one file at
--- boot instead of one per module.
---
--- Each `require` through the runtime's own loader costs a probe of the save directory and an
--- open, and PhysFS reopens the package for every file it opens: on an Old 3DS that is about
--- ten milliseconds a module, before a byte is read, and boot requires over seventy. A console
--- build (`dev/lua_bundle.py`) moves every module except this one, main.lua and conf.lua into
--- `modules.luab`, stored uncompressed so a seek in it is a plain file seek. This keeps the file
--- open and reads each module from it on demand.
---
--- A desktop run, or any tree without a bundle, has nothing to install: `install` returns false
--- and `require` behaves as it always has.
---
--- The format, written by `dev/lua_bundle.py`:
---
---   "LUAB1 " .. the index's length in bytes, as 9 decimal digits .. "\n"
---   the index: one "<path>\t<size>\n" line per module
---   the modules' bytes, concatenated in index order
local Bundle = {}

Bundle.PATH = "modules.luab"

--- LövePotion's require path, tried in this order (as its loader tries them).
Bundle.TEMPLATES = { "?.lua", "?/init.lua" }

local HEADER_BYTES = 16

--- Parse a bundle's index.
---@param read fun(offset: integer, size: integer): string exactly `size` bytes from `offset`
---@return table<string, { offset: integer, size: integer }> index
function Bundle.read_index(read)
    local digits = read(0, HEADER_BYTES):match("^LUAB1 (%d%d%d%d%d%d%d%d%d)\n$")
    if not digits then error("module bundle: " .. Bundle.PATH .. " has no LUAB1 header", 0) end
    local length = tonumber(digits)
    local text = read(HEADER_BYTES, length)
    local index, offset, parsed = {}, HEADER_BYTES + length, 0
    for line, path, size in text:gmatch("(([^\t\n]+)\t(%d+)\n)") do
        size = tonumber(size)
        index[path] = { offset = offset, size = size }
        offset = offset + size
        parsed = parsed + #line
    end
    if parsed ~= length then error("module bundle: malformed index in " .. Bundle.PATH, 0) end
    return index
end

--- The bundled file `require(name)` resolves to, or nil.
---@param index table<string, table>
---@param name string
---@return string|nil path
function Bundle.find(index, name)
    local rel = name:gsub("%.", "/")
    for _, template in ipairs(Bundle.TEMPLATES) do
        local path = template:gsub("%?", function() return rel end)
        if index[path] then return path end
    end
    return nil
end

--- Put a searcher for the bundle ahead of the runtime's file loader.
---@return boolean installed false when there is no bundle
function Bundle.install()
    local fs = love.filesystem
    if not fs.getInfo(Bundle.PATH, "file") then return false end

    local file = fs.newFile(Bundle.PATH)
    local opened, err = file:open("r")
    if not opened then error("module bundle: cannot open " .. Bundle.PATH .. ": " .. tostring(err), 0) end
    local function read(offset, size)
        if not file:seek(offset) then error("module bundle: cannot seek to " .. offset, 0) end
        local data = file:read(size)
        if type(data) ~= "string" or #data ~= size then
            error("module bundle: short read at " .. offset .. " in " .. Bundle.PATH, 0)
        end
        return data
    end
    local index = Bundle.read_index(read)

    local loaders = package.loaders or package.searchers
    table.insert(loaders, 2, function(name)
        local path = Bundle.find(index, name)
        if not path then return "\n\tno module '" .. name .. "' in " .. Bundle.PATH end
        local entry = index[path]
        local chunk, load_err = loadstring(read(entry.offset, entry.size), "@" .. path)
        if not chunk then error(load_err, 0) end
        return chunk
    end)
    return true
end

return Bundle
