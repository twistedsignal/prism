-- talks to the local prism backend over http.
const HttpService = game:GetService("HttpService")
const vide = require("./vide")
const Types = require("./Types")

const DEFAULT_PORT = 47821
const PORT_SETTING = "PrismPort"
const POLL_INTERVAL = 3

export type Response = {
	ok: boolean,
	status: number,
	body: any,
	error: string?,
}

export type Bridge = {
	port: (number?) -> number,
	connected: () -> boolean,
	lastError: () -> string?,
	httpBlocked: () -> boolean,
	blender: () -> string?,
	version: () -> string?,
	renderProgress: () -> Types.RenderProgress?,
	request: (method: string, path: string, body: any?) -> Response,
	setPort: (number) -> (),
	resetPort: () -> (),
	setActive: (boolean) -> (),
	refresh: () -> (),
	destroy: () -> (),
}

-- studio's errors when the user denied this plugin http access.
const BLOCKED_PATTERNS = { "permission", "not allowed", "denied", "not enabled" }

const function create(plugin: Plugin): Bridge
	const savedPort = tonumber(plugin:GetSetting(PORT_SETTING))
	const port = vide.source(if savedPort then math.floor(savedPort) else DEFAULT_PORT)
	const connected = vide.source(false)
	const blender = vide.source(nil :: string?)
	const version = vide.source(nil :: string?)
	const renderProgress = vide.source(nil :: Types.RenderProgress?)
	const lastError = vide.source(nil :: string?)
	local running = true
	-- only poll while the widget is open.
	local active = true
	local wake: thread? = nil

	const function request(method: string, path: string, body: any?, overridePort: number?): Response
		const options: { [string]: any } = {
			Url = `http://127.0.0.1:{overridePort or port()}{path}`,
			Method = method,
			Headers = {
				["X-Prism"] = "1",
				["Content-Type"] = "application/json",
			},
		}
		if body ~= nil then
			options.Body = if type(body) == "string" then body else HttpService:JSONEncode(body)
		end
		const ok, result = pcall(function()
			return HttpService:RequestAsync(options :: any)
		end)
		if not ok then
			connected(false)
			if lastError() ~= tostring(result) then
				lastError(tostring(result))
			end
			return { ok = false, status = 0, body = nil, error = tostring(result) }
		end
		if lastError() ~= nil then
			lastError(nil)
		end
		local decoded = nil
		if result.Body ~= "" then
			const decodeOk, value = pcall(function()
				return HttpService:JSONDecode(result.Body)
			end)
			decoded = if decodeOk then value else nil
		end
		const message = if type(decoded) == "table" and type(decoded.error) == "string" then decoded.error else nil
		return {
			ok = result.Success,
			status = result.StatusCode,
			body = decoded,
			error = if result.Success then nil else message or result.StatusMessage,
		}
	end

	const function savePort(value: number)
		port(value)
		plugin:SetSetting(PORT_SETTING, value)
	end

	const function isStatus(response: Response): boolean
		return response.ok and type(response.body) == "table" and type(response.body.version) == "string"
	end

	const function refresh()
		local response = request("GET", "/status")
		-- a stale saved port hides a backend still on the default one; switch back to it.
		if not response.ok and port() ~= DEFAULT_PORT then
			const fallback = request("GET", "/status", nil, DEFAULT_PORT)
			if isStatus(fallback) then
				savePort(DEFAULT_PORT)
				response = fallback
			elseif response.error and lastError() ~= response.error then
				lastError(response.error)
			end
		end
		if not isStatus(response) and response.status ~= 0 then
			-- something answered, but it isn't prism.
			const message = `Port {port()} answered with HTTP {response.status}. Another program may be using it.`
			if lastError() ~= message then
				lastError(message)
			end
		end
		if isStatus(response) then
			const status = response.body :: Types.Status
			blender(status.blender)
			version(status.version)
			renderProgress(status.renderProgress)
			connected(true)
		else
			renderProgress(nil)
			connected(false)
		end
	end

	task.spawn(function()
		while running do
			if active then
				refresh()
				task.wait(POLL_INTERVAL)
			else
				wake = coroutine.running()
				coroutine.yield()
			end
		end
	end)

	const function resume()
		const thread = wake
		wake = nil
		if thread then
			task.spawn(thread)
		end
	end

	return {
		port = port,
		connected = connected,
		lastError = lastError,
		httpBlocked = function(): boolean
			const message = string.lower(lastError() or "")
			for _, pattern in BLOCKED_PATTERNS do
				if string.find(message, pattern, 1, true) then
					return true
				end
			end
			return false
		end,
		blender = blender,
		version = version,
		renderProgress = renderProgress,
		request = request,
		setPort = function(value: number)
			savePort(value)
			task.spawn(refresh)
		end,
		resetPort = function()
			savePort(DEFAULT_PORT)
			task.spawn(refresh)
		end,
		setActive = function(value: boolean)
			active = value
			if value then
				resume()
			end
		end,
		refresh = refresh,
		destroy = function()
			running = false
			resume()
		end,
	}
end

return {
	create = create,
	DEFAULT_PORT = DEFAULT_PORT,
}
