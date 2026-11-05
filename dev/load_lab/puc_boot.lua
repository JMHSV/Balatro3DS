--- Load Lab, PUC Lua 5.1 driver: the boot path's Lua cost under the console's interpreter.
---
---   BALATRO_ROOT=<repo> lua5.1 dev/load_lab/puc_boot.lua <stage_dir> <out_file> [time|alloc]
---
--- Run from the repository root. Game modules are loaded from `<stage_dir>`, the Lua exactly as
--- the build would ship it (`score.py` writes it), so anything the build does to Lua is what gets
--- timed. LÖVE is `tests/love_stub.lua`: no real asset is decoded, which is the point -- this
--- measures the interpreter, and `init.lua` counts the I/O under real LÖVE.
---
--- Walks the same two phases as `init.lua`: boot (main.lua, love.load, the first menu frame) and
--- hand (`to_hand.lua`). Modes:
---
---   time   phase CPU time, per-module compile time inline, and a compile bench that recompiles
---          every module the phases compiled, many times over, for a per-module figure that the
---          host clock's resolution does not swamp.
---   alloc  the same walk with the collector stopped, so `collectgarbage("count")` deltas are
---          bytes allocated rather than whatever survived the last cycle.
assert(not rawget(_G, "jit"), "puc_boot.lua is for PUC Lua 5.1; run it with lua5.1, not LuaJIT")
assert(_VERSION == "Lua 5.1", "puc_boot.lua needs Lua 5.1, got " .. tostring(_VERSION))

local stage_dir, out_file, mode = arg[1], arg[2], arg[3] or "time"
assert(stage_dir and out_file, "usage: lua5.1 dev/load_lab/puc_boot.lua <stage_dir> <out_file> [time|alloc]")
assert(mode == "time" or mode == "alloc", "mode must be time or alloc")
assert(os.getenv("BALATRO_ROOT"), "set BALATRO_ROOT to the repository root (tests/love_stub.lua reads it)")

package.path = "./?.lua;./?/init.lua;" .. package.path

local DT = 1 / 60
local Trace = require("dev.load_lab.trace")
local View = require("dev.load_lab.view")
local script = require("dev.load_lab.to_hand")

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- The whole stage is read into memory before anything is timed: the console's file costs are
-- `score.py`'s business, and host file I/O inside a timed phase would be scaled up as Lua CPU.
local listing = assert(read_file(stage_dir .. "/" .. "FILES.txt"), "no FILES.txt in the stage; run score.py stage")
local staged = {}
for path in listing:gmatch("[^\n]+") do
    staged[path] = assert(read_file(stage_dir .. "/" .. path), "stage lists but lacks " .. path)
end
local view = View.new(function() return read_file("dev/load_lab/package_baseline.tsv") end,
    function(path) return staged[path] end)

-- Allocation accounting. With the collector stopped the heap only shrinks when something asks for
-- a collection outright (fonts.lua does), so each such call's drop is added back.
local freed_kb = 0
if mode == "alloc" then
    local raw_collect = collectgarbage
    raw_collect("collect")
    raw_collect("stop")
    collectgarbage = function(opt, arg2)
        opt = opt or "collect"
        if opt == "count" then return raw_collect("count") end
        if opt == "restart" or opt == "setpause" or opt == "setstepmul" then return 0 end
        local before = raw_collect("count")
        local r = raw_collect(opt, arg2)
        local after = raw_collect("count")
        if before > after then freed_kb = freed_kb + (before - after) end
        raw_collect("stop")
        return r
    end
end
local function allocated_kb()
    return collectgarbage("count") + freed_kb
end

-- The console's runtime links Lua BitOp; a stock PUC 5.1 has none. Only `reference_rng.lua` uses it.
local bitop = require("dev.load_lab.bitop")
assert(not package.loaded.bit and not package.preload.bit, "a `bit` module is already present; drop the stand-in")
package.preload.bit = function() return bitop end

local stub = require("tests.love_stub")
local love = stub.install()

