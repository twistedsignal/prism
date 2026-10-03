local fs = require('@lune/fs')
local luau = require('@lune/luau')
local Vector2 = require('@lune/roblox').Vector2
local function load(path, environment)
    local code = fs.readFile(path):gsub('%f[%w]const%f[%W]', 'local')
    return luau.load(code, { environment = environment or {} })()
end
local camera = load('src/CameraControls.luau')
local settings = { cameraRotation = 20, cameraElevation = 15, zoom = 1, textOffsetX = 0, textOffsetY = 0 }
local progress
local phase, previewPhase, busy, connected = "ready", "idle", nil, true
local model = { state = function() return phase end, name = 'Test', settings = function() return settings end }
local controls, move, onEnd, initiatingPress, activity, activityText, spinnerVisible
local textPreview, renderImage
local image, textBounds
local textPreviewing = false
local automatic = false
local visibility = {}
local effects = {}
local source = function(value) return function(next)
    if next ~= nil then value = next end
    return value
end end
local vide = {
    source = source, cleanup = function() end, show = function(condition) table.insert(visibility, condition) end,
    effect = function(callback) table.insert(effects, callback); callback() end,
    changed = function(property, target)
        if property == 'AbsoluteSize' then target(Vector2.new(300, 200)) end
        return {}
    end,
    create = function() return function(properties)
        if properties.Name == 'CameraControls' then controls = properties end
        if properties.Name == 'Activity' then activity = properties end
        if properties.Name == 'ActivityText' then activityText = properties end
        if properties.Name == 'TextDragPreview' then textPreview = properties end
        if properties.Name == 'Render' then renderImage = properties end
        return properties
    end end,
}
local modules = {
    ['../vide'] = vide, ['./Theme'] = { stroke = function() return {} end },
    ['./Segmented'] = function() return {} end, ['../Types'] = {},
    ['../CameraControls'] = camera, ['./Spinner'] = function(visible) spinnerVisible = visible; return {} end,
    ['../Overlay'] = { drag = function(input, callback, finish) initiatingPress = input; move = callback; onEnd = finish end },
}
local Preview = load('src/components/Preview.luau', {
    require = function(path) return assert(modules[path], path) end,
    Vector2 = Vector2,
    UDim = { new = function() return {} end },
    UDim2 = { new = function(xScale, xOffset, yScale, yOffset)
        return { X = { Scale = xScale, Offset = xOffset }, Y = { Scale = yScale, Offset = yOffset } }
    end, fromOffset = function() return {} end, fromScale = function() return {} end },
    Enum = { UserInputType = { MouseWheel = 'Wheel', MouseButton1 = 'Left' }, ScaleType = { Fit = 'Fit' },
             AutomaticSize = { Y = 'Y' }, TextXAlignment = { Left = 'Left', Center = 'Center' },
             TextYAlignment = { Center = 'Center' }, TextTruncate = { AtEnd = 'AtEnd' },
             Font = { SourceSansBold = 'Bold', SourceSans = 'Regular' } },
    Font = { fromEnum = function() return 'default' end, new = function(path) return path end },
    Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end },
})
Preview({
    connected = function() return connected end,
    previewState = function() return previewPhase end,
    busy = function() return busy end,
    renderProgress = function() return progress end,
    auto3d = function() return automatic end,
    currentModel = function() return model end, view = function() return 'blender' end,
    previewVersion = function() return 1 end, previewImage = function() return image end,
    previewTextBounds = function() return textBounds end,
    textPreviewing = function() return textPreviewing end,
    fonts = function() return { { value = 'TestFont', robloxFont = 'rbxasset://fonts/families/Test.json' } } end,
    setCamera = function(values) for key, value in values do settings[key] = value end end,
    setTextOffset = function(values) for key, value in values do settings[key] = math.round(value) end end,
    beginTextDrag = function() textPreviewing = true end,
    endTextDrag = function() end,
})
controls.AbsolutePosition = Vector2.new(10, 20)
controls.AbsoluteSize = Vector2.new(200, 200)
local input = { UserInputType = 'Left', Position = { X = 100, Y = 100 } }
controls.InputBegan(input)
assert(initiatingPress == input)
move(Vector2.new(120, 110))
assert(settings.cameraRotation == 30 and settings.cameraElevation == 20)
move(Vector2.new(130, 115))
assert(settings.cameraRotation == 35 and settings.cameraElevation == 22.5)
controls.InputChanged({ UserInputType = 'Wheel', Position = { Z = 1 } })
assert(settings.zoom > 1)
image = {}
effects[1]()
settings.text = 'Drag me'
settings.textFont = 'TestFont'
settings.textColor = '#112233CC'
settings.textSize = 64
settings.textRotation = 15
textBounds = { x = 200, y = 220, width = 80, height = 40 }
controls.AbsoluteSize = Vector2.new(300, 200)
local rotation = settings.cameraRotation
local textPress = { UserInputType = 'Left', Position = { X = 150, Y = 114 } }
controls.InputBegan(textPress)
assert(textPreviewing and textPreview.Visible(), 'Text drag preview did not appear on press')
assert(not renderImage.Visible() and visibility[2](), 'The stale Blender image stayed visible while dragging')
assert(textPreview.Text() == 'Drag me' and textPreview.TextSize() == 25 and textPreview.Rotation() == 15)
assert(textPreview.FontFace() == 'rbxasset://fonts/families/Test.json')
assert(textPreview.TextColor3().R == 17 and math.abs(textPreview.TextTransparency() - 0.2) < 0.001)
move(Vector2.new(170, 124))
assert(settings.textOffsetX == 51 and settings.textOffsetY == 26)
assert(settings.cameraRotation == rotation, 'Dragging text rotated the camera')
assert(textPreview.Position().X.Offset == 51 * 200 / 512, 'Roblox text did not follow the mouse')
onEnd()
assert(textPreview.Visible(), 'Roblox text disappeared before the final render')
textPreviewing = false
assert(renderImage.Visible() and not textPreview.Visible(), 'Rendered text did not replace the drag preview')
controls.InputBegan({ UserInputType = 'Left', Position = { X = 20, Y = 30 } })
move(Vector2.new(30, 30))
assert(settings.cameraRotation == rotation + 5, 'Dragging outside text did not rotate the camera')
print('Preview mouse drag and wheel checks passed')

