-- Mount the page with Vide's actual branch lifecycle and real slider/color controls.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local source = require("../Packages/_Index/centau_vide@0.4.1/vide/src/source")
local root = require("../Packages/_Index/centau_vide@0.4.1/vide/src/root")
local effect = require("../Packages/_Index/centau_vide@0.4.1/vide/src/effect")
local graph = require("../Packages/_Index/centau_vide@0.4.1/vide/src/graph")
local function cleanup(fn) graph.push_cleanup(graph.get_scope(), fn) end
local rows = {}
local function node(props)
	props.GetPropertyChangedSignal = function()
		return { Connect = function() return function() end end }
	end
	return props
end
local function base(props)
	local row = { active = true }
	rows[props.name] = row
	cleanup(function() row.active = false end)
	return row
end
local vide = {
	source = source, effect = effect, cleanup = cleanup,
	values = require("../Packages/_Index/centau_vide@0.4.1/vide/src/values"),
	show = require("../Packages/_Index/centau_vide@0.4.1/vide/src/show"),
	create = function() return node end,
	action = function() return {} end, changed = function() return {} end,
}
local theme = { stroke = function() return {} end }
local globals = {
	game = { CreatorId = 0, GetService = function() return {} end },
	UDim2 = roblox.UDim2, UDim = roblox.UDim, Vector2 = roblox.Vector2,
	Color3 = roblox.Color3, Enum = roblox.Enum,
	task = { defer = function(fn) fn() end },
}
local function load(path, modules)
	local environment = table.clone(globals)
	environment.require = function(name) return modules[name] end
	return luau.load(fs.readFile(path):gsub("%f[%w]const%f[%W]", "local"), { environment = environment })()
end
local controlsVide = table.clone(vide)
controlsVide.create = function()
	return function(props)
		for _, key in { "Size", "Position", "Text", "BackgroundColor3", "BackgroundTransparency" } do
			if type(props[key]) == "function" then effect(function() props[key]() end) end
		end
		return node(props)
	end
end
local controls = setmetatable({
	["../vide"] = controlsVide, ["./Theme"] = theme, ["./BaseSetting"] = base,
}, { __index = function() return {} end })
local modules = setmetatable({
	["../vide"] = vide, ["../components/Theme"] = theme,
	["../components/SliderSetting"] = load("src/components/SliderSetting.luau", controls),
	["../components/ColorSetting"] = load("src/components/ColorSetting.luau", controls),
	["../components/Section"] = function()
		return { header = {}, body = {}, layout = node({ AbsoluteContentSize = { Y = 34 } }),
			setHeight = function() end }
	end,
	["../SettingsSearch"] = load("src/SettingsSearch.luau", {}),
	["../Requirements"] = load("src/Requirements.luau", {}),
}, { __index = function() return function() return {} end end })
local page = load("src/pages/RenderPage.luau", modules)
local function schema(numberKey, colorKey)
	return { defaults = { [numberKey] = 1, [colorKey] = "#FFFFFF" }, sections = {
		{ id = "camera", label = "Camera", settings = {
			{ key = numberKey, label = numberKey, type = "number", min = 0, max = 10, step = 0.1 },
			{ key = colorKey, label = colorKey, type = "color" },
		} },
	} }
end
local current = source({ settings = source({ zoom = 2, sunColor = "#FF0000" }) })
local store = { currentModel = current, models = source({}), schema = source(nil), config = source(nil),
	previewView = source("blender"), selected = source(1) }
local dispose = root(function()
	page({ store = store, connected = function() return false end,
		rootSize = function() return roblox.Vector2.new(720, 860) end })
end)
store.schema(schema("zoom", "sunColor"))
assert(rows.zoom.active and rows.sunColor.active)
-- As loadRemote does, populate model defaults before publishing the new schema.
current().settings({ zoom = 2, sunColor = "#FF0000", exposure = 1, tint = "#FFFFFF" })
store.schema(schema("zoom", "tint"))
current(nil)
assert(not rows.sunColor.active and rows.tint.active, "Color controls must follow schema changes")
current({ settings = source({ zoom = 2, sunColor = "#FF0000", exposure = 1, tint = "#FFFFFF" }) })
store.schema(schema("exposure", "tint"))
-- Stale controls previously read missing defaults and crashed upon deselection.
current(nil)
assert(not rows.zoom.active and not rows.sunColor.active, "Removed controls must be disposed")
assert(rows.exposure.active and rows.tint.active, "New schema controls must mount")
local exposure = rows.exposure
store.schema(nil)
assert(not exposure.active, "Clearing the schema must dispose its controls")
store.schema(schema("zoom", "sunColor"))
assert(rows.zoom.active and rows.sunColor.active, "Settings must remount after reconnect")
dispose()
assert(not rows.zoom.active and not rows.sunColor.active)
print("Schema panel refresh, slider/color cleanup, deselection and reconnect checks passed")
