-- app state: the selected models, their settings, previews and backend data.
const AssetService = game:GetService("AssetService")
const HttpService = game:GetService("HttpService")
const vide = require("./vide")
const Data = require("./Data")
const Types = require("./Types")
const Base64 = require("./Base64")
const Serializer = require("./Serializer")
const LightingSync = require("./LightingSync")
const MaterialStyle = require("./MaterialStyle")
const PathGlob = require("./PathGlob")
const ScriptInsert = require("./ScriptInsert")
const Template = require("./Template")

const source = vide.source

const VERSION = require("./Version")

const AUTO_3D_KEY = "PrismAuto3d"
const LAST_SETTINGS_KEY = "PrismLastSettings"
const TEMPLATES_KEY = "PrismTemplates"
const UPDATE_CHECK_INTERVAL = 30 * 60
const THUMBNAIL_SIZE = 128
const THUMBNAIL_DELAY = 0.6
const SAVE_DELAY = 1
const MODEL_CHANGE_DELAY = 0.2

type Bridge = {
	connected: () -> boolean,
	request: (method: string, path: string, body: any?) -> any,
}

export type Mode = "one" | "all"
export type Notice = { text: string, kind: "info" | "error" | "success" }
export type UpdateInfo = {
	current: string,
	plugin: string?,
	latest: string?,
	available: boolean,
	canUpdate: boolean,
	notes: string,
	url: string,
	error: string?,
}
export type UpdateState = "idle" | "updating" | "restart"
export type UploadResult = {
	name: string,
	assetId: string?,
	imageId: string?,
	moderation: string?,
	path: string?,
	source: string?,
	parent: string?,
	creator: string?,
	error: string?,
}
export type HistoryEntry = {
	kind: "render" | "upload",
	time: number,
	name: string?,
	path: string?,
	assetId: string?,
	imageId: string?,
	moderation: string?,
	creator: string?,
	source: string?,
	parent: string?,
}

const function cloneSettings(settings: Types.Settings): Types.Settings
	return table.clone(settings)
end

