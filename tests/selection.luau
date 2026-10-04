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
local serialized = {}
local delayed = {}
local duringSerialize = nil
local guid = 0
local modules = {
	["./vide"] = { source = source, effect = function() end },
	["./Data"] = { load = function() return {} end },
	["./Types"] = {},
	["./LightingSync"] = {},
	["./MaterialStyle"] = { load = function() return "auto" end, save = function() end },
	["./PathGlob"] = { pathOf = function() return "" end, match = function() return {}, false end },
	["./ScriptInsert"] = {},
	["./Template"] = { defaults = function() return {} end },
	["./Base64"] = {},
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
				return {}
			end,
		},
		task = {
			spawn = function(callback) table.insert(pending, callback) end,
			delay = function(time, callback)
				if time == 0.2 then table.insert(delayed, callback) end
			end,
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

local store = storeModule.create({}, { connected = function() return false end })
local first = { Name = "First" }
local second = { Name = "Second" }
local third = { Name = "Third" }

store.useSelection({ first })
drain()
assert(#store.models() == 1)
local original = store.models()[1]
original.settings({ zoom = 2 })

store.useSelection({ first, second })
drain()
assert(#store.models() == 2)
assert(store.models()[1] == original)
assert(original.settings().zoom == 2)
assert(store.currentModel() == original)

local reads = #serialized
store.useSelection({ first, first, second })
drain()
assert(#store.models() == 2, "Reselection must not duplicate models")
assert(#serialized == reads, "Existing models must not be serialized again")
assert(store.currentModel() == original)

local destroyedThumbnails = 0
original.thumbnail = { Destroy = function() destroyedThumbnails += 1 end }
store.useSelection({ second })
assert(#store.models() == 1 and store.currentModel().instance == second)
assert(destroyedThumbnails == 1 and original.thumbnail == nil)
store.useSelection({ first })
assert(store.currentModel().settings().zoom == 2, "Reselecting a model must restore its settings")
store.useSelection({ second })
store.useSelection({})
drain()
assert(#store.models() == 0 and store.currentModel() == nil, "Deselecting all must clear the menu")
assert(store.previewImage() == nil and store.previewState() == "idle")

-- Deselecting while serialization yields must discard the stale result.
local fourth = { Name = "Fourth" }
duringSerialize = function() store.useSelection({ fourth }) end
store.useSelection({ third })
drain()
assert(#store.models() == 1 and store.currentModel().instance == fourth)
assert(store.currentModel().state() == "sending")
assert(table.find(serialized, third) and table.find(serialized, fourth))

-- A stale item must not prevent a retained item in the same import from loading.
store.useSelection({ first, second })
store.useSelection({ second })
drain()
assert(#store.models() == 1 and store.currentModel().instance == second)
assert(store.currentModel().state() == "sending")

store.mode("this")
store.setCamera({ cameraRotation = 42, cameraElevation = 20, zoom = 1.4, ignored = 99 })
assert(store.currentModel().settings().cameraRotation == 42)
assert(store.currentModel().settings().ignored == nil)
store.mode("all")
store.setCamera({ zoom = 2.4 })
for _, model in store.models() do
	assert(model.settings().zoom == 2.4, "Camera gestures must update real render settings in the selected scope")
end
store.destroy()
store.useSelection({ { Name = "After cleanup" } })
assert(#store.models() == 1, "Disposed stores must ignore selection events")
local sceneRequests = 0
local incomplete = true
local duringSend = nil
local retryStore = storeModule.create({}, {
	connected = function() return true end,
	request = function(_, path)
		if path == "/scenes" then
			sceneRequests += 1
			if duringSend then
				local callback = duringSend
				duringSend = nil
				callback()
			end
			return { ok = true, body = {
				sceneId = tostring(sceneRequests), incomplete = incomplete,
				warnings = if incomplete then { "Mesh recovery failed; using a box" } else {},
			} }
		end
		return { ok = false, status = 409 }
	end,
})
local recoverable = { Name = "Recoverable" }
retryStore.useSelection({ recoverable })
drain()
assert(sceneRequests == 1)
assert(retryStore.currentModel().warning() ~= nil)
local serializationsBeforeRetry = #serialized
incomplete = false
retryStore.useSelection({ recoverable })
drain()
assert(sceneRequests == 2, "Reselecting an incomplete model must retry backend recovery")
assert(retryStore.currentModel().warning() == nil, "Successful recovery must clear placeholder warnings")
assert(#serialized == serializationsBeforeRetry, "Recovery must preserve the existing Studio payload")
-- Refresh the same model without reselection, preserving settings and identity.
local retained = retryStore.currentModel()
retained.settings({ zoom = 3 })
local function flushEdits()
	while #delayed > 0 do table.remove(delayed, 1)() end
	drain()
end
local beforeEdits = #serialized
retryStore.refreshModel(retained)
retryStore.refreshModel(retained)
retryStore.refreshModel(retained)
assert(retained.sceneId() == nil and retained.state() == "serializing")
assert(retryStore.previewView() == "3d")
flushEdits()
assert(#serialized == beforeEdits + 1, "Rapid edits must serialize only once")
assert(retained.visualVersion() == 2, "Viewport clones refresh after the edit debounce")
assert(sceneRequests == 3 and retained.sceneId() == "3", "Edits must replace the backend scene")
assert(retryStore.currentModel() == retained and retained.settings().zoom == 3)

-- A newer edit during serialization must discard the superseded payload.
duringSerialize = function() retryStore.refreshModel(retained) end
beforeEdits = #serialized
retryStore.refreshModel(retained)
flushEdits()
assert(#serialized == beforeEdits + 2 and sceneRequests == 4)

-- An edit while a scene upload yields invalidates that upload, even if payloads encode identically.
retryStore.refreshModel(retained)
duringSend = function()
	retryStore.refreshModel(retained)
end
local pendingEdit = table.remove(delayed, 1)
pendingEdit()
assert(retained.sceneId() == nil and retained.state() == "serializing", "A superseded upload must not mark the model ready")
flushEdits()
assert(retained.sceneId() == "6" and retained.state() == "ready")

-- Removal cancels a scheduled refresh and preserves the settings for reselection.
retryStore.refreshModel(retained)
beforeEdits = #serialized
retryStore.useSelection({})
flushEdits()
assert(#serialized == beforeEdits, "Removed models must not refresh")
retryStore.useSelection({ recoverable })
drain()
assert(retryStore.currentModel().settings().zoom == 3)
retained = retryStore.currentModel()
retryStore.refreshModel(retained)
beforeEdits = #serialized
retryStore.destroy()
flushEdits()
assert(#serialized == beforeEdits, "Destroying the store cancels pending edits")
print("Selection checks passed")
