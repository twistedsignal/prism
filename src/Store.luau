-- app state: the selected models, their settings, previews and backend data.
const AssetService = game:GetService("AssetService")
const HttpService = game:GetService("HttpService")
const vide = require("./vide")
const Data = require("./Data")
const Types = require("./Types")
const Base64 = require("./Base64")
const Serializer = require("./Serializer")

const source = vide.source

const LAST_SETTINGS_KEY = "PrismLastSettings"
const THUMBNAIL_SIZE = 128
const THUMBNAIL_DELAY = 0.6
const SAVE_DELAY = 1

type Bridge = {
	connected: () -> boolean,
	request: (method: string, path: string, body: any?) -> any,
}

export type Mode = "one" | "all"
export type Notice = { text: string, kind: "info" | "error" | "success" }
export type UploadResult = { name: string, assetId: string?, moderation: string?, path: string?, error: string? }

const function cloneSettings(settings: Types.Settings): Types.Settings
	return table.clone(settings)
end

const function create(plugin: Plugin, bridge: Bridge)
	const schema = source(nil :: Types.Schema?)
	const config = source(nil :: Types.Config?)
	const presets = source({} :: { [string]: Types.Settings })
	const models = source({} :: { Types.Model })
	const selected = source(1)
	const mode = source("all" :: Mode)
	const activePreset = source(nil :: string?)
	const notice = source(nil :: Notice?)
	const previewVersion = source(0)
	const previewState = source("idle" :: "idle" | "rendering" | "error")
	const previewError = source(nil :: string?)
	const busy = source(nil :: string?)

	local lastSettings: Types.Settings = {}
	task.spawn(function()
		const ok, saved = pcall(Data.load, plugin, LAST_SETTINGS_KEY, {})
		if ok and type(saved) == "table" then
			lastSettings = saved
		end
	end)

	local previewImage: EditableImage? = nil
	const payloads: { [string]: string } = {}
	local destroyed = false

	-- ---------------------------------------------------------------
	-- helpers
	-- ---------------------------------------------------------------

	const function setNotice(text: string, kind: "info" | "error" | "success")
		const value = { text = text, kind = kind }
		notice(value)
		task.delay(6, function()
			if notice() == value then
				notice(nil)
			end
		end)
	end

	const function defaults(): Types.Settings
		const current = schema()
		const result = if current then cloneSettings(current.defaults) else {}
		for key, value in lastSettings do
			if result[key] ~= nil and type(value) == type(result[key]) then
				result[key] = value
			end
		end
		return result
	end

	const function currentModel(): Types.Model?
		return models()[selected()]
	end

	local saveToken = 0
	const function rememberSettings(settings: Types.Settings)
		lastSettings = cloneSettings(settings)
		saveToken += 1
		const token = saveToken
		task.delay(SAVE_DELAY, function()
			if token == saveToken and not destroyed then
				pcall(Data.save, plugin, LAST_SETTINGS_KEY, lastSettings)
			end
		end)
	end

	const function writeImage(image: EditableImage?, body: any): EditableImage?
		const size = Vector2.new(body.width, body.height)
		local target = image
		if target == nil or target.Size ~= size then
			if target then
				target:Destroy()
			end
			target = AssetService:CreateEditableImage({ Size = size })
		end
		assert(target, "EditableImage could not be created")
		target:WritePixelsBuffer(Vector2.zero, size, Base64.decode(body.pixels))
		return target
	end

	-- ---------------------------------------------------------------
	-- scenes
	-- ---------------------------------------------------------------

	local requestPreview: () -> ()
	local queueThumbnail: (Types.Model) -> ()

	const function sendScene(model: Types.Model): boolean
		const payload = payloads[model.id]
		if payload == nil then
			return false
		end
		model.state("sending")
		const response = bridge.request("POST", "/scenes", payload)
		if not response.ok then
			model.state("error")
			model.warning(response.error or "Could not send the model to Prism")
			return false
		end
		model.sceneId(response.body.sceneId)
		model.state("ready")
		return true
	end

	const function render(model: Types.Model, size: number?, client: string): any
		if model.sceneId() == nil and not sendScene(model) then
			return nil
		end
		local response = bridge.request("POST", "/preview", {
			sceneId = model.sceneId(),
			settings = model.settings(),
			size = size,
			client = client,
		})
		if response.status == 404 and sendScene(model) then
			-- the backend restarted or pruned its cache; send the scene again.
			response = bridge.request("POST", "/preview", {
				sceneId = model.sceneId(),
				settings = model.settings(),
				size = size,
				client = client,
			})
		end
		return response
	end

	-- ---------------------------------------------------------------
	-- previews
	-- ---------------------------------------------------------------

	local previewBusy = false
	local previewDirty = false
	requestPreview = function()
		previewDirty = true
		if previewBusy then
			return
		end
		previewBusy = true
		task.spawn(function()
			while previewDirty and not destroyed do
				previewDirty = false
				const model = currentModel()
				if model == nil or model.state() == "serializing" or not bridge.connected() then
					break
				end
				previewState("rendering")
				const response = render(model, nil, "preview")
				if response == nil then
					previewState("error")
					previewError(model.warning())
				elseif response.ok then
					previewImage = writeImage(previewImage, response.body)
					previewVersion(previewVersion() + 1)
					previewState("idle")
					previewError(nil)
				elseif response.status ~= 409 then
					previewState("error")
					previewError(response.error)
				end
			end
			previewBusy = false
		end)
	end

	const thumbnailQueue: { Types.Model } = {}
	local thumbnailBusy = false
	const thumbnailTokens: { [string]: number } = {}

	const function processThumbnails()
		if thumbnailBusy then
			return
		end
		thumbnailBusy = true
		task.spawn(function()
			while #thumbnailQueue > 0 and not destroyed do
				-- the main preview takes priority.
				while previewBusy and not destroyed do
					task.wait(0.05)
				end
				const model = table.remove(thumbnailQueue, 1) :: Types.Model
				if not table.find(models(), model) or not bridge.connected() then
					continue
				end
				const response = render(model, THUMBNAIL_SIZE, `thumb:{model.id}`)
				if response and response.ok then
					model.thumbnail = writeImage(model.thumbnail, response.body)
					model.thumbnailVersion(model.thumbnailVersion() + 1)
				end
			end
			thumbnailBusy = false
		end)
	end

	queueThumbnail = function(model: Types.Model)
		thumbnailTokens[model.id] = (thumbnailTokens[model.id] or 0) + 1
		const token = thumbnailTokens[model.id]
		task.delay(THUMBNAIL_DELAY, function()
			if thumbnailTokens[model.id] ~= token or table.find(thumbnailQueue, model) then
				return
			end
			table.insert(thumbnailQueue, model)
			processThumbnails()
		end)
	end

	-- ---------------------------------------------------------------
	-- models
	-- ---------------------------------------------------------------

	const function destroyModels(list: { Types.Model })
		for _, model in list do
			payloads[model.id] = nil
			if model.thumbnail then
				model.thumbnail:Destroy()
				model.thumbnail = nil
			end
		end
	end

	const function useSelection(roots: { Instance })
		if #roots == 0 then
			setNotice("Select a model, tool, accessory or part first.", "info")
			return
		end
		destroyModels(models())
		const initial = defaults()
		const list: { Types.Model } = {}
		for _, root in roots do
			table.insert(list, {
				id = HttpService:GenerateGUID(false),
				name = root.Name,
				instance = root,
				sceneId = source(nil :: string?),
				state = source("serializing" :: Types.ModelState),
				warning = source(nil :: string?),
				settings = source(cloneSettings(initial)),
				assetId = source(nil :: string?),
				thumbnail = nil,
				thumbnailVersion = source(0),
			})
		end
		models(list)
		selected(1)
		activePreset(nil)

		task.spawn(function()
			for _, model in list do
				if destroyed or models() ~= list then
					return
				end
				const ok, result = pcall(Serializer.serialize, model.instance)
				if not ok then
					model.state("error")
					model.warning(`Could not read {model.name}: {result}`)
					continue
				end
				if #result.payload.parts == 0 then
					model.state("error")
					model.warning(`{model.name} has no visible parts`)
					continue
				end
				payloads[model.id] = HttpService:JSONEncode(result.payload)
				if #result.warnings > 0 then
					model.warning(table.concat(result.warnings, "\n"))
				end
				model.state("sending")
				if bridge.connected() and sendScene(model) then
					if model == currentModel() then
						requestPreview()
					end
					queueThumbnail(model)
				end
			end
		end)
	end

	const function select(index: number)
		if models()[index] == nil then
			return
		end
		selected(index)
		requestPreview()
	end

	-- models affected by an edit, depending on the "this model" / "all" scope.
	const function targets(): { Types.Model }
		if mode() == "all" then
			return models()
		end
		const model = currentModel()
		return if model then { model } else {}
	end

	const function applyToTargets(change: (Types.Settings) -> ())
		const affected = targets()
		for _, model in affected do
			const settings = cloneSettings(model.settings())
			change(settings)
			model.settings(settings)
			queueThumbnail(model)
		end
		const model = currentModel()
		if model then
			rememberSettings(model.settings())
		end
		requestPreview()
	end

	const function setValue(key: string, value: any)
		activePreset(nil)
		applyToTargets(function(settings)
			settings[key] = value
		end)
	end

	const function applySettings(values: Types.Settings)
		applyToTargets(function(settings)
			for key, value in values do
				settings[key] = value
			end
		end)
	end

	const function resetToDefaults()
		const current = schema()
		if current == nil then
			return
		end
		activePreset(nil)
		applySettings(current.defaults)
	end

	const function copyToAll()
		const model = currentModel()
		if model == nil then
			return
		end
		const settings = model.settings()
		for _, other in models() do
			if other ~= model then
				other.settings(cloneSettings(settings))
				queueThumbnail(other)
			end
		end
		setNotice(`Copied {model.name}'s settings to every model.`, "success")
	end

	-- ---------------------------------------------------------------
	-- backend data
	-- ---------------------------------------------------------------

	const function loadRemote()
		const schemaResponse = bridge.request("GET", "/schema")
		if schemaResponse.ok then
			const firstLoad = schema() == nil
			schema(schemaResponse.body)
			if firstLoad then
				-- models created before the schema loaded get the defaults now.
				for _, model in models() do
					const settings = defaults()
					for key, value in model.settings() do
						settings[key] = value
					end
					model.settings(settings)
				end
			end
		end
		const configResponse = bridge.request("GET", "/config")
		if configResponse.ok then
			config(configResponse.body)
		end
		const presetResponse = bridge.request("GET", "/presets")
		if presetResponse.ok then
			presets(presetResponse.body)
		end
		for _, model in models() do
			if model.sceneId() == nil and payloads[model.id] and sendScene(model) then
				queueThumbnail(model)
			end
		end
		requestPreview()
	end

	const function updateConfig(changes: { [string]: any })
		task.spawn(function()
			const response = bridge.request("PUT", "/config", changes)
			if response.ok then
				config(response.body)
			else
				setNotice(response.error or "Could not save settings", "error")
			end
		end)
	end

	const function pickFolder()
		task.spawn(function()
			const response = bridge.request("POST", "/pick-folder")
			if response.ok then
				config(response.body.config)
			else
				setNotice(response.error or "Could not open the folder picker", "error")
			end
		end)
	end

	const function savePreset(name: string)
		const model = currentModel()
		if model == nil then
			return
		end
		task.spawn(function()
			const response = bridge.request("PUT", `/presets/{HttpService:UrlEncode(name)}`, {
				settings = model.settings(),
			})
			if response.ok then
				presets(response.body.presets)
				activePreset(response.body.name)
				setNotice(`Saved preset "{response.body.name}".`, "success")
			else
				setNotice(response.error or "Could not save the preset", "error")
			end
		end)
	end

	const function deletePreset(name: string)
		task.spawn(function()
			const response = bridge.request("DELETE", `/presets/{HttpService:UrlEncode(name)}`)
			if response.ok then
				presets(response.body.presets)
				if activePreset() == name then
					activePreset(nil)
				end
				setNotice(`Deleted preset "{name}".`, "info")
			else
				setNotice(response.error or "Could not delete the preset", "error")
			end
		end)
	end

	const function applyPreset(name: string)
		const settings = presets()[name]
		if settings == nil then
			return
		end
		applySettings(settings)
		activePreset(name)
	end

	-- ---------------------------------------------------------------
	-- export and upload
	-- ---------------------------------------------------------------

	-- returns request items plus the models they came from, in the same order.
	const function items(list: { Types.Model }): ({ { [string]: any } }, { Types.Model })
		const result = {}
		const included = {}
		for _, model in list do
			if model.sceneId() == nil then
				sendScene(model)
			end
			if model.sceneId() then
				table.insert(result, { sceneId = model.sceneId(), name = model.name, settings = model.settings() })
				table.insert(included, model)
			end
		end
		return result, included
	end

	const function exportModels(list: { Types.Model })
		if busy() then
			return
		end
		busy("Rendering")
		task.spawn(function()
			const payload = items(list)
			if #payload == 0 then
				busy(nil)
				setNotice("Nothing to render yet.", "info")
				return
			end
			const response = bridge.request("POST", "/export", { items = payload })
			busy(nil)
			if not response.ok then
				setNotice(response.error or "Rendering failed", "error")
				return
			end
			local saved = 0
			local firstError = nil
			for _, result in response.body.results do
				if result.error then
					firstError = firstError or `{result.name}: {result.error}`
				else
					saved += 1
				end
			end
			if firstError then
				setNotice(`Saved {saved} of {#response.body.results}. {firstError}`, "error")
			else
				setNotice(`Saved {saved} icon{if saved == 1 then "" else "s"} to {response.body.folder}`, "success")
			end
		end)
	end

	const function uploadModels(list: { Types.Model }, creator: string?, onDone: ({ UploadResult }) -> ())
		if busy() then
			return
		end
		busy("Uploading")
		task.spawn(function()
			const payload, included = items(list)
			if #payload == 0 then
				busy(nil)
				setNotice("Nothing to upload yet.", "info")
				return
			end
			const response = bridge.request("POST", "/upload", { items = payload, creator = creator })
			busy(nil)
			if not response.ok then
				setNotice(response.error or "Upload failed", "error")
				return
			end
			const results = response.body.results :: { UploadResult }
			for index, result in results do
				const model = included[index]
				if model and result.assetId then
					model.assetId(result.assetId)
				end
			end
			onDone(results)
		end)
	end

	const function openFolder()
		task.spawn(function()
			const response = bridge.request("POST", "/open-folder")
			if not response.ok then
				setNotice(response.error or "Could not open the folder", "error")
			end
		end)
	end

	-- reload backend data whenever the bridge (re)connects.
	vide.effect(function()
		if bridge.connected() then
			task.spawn(loadRemote)
		end
	end)

	return {
		schema = schema,
		config = config,
		presets = presets,
		models = models,
		selected = selected,
		mode = mode,
		activePreset = activePreset,
		notice = notice,
		busy = busy,
		previewVersion = previewVersion,
		previewState = previewState,
		previewError = previewError,
		previewImage = function(): EditableImage?
			return previewImage
		end,
		currentModel = currentModel,
		useSelection = useSelection,
		select = select,
		setValue = setValue,
		resetToDefaults = resetToDefaults,
		copyToAll = copyToAll,
		applyPreset = applyPreset,
		savePreset = savePreset,
		deletePreset = deletePreset,
		updateConfig = updateConfig,
		pickFolder = pickFolder,
		exportModels = exportModels,
		uploadModels = uploadModels,
		openFolder = openFolder,
		requestPreview = requestPreview,
		setNotice = setNotice,
		reload = function()
			task.spawn(loadRemote)
		end,
		destroy = function()
			destroyed = true
			destroyModels(models())
			if previewImage then
				previewImage:Destroy()
				previewImage = nil
			end
		end,
	}
end

export type Store = typeof(create(...))

return {
	create = create,
}
