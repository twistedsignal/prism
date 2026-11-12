local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local function source(value)
	return function(...)
		if select("#", ...) > 0 then value = ... end
		return value
	end
end
local sessionGuid = 0
local function scenario(failImage, supersede, blockedName)
	local pending, errors, exports = {}, {}, {}
	local previewCalls = 0
	local writeFails = false
	local imageSize = 1
	local thumbnails = {}
	local clients = {}
	local guid = 0
	local modules = {
		["./vide"] = { source = source, effect = function() end },
		["./Data"] = { load = function() return {} end },
		["./Types"] = {}, ["./LightingSync"] = {},
		["./MaterialStyle"] = { load = function() return "auto" end },
		["./PathGlob"] = { pathOf = function() return "Workspace/Test" end },
		["./ScriptInsert"] = {}, ["./Template"] = { defaults = function() return {} end },
		["./Base64"] = { decode = function() return buffer.create(4) end },
		["./Version"] = "test", ["./PluginHash"] = "test",
		["./Serializer"] = { serialize = function(root)
			if root.Name == blockedName then coroutine.yield() end
			return { payload = { parts = { {} } }, warnings = {} }
		end },
	}
	local bridge = { connected = function() return true end, request = function(method, path, body)
		if path == "/scenes" then return { ok = true, body = { sceneId = "scene", warnings = {} } } end
		if path == "/preview" then
			previewCalls += 1
			table.insert(clients, body.client)
			if supersede then return { ok = false, status = 409, error = "superseded" } end
			return { ok = true, body = { width = imageSize, height = imageSize, pixels = "AAAAAA==" } }
		end
		if path == "/export" then
			table.insert(exports, body.items)
			local results = {}
			for _, item in body.items do table.insert(results, { name = item.name }) end
			return { ok = true, body = { results = results, folder = "test" } }
		end
		return { ok = false, error = "offline" }
	end }
	local module = luau.load(fs.readFile("src/Store.luau"):gsub("%f[%w]const%f[%W]", "local"), { environment = {
		require = function(path) return assert(modules[path], path) end,
		Vector2 = roblox.Vector2,
		game = { GetService = function(_, name)
			if name == "HttpService" then return {
				GenerateGUID = function() guid += 1; sessionGuid += 1; return tostring(sessionGuid) end,
				JSONEncode = function() return "{}" end,
			} end
			if name == "AssetService" then return { CreateEditableImage = function()
				if failImage then return nil end
				return { Size = roblox.Vector2.new(imageSize, imageSize), WritePixelsBuffer = function() if writeFails then error("Pixel write failed") end end, Destroy = function(self) self.destroyed = true end }
			end } end
			return {}
		end },
		task = { spawn = function(callback) table.insert(pending, callback) end,
			delay = function(seconds, callback) if seconds == 0.6 then table.insert(thumbnails, callback) end end, wait = function() coroutine.yield() end },
	} })()
	local store = module.create({}, bridge)
	local function drain()
		while #pending > 0 do
			local ok, message = coroutine.resume(coroutine.create(table.remove(pending, 1)))
			if not ok then table.insert(errors, tostring(message)) end
		end
	end
	return store, drain, function() return previewCalls, errors, exports, clients end,
		function(allocateFails: boolean, pixelFails: boolean, size: number)
			failImage, writeFails, imageSize = allocateFails, pixelFails, size
		end,
		function()
			while #thumbnails > 0 do table.remove(thumbnails, 1)() end
			drain()
		end
end
local store, drain, inspect, fail, thumbnails = scenario(true, false)
store.useSelection({ { Name = "A" } })
drain()
local before, errors = inspect()
assert(#errors == 0 and store.previewState() == "error")
fail(false, false, 1)
store.requestPreview()
drain()
local after = inspect()
assert(after == before + 1 and store.previewState() == "idle")
local old = store.previewImage()
fail(true, false, 2)
store.requestPreview()
drain()
assert(store.previewImage() == old and not old.destroyed, "Failed replacement preserves the old image")
fail(false, true, 2)
store.requestPreview()
drain()
assert(store.previewImage() == old and not old.destroyed)
fail(false, false, 2)
store.requestPreview()
drain()
assert(store.previewState() == "idle" and store.previewImage() ~= old and old.destroyed)
fail(true, false, 2)
thumbnails()
assert(store.models()[1].thumbnail == nil)
fail(false, false, 2)
store.setValue("zoom", 2)
drain()
thumbnails()
assert(store.models()[1].thumbnail ~= nil, "Thumbnail queue recovers after allocation failure")

local second, drainSecond, inspectSecond = scenario(false, true)
second.useSelection({ { Name = "A" } })
drainSecond()
local count, _, _, clientsSecond = inspectSecond()
assert(count == 1 and second.previewState() == "idle", "Superseded previews settle")
local _, _, _, clientsFirst = inspect()
assert(clientsFirst[1] ~= clientsSecond[1], "Each Store has an independent preview client key")

store, drain, inspect = scenario(false, false, "B")
store.useSelection({ { Name = "A" }, { Name = "B" } })
drain()
assert(store.models()[2].state() == "serializing")
store.exportModels(store.models())
drain()
local _, _, exports = inspect()
assert(#exports[1] == 2 and exports[1][2].error and exports[1][1].payload,
	"Every requested model remains in the batch, with recovery data or a preparation error")
print("Preview allocation/write recovery, thumbnail recovery, session keys, cancellation and batch completeness checks passed")