const function create(plugin: Plugin, bridge: Bridge)
	const schema = source(nil :: Types.Schema?)
	const config = source(nil :: Types.Config?)
	const presets = source({} :: { [string]: Types.Settings })
	const fonts = source({} :: { Types.SelectOption })
	const models = source({} :: { Types.Model })
	const selected = source(1)
	const mode = source("all" :: Mode)
	const activePreset = source(nil :: string?)
	const notice = source(nil :: Notice?)
	const auto3d = source(true)
	const materialStyle = source("auto" :: MaterialStyle.Style)
	const previewView = source("3d" :: "3d" | "blender")
	local preferenceChanged = false
	local previewRevision = 0
	const previewVersion = source(0)
	const previewTextBounds = source(nil :: Types.TextBounds?)
	const textPreviewing = source(false)
	local textDragActive = false
	local textDragChanged = false
	const previewState = source("idle" :: "idle" | "rendering" | "error")
	const previewError = source(nil :: string?)
	const busy = source(nil :: string?)
	const update = source(nil :: UpdateInfo?)
	const updateState = source("idle" :: UpdateState)
	const installedVersion = source(nil :: string?)
	const history = source({} :: { HistoryEntry })
	-- templates are edited in place; templatesVersion changes whenever one does.
	const templates = source(Template.defaults())
	const templatesVersion = source(0)
	const lastTemplate = source(nil :: string?)

	task.spawn(function()
		const ok, saved = pcall(Data.load, plugin, AUTO_3D_KEY, true)
		if ok and type(saved) == "boolean" and not preferenceChanged then
			auto3d(saved)
			if not saved then
				previewView("blender")
			end
		end
	end)

	task.spawn(function()
		materialStyle(MaterialStyle.load(plugin))
	end)

	local templatesChanged = false
	task.spawn(function()
		const ok, saved = pcall(Data.load, plugin, TEMPLATES_KEY, nil)
		if not ok or type(saved) ~= "table" or type(saved.templates) ~= "table" or templatesChanged then
			return
		end
		const list = {}
		for _, template in saved.templates do
			if type(template) == "table" and type(template.name) == "string" and type(template.item) == "string" then
				table.insert(list, template)
			end
		end
		templates(list)
		if type(saved.last) == "string" then
			lastTemplate(saved.last)
		end
	end)

	local lastSettings: Types.Settings = {}
	task.spawn(function()
		const ok, saved = pcall(Data.load, plugin, LAST_SETTINGS_KEY, {})
		if ok and type(saved) == "table" then
			lastSettings = saved
		end
	end)

	local previewImage: EditableImage? = nil
	const payloads: { [string]: string } = {}
	const recoveryNeeded: { [string]: boolean } = {}
	const modelRevisions: { [string]: number } = {}
	-- settings of deselected instances, restored when they're selected again.
	const rememberedSettings: { [Instance]: Types.Settings } = setmetatable({}, { __mode = "k" }) :: any
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

	local requestPreview: (boolean?) -> ()
	local queueThumbnail: (Types.Model) -> ()

	const function sendScene(model: Types.Model): boolean
		const payload = payloads[model.id]
		if payload == nil then
			return false
		end
		const revision = modelRevisions[model.id]
		model.state("sending")
		const response = bridge.request("POST", "/scenes", payload)
		if destroyed or not table.find(models(), model) or modelRevisions[model.id] ~= revision or payloads[model.id] ~= payload then
			return false
		end
		if not response.ok then
			model.state("error")
			model.warning(response.error or "Could not send the model to Prism")
			return false
		end
		model.sceneId(response.body.sceneId)
		recoveryNeeded[model.id] = response.body.incomplete == true
		const warnings = response.body.warnings or {}
		model.warning(if #warnings > 0 then table.concat(warnings, "\n") else nil)
		model.state("ready")
		return true
	end

	const function render(model: Types.Model, size: number?, client: string): any
		if model.state() == "serializing" then
			return nil
		end
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

	const function invalidatePreview(keepView: boolean?)
		previewRevision += 1
		if auto3d() and not keepView then
			previewView("3d")
		end
	end

	local previewBusy = false
	local previewDirty = false
	requestPreview = function(keepView: boolean?)
		invalidatePreview(keepView)
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
					if not textDragActive then
						textPreviewing(false)
					end
					break
				end
				const revision = previewRevision
				previewState("rendering")
				const response = render(model, nil, "preview")
				if destroyed or model ~= currentModel() or revision ~= previewRevision then
					continue
				end
				if response == nil then
					previewState("error")
					previewError(model.warning())
					if not textDragActive then
						textPreviewing(false)
					end
				elseif response.ok then
					previewImage = writeImage(previewImage, response.body)
					previewTextBounds(response.body.textBounds)
					previewVersion(previewVersion() + 1)
					previewState("idle")
					previewError(nil)
					if not textDragActive then
						textPreviewing(false)
					end
					if auto3d() then
						previewView("blender")
					end
				elseif response.status ~= 409 then
					previewState("error")
					previewError(response.error)
					if not textDragActive then
						textPreviewing(false)
					end
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
				const revision = modelRevisions[model.id]
				const response = render(model, THUMBNAIL_SIZE, `thumb:{model.id}`)
				if not destroyed and table.find(models(), model) and revision == modelRevisions[model.id] and response and response.ok then
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
			if destroyed or not table.find(models(), model) or thumbnailTokens[model.id] ~= token or table.find(thumbnailQueue, model) then
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
			rememberedSettings[model.instance] = model.settings()
			payloads[model.id] = nil
			recoveryNeeded[model.id] = nil
			modelRevisions[model.id] = nil
			thumbnailTokens[model.id] = nil
			if model.thumbnail then
				model.thumbnail:Destroy()
				model.thumbnail = nil
			end
		end
	end

	const function serializeModel(model: Types.Model, revision: number)
		if destroyed or not table.find(models(), model) or modelRevisions[model.id] ~= revision then
			return
		end
		model.name = model.instance.Name
		model.visualVersion(model.visualVersion() + 1)
		const function failed(message: string)
			model.state("error")
			model.warning(message)
			if model == currentModel() then
				previewState("error")
				previewError(message)
			end
		end
		const ok, result = pcall(Serializer.serialize, model.instance)
		if destroyed or not table.find(models(), model) or modelRevisions[model.id] ~= revision then
			return
		end
		if not ok then
			failed(`Could not read {model.name}: {result}`)
			return
		end
		if #result.payload.parts == 0 then
			failed(`{model.name} has no visible parts`)
			return
		end
		result.payload.warnings = result.warnings
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

	const function refreshModel(model: Types.Model)
		if destroyed or not table.find(models(), model) then
			return
		end
		const revision = (modelRevisions[model.id] or 0) + 1
		modelRevisions[model.id] = revision
		payloads[model.id] = nil
		recoveryNeeded[model.id] = nil
		model.sceneId(nil)
		model.state("serializing")
		model.warning(nil)
		if model == currentModel() then
			invalidatePreview()
			previewState("rendering")
			previewError(nil)
			previewTextBounds(nil)
		end
		task.delay(MODEL_CHANGE_DELAY, function()
			if not destroyed and table.find(models(), model) and modelRevisions[model.id] == revision then
				serializeModel(model, revision)
			end
		end)
	end

	const function useSelection(roots: { Instance })
		if destroyed then
			return
		end
		const initial = defaults()
		const previous = currentModel()
		const chosen = {}
		for _, root in roots do
			chosen[root] = true
		end
		const list: { Types.Model } = {}
		const removed: { Types.Model } = {}
		for _, model in models() do
			table.insert(if chosen[model.instance] then list else removed, model)
		end
		destroyModels(removed)
		const added: { Types.Model } = {}
		const retry: { Types.Model } = {}
		local firstSelected: number? = nil
		for _, root in roots do
			local existing: number? = nil
			for index, model in list do
				if model.instance == root then
					existing = index
					break
				end
			end
			if existing then
				firstSelected = firstSelected or existing
				const model = list[existing]
				if recoveryNeeded[model.id] and not table.find(retry, model) then
					table.insert(retry, model)
				end
				continue
			end
			const model: Types.Model = {
				id = HttpService:GenerateGUID(false),
				name = root.Name,
				instance = root,
				sceneId = source(nil :: string?),
				state = source("serializing" :: Types.ModelState),
				warning = source(nil :: string?),
				settings = source(cloneSettings(rememberedSettings[root] or initial)),
				assetId = source(nil :: string?),
				thumbnail = nil,
				thumbnailVersion = source(0),
				visualVersion = source(0),
			}
			modelRevisions[model.id] = 0
			table.insert(list, model)
			table.insert(added, model)
			firstSelected = firstSelected or #list
		end
		if #added > 0 or #removed > 0 then
			models(list)
		end
		selected(firstSelected or 1)
		if previous ~= currentModel() then
			activePreset(nil)
			textDragActive = false
			textDragChanged = false
			textPreviewing(false)
			previewTextBounds(nil)
			if previewImage then
				previewImage:Destroy()
				previewImage = nil
			end
			previewVersion(previewVersion() + 1)
			previewState("idle")
			previewError(nil)
			requestPreview()
		end
		if #added == 0 and #retry == 0 then
			return
		end

		task.spawn(function()
			for _, model in retry do
				if not destroyed and table.find(models(), model) and bridge.connected() and sendScene(model) then
					if model == currentModel() then
						requestPreview()
					end
					queueThumbnail(model)
				end
			end
			for _, model in added do
				if destroyed or not table.find(models(), model) then
					continue
				end
				serializeModel(model, 0)
			end
		end)
	end

	const function select(index: number)
		if models()[index] == nil then
			return
		end
		selected(index)
		textDragActive = false
		textDragChanged = false
		textPreviewing(false)
		previewTextBounds(nil)
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

	local cameraToken = 0
	const function applyToTargets(change: (Types.Settings, Types.Model) -> (), deferPreview: boolean?, keepView: boolean?, skipPreview: boolean?)
		invalidatePreview(keepView)
		const affected = targets()
		for _, model in affected do
			const settings = cloneSettings(model.settings())
			change(settings, model)
			model.settings(settings)
			if not skipPreview then
				queueThumbnail(model)
			end
		end
		const model = currentModel()
		if model then
			rememberSettings(model.settings())
		end
		cameraToken += 1
		if skipPreview then
			return
		elseif deferPreview then
			const token = cameraToken
			task.delay(0.12, function()
				if not destroyed and cameraToken == token then
					requestPreview(keepView)
				end
			end)
		else
			requestPreview(keepView)
		end
	end

	const function syncLighting()
		if currentModel() == nil or busy() ~= nil then
			return
		end
		-- Compute every target first so an unreadable place or pivot cannot partially apply.
		const ok, changes = pcall(function()
			const snapshot = LightingSync.capture(game:GetService("Lighting"))
			const values = {}
			for _, model in targets() do
				const root = model.instance
				local pivot = CFrame.identity
				if root:IsA("PVInstance") then
					pivot = (root :: PVInstance):GetPivot()
				else
					const parts = Serializer.getParts(root)
					if parts[1] then
						pivot = parts[1].CFrame
					end
				end
				values[model] = LightingSync.forModel(snapshot, model.settings(), pivot)
			end
			return values
		end)
		if not ok then
			setNotice("Could not read this place's lighting. Render settings were kept.", "error")
			return
		end
		activePreset(nil)
		applyToTargets(function(settings, model)
			for key, value in changes[model] do
				settings[key] = value
			end
		end)
		setNotice("Place lighting synced for the current model view.", "success")
	end

	const function setCamera(values: { [string]: number })
		activePreset(nil)
		applyToTargets(function(settings)
			for _, key in { "cameraRotation", "cameraElevation", "zoom" } do
				if values[key] ~= nil then
					settings[key] = values[key]
				end
			end
		end, true)
	end

	const function beginTextDrag()
		textDragActive = true
		textDragChanged = false
		textPreviewing(true)
	end

	const function setTextOffset(values: { [string]: number })
		textDragChanged = true
		activePreset(nil)
		applyToTargets(function(settings)
			for _, key in { "textOffsetX", "textOffsetY" } do
				if values[key] ~= nil then
					settings[key] = math.clamp(math.round(values[key]), -512, 512)
				end
			end
		end, false, true, textDragActive)
	end

	const function endTextDrag()
		textDragActive = false
		if textDragChanged then
			-- Render the final offset after the instant Studio preview.
			for _, model in targets() do
				queueThumbnail(model)
			end
			requestPreview(true)
		else
			textPreviewing(false)
		end
		textDragChanged = false
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
	-- history
	-- ---------------------------------------------------------------

	const function loadHistory()
		task.spawn(function()
			const response = bridge.request("GET", "/history")
			if response.ok and type(response.body) == "table" and type(response.body.entries) == "table" then
				history(response.body.entries)
			end
		end)
	end

	const function clearHistory()
		task.spawn(function()
			const response = bridge.request("DELETE", "/history")
			if response.ok then
				history({})
			else
				setNotice(response.error or "Could not clear the history", "error")
			end
		end)
	end

	-- ---------------------------------------------------------------
	-- templates
	-- ---------------------------------------------------------------

	local templateSaveToken = 0
	const function saveTemplates()
		templatesChanged = true
		templatesVersion(vide.untrack(templatesVersion) + 1)
		templateSaveToken += 1
		const token = templateSaveToken
		task.delay(SAVE_DELAY, function()
			if token == templateSaveToken and not destroyed then
				pcall(Data.save, plugin, TEMPLATES_KEY, { templates = vide.untrack(templates), last = vide.untrack(lastTemplate) })
			end
		end)
	end

	const function findTemplate(name: string?): Template.Template?
		for _, template in vide.untrack(templates) do
			if template.name == name then
				return template
			end
		end
		return nil
	end

	-- "Name", or "Name 2", "Name 3"… when it's taken by another template.
	const function uniqueName(base: string, except: Template.Template?): string
		local name = if base == "" then "Template" else base
		local counter = 1
		while true do
			const existing = findTemplate(name)
			if existing == nil or existing == except then
				return name
			end
			counter += 1
			name = `{base} {counter}`
		end
	end

	const function updateTemplate(template: Template.Template, changes: { [string]: any })
		for field, value in changes do
			if field == "name" then
				const old = template.name
				template.name = uniqueName(string.sub(value, 1, 64), template)
				if vide.untrack(lastTemplate) == old then
					lastTemplate(template.name)
				end
			else
				(template :: any)[field] = value
			end
		end
		saveTemplates()
	end

	const function addTemplate(template: Template.Template): Template.Template
		template.name = uniqueName(template.name)
		const list = table.clone(vide.untrack(templates))
		table.insert(list, template)
		templates(list)
		saveTemplates()
		return template
	end

	const function deleteTemplate(template: Template.Template)
		const list = table.clone(vide.untrack(templates))
		const index = table.find(list, template)
		if index then
			table.remove(list, index)
			templates(list)
			saveTemplates()
		end
	end

	-- brings back the built-in templates, resetting any that kept their names.
	const function restoreTemplates()
		const list = table.clone(vide.untrack(templates))
		for _, default in Template.defaults() do
			const existing = findTemplate(default.name)
			if existing then
				table.clear(existing)
				for field, value in default do
					(existing :: any)[field] = value
				end
			else
				table.insert(list, default)
			end
		end
		templates(list)
		saveTemplates()
	end

	-- the template last picked for output, or the first one.
	const function currentTemplate(): Template.Template?
		templatesVersion()
		const list = templates()
		const name = lastTemplate()
		for _, template in list do
			if template.name == name then
				return template
			end
		end
		return list[1]
	end

	const function useTemplate(name: string)
		lastTemplate(name)
		saveTemplates()
	end

	-- finds the script a template writes to, then inserts the items there.
	const function insertTemplate(template: Template.Template, entries: { Template.Entry })
		const target = template.target or ""
		local script: LuaSourceContainer? = nil
		if target ~= "" then
			const found = PathGlob.match(game, target, {
				limit = 2,
				filter = function(instance)
					return instance:IsA("LuaSourceContainer")
				end,
			})
			if found == nil or #found == 0 then
				setNotice(`No script matches {target}.`, "error")
				return
			elseif #found > 1 then
				setNotice(`More than one script matches {target}. Use a more specific path.`, "error")
				return
			end
			script = found[1] :: LuaSourceContainer
		else
			for _, instance in game:GetService("Selection"):Get() do
				if instance:IsA("LuaSourceContainer") then
					script = instance
					break
				end
			end
			if script == nil then
				setNotice("Select a ModuleScript in Studio, or set the template's target script.", "error")
				return
			end
		end
		const chosen = script :: LuaSourceContainer
		const items = Template.renderItems(template, entries, os.time())
		task.spawn(function()
			const ok, result = pcall(ScriptInsert.apply, chosen, items, template.replace)
			if not ok then
				setNotice(`Could not write to {chosen.Name}: {result}`, "error")
				return
			end
			const parts = {}
			if result.inserted > 0 then
				table.insert(parts, `added {result.inserted} {result.where}`)
			end
			if result.replaced > 0 then
				table.insert(parts, `replaced {result.replaced}`)
			end
			setNotice(`{chosen.Name}: {table.concat(parts, ", ")}. Ctrl+Z undoes it.`, "success")
		end)
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
		const fontResponse = bridge.request("GET", "/fonts")
		if fontResponse.ok and type(fontResponse.body) == "table" and type(fontResponse.body.fonts) == "table" then
			fonts(fontResponse.body.fonts)
		end
		for _, model in models() do
			if model.sceneId() == nil and payloads[model.id] and sendScene(model) then
				queueThumbnail(model)
			end
		end
		loadHistory()
		requestPreview()
	end

	const function updateConfig(changes: { [string]: any })
		task.spawn(function()
			const response = bridge.request("PUT", "/config", changes)
			if response.ok then
				config(response.body)
				if changes.emojiProvider ~= nil then
					requestPreview(true)
					for _, model in models() do
						queueThumbnail(model)
					end
				end
			else
				setNotice(response.error or "Could not save settings", "error")
			end
		end)
	end

	-- saves the port, then restarts the backend so it listens there.
	const function changePort(port: number, onDone: (ok: boolean, message: string?) -> ())
		task.spawn(function()
			const saved = bridge.request("PUT", "/config", { port = port })
			if not saved.ok then
				onDone(false, saved.error or "Could not save the port")
				return
			end
			config(saved.body)
			const restarted = bridge.request("POST", "/restart")
			onDone(restarted.ok, restarted.error)
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

	-- Sharing requests leave model settings and the active preset untouched.
	const function presetRequest(action: string, body: { [string]: any }, onDone: (any?, string?) -> ())
		task.spawn(function()
			const response = bridge.request("POST", `/presets/{action}`, body)
			if response.ok then
				if action == "import" then
					presets(response.body.presets)
					setNotice(`Imported preset "{response.body.name}".`, "success")
				end
				onDone(response.body, nil)
			else
				onDone(nil, response.error or "Could not complete the preset request")
			end
		end)
	end

	const function exportPreset(name: string, onDone: (any?, string?) -> ())
		presetRequest("export", { name = name }, onDone)
	end

	const function decodePreset(code: string, onDone: (any?, string?) -> ())
		presetRequest("decode", { code = code }, onDone)
	end

	const function importPreset(code: string, name: string, onDone: (any?, string?) -> ())
		presetRequest("import", { code = code, name = name }, onDone)
	end

	const function deletePreset(name: string, onDone: ((boolean, string?) -> ())?)
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
			if onDone then
				onDone(response.ok, response.error)
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
				table.insert(result, {
					sceneId = model.sceneId(),
					name = model.name,
					settings = model.settings(),
					-- {index} in file names is the model's position in the list.
					index = table.find(models(), model),
					-- where the model lives, for templates and history.
					source = PathGlob.pathOf(model.instance, game),
					parent = if model.instance.Parent then model.instance.Parent.Name else nil,
				})
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
			loadHistory()
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
			loadHistory()
			if not response.ok then
				setNotice(response.error or "Upload failed", "error")
				return
			end
			const results = response.body.results :: { UploadResult }
			for index, result in results do
				result.creator = result.creator or response.body.creator
				const model = included[index]
				if model and result.assetId then
					model.assetId(result.imageId or result.assetId)
				end
			end
			onDone(results)
		end)
	end

	-- the backend runs on this machine, so it can reach the clipboard plugins can't.
	const function copyText(text: string, onDone: ((boolean) -> ())?)
		task.spawn(function()
			const response = bridge.request("POST", "/clipboard", { text = text })
			if not response.ok then
				setNotice(response.error or "Could not copy to the clipboard", "error")
			end
			if onDone then
				onDone(response.ok)
			end
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

	-- ---------------------------------------------------------------
	-- updates
	-- ---------------------------------------------------------------

	const function checkForUpdate(force: boolean?, onResult: ((UpdateInfo?, string?) -> ())?)
		task.spawn(function()
			const query = `/update?plugin={HttpService:UrlEncode(VERSION)}{if force then "&force=1" else ""}`
			const response = bridge.request("GET", query)
			if response.ok and type(response.body) == "table" then
				update(response.body)
				if onResult then
					onResult(response.body, response.body.error)
				end
			elseif onResult then
				onResult(nil, response.error or "Could not reach the Prism backend")
			end
		end)
	end

	const function installUpdate(onDone: (ok: boolean, message: string, plugins: { string }) -> ())
		if updateState() ~= "idle" then
			return
		end
		updateState("updating")
		task.spawn(function()
			const response = bridge.request("POST", "/update")
			if response.ok and type(response.body) == "table" then
				installedVersion(response.body.version)
				updateState("restart")
				onDone(true, response.body.version, response.body.plugins or {})
			else
				updateState("idle")
				onDone(false, response.error or "The update failed.", {})
			end
		end)
	end

	task.spawn(function()
		while not destroyed do
			task.wait(UPDATE_CHECK_INTERVAL)
			if bridge.connected() and updateState() == "idle" then
				checkForUpdate()
			end
		end
	end)

	-- reload backend data whenever the bridge (re)connects.
	vide.effect(function()
		if bridge.connected() then
			task.spawn(loadRemote)
			if vide.untrack(updateState) ~= "restart" then
				checkForUpdate()
			end
		end
	end)

	return {
		schema = schema,
		config = config,
		presets = presets,
		fonts = fonts,
		models = models,
		selected = selected,
		mode = mode,
		activePreset = activePreset,
		notice = notice,
		busy = busy,
		renderProgress = bridge.renderProgress,
		update = update,
		updateState = updateState,
		installedVersion = installedVersion,
		history = history,
		templates = templates,
		templatesVersion = templatesVersion,
		lastTemplate = lastTemplate,
		currentTemplate = currentTemplate,
		useTemplate = useTemplate,
		updateTemplate = updateTemplate,
		addTemplate = addTemplate,
		deleteTemplate = deleteTemplate,
		restoreTemplates = restoreTemplates,
		insertTemplate = insertTemplate,
		loadHistory = loadHistory,
		clearHistory = clearHistory,
		checkForUpdate = checkForUpdate,
		installUpdate = installUpdate,
		auto3d = auto3d,
		previewView = previewView,
		setAuto3d = function(value: boolean)
			preferenceChanged = true
			auto3d(value)
			if value then
				previewView("3d")
				requestPreview()
			end
			task.spawn(function()
				pcall(Data.save, plugin, AUTO_3D_KEY, value)
			end)
		end,
		materialStyle = materialStyle,
		setMaterialStyle = function(style: MaterialStyle.Style)
			if style == vide.untrack(materialStyle) then
				return
			end
			const before = Serializer.legacyMaterials()
			materialStyle(style)
			MaterialStyle.save(plugin, style)
			-- only models whose built-in materials change need serializing again.
			if Serializer.legacyMaterials() ~= before then
				for _, model in models() do
					refreshModel(model)
				end
			end
		end,
		previewVersion = previewVersion,
		previewTextBounds = previewTextBounds,
		textPreviewing = textPreviewing,
		previewState = previewState,
		previewError = previewError,
		previewImage = function(): EditableImage?
			return previewImage
		end,
		currentModel = currentModel,
		useSelection = useSelection,
		refreshModel = refreshModel,
		select = select,
		setValue = setValue,
		syncLighting = syncLighting,
		setCamera = setCamera,
		setTextOffset = setTextOffset,
		beginTextDrag = beginTextDrag,
		endTextDrag = endTextDrag,
		resetToDefaults = resetToDefaults,
		copyToAll = copyToAll,
		applyPreset = applyPreset,
		savePreset = savePreset,
		deletePreset = deletePreset,
		exportPreset = exportPreset,
		decodePreset = decodePreset,
		importPreset = importPreset,
		updateConfig = updateConfig,
		changePort = changePort,
		pickFolder = pickFolder,
		exportModels = exportModels,
		uploadModels = uploadModels,
		openFolder = openFolder,
		copyText = copyText,
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
