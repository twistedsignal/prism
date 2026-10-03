-- Agent jobs run in edit mode independently of the dock widget and selection.
const HttpService = game:GetService("HttpService")
const Serializer = require("./Serializer")
const VERSION = require("./Version")

const function create(plugin: Plugin): () -> ()
	const session = HttpService:GenerateGUID(false)
	local running = true
	local registered = false
	local pending: { [string]: any }? = nil
	local nextId = 0
	const targets: { [string]: Instance } = {}
	const ids: { [Instance]: string } = setmetatable({}, { __mode = "k" }) :: any

	const function request(method: string, path: string, body: any?): any
		const port = tonumber(plugin:GetSetting("PrismPort")) or 47821
		const ok, response = pcall(function()
			return HttpService:RequestAsync({
				Url = `http://127.0.0.1:{port}/agent/v1{path}`,
				Method = method,
				Headers = { ["X-Prism"] = "1", ["Content-Type"] = "application/json" },
				Body = if body then HttpService:JSONEncode(body) else nil,
			})
		end)
		if not ok then
			return nil
		end
		const decoded, result = pcall(HttpService.JSONDecode, HttpService, response.Body)
		if decoded then
			result._httpStatus = response.StatusCode
			return result
		end
		return nil
	end

	const function pathOf(instance: Instance): { string }
		const path = {}
		local current: Instance? = instance
		while current and current ~= game do
			table.insert(path, 1, current.Name)
			current = current.Parent
		end
		return path
	end

	const function resolve(path: any): Instance
		const segments = if type(path) == "string" then string.split(path, ".") else path
		assert(type(segments) == "table" and #segments > 0, "Provide a target id or instance path")
		local current: Instance = game
		for _, name in segments do
			assert(type(name) == "string" and name ~= "", "Path segments must be non-empty strings")
			local found: Instance? = nil
			for _, child in current:GetChildren() do
				if child.Name == name then
					assert(found == nil, `Ambiguous path segment: {name}. Discover target ids with prism models.`)
					found = child
				end
			end
			assert(found, `Missing path segment: {name}`)
			current = found :: Instance
		end
		return current
	end

	const function renderable(instance: Instance): boolean
		return instance:IsA("BasePart") or instance:IsA("Model") or instance:IsA("Folder")
			or instance:IsA("Accessory") or instance:IsA("Tool")
	end

	const function describe(instance: Instance): any
		local id = ids[instance]
		if not id then
			nextId += 1
			id = tostring(nextId)
			ids[instance] = id
			targets[id] = instance
		end
		return { id = id, name = instance.Name, class = instance.ClassName, path = pathOf(instance) }
	end

	const function execute(job: any): any
		if job.operation == "models" then
			const root = resolve(job.root)
			const matches = {}
			local truncated = false
			const query = string.lower(job.query or "")
			for id, instance in targets do
				if not instance:IsDescendantOf(game) then
					targets[id] = nil
				end
			end
			const candidates = root:GetDescendants()
			table.insert(candidates, 1, root)
			for _, instance in candidates do
				if renderable(instance) and string.find(string.lower(instance.Name), query, 1, true) then
					if #matches >= job.limit then
						truncated = true
						break
					end
					table.insert(matches, describe(instance))
				end
			end
			return { models = matches, truncated = truncated }
		end
		assert(job.operation == "serialize", "Unsupported Studio operation")
		const items = {}
		for _, target in job.items do
			local name: string? = nil
			const ok, result = pcall(function()
				const instance = if target.target then targets[target.target] else resolve(target.path)
				assert(instance and instance:IsDescendantOf(game), "Target is missing; rediscover it with prism models")
				assert(renderable(instance), "Target must be a part, model, folder, accessory or tool")
				name = instance.Name
				-- Freeze geometry before any yielding mesh/texture reads.
				local snapshotRoot = instance
				local childIndex: number? = nil
				const parent = instance.Parent
				-- A selected limb still needs its rig's clothing and other limb sizes.
				if instance:IsA("BasePart") and parent and parent:FindFirstChildOfClass("Humanoid") then
					snapshotRoot = parent
					childIndex = table.find(parent:GetChildren(), instance)
				end
				const flags = {}
				const descendants = snapshotRoot:GetDescendants()
				table.insert(descendants, snapshotRoot)
				for _, descendant in descendants do
					if not descendant.Archivable then
						table.insert(flags, descendant)
						descendant.Archivable = true
					end
				end
				const cloned, copy = pcall(snapshotRoot.Clone, snapshotRoot)
				for _, descendant in flags do
					descendant.Archivable = false
				end
				assert(cloned and copy, "Could not snapshot target")
				const read, snapshot = pcall(function()
					const targetCopy = if childIndex then copy:GetChildren()[childIndex] else copy
					assert(targetCopy and targetCopy.Name == instance.Name and targetCopy.ClassName == instance.ClassName, "Could not resolve snapshotted target")
					return Serializer.serialize(targetCopy)
				end)
				copy:Destroy()
				assert(read, tostring(snapshot))
				return { name = name, payload = snapshot.payload, warnings = snapshot.warnings }
			end)
			table.insert(items, if ok then result else { name = name, error = tostring(result) })
		end
		return { items = items }
	end

	task.spawn(function()
		while running do
			if registered then
				request("POST", "/sessions", {
					id = session, name = game.Name, placeId = game.PlaceId, pluginVersion = VERSION, apiVersion = 1,
				})
			end
			task.wait(5)
		end
	end)

	task.spawn(function()
		while running do
			if not registered then
				const registration = request("POST", "/sessions", {
					id = session, name = game.Name, placeId = game.PlaceId, pluginVersion = VERSION, apiVersion = 1,
				})
				registered = registration ~= nil and registration.id == session
			end
			if registered then
				if pending then
					const completion = request("POST", "/complete", pending)
					if completion then
						if completion._httpStatus < 400 then
							pending = nil
						elseif string.find(completion.error or "", "Unknown job", 1, true) then
							-- Backend restarts discard jobs; never submit the operation again.
							pending = nil
							registered = false
						else
							pending = { id = pending.id, session = session, error = `Studio completion failed: {completion.error}` }
						end
					else
						registered = false
					end
				else
					const response = request("POST", "/poll", { session = session })
					if not response or response.error then
						registered = false
					elseif response.job then
						const job = response.job
						const ok, result = pcall(execute, job)
						pending = if ok then result else { error = tostring(result) }
						pending.id = job.id
						pending.session = session
					end
				end
			end
			-- During a long serialization, queued work stays in the backend until this loop resumes.
			task.wait(if registered then 1 else 3)
		end
	end)
	return function()
		running = false
		request("DELETE", "/sessions", { session = session })
		table.clear(targets)
	end
end

return { create = create }
