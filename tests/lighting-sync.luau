local fs = require('@lune/fs')
local luau = require('@lune/luau')
local roblox = require('@lune/roblox')
local Color3, Vector3, CFrame = roblox.Color3, roblox.Vector3, roblox.CFrame
local sync = luau.load(fs.readFile('src/LightingSync.luau'):gsub('%f[%w]const%f[%W]', 'local'), {
    environment = { Color3 = Color3, Vector3 = Vector3, CFrame = CFrame },
})()
local sun = Vector3.new(0.3, 0.8, -0.4).Unit
local moon = Vector3.new(-0.3, 0.8, 0.4).Unit
local lighting = {
    Brightness = 2, Ambient = Color3.fromRGB(30, 20, 10), OutdoorAmbient = Color3.fromRGB(127, 127, 127),
    GlobalShadows = true, ColorShift_Top = Color3.new(), ColorShift_Bottom = Color3.new(),
    EnvironmentDiffuseScale = 0, EnvironmentSpecularScale = 0.3, ExposureCompensation = 1,
    GetSunDirection = function() return sun end, GetMoonDirection = function() return moon end,
}
local day = sync.capture(lighting)
assert(day.values.sunColor == '#ffffff' or day.values.sunColor == '#FFFFFF')
assert(day.values.sunIntensity == 2 and day.values.secondaryIntensity == 0)
assert(day.values.ambientIntensity > 0.21 and day.values.ambientIntensity < 0.22)
assert(day.values.castShadows and day.values.exposure == 1 and day.values.specular == 0.3)
assert(day.direction == sun)
lighting.GlobalShadows = false
local unshadowed = sync.capture(lighting)
assert(not unshadowed.values.castShadows and unshadowed.values.ambientIntensity < day.values.ambientIntensity)
lighting.GlobalShadows = true
lighting.EnvironmentDiffuseScale = 1
assert(sync.capture(lighting).values.ambientIntensity > day.values.ambientIntensity)
lighting.ColorShift_Top = Color3.new(1,0,0)
lighting.ColorShift_Bottom = Color3.new(0,0,1)
local tinted = sync.capture(lighting)
assert(tinted.values.sunColor:lower() == '#ff0000' and tinted.values.secondaryColor:lower() == '#0000ff')
assert(tinted.values.secondaryIntensity > 0)
lighting.ColorShift_Top, lighting.ColorShift_Bottom = Color3.new(), Color3.new()
sun = -sun
local night = sync.capture(lighting)
assert(night.direction == moon and night.values.sunIntensity < day.values.sunIntensity)
assert(night.values.sunColor:lower() ~= '#ffffff')
lighting.Brightness = 0
assert(sync.capture(lighting).values.sunIntensity == 0 and not sync.capture(lighting).values.castShadows)
lighting.Brightness, lighting.ExposureCompensation, lighting.EnvironmentSpecularScale = 100, 10, 10
sun = -sun
local capped = sync.capture(lighting)
assert(capped.values.sunIntensity == 3 and capped.values.exposure == 3 and capped.values.specular == 1)

-- Verify world -> pivot -> stance -> camera conversion, including roll and polar directions.
local cases = {
    { pivot = {0,0,0}, stance = {0,0,0}, camera = {0,0,0}, direction = {1,0,0} },
    { pivot = {10,85,-20}, stance = {30,-40,25}, camera = {72,-15,35}, direction = {0.3,0.8,-0.4} },
    { pivot = {-20,-110,30}, stance = {-45,80,-20}, camera = {-105,50,-70}, direction = {-0.5,0.2,0.7} },
    { pivot = {0,0,0}, stance = {0,0,0}, camera = {0,0,0}, direction = {0,1,0} },
}
for _, case in cases do
    local pose = function(v) return CFrame.fromOrientation(math.rad(v[1]), math.rad(v[2]), math.rad(v[3])) end
    local pivot, stance = pose(case.pivot), pose(case.stance)
    local settings = { pitch = case.stance[1], yaw = case.stance[2], roll = case.stance[3],
        cameraRotation = case.camera[1], cameraElevation = case.camera[2], cameraRoll = case.camera[3],
        zoom = 2, text = 'Keep me' }
    local snapshot = { direction = Vector3.new(unpack(case.direction)).Unit, values = day.values }
    local values = sync.forModel(snapshot, settings, pivot)
    local rotation, elevation = math.rad(values.sunRotation), math.rad(values.sunElevation)
    local view = Vector3.new(math.sin(rotation) * math.cos(elevation), math.sin(elevation), math.cos(rotation) * math.cos(elevation))
    local a, e = math.rad(case.camera[1]), math.rad(case.camera[2])
    local eye = Vector3.new(math.sin(a)*math.cos(e), math.sin(e), -math.cos(a)*math.cos(e))
    local right = Vector3.new(-math.cos(a), 0, -math.sin(a))
    local up = eye:Cross(right)
    local r = math.rad(case.camera[3])
    local world = (right*math.cos(r) + up*math.sin(r))*view.X
        + (up*math.cos(r) - right*math.sin(r))*view.Y + eye*view.Z
    local restored = pivot:VectorToWorldSpace(stance:VectorToObjectSpace(world))
    assert(restored:Dot(snapshot.direction) > 0.9998, 'Synced direction changed when transformed back to place space')
    assert(values.sunRotation >= -180 and values.sunRotation < 180 and math.abs(values.sunElevation) <= 89)
    assert(settings.zoom == 2 and settings.text == 'Keep me' and snapshot.values.sunRotation == nil)
    case.sunRotation, case.sunElevation = values.sunRotation, values.sunElevation
