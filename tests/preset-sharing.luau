local fs = require('@lune/fs')
local luau = require('@lune/luau')
local roblox = require('@lune/roblox')
local function source(value)
    return function(...)
        if select('#', ...) > 0 then value = ... end
        return value
    end
end
local pending, requests = {}, {}
local response = {ok = true, body = {}}
local modules = {
    ['./vide'] = {source = source, effect = function() end},
    ['./Data'] = {load = function(_, _, fallback) return fallback end, save = function() end},
    ['./Types'] = {}, ['./Base64'] = {}, ['./Version'] = 'test', ['./PluginHash'] = 'test',
    ['./MaterialStyle'] = {load = function() return 'auto' end, save = function() end},
    ['./PathGlob'] = {}, ['./ScriptInsert'] = {}, ['./Serializer'] = {}, ['./LightingSync'] = {},
    ['./Template'] = {defaults = function() return {} end},
}
local Store = luau.load(fs.readFile('src/Store.luau'):gsub('%f[%w]const%f[%W]', 'local'), {environment = {
    require = function(name) return assert(modules[name], name) end,
    game = {GetService = function() return {UrlEncode = function(_, text) return text end} end}, Vector2 = roblox.Vector2,
    task = {spawn = function(fn) table.insert(pending, fn) end, delay = function() end},
}})()
local store = Store.create({}, {connected = function() return false end, request = function(method, path, body)
    table.insert(requests, {method, path, body})
    return response
end})
local model = {settings = source({zoom = 1.25}), state = source('ready'), sceneId = source('scene')}
store.models({model})
store.activePreset('Existing')
local original = model.settings()
local callback
store.decodePreset('code', function(result, message) callback = {result, message} end)
table.remove(pending)()
assert(requests[#requests][2] == '/presets/decode' and callback[1] == response.body)
assert(next(store.presets()) == nil and model.settings() == original and store.activePreset() == 'Existing')
response = {ok = true, body = {name = 'Imported', presets = {Imported = {zoom = 3}}}}
store.importPreset('code', 'Imported', function(result) callback = result end)
table.remove(pending)()
assert(store.presets().Imported.zoom == 3 and callback.name == 'Imported')
assert(model.settings() == original and store.activePreset() == 'Existing', 'Import must not apply settings')
response = {ok = false, error = 'Invalid code'}
store.exportPreset('Imported', function(result, message) callback = {result, message} end)
table.remove(pending)()
assert(callback[1] == nil and callback[2] == 'Invalid code')
assert(store.presets().Imported.zoom == 3 and model.settings() == original)
response = {ok = true, body = {presets = {Imported = {zoom = 3}}}}
store.deletePreset('Existing', function(ok) assert(ok) end)
table.remove(pending)()
assert(store.activePreset() == nil and model.settings() == original)
print('Preset sharing Store persistence, non-application, failures and deletion checks passed')

-- Exercise the dialog callbacks with deferred requests and explicit dismissal.
local dialog, nodes, codeInputs, cleanups = nil, {}, {}, {}
local function node(props)
    props.CaptureFocus = function() end
    table.insert(nodes, props)
    return props
end
local function close()
    for _, cleanup in cleanups do cleanup() end
    cleanups = {}
    dialog.closed = true
end
local fake = {presets = source({Saved = {zoom = 2}}), activePreset = source(nil)}
local callbacks, calls = {}, {}
for _, action in {'decode', 'import', 'export', 'delete'} do
    fake[action .. 'Preset'] = function(...)
        local args = {...}
        callbacks[action] = table.remove(args)
        calls[action] = args
    end
end
fake.copyText = function(code, done) calls.copy = code callbacks.copy = done end
local deps = {
    ['../vide'] = {
        source = source, create = function() return node end,
        batch = function(fn) fn() end,
        cleanup = function(fn) table.insert(cleanups, fn) end, effect = function(fn) fn() end,
        changed = function(_, fn) return fn end,
    },
    ['./Theme'] = {stroke = function() return {} end, OVERLAY_Z = 50}, ['../Store'] = {},
    ['./Modal'] = {open = function(props)
        nodes, codeInputs, cleanups = {}, {}, {}
        dialog = props
        props.body(close)
        return close
    end},
    ['./Dropdown'] = function(props) return props end,
    ['./CodeBox'] = function(props)
        local result = {frame = {}, box = {}, props = props}
        table.insert(codeInputs, result)
        return result
    end,
}
local Dialogs = luau.load(fs.readFile('src/components/PresetDialogs.luau'):gsub('%f[%w]const%f[%W]', 'local'), {environment = {
    require = function(name) return assert(deps[name], name) end,
    UDim2 = roblox.UDim2, UDim = roblox.UDim, Enum = roblox.Enum,
    task = {defer = function(fn) fn() end},
}})()
local function activate()
    if dialog.buttons[2].enabled() then dialog.buttons[2].activated(close) end
end
Dialogs.import(fake)
codeInputs[1].props.onChange('bad')
activate()
assert(calls.decode[1] == 'bad' and not dialog.buttons[2].enabled())
activate()
callbacks.decode(nil, 'Invalid code')
assert(dialog.buttons[2].text() == 'Next' and dialog.buttons[2].enabled())
codeInputs[1].props.onChange('valid')
activate()
callbacks.decode({settings = {zoom = 2}}, nil)
assert(dialog.buttons[2].text() == 'Save')
-- The TextBox's change handler is its first numeric child.
for _, n in nodes do
    if n.PlaceholderText == 'Your preset name' then n[1]('Personal') end
end
activate()
assert(calls.import[1] == 'valid' and calls.import[2] == 'Personal')
callbacks.import(nil, 'Duplicate name')
assert(not dialog.closed and dialog.buttons[2].enabled())
activate()
callbacks.import({name = 'Personal'}, nil)
assert(dialog.closed)
Dialogs.import(fake)
activate()
close()
callbacks.decode({settings = {}}, nil)
assert(dialog.closed and dialog.buttons[2].text() == 'Working…', 'Dismissed callbacks must do nothing')
Dialogs.saved(fake, 'export')
assert(calls.export[1] == 'Saved')
callbacks.export({code = 'share-code'}, nil)
activate()
assert(calls.copy == 'share-code')
callbacks.copy(false)
assert(dialog.buttons[2].enabled() and dialog.buttons[2].text() == 'Copy')
activate()
callbacks.copy(true)
assert(dialog.buttons[2].text() == 'Copied')
close()
Dialogs.saved(fake, 'delete')
activate()
assert(dialog.buttons[2].text() == 'Confirm delete' and calls.delete == nil)
activate()
callbacks.delete(false, 'Disconnected')
assert(not dialog.closed and dialog.buttons[2].enabled())
activate()
callbacks.delete(true, nil)
assert(dialog.closed)
print('Preset dialogs validation, naming, errors, disabled submissions, stale callbacks, copying and deletion checks passed')
