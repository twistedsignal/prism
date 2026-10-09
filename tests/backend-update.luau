-- backend-only updates restart the backend and reload in place; plugin changes ask for a studio restart.
local fs = require('@lune/fs')
local luau = require('@lune/luau')
local roblox = require('@lune/roblox')
local function source(value)
    return function(...)
        if select('#', ...) > 0 then value = ... end
        return value
    end
end
local queue = {}
local modules = {
    ['./vide'] = {source = source, effect = function() end, untrack = function(fn) return fn() end},
    ['./Data'] = {load = function(_, _, fallback) return fallback end, save = function() end},
    ['./Types'] = {}, ['./Base64'] = {}, ['./Version'] = '0.21.0', ['./PluginHash'] = 'plugin-hash',
    ['./MaterialStyle'] = {load = function() return 'auto' end, save = function() end},
    ['./PathGlob'] = {}, ['./ScriptInsert'] = {}, ['./Serializer'] = {}, ['./LightingSync'] = {},
    ['./Template'] = {defaults = function() return {} end},
}
local Store = luau.load(fs.readFile('src/Store.luau'):gsub('%f[%w]const%f[%W]', 'local'), {environment = {
    require = function(name) return assert(modules[name], name) end,
    game = {GetService = function() return {UrlEncode = function(_, text) return text end} end},
    Vector2 = roblox.Vector2, os = os,
    task = {
        spawn = function(fn) table.insert(queue, coroutine.create(fn)) end,
        delay = function() end,
        -- short waits poll again; the half-hour update loop never resumes.
        wait = function(seconds)
            if (seconds or 0) < 60 then table.insert(queue, coroutine.running()) end
            coroutine.yield()
        end,
    },
}})()
local function drain()
    local steps = 0
    while #queue > 0 do
        steps += 1
        assert(steps < 1000, 'scheduler did not settle')
        local ok, message = coroutine.resume(table.remove(queue, 1))
        assert(ok, message)
    end
end

local function run(pluginChanged)
    local requests, statusCalls, refreshed = {}, 0, 0
    local bridge = {
        connected = function() return true end,
        refresh = function() refreshed += 1 end,
        request = function(method, path, body)
            table.insert(requests, method .. ' ' .. path)
            if method == 'POST' and path == '/update' then
                assert(body.pluginHash == 'plugin-hash')
                return {ok = true, body = {version = '0.21.1', plugins = {}, pluginChanged = pluginChanged}}
            elseif path == '/status' then
                statusCalls += 1
                -- the old backend answers once more before it exits.
                return {ok = true, body = {version = if statusCalls < 3 then '0.21.0' else '0.21.1'}}
            end
            return {ok = false, status = 0}
        end,
    }
    local store = Store.create({}, bridge)
    drain()
    local result
    store.installUpdate(function(ok, version, _, changed)
        result = {ok = ok, version = version, changed = changed}
    end)
    drain()
    return store, result, requests, statusCalls, refreshed
end

local store, result, requests, statusCalls, refreshed = run(false)
assert(result.ok and result.version == '0.21.1' and result.changed == false)
assert(store.updateState() == 'idle', store.updateState())
assert(statusCalls == 3 and refreshed == 1)
assert(table.find(requests, 'GET /schema'), 'renders reload after the new backend answers')
assert(table.find(requests, 'GET /schema') > table.find(requests, 'GET /status'))
assert(store.notice() and store.notice().kind == 'success', 'tells the user no restart is needed')

store, result, requests, statusCalls, refreshed = run(true)
assert(result.ok and result.changed == true)
assert(store.updateState() == 'restart')
assert(statusCalls == 0 and refreshed == 0 and not table.find(requests, 'GET /schema'))

store, result = run(nil)
assert(result.changed == true and store.updateState() == 'restart', 'older backends still ask for a restart')
print('backend-update ok')