Trace.on_loaded("console", function(Console)
    Console.is_new_3ds = function() return false end
end)
Trace.install_searcher(view, "?.lua;?/init.lua")
-- From here on a game module comes from the stage or not at all: without this, one the stage
-- lacks would quietly load from the working tree through the stock path searcher.
local loaders = package.loaders
for i = #loaders, 3, -1 do table.remove(loaders, i) end

-- The console's screens with 3D off: the left eye, then the bottom screen.
local SCREENS = { "left", "bottom" }
local function frame()
    love._test.advance(DT)
    love.update(DT)
    for _, s in ipairs(SCREENS) do love.draw(s) end
end

-- Shim calls per phase, so their extra cost can be taken out of that phase's CPU time.
local bit_counts = {}
local function snapshot_bits()
    local snap = {}
    for k, v in pairs(bitop.counts) do snap[k] = v end
    return snap
end
local function close_bits(phase, since)
    local now = snapshot_bits()
    local d = {}
    for k, v in pairs(now) do d[k] = v - since[k] end
    bit_counts[phase] = d
    return now
end

local kb0 = allocated_kb()
local bits0 = snapshot_bits()
Trace.phase("boot")
for _, path in ipairs({ "conf.lua", "main.lua" }) do
    local src = assert(view.read(path), path .. " missing from the stage")
    local chunk = Trace.compile(path, path, src)
    chunk()
end
if love.conf then love.conf({ window = {}, modules = {}, audio = {} }) end
love.load()
frame()
assert(G and G.STATE == G.STATES.MENU, "load lab: first frame is not the main menu")
local kb1 = allocated_kb()
Trace.phase_stat("boot", "alloc_kb", string.format("%.1f", kb1 - kb0))
local bits1 = close_bits("boot", bits0)

Trace.phase("hand")
local lab = setmetatable({}, { __index = function(_, k) if k == "G" then return G end end })
function lab.wait(seconds)
    for _ = 1, math.max(1, math.floor(seconds / DT + 0.5)) do coroutine.yield() end
end
local co = coroutine.create(function() script(lab) end)
local frames = 0
while true do
    local ok, err = coroutine.resume(co)
    if not ok then error(err, 0) end
    if coroutine.status(co) == "dead" then break end
    frame()
    frames = frames + 1
end
Trace.phase_stat("hand", "frames", frames)
Trace.phase_stat("hand", "alloc_kb", string.format("%.1f", allocated_kb() - kb1))
Trace.phase(nil)
close_bits("hand", bits1)

local excess = mode == "time" and bitop.excess_per_call(os.clock) or nil
for _, phase in ipairs({ "boot", "hand" }) do
    local calls, seconds = 0, 0
    for k, n in pairs(bit_counts[phase]) do
        calls = calls + n
        if excess then seconds = seconds + n * excess[k] end
    end
    Trace.phase_stat(phase, "bitop_calls", calls)
    if excess then Trace.phase_stat(phase, "bitop_excess_s", string.format("%.6f", seconds)) end
end

local extra = { mode = mode, lua = _VERSION }
local text = Trace.serialize(extra)

if mode == "time" then
    -- Compile bench: every module the walk compiled, recompiled REPS times, interleaved so drift
    -- in the host's clock spreads evenly. The lab's own driver files are not part of the game.
    local REPS = 20
    local mods = {}
    for _, m in ipairs(Trace.result().modules) do
        if m.observed then mods[#mods + 1] = { m = m, src = assert(view.module(m.path), m.path), t = 0 } end
    end
    for _ = 1, REPS do
        for _, e in ipairs(mods) do
            local t0 = os.clock()
            local chunk = loadstring(e.src, "@" .. e.m.path)
            e.t = e.t + (os.clock() - t0)
            assert(chunk, e.m.path)
        end
    end
    local lines = {}
    for _, e in ipairs(mods) do
        lines[#lines + 1] = table.concat({ "compilebench", tostring(e.m.phase), e.m.path,
            tostring(e.m.bytes), string.format("%.7f", e.t / REPS) }, "\t")
    end
    text = text .. table.concat(lines, "\n") .. "\n"
end

local f = assert(io.open(out_file, "wb"))
f:write(text)
f:close()
io.write("[load-lab] puc ", mode, " run written to ", out_file, "\n")
