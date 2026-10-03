local fs = require('@lune/fs')
local luau = require('@lune/luau')
local Vector2 = require('@lune/roblox').Vector2
local function load(path, environment)
    local code = fs.readFile(path):gsub('%f[%w]const%f[%W]', 'local')
    return luau.load(code, { environment = environment or {} })()
end
local camera = load('src/CameraControls.luau')
local settings = { cameraRotation = 20, cameraElevation = 15, zoom = 1 }
local model = { name = 'Test', settings = function() return settings end }
local controls, move, initiatingPress
local source = function(value) return function(next)
    if next ~= nil then value = next end
    return value
end end
local vide = {
    source = source, cleanup = function() end, show = function() end,
    effect = function(callback) callback() end,
    create = function() return function(properties)
        if properties.Name == 'CameraControls' then controls = properties end
        return properties
    end end,
}
local modules = {
    ['../vide'] = vide, ['./Theme'] = { stroke = function() return {} end },
    ['./Segmented'] = function() return {} end, ['../Types'] = {},
    ['../CameraControls'] = camera, ['./Spinner'] = function() return {} end,
    ['../Overlay'] = { drag = function(input, callback) initiatingPress = input; move = callback end },
}
local Preview = load('src/components/Preview.luau', {
    require = function(path) return assert(modules[path], path) end,
    Vector2 = Vector2,
    UDim = { new = function() return {} end },
    UDim2 = { new = function() return {} end, fromOffset = function() return {} end, fromScale = function() return {} end },
    Enum = { UserInputType = { MouseWheel = 'Wheel', MouseButton1 = 'Left' }, ScaleType = { Fit = 'Fit' },
             AutomaticSize = { Y = 'Y' }, TextXAlignment = { Left = 'Left' }, TextTruncate = { AtEnd = 'AtEnd' },
             Font = { SourceSansBold = 'Bold', SourceSans = 'Regular' } },
})
Preview({
    currentModel = function() return model end, view = function() return 'blender' end,
    previewVersion = function() return 1 end, previewImage = function() return nil end,
    setCamera = function(values) for key, value in values do settings[key] = value end end,
})
local input = { UserInputType = 'Left', Position = { X = 100, Y = 100 } }
controls.InputBegan(input)
assert(initiatingPress == input)
move(Vector2.new(120, 110))
assert(settings.cameraRotation == 30 and settings.cameraElevation == 20)
move(Vector2.new(130, 115))
assert(settings.cameraRotation == 35 and settings.cameraElevation == 22.5)
controls.InputChanged({ UserInputType = 'Wheel', Position = { Z = 1 } })
assert(settings.zoom > 1)
print('Preview mouse drag and wheel checks passed')
