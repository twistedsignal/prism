local fs = require('@lune/fs')
local luau = require('@lune/luau')
local roblox = require('@lune/roblox')
local function source(value)
    return function(...)
        if select('#', ...) > 0 then value = ... end
        return value
    end
end
local pending, saved, persisted = {}, {}, {}
local saveFails = false
local modules = {
    ['./vide'] = {source = source, effect = function() end},
    ['./Data'] = {
        load = function(_, key, fallback)
            return if persisted[key] ~= nil then persisted[key] else fallback
        end,
        save = function(_, key, value)
            if saveFails then error('Disk unavailable') end
            saved[key] = value
        end,
    },
    ['./Types'] = {}, ['./Base64'] = {}, ['./Version'] = 'test', ['./PluginHash'] = 'test',
    ['./MaterialStyle'] = {load = function() return 'auto' end, save = function() end},
    ['./PathGlob'] = {}, ['./ScriptInsert'] = {}, ['./Serializer'] = {}, ['./LightingSync'] = {},
    ['./Template'] = {defaults = function() return {} end},
}
local Store = luau.load(fs.readFile('src/Store.luau'):gsub('%f[%w]const%f[%W]', 'local'), {environment = {
    require = function(name) return assert(modules[name], name) end,
    game = {GetService = function() return {} end}, Vector2 = roblox.Vector2,
    task = {spawn = function(fn) table.insert(pending, fn) end, delay = function() end,
            wait = function() coroutine.yield() end},
}})()
local function create()
    return Store.create({}, {connected = function() return false end,
        request = function() error('Display preferences must work offline') end})
end
local function drain()
    while #pending > 0 do
        local ok, message = coroutine.resume(coroutine.create(table.remove(pending, 1)))
        assert(ok, message)
    end
end
local defaults = create()
drain()
assert(defaults.showBlenderVersion() and defaults.showStatusDot())
defaults.setShowBlenderVersion(false)
assert(not defaults.showBlenderVersion() and defaults.showStatusDot())
drain()
assert(saved.PrismShowBlenderVersion == false and saved.PrismShowStatusDot == nil)
defaults.setShowStatusDot(false)
drain()
assert(saved.PrismShowStatusDot == false)
persisted = table.clone(saved)
local restored = create()
drain()
assert(not restored.showBlenderVersion() and not restored.showStatusDot())
restored.setShowBlenderVersion(true)
drain()
assert(restored.showBlenderVersion() and not restored.showStatusDot())
assert(saved.PrismShowBlenderVersion and saved.PrismShowStatusDot == false)
-- A user edit made before the asynchronous load finishes wins over the saved value.
persisted = {PrismShowBlenderVersion = true, PrismShowStatusDot = false}
local early = create()
early.setShowBlenderVersion(false)
drain()
assert(not early.showBlenderVersion() and not early.showStatusDot())
persisted = {PrismShowBlenderVersion = 'invalid', PrismShowStatusDot = 0}
local invalid = create()
drain()
assert(invalid.showBlenderVersion() and invalid.showStatusDot())
saveFails = true
invalid.setShowStatusDot(false)
drain()
assert(not invalid.showStatusDot() and invalid.notice().kind == 'error')
print('Header preference defaults, independent toggles, offline persistence, restoration, early edits and failures passed')
