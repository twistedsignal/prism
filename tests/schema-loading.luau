-- Exercise schema publication with Vide's synchronous effects and the real slider.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local source = require("../Packages/_Index/centau_vide@0.4.1/vide/src/source")
local effect = require("../Packages/_Index/centau_vide@0.4.1/vide/src/effect")
local root = require("../Packages/_Index/centau_vide@0.4.1/vide/src/root")
local queue = {}
local guid = 0
local nextSchema = { defaults = { zoom = 1, enabled = false } }
local modules = {
	["./vide"] = { source = source, effect = effect,
		untrack = require("../Packages/_Index/centau_vide@0.4.1/vide/src/untrack") },
	["./Data"] = { load = function(_, _, fallback) return fallback end },
	["./MaterialStyle"] = { load = function() return "auto" end },
	["./Template"] = { defaults = function() return {} end },
	["./Serializer"] = { serialize = function() return { payload = { parts = { {} } }, warnings = {} } end },
	["./Types"] = {}, ["./Base64"] = {}, ["./LightingSync"] = {}, ["./PathGlob"] = {}, ["./ScriptInsert"] = {},
	["./Version"] = "test", ["./PluginHash"] = "test",
}
local Store = luau.load(fs.readFile("src/Store.luau"):gsub("%f[%w]const%f[%W]", "local"), { environment = {
	require = function(name) return assert(modules[name], name) end,
	game = { GetService = function()
		return { GenerateGUID = function() guid += 1 return tostring(guid) end,
			JSONEncode = function() return "{}" end }
	end },
	task = { spawn = function(fn) table.insert(queue, coroutine.create(fn)) end,
		delay = function() end, wait = function() coroutine.yield() end },
} })()
local function drain()
	while #queue > 0 do
		local ok, message = coroutine.resume(table.remove(queue, 1))
		assert(ok, message)
	end
end
local sliders = 0
local uiModules = {
	["../vide"] = {
		create = function()
			return function(props)
				-- Evaluate the same properties that Vide applies when a slider mounts.
				for _, key in { "Size", "Position", "Text" } do
					if type(props[key]) == "function" then props[key]() end
				end
				return props
			end
		end,
		action = function() return {} end,
	},
	["./Theme"] = { stroke = function() return {} end },
	["./BaseSetting"] = function() return {} end,
	["../Overlay"] = {},
}
local Slider = luau.load(fs.readFile("src/components/SliderSetting.luau"):gsub("%f[%w]const%f[%W]", "local"), {
	environment = { require = function(name) return assert(uiModules[name], name) end,
		UDim2 = roblox.UDim2, UDim = roblox.UDim, Vector2 = roblox.Vector2, Enum = roblox.Enum },
})()
local store
local dispose = root(function()
	store = Store.create({}, { connected = function() return false end,
		request = function(_, path)
			return if path == "/schema" then { ok = true, body = nextSchema } else { ok = false }
		end })
	effect(function()
		local schema = store.schema()
		if not schema then return end
		local model = store.currentModel()
		local values = if model then model.settings() else schema.defaults
		for key, default in schema.defaults do
			if type(default) == "number" then
				Slider({ name = key, index = 1, min = 0, max = 10, step = 0.1,
					value = function() return values[key] end, onChange = function() end })
				sliders += 1
			end
		end
		for key, default in schema.defaults do
			assert(type(values[key]) == type(default), `Missing setting {key} when schema became visible`)
		end
	end)
end)
drain()
local first, second = { Name = "First" }, { Name = "Second" }
store.useSelection({ first, second })
drain()
store.models()[1].settings({ zoom = 2 })
store.models()[2].settings({ enabled = false })
store.selected(2)
store.reload()
drain()
assert(sliders > 0, "The loaded schema must mount real sliders")
assert(store.models()[1].settings().zoom == 2, "Schema loading must preserve edits")
assert(store.models()[2].settings().zoom == 1, "Every selected model needs defaults")
assert(store.models()[2].settings().enabled == false)

-- A schema refresh adds defaults while preserving edits and remembered settings.
store.useSelection({ second })
nextSchema = { defaults = { zoom = 1, enabled = false, exposure = 0.5 } }
store.reload()
drain()
assert(store.currentModel().settings().exposure == 0.5)
store.useSelection({ first })
drain()
assert(store.currentModel().settings().zoom == 2)
assert(store.currentModel().settings().exposure == 0.5, "Reselection must fill new schema defaults")
store.reload()
drain()
assert(store.currentModel().settings().zoom == 2)
store.useSelection({})
store.reload()
drain()
store.destroy()
dispose()
print("Schema startup, refresh, reselection and slider checks passed")
