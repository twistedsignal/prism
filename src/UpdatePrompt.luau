-- selene: allow(mixed_table)
-- asks to install a new release, then tells the user to restart studio.
const vide = require("./vide")
const Theme = require("./components/Theme")
const Modal = require("./components/Modal")
const Store = require("./Store")
const VERSION = require("./Version")

const new = vide.create

const function bodyText(text: string, color: Color3?): GuiObject
	return new("ScrollingFrame")({
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.BORDER,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = Theme.OVERLAY_Z + 1,

		new("TextLabel")({
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = text,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextColor3 = color or Theme.MUTED,
			Font = Enum.Font.SourceSans,
			TextSize = 15,
			ZIndex = Theme.OVERLAY_Z + 1,
		}),
	}) :: ScrollingFrame
end

const function showRestart(version: string, plugins: { string }, url: string)
	const text = if #plugins > 0
		then `Prism v{version} is installed. Restart Roblox Studio to load the new plugin.`
		else `The Prism backend is updated to v{version}, but the plugin folder wasn't found. Download Prism.rbxm from {url} into your Plugins folder, then restart Roblox Studio.`
	Modal.open({
		title = "Restart Roblox Studio",
		height = 170,
		buttons = {
			{
				text = "OK",
				variant = "accent",
				activated = function(close)
					close()
				end,
			},
		},
		body = function()
			return bodyText(text, Theme.TEXT)
		end,
	})
end

const function open(store: Store.Store)
	const info = store.update()
	if info == nil or not info.available or info.latest == nil then
		return
	end
	const latest = info.latest
	const notes = if info.notes ~= "" then `\n\n{info.notes}` else ""
	Modal.open({
		title = `Prism v{latest} is available`,
		width = 420,
		height = if info.notes ~= "" then 300 else 190,
		buttons = {
			{
				text = "Later",
				activated = function(close)
					close()
				end,
			},
			{
				text = "Update",
				variant = "accent",
				activated = function(close)
					close()
					store.installUpdate(function(ok, message, plugins)
						if ok then
							showRestart(message, plugins, info.url)
						else
							store.setNotice(`Update failed: {message}`, "error")
						end
					end)
				end,
			},
		},
		body = function()
			return bodyText(
				`You have v{VERSION}. Updating downloads the new release, reinstalls the backend and plugin, then restarts the backend. You'll need to restart Roblox Studio afterwards.{notes}`
			)
		end,
	})
end

return {
	open = open,
}