end
-- Update the cross-renderer reference only when explicitly regenerating the fixture.
if require('@lune/process').env.PRISM_UPDATE_LIGHTING_FIXTURE == '1' then
    fs.writeFile('tests/fixtures/lighting-directions.json', require('@lune/serde').encode('json', cases, true))
end

local function source(value)
    return function(...)
        if select('#', ...) > 0 then value = ... end
        return value
    end
end
local pending, delayed, saved = {}, {}, nil
local snapshots = 0
local fails = false
local modules = {
    ['./vide'] = { source = source, effect = function() end },
    ['./Data'] = { load = function(_, _, fallback) return fallback end, save = function(_, _, value) saved = value end },
    ['./Types'] = {}, ['./Base64'] = {}, ['./Version'] = 'test',
    ['./Serializer'] = { getParts = function(root) return root.parts end },
    ['./LightingSync'] = {
        capture = function()
            snapshots += 1
            if fails then error('Unavailable') end
            return day
        end,
        forModel = sync.forModel,
    },
}
local storeModule = luau.load(fs.readFile('src/Store.luau'):gsub('%f[%w]const%f[%W]', 'local'), { environment = {
    CFrame = CFrame, Vector2 = roblox.Vector2,
    require = function(name) return assert(modules[name], name) end,
    game = { GetService = function() return {} end },
    task = { spawn = function(fn) table.insert(pending, fn) end,
             delay = function(time, fn) if time == 1 then table.insert(delayed, fn) end end,
             wait = function() coroutine.yield() end },
} })()
local store = storeModule.create({}, { connected = function() return false end })
local function model(rotation, folder)
    local pivot = CFrame.Angles(0, math.rad(rotation), 0)
    return { id = tostring(rotation), instance = {
        IsA = function() return not folder end, GetPivot = function() return pivot end,
        parts = {{CFrame = pivot}},
    }, settings = source({ cameraRotation = 20, cameraElevation = 25, yaw = 10, zoom = 2, text = 'Keep' }),
       state = source('ready'), sceneId = source('scene') }
end
local first, second = model(0), model(90, true)
store.syncLighting()
assert(snapshots == 0, 'Empty selections do nothing')
store.models({first, second})
store.mode('one')
store.activePreset('Saved preset')
store.syncLighting()
assert(first.settings().sunIntensity == 2 and second.settings().sunIntensity == nil)
assert(store.activePreset() == nil and store.notice().kind == 'success')
assert(first.settings().zoom == 2 and first.settings().text == 'Keep')
store.mode('all')
store.syncLighting()
assert(second.settings().sunIntensity == 2 and first.settings().sunRotation ~= second.settings().sunRotation)
local previous = first.settings()
fails = true
store.syncLighting()
assert(first.settings() == previous and store.notice().kind == 'error', 'Failed sync must not partially update settings')
local before = snapshots
store.busy('Uploading')
store.syncLighting()
assert(snapshots == before, 'Busy store must not sync')
store.busy(nil)
while #delayed > 0 do table.remove(delayed, 1)() end
assert(saved.sunIntensity == 2, 'Synced values use the normal persistence path')
print('Lighting sync day/night, colors, clamping, coordinate transforms, scope, persistence and failure checks passed')

-- Mount the settings sections with UI stubs and exercise the action's actual callbacks.
local buttons, rows = {}, {}
local selectedModel, busy = first, nil
local clicks = 0
local function node(props)
    props.GetPropertyChangedSignal = function()
        return { Connect = function() return {} end }
    end
    return props
end
local uiModules = setmetatable({
    ['../vide'] = { create = function() return node end, source = source, effect = function() end,
                   cleanup = function() end },
    ['../components/Theme'] = { ROW_HEIGHT = 34 },
    ['../components/Section'] = function()
        return { header = {}, body = {}, layout = node({ AbsoluteContentSize = {Y = 34} }), setHeight = function() end }
    end,
    ['../components/BaseSetting'] = function(props) table.insert(rows, props); return {} end,
    ['../components/Button'] = function(props) table.insert(buttons, props); return {} end,
}, {__index = function() return {} end})
local uiCode = fs.readFile('src/pages/RenderPage.luau'):gsub('%f[%w]const%f[%W]', 'local'):gsub('return RenderPage%s*$', 'return SettingsSections')
local sections = luau.load(uiCode, { environment = {
    require = function(name) return uiModules[name] end,
    game = { GetService = function() return {} end },
    UDim2 = roblox.UDim2, UDim = roblox.UDim, Vector2 = roblox.Vector2,
    Enum = { AutomaticSize = {Y = 'Y'}, SortOrder = {LayoutOrder = 'LayoutOrder'} },
    task = { defer = function(fn) fn() end },
} })()
sections({ currentModel = function() return selectedModel end, busy = function() return busy end,
           syncLighting = function() clicks += 1 end },
         function() return {sections = {{id = 'stance', label = 'Stance', settings = {}},
                                       {id = 'lighting', label = 'Lighting', settings = {}}}} end)
assert(#buttons == 1 and buttons[1].text == 'Sync Lighting' and rows[1].index == 0)
assert(buttons[1].enabled())
buttons[1].activated()
assert(clicks == 1)
selectedModel = nil
assert(not buttons[1].enabled())
selectedModel, busy = first, 'Uploading'
assert(not buttons[1].enabled())
print('Lighting section button, edit scope and disabled state checks passed')
