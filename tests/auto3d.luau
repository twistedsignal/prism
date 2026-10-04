-- Run with: lune run tests/selection.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local function source(value)
	return function(...)
		if select("#", ...) > 0 then
			value = ...
		end
		return value
	end
end

local pending = {}
local delayed = {}
local saved = {}
local restored = true
local writes = 0
local Vector2 = require("@lune/roblox").Vector2
local serialized = {}
local duringSerialize = nil
local guid = 0
local modules = {
	["./vide"] = { source = source, effect = function() end },
	["./Data"] = {
		load = function(_, key, fallback) return if key == "PrismAuto3d" then restored else fallback end,
		save = function(_, key, value) saved[key] = value end,
	},
	["./Types"] = {},
	["./LightingSync"] = {},
	["./MaterialStyle"] = { load = function() return "auto" end, save = function() end },
	["./Base64"] = { decode = function() return buffer.create(4) end },
	["./Version"] = "test",
	["./Serializer"] = {
		serialize = function(instance)
			table.insert(serialized, instance)
			if duringSerialize then
				local callback = duringSerialize
				duringSerialize = nil
				callback()
			end
			return { payload = { parts = { {} } }, warnings = {} }
		end,
	},
}
-- Lune uses stock Luau; Studio supports the const declarations used by this plugin.
local code = fs.readFile("src/Store.luau"):gsub("%f[%w]const%f[%W]", "local")
local storeModule = luau.load(code, {
	environment = {
		Vector2 = Vector2,
		require = function(path) return assert(modules[path], path) end,
		game = {
			GetService = function(_, name)
				if name == "HttpService" then
					return {
						GenerateGUID = function()
							guid += 1
							return tostring(guid)
						end,
						JSONEncode = function() return "{}" end,
					}
				end
				if name == "AssetService" then
					return { CreateEditableImage = function(_, options)
						return { Size = options.Size, Destroy = function() end,
							WritePixelsBuffer = function() writes += 1 end }
					end }
				end
				return {}
			end,
		},
		task = {
			spawn = function(callback) table.insert(pending, callback) end,
			delay = function(seconds, callback) if seconds == 0.12 then table.insert(delayed, callback) end end,
			-- Stop the update timer after its first wait.
			wait = function() coroutine.yield() end,
		},
	},
})()

local function drain()
	while #pending > 0 do
		local thread = coroutine.create(table.remove(pending, 1))
		local ok, message = coroutine.resume(thread)
		assert(ok, message)
	end
end

local connected = false
local duringRender = nil
local renders = 0
local store = storeModule.create({}, {
	connected = function() return connected end,
	request = function(_, path)
		assert(path == "/preview", path)
		renders += 1
		if duringRender then
			local callback = duringRender
			duringRender = nil
			callback()
		end
		return { ok = true, body = { width = 1, height = 1, pixels = "" } }
	end,
})
drain()
assert(store.auto3d() and store.previewView() == "3d")
local model = { id = "1", settings = source({ zoom = 1 }), state = source("ready"), sceneId = source("scene") }
store.models({ model })
connected = true
store.requestPreview()
drain()
assert(store.previewView() == "blender" and writes == 1)
-- A drag invalidates an in-flight image before the debounce expires.
duringRender = function()
	store.setCamera({ cameraRotation = 40 })
	assert(store.previewView() == "3d")
end
store.requestPreview()
drain()
assert(store.previewView() == "3d" and writes == 1, "stale image switched back to Blender")
table.remove(delayed, 1)()
drain()
assert(store.previewView() == "blender" and writes == 2)
store.beginTextDrag()
assert(store.textPreviewing(), "Text drag did not show the temporary preview")
store.setTextOffset({ textOffsetX = 36, textOffsetY = -12 })
assert(store.previewView() == "blender", "Text drag changed the selected view")
drain()
assert(store.textPreviewing() and writes == 2, "Text drag rendered before release")
store.endTextDrag()
assert(store.textPreviewing(), "Text preview disappeared before the final render")
drain()
assert(model.settings().textOffsetX == 36 and store.previewView() == "blender" and not store.textPreviewing())
-- Coalesced immediate edits also suppress the obsolete image.
duringRender = function() store.setValue("yaw", 10) end
store.requestPreview()
drain()
assert(writes == 4 and renders == 6)
store.setAuto3d(false)
drain()
assert(saved.PrismAuto3d == false)
store.previewView("blender")
store.setCamera({ cameraRotation = 80 })
assert(store.previewView() == "blender", "manual view changed with Auto-3D off")
store.setAuto3d(true)
assert(store.previewView() == "3d")
drain()
assert(store.previewView() == "blender" and saved.PrismAuto3d == true)
restored = false
local second = storeModule.create({}, { connected = function() return false end })
drain()
assert(not second.auto3d() and second.previewView() == "blender")
print("Auto-3D default, persistence, manual view and stale-render checks passed")
