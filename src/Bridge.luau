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
	blender: () -> string?,
	version: () -> string?,
	request: (method: string, path: string, body: any?) -> Response,
	setPort: (number) -> (),
	refresh: () -> (),
	destroy: () -> (),
}

const function create(plugin: Plugin): Bridge
	const savedPort = tonumber(plugin:GetSetting(PORT_SETTING))
	const port = vide.source(if savedPort then math.floor(savedPort) else DEFAULT_PORT)
	const connected = vide.source(false)
	const blender = vide.source(nil :: string?)
	const version = vide.source(nil :: string?)
	local running = true

	const function request(method: string, path: string, body: any?): Response
		const options: { [string]: any } = {
			Url = `http://127.0.0.1:{port()}{path}`,
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
			return { ok = false, status = 0, body = nil, error = tostring(result) }
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

	const function refresh()
		const response = request("GET", "/status")
		if response.ok and type(response.body) == "table" then
			const status = response.body :: Types.Status
			blender(status.blender)
			version(status.version)
			connected(true)
		else
			connected(false)
		end
	end

	task.spawn(function()
		while running do
			refresh()
			task.wait(POLL_INTERVAL)
		end
	end)

	return {
		port = port,
		connected = connected,
		blender = blender,
		version = version,
		request = request,
		setPort = function(value: number)
			port(value)
			plugin:SetSetting(PORT_SETTING, value)
			task.spawn(refresh)
		end,
		refresh = refresh,
		destroy = function()
			running = false
		end,
	}
end

return {
	create = create,
	DEFAULT_PORT = DEFAULT_PORT,
}
