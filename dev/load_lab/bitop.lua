--- Pure-Lua stand-in for Lua BitOp, for the PUC driver only.
---
--- The 3DS runtime links the C BitOp library (`reference_rng.lua` says where); a stock PUC 5.1
--- has none. This covers the operations the game uses, with BitOp's semantics: arguments are
--- reduced modulo 2^32 and results are signed 32-bit. It is much slower than the C library, so
--- it counts calls per operation, and the driver subtracts what those calls cost beyond a call to
--- a C function (`excess_per_call`).
local M = { counts = { band = 0, bor = 0, bxor = 0, lshift = 0, rshift = 0, tobit = 0, bnot = 0 } }
local counts = M.counts

local TWO32, TWO31 = 4294967296, 2147483648

local AND, OR, XOR = {}, {}, {}
for a = 0, 15 do
    for b = 0, 15 do
        local r_and, r_or, r_xor, bit = 0, 0, 0, 1
        local x, y = a, b
        for _ = 1, 4 do
            local xb, yb = x % 2, y % 2
            if xb == 1 and yb == 1 then r_and = r_and + bit end
            if xb == 1 or yb == 1 then r_or = r_or + bit end
            if xb ~= yb then r_xor = r_xor + bit end
            x, y, bit = (x - xb) / 2, (y - yb) / 2, bit * 2
        end
        AND[a * 16 + b], OR[a * 16 + b], XOR[a * 16 + b] = r_and, r_or, r_xor
    end
end

local floor = math.floor

-- BitOp converts with the 2^52 + 2^51 trick: round to nearest, ties to even, then mod 2^32.
local MAGIC = 6755399441055744
local function u32(x)
    return ((x + MAGIC) - MAGIC) % TWO32
end

local function signed(x)
    if x >= TWO31 then return x - TWO32 end
    return x
end

local function op(name, t)
    local f
    f = function(a, b, ...)
        counts[name] = counts[name] + 1
        local x, y = u32(a), u32(b)
        local r, scale = 0, 1
        for _ = 1, 8 do
            local xn, yn = x % 16, y % 16
            r = r + t[xn * 16 + yn] * scale
            x, y, scale = (x - xn) / 16, (y - yn) / 16, scale * 16
        end
        if select("#", ...) > 0 then return f(signed(r), ...) end
        return signed(r)
    end
    return f
end

M.band, M.bor, M.bxor = op("band", AND), op("bor", OR), op("bxor", XOR)

function M.lshift(x, n)
    counts.lshift = counts.lshift + 1
    return signed((u32(x) * 2 ^ (n % 32)) % TWO32)
end

function M.rshift(x, n)
    counts.rshift = counts.rshift + 1
    return signed(floor(u32(x) / 2 ^ (n % 32)))
end

function M.tobit(x)
    counts.tobit = counts.tobit + 1
    return signed(u32(x))
end

function M.bnot(x)
    counts.bnot = counts.bnot + 1
    return signed(TWO32 - 1 - u32(x))
end

--- Total calls so far.
function M.total()
    local n = 0
    for _, c in pairs(counts) do n = n + c end
    return n
end

--- Seconds per call this stand-in spends beyond a two-argument call to a C function, per
--- operation, measured on this host now. Typical game arguments: full-range 32-bit words.
---@param clock fun(): number
---@return table<string, number>
function M.excess_per_call(clock)
    local N = 200000
    local saved = {}
    for k, v in pairs(counts) do saved[k] = v end
    local a, b = 0x9e3779b9, 0x7f4a7c15
    local cmax = math.max
    local t0 = clock()
    for _ = 1, N do cmax(a, b) end
    local base = (clock() - t0) / N
    local per = {}
    for name in pairs(counts) do
        local f = M[name]
        local arg2 = (name == "lshift" or name == "rshift") and 13 or b
        t0 = clock()
        for _ = 1, N do f(a, arg2) end
        per[name] = math.max(0, (clock() - t0) / N - base)
    end
    for k, v in pairs(saved) do counts[k] = v end
    return per
end

return M
