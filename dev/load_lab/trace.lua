--- Load Lab trace: records what boot asks of the console's filesystem and Lua compiler.
---
--- Shared by the two drivers. `init.lua` runs the game under desktop LÖVE and uses this for
--- the counts (which files, how many bytes, which textures). `puc_boot.lua` runs the same boot
--- under PUC Lua 5.1 against `tests/love_stub.lua` and uses it for compile and exec timing.
---
--- Everything here is about the console's view of the game, not the desktop's: a driver hands
--- in a `view` that answers "does this path exist in the shipped package, and what are its
--- bytes", and every event is recorded under the path the console would open.
---
--- Desktop only. `dev/` is never staged into a console build.
local Trace = {}

local clock = os.clock

local state = {
    phase = nil,
    paused = 0,
    events = {},     -- { phase, kind, path, a, b }
    modules = {},    -- compile records, in compile order
    phases = {},     -- name -> { cpu0, cpu1 }
    order = {},      -- phase names in order
    stack = {},      -- exec stack of module records
    on_loaded = {},  -- module name -> function(module)
}

--- Record one event in the current phase. Ignored while paused (lab setup, nest's desktop
--- emulation) or before the first phase starts.
---@param kind string
---@param path string
function Trace.event(kind, path, a, b)
    if state.paused > 0 or not state.phase then return end
    state.events[#state.events + 1] = { state.phase, kind, path, a or "", b or "" }
end

--- Run `fn` with recording suspended. For lab plumbing that the console never does.
function Trace.untraced(fn, ...)
    state.paused = state.paused + 1
    local results = { pcall(fn, ...) }
    state.paused = state.paused - 1
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2)
end

function Trace.recording()
    return state.paused == 0 and state.phase ~= nil
end

--- Close the current phase (if any) and open `name`.
function Trace.phase(name)
    local now = clock()
    if state.phase then state.phases[state.phase].cpu1 = now end
    state.phase = name
    if name then
        assert(not state.phases[name], "phase opened twice: " .. name)
        state.phases[name] = { cpu0 = now }
        state.order[#state.order + 1] = name
    end
end

--- Call `fn(module)` once `name` has been required through the traced searcher.
function Trace.on_loaded(name, fn)
    state.on_loaded[name] = fn
end

--- A compile the console performs that the desktop driver cannot observe (main.lua is
--- compiled by the runtime before any lab code exists). Recorded with its size only.
function Trace.compiled_elsewhere(path, bytes)
    state.modules[#state.modules + 1] = {
        phase = state.phase, name = path, path = path, bytes = bytes,
        compile = 0, exec = 0, self = 0, child = 0, observed = false,
    }
end

--- Wrap a compiled chunk so its execution time is attributed to `rec`, with nested requires
--- subtracted to give self time.
local function timed_chunk(chunk, rec)
    return function(...)
        local stack = state.stack
        stack[#stack + 1] = rec
        local t0 = clock()
        local results = { pcall(chunk, ...) }
        local dt = clock() - t0
        stack[#stack] = nil
        rec.exec = rec.exec + dt
        local parent = stack[#stack]
        if parent then parent.child = parent.child + dt end
        if not results[1] then error(results[2], 0) end
        return unpack(results, 2)
    end
end

--- Compile `src` as `path` and record it. Errors are raised, not returned: a module that does
--- not compile is a broken measurement, not a data point.
---@return function chunk
function Trace.compile(name, path, src)
    local t0 = clock()
    local chunk, err = loadstring(src, "@" .. path)
    local dt = clock() - t0
    if not chunk then error("load lab: " .. tostring(err), 0) end
    local rec = {
        phase = state.phase, name = name, path = path, bytes = #src,
        compile = dt, exec = 0, child = 0, observed = true,
    }
    if Trace.recording() then
        state.modules[#state.modules + 1] = rec
        local parent = state.stack[#state.stack]
        if parent then parent.child = parent.child + dt end
    end
    return timed_chunk(chunk, rec)
end

--- Install a `require` searcher ahead of every other one. It resolves module names exactly as
--- LÖVE's own loader does (each `?` template of the require path in turn, one existence probe
--- per template tried) but against `view`, so a module is found where the console would find it.
---@param view { exists: fun(path: string): boolean, read: fun(path: string): string }
---@param require_path string e.g. "?.lua;?/init.lua"
function Trace.install_searcher(view, require_path)
    local function searcher(name)
        local rel = name:gsub("%.", "/")
        local tried = {}
        for template in require_path:gmatch("[^;]+") do
            local path = template:gsub("%?", rel)
            Trace.event("stat", path, view.exists(path) and "hit" or "miss")
            if view.exists(path) then
                local src = view.read(path)
                assert(src, "load lab view claims " .. path .. " exists but cannot read it")
                Trace.event("open", path, #src, "compile")
                local chunk = Trace.compile(name, path, src)
                local hook = state.on_loaded[name]
                if hook then
                    return function(...)
                        local m = chunk(...)
                        hook(m == nil and package.loaded[name] or m)
                        return m
                    end
                end
                return chunk
            end
            tried[#tried + 1] = path
        end
        return "\n\tno file in the load lab's console view: " .. table.concat(tried, ", ")
    end
    local loaders = package.loaders or package.searchers
    table.insert(loaders, 2, searcher)
end

function Trace.result()
    return state
end

--- Plain-text dump, one record per line, for `score.py`. Stable order: events as they
--- happened, then modules in compile order, then phases.
---@param extra table<string,string>|nil header fields
---@return string
function Trace.serialize(extra)
    local out = { "# load lab trace v1" }
    local header = {}
    for k in pairs(extra or {}) do header[#header + 1] = k end
    table.sort(header)
    for _, k in ipairs(header) do out[#out + 1] = "#\t" .. k .. "\t" .. tostring(extra[k]) end
    for _, e in ipairs(state.events) do
        out[#out + 1] = table.concat({ "event", e[1], e[2], e[3], tostring(e[4]), tostring(e[5]) }, "\t")
    end
    for _, m in ipairs(state.modules) do
        local self_time = m.exec - m.child
        out[#out + 1] = table.concat({ "module", tostring(m.phase), m.name, m.path, tostring(m.bytes),
            string.format("%.6f", m.compile), string.format("%.6f", m.exec),
            string.format("%.6f", self_time), m.observed and "observed" or "runtime" }, "\t")
    end
    for _, name in ipairs(state.order) do
        local p = state.phases[name]
        out[#out + 1] = table.concat({ "phase", name, string.format("%.6f", (p.cpu1 or clock()) - p.cpu0) }, "\t")
        local keys = {}
        for k in pairs(p) do
            if k ~= "cpu0" and k ~= "cpu1" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            out[#out + 1] = table.concat({ "phasestat", name, k, tostring(p[k]) }, "\t")
        end
    end
    return table.concat(out, "\n") .. "\n"
end

--- Attach a named number to a phase (GC counts, frame counts).
function Trace.phase_stat(name, key, value)
    assert(state.phases[name], "no such phase: " .. tostring(name))
    state.phases[name][key] = value
end

return Trace
