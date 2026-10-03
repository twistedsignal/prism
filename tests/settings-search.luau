local fs = require("@lune/fs")
local luau = require("@lune/luau")
local code = fs.readFile("src/SettingsSearch.luau"):gsub("%f[%w]const%f[%W]", "local")
local matches = luau.load(code)().matches

assert(matches("", "Camera Rotation"), "Clearing search restores settings")
assert(matches(" \t ", "Camera Rotation"), "Whitespace is an empty search")
assert(matches("  CAMERA   rotation ", "Camera Rotation cameraRotation"), "Search ignores case and repeated spaces")
assert(matches("rotation camera", "Camera Rotation"), "Words may appear in any order")
assert(not matches("camera sun", "Camera Rotation"), "Every search word must match")
assert(matches("(X)", "Model stance Pitch (X)"), "Punctuation is literal")
assert(not matches(".*", "Camera Rotation"), "Search does not interpret Lua patterns")
assert(matches("sun intensity", "Lighting Sun Sun intensity sunIntensity Brightness of the sun"), "Group names combine with setting names")
assert(matches("brightness", "Lighting Sun Sun intensity sunIntensity Brightness of the sun"), "Descriptions are searchable")
assert(matches("sunIntensity", "Lighting Sun Sun intensity sunIntensity"), "Setting keys are searchable")

print("Settings search checks passed")

-- Mount the actual settings tree and rerun its reactive visibility callbacks.
local roblox = require("@lune/roblox")
local effects, nodes, sectionsByName, rows = {}, {}, {}, {}
local query = ""
local values = { enabled = false }
local function node(props)
    props.GetPropertyChangedSignal = function()
        return { Connect = function() return {} end }
    end
    table.insert(nodes, props)
    return props
end
local function row(props)
    local result = { name = props.name, onCommit = props.onCommit }
    rows[props.name] = result
    return result
end
local modules = setmetatable({
    ['../vide'] = {
        create = function() return node end,
        effect = function(fn) table.insert(effects, fn) end,
        cleanup = function() end,
    },
    ['../components/Theme'] = {},
    ['../components/Section'] = function(_, name, _, collapsed, _, forceExpanded)
        local result = {
            header = {}, body = {}, layout = node({ AbsoluteContentSize = { Y = 34 } }),
            setHeight = function() end,
            collapsed = collapsed, forceExpanded = forceExpanded,
        }
        sectionsByName[name] = result
        return result
    end,
    ['../components/SliderSetting'] = row,
    ['../components/ToggleSetting'] = row,
    ['../components/TextBoxSetting'] = row,
    ['../components/BaseSetting'] = row,
    ['../components/Button'] = function() return {} end,
    ['../SettingsSearch'] = { matches = matches },
    ['../Requirements'] = luau.load((fs.readFile('src/Requirements.luau'):gsub('%f[%w]const%f[%W]', 'local')))(),
}, { __index = function() return {} end })
local uiCode = fs.readFile('src/pages/RenderPage.luau'):gsub('%f[%w]const%f[%W]', 'local')
    :gsub('return RenderPage%s*$', 'return SettingsSections')
local mount = luau.load(uiCode, { environment = {
    require = function(name) return modules[name] end,
    game = { GetService = function() return {} end },
    UDim2 = roblox.UDim2, UDim = roblox.UDim, Vector2 = roblox.Vector2, Enum = roblox.Enum,
    task = { defer = function(fn) fn() end },
} })()
local schema = { defaults = values, sections = {
    { id = 'camera', label = 'Camera', collapsed = true, settings = {
        { type = 'number', key = 'rotation', label = 'Rotation' },
        { type = 'number', key = 'zoom', label = 'Zoom', description = 'Scale the model' },
        { type = 'text', key = 'caption', label = 'Caption', maxLength = 3 },
        { type = 'text', key = 'secret', label = 'Hidden', hidden = true },
    } },
    { id = 'lighting', label = 'Lighting', settings = {
        { type = 'group', label = 'Sun', collapsed = true, settings = {
            { type = 'number', key = 'sunIntensity', label = 'Intensity' },
            { type = 'number', key = 'sunGlow', label = 'Glow', requires = 'enabled' },
        } },
        { type = 'group', label = 'Gated', requires = 'enabled', settings = {
            { type = 'number', key = 'gatedPower', label = 'Power' },
        } },
    } },
} }
local committed
mount({ currentModel = function() return nil end, busy = function() return nil end,
    setValue = function(_, value) committed = value end },
    function() return schema end, function() return query end)
local function refresh(text)
    query = text
    for _, fn in effects do fn() end
end
local function named(name)
    for _, item in nodes do if item.Name == name then return item end end
    error('Missing node ' .. name)
end
local function empty()
    for _, item in nodes do if item.Text == 'No matching settings' then return item end end
    error('Missing empty message')
end
refresh('sun intensity')
assert(rows.Intensity.Visible and not rows.Rotation.Visible and not rows.Glow.Visible)
assert(named('Sun').Visible and not named('Gated').Visible)
assert(not sectionsByName.Camera.header.Visible and sectionsByName.Lighting.header.Visible)
assert(sectionsByName.Sun.forceExpanded(), 'Searching expands collapsed nested groups')
assert(not empty().Visible)
refresh('camera')
assert(rows.Rotation.Visible and rows.Zoom.Visible and not rows.Intensity.Visible)
assert(sectionsByName.Camera.forceExpanded(), 'Searching expands collapsed sections')
refresh('scale')
assert(rows.Zoom.Visible and not rows.Rotation.Visible, 'Descriptions filter actual rows')
refresh('sync')
assert(rows['Sync Lighting'].Visible and sectionsByName.Lighting.header.Visible)
refresh('glow')
assert(empty().Visible, 'Unavailable conditional controls do not produce matches')
values.enabled = true
refresh('glow')
assert(rows.Glow.Visible and named('Sun').Visible and not empty().Visible)
refresh('nothing matches')
assert(empty().Visible and not sectionsByName.Camera.header.Visible and not sectionsByName.Lighting.header.Visible)
refresh('')
assert(rows.Rotation.Visible and rows.Zoom.Visible and rows.Intensity.Visible)
assert(not sectionsByName.Sun.forceExpanded() and sectionsByName.Sun.collapsed, 'Clearing search preserves collapse state')
assert(not empty().Visible and rows.Hidden == nil, 'Hidden schema fields never render')
print('Settings tree filtering, nested groups, conditional controls and empty state checks passed')

rows.Caption.onCommit("😀😀😀😀")
assert(committed == "😀😀😀" and utf8.len(committed) == 3, "Text limits must preserve complete Unicode characters")
rows.Caption.onCommit("hi")
assert(committed == "hi")