assert(visibility[1](), "Manual view picker should be visible")
automatic = true
assert(not visibility[1](), "Auto-3D must hide the view picker")

assert(not activity.Visible() and not spinnerVisible(), "Idle preview showed progress")
phase = "sending"
assert(activity.Visible() and spinnerVisible() and activityText.Text() == "Downloading model...")
previewPhase = "rendering"
assert(activityText.Text() == "Downloading model...", "Download phase should take priority")
phase = "ready"
assert(activityText.Text() == "Rendering..." and activity.Visible(), "Auto-3D hid render progress")
previewPhase = "idle"
assert(not activity.Visible(), "Finished render left the indicator visible")
busy = "Rendering"
assert(activityText.Text() == "Rendering...")
progress = { stage = "Rendering base image", completed = 2, total = 5, elapsedSeconds = 2.9 }
assert(activityText.Text() == "Rendering...", "Fast renders should keep the simple label")
progress.elapsedSeconds = 6.5
assert(activityText.Text() == "Rendering base image\n(2/5 steps) · 6s", "Slow renders should show counts and elapsed time")
previewPhase = "idle"
busy = nil
assert(not activity.Visible(), "Stale progress must not keep the indicator visible")
busy = "Uploading"
progress = nil
assert(activityText.Text() == "Uploading...")
busy = nil
phase = "error"
assert(not activity.Visible(), "Failed download left the indicator spinning")
phase = "sending"
connected = false
assert(not activity.Visible(), "Offline model falsely showed an active download")
print("Preview download, render, completion and error indicator checks passed")
