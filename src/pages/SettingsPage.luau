-- selene: allow(mixed_table)
-- backend settings: output folder, render sizes, tool paths and the bridge port.
const UserInputService = game:GetService("UserInputService")
const vide = require("../vide")
const Bridge = require("../Bridge")
const Theme = require("../components/Theme")
const Icons = require("../Icons")
const Button = require("../components/Button")
const TextBoxSetting = require("../components/TextBoxSetting")
const ToggleSetting = require("../components/ToggleSetting")
const DropdownSetting = require("../components/DropdownSetting")
const Store = require("../Store")

const new = vide.create

const PREVIEW_SIZES = { 128, 256, 384, 512, 768, 1024 }
const RENDER_SIZES = { 128, 256, 384, 512, 768, 1024, 2048, 4096 }
const EMOJI_PROVIDERS = { "apple", "google", "facebook", "twitter" }
const AA = { "OFF", "FXAA", "5", "8", "11", "16", "32" }
const MATERIAL_STYLES = { auto = "Automatic", ["2022"] = "2022 materials", legacy = "Legacy (pre-2022)" }

export type Props = {
	store: Store.Store,
	bridge: {
		port: () -> number,
		setPort: (number) -> (),
		resetPort: () -> (),
		connected: () -> boolean,
		httpBlocked: () -> boolean,
		lastError: () -> string?,
		blender: () -> string?,
		version: () -> string?,
		refresh: () -> (),
	},
	pluginVersion: string,
	onOpenHistory: () -> (),
}

const function heading(text: string, order: number): TextLabel
	return new("TextLabel")({
		Name = text,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Text = `  {string.upper(text)}`,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		TextColor3 = Theme.SUBTLE,
		Font = Enum.Font.SourceSansBold,
		TextSize = 13,

		new("UIPadding")({ PaddingBottom = UDim.new(0, 4) }),
	}) :: TextLabel
end

-- how to start the backend and where its log is, for the os studio runs on.
const function startHelp(): { command: string, logs: string }
	const ok, platform = pcall(function()
		return UserInputService:GetPlatform()
	end)
	if ok and platform == Enum.Platform.Windows then
		-- vinegar reports windows too, so mention the linux command.
		return {
			command = '& "$env:LOCALAPPDATA\\Prism\\bin\\prism.cmd" start',
			logs = "%LOCALAPPDATA%\\Prism\\prism.log. On Linux with Vinegar, run ~/.local/bin/prism start instead",
		}
	elseif ok and platform == Enum.Platform.OSX then
		return { command = "~/.local/bin/prism start", logs = "~/Library/Logs/Prism.log" }
	end
	return { command = "~/.local/bin/prism start", logs = "journalctl --user -u prism" }
end

const function at<T>(layoutOrder: number, instance: T & GuiObject): T
	instance.LayoutOrder = layoutOrder
	return instance
end

const function paragraph(text: () -> string, color: Color3, bold: boolean?): TextLabel
	return new("TextLabel")({
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = color,
		Font = if bold then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
		TextSize = 15,
	}) :: TextLabel
end

-- read-only, so it can be selected and copied.
const function copyable(text: () -> string): TextBox
	return new("TextBox")({
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundColor3 = Theme.INPUT,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		TextEditable = false,
		ClipsDescendants = true,
		Text = text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = Theme.TEXT,
		Font = Enum.Font.Code,
		TextSize = 14,

		Theme.stroke(Theme.BORDER),
		new("UIPadding")({ PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
	}) :: TextBox
end

const function options(values: { any }, suffix: string): () -> { { label: string, value: any } }
	return function()
		const list = {}
		for _, value in values do
			table.insert(list, { label = `{value}{suffix}`, value = value })
		end
		return list
	end
end

-- shown while the backend is unreachable: what's wrong and how to fix it.
const function ConnectionHelp(bridge: any, reconnect: () -> (), layoutOrder: number)
	const help = startHelp()
	return vide.show(function()
		return not bridge.connected()
	end, function()
		return new("Frame")({
			Name = "ConnectionHelp",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = layoutOrder,
			BackgroundTransparency = 1,

			new("UIPadding")({ PaddingTop = UDim.new(0, 10) }),
			new("Frame")({
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = Color3.fromRGB(46, 30, 32),
				BorderSizePixel = 0,

				Theme.stroke(Color3.fromRGB(96, 44, 46)),
				new("UICorner")({ CornerRadius = UDim.new(0, 6) }),
				new("UIPadding")({
					PaddingLeft = UDim.new(0, 12),
					PaddingRight = UDim.new(0, 12),
					PaddingTop = UDim.new(0, 10),
					PaddingBottom = UDim.new(0, 12),
				}),
				new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }),

				at(1, paragraph(function()
					return if bridge.httpBlocked()
						then "Studio blocked Prism's HTTP access"
						else `Prism can't reach its backend on 127.0.0.1:{bridge.port()}`
				end, Theme.TEXT, true)),
				at(2, paragraph(function()
					if bridge.httpBlocked() then
						return "Open Plugins → Manage Plugins, find Prism and allow 127.0.0.1. Then click Reconnect."
					end
					return "Render settings, previews and uploads need the backend, a small program on your computer "
						.. "that runs Blender. It starts at login, but Studio can't start it for you. "
						.. "Run this in a terminal to start it and see why it failed:"
				end, Theme.MUTED)),
				vide.show(function()
					return not bridge.httpBlocked()
				end, function()
					return at(3, copyable(function()
						return help.command
					end))
				end),
				vide.show(function()
					return not bridge.httpBlocked()
				end, function()
					return at(4, paragraph(function()
						return `If prism isn't found or the backend stops again, run the installer again. `
							.. `prism logs shows recent output. Logs: {help.logs}`
					end, Theme.MUTED))
				end),
				vide.show(bridge.lastError, function()
					return at(5, paragraph(function()
						return "Last error:"
					end, Theme.SUBTLE))
				end),
				vide.show(bridge.lastError, function()
					return at(6, copyable(function()
						return bridge.lastError() or ""
					end))
				end),
				new("Frame")({
					Name = "Actions",
					Size = UDim2.new(1, 0, 0, 30),
					LayoutOrder = 100,
					BackgroundTransparency = 1,

					Button({
						text = "Reconnect",
						variant = "accent",
						size = UDim2.fromOffset(110, 28),
						position = UDim2.fromOffset(0, 2),
						activated = reconnect,
					}),
					Button({
						text = `Use default port ({Bridge.DEFAULT_PORT})`,
						size = UDim2.fromOffset(190, 28),
						position = UDim2.fromOffset(118, 2),
						enabled = function()
							return bridge.port() ~= Bridge.DEFAULT_PORT
						end,
						activated = bridge.resetPort,
					}),
				}),
			}),
		})
	end)
end

const function SettingsPage(props: Props): ScrollingFrame
	const store = props.store
	const config = function(key: string): any
		const current = store.config()
		return if current then (current :: any)[key] else nil
	end
	const text = function(key: string): () -> string
		return function()
			const value = config(key)
			return if value == nil then "" else tostring(value)
		end
	end
	const commit = function(key: string): (string) -> ()
		return function(value: string)
			store.updateConfig({ [key] = value })
		end
	end

	const function reconnect()
		task.spawn(function()
			props.bridge.refresh()
			if props.bridge.connected() then
				store.reload()
				store.setNotice("Connected to the Prism backend.", "success")
			elseif props.bridge.httpBlocked() then
				store.setNotice(
					"Studio blocked Prism's HTTP access. Allow 127.0.0.1 for Prism under Plugins → Manage Plugins.",
					"error"
				)
			else
				const detail = props.bridge.lastError()
				store.setNotice(
					`No backend on port {props.bridge.port()}.{if detail then ` ({detail})` else ""}`,
					"error"
				)
			end
		end)
	end

	local order = 0
	const function nextOrder(): number
		order += 1
		return order
	end

	const function row<T>(instance: T & GuiObject): T
		instance.LayoutOrder = nextOrder()
		return instance
	end

	return new("ScrollingFrame")({
		Name = "SettingsPage",
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -20, 1, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = Theme.BORDER,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,

		new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),

		ConnectionHelp(props.bridge, reconnect, nextOrder()),

		heading("Plugin", nextOrder()),
		row(ToggleSetting({
			name = "Auto-3D",
			index = 0,
			labelWidth = 0.35,
			description = "Show 3D while adjusting your model, then display the finished Blender preview automatically.",
			value = store.auto3d,
			onChange = store.setAuto3d,
		})),

		row(ToggleSetting({
			name = "Blender version label",
			index = 1,
			labelWidth = 0.5,
			description = "Show the Blender version in the top bar. Offline troubleshooting remains available.",
			value = store.showBlenderVersion,
			onChange = store.setShowBlenderVersion,
		})),
		row(ToggleSetting({
			name = "Connection status dot",
			index = 2,
			labelWidth = 0.5,
			description = "Show the green or red connection status circle in the top bar.",
			value = store.showStatusDot,
			onChange = store.setShowStatusDot,
		})),

		row(DropdownSetting({
			name = "Emoji provider",
			index = 1,
			description = "Emoji artwork used in text previews, exports and uploads. Images download once and are cached for offline use.",
			text = function()
				const provider = config("emojiProvider") or "google"
				return string.upper(string.sub(provider, 1, 1)) .. string.sub(provider, 2)
			end,
			options = function()
				const list = {}
				for _, provider in EMOJI_PROVIDERS do
					table.insert(list, { value = provider, label = string.upper(string.sub(provider, 1, 1)) .. string.sub(provider, 2) })
				end
				return list
			end,
			onSelect = function(value)
				store.updateConfig({ emojiProvider = value })
			end,
		})),

		row(DropdownSetting({
			name = "Material style",
			index = 2,
			description = "Built-in material look for this place. Studio hides MaterialService.Use2022Materials from plugins, "
				.. "so Automatic uses 2022 materials unless Studio reports otherwise. Choose Legacy for places that turned 2022 materials off.",
			text = function()
				return MATERIAL_STYLES[store.materialStyle()] or "Automatic"
			end,
			options = function()
				return {
					{ value = "auto", label = MATERIAL_STYLES.auto },
					{ value = "2022", label = MATERIAL_STYLES["2022"] },
					{ value = "legacy", label = MATERIAL_STYLES.legacy },
				}
			end,
			onSelect = store.setMaterialStyle,
		})),

		heading("Output", nextOrder()),
		row(TextBoxSetting({
			name = "Output folder",
			index = 1,
			description = "Rendered icons are saved here. Browse opens your system's folder picker.",
			value = text("outputFolder"),
			onCommit = commit("outputFolder"),
			button = { text = "Browse", activated = store.pickFolder },
		})),
		row(TextBoxSetting({
			name = "File name",
			index = 2,
			description = "Pattern for saved files. {name} is the model name, {index} its position in the list.",
			value = text("filenamePattern"),
			onCommit = commit("filenamePattern"),
		})),
		row(ToggleSetting({
			name = "Overwrite files",
			index = 3,
			labelWidth = 0.35,
			description = "Replace files with the same name instead of adding a number.",
			value = function()
				return config("overwrite") == true
			end,
			onChange = function(value)
				store.updateConfig({ overwrite = value })
			end,
		})),

		heading("Quality", nextOrder()),
		row(DropdownSetting({
			name = "Render size",
			index = 1,
			description = "Pixel size of saved and uploaded icons.",
			text = function()
				return `{config("renderSize") or "-"} px`
			end,
			options = options(RENDER_SIZES, " px"),
			onSelect = function(value)
				store.updateConfig({ renderSize = value })
			end,
		})),
		row(DropdownSetting({
			name = "Render anti-aliasing",
			index = 2,
			description = "Samples for saved icons. More samples are smoother and slower.",
			text = function()
				return tostring(config("renderAA") or "-")
			end,
			options = options(AA, ""),
			onSelect = function(value)
				store.updateConfig({ renderAA = value })
			end,
		})),
		row(DropdownSetting({
			name = "Preview size",
			index = 3,
			description = "Pixel size of the live preview. Smaller is faster.",
			text = function()
				return `{config("previewSize") or "-"} px`
			end,
			options = options(PREVIEW_SIZES, " px"),
			onSelect = function(value)
				store.updateConfig({ previewSize = value })
				task.defer(store.requestPreview)
			end,
		})),
		row(DropdownSetting({
			name = "Preview anti-aliasing",
			index = 4,
			description = "Samples for the live preview.",
			text = function()
				return tostring(config("previewAA") or "-")
			end,
			options = options(AA, ""),
			onSelect = function(value)
				store.updateConfig({ previewAA = value })
				task.defer(store.requestPreview)
			end,
		})),

		heading("Uploading", nextOrder()),
		row(TextBoxSetting({
			name = "Default creator",
			index = 1,
			description = "Who uploads go to when the place has no owner yet: user:<id> or group:<id>.",
			placeholderText = "user:123456",
			value = text("defaultCreator"),
			onCommit = commit("defaultCreator"),
		})),
		row(TextBoxSetting({
			name = "Raven path",
			index = 2,
			description = "Full path to the raven executable. Leave empty to search PATH.",
			value = text("ravenPath"),
			onCommit = commit("ravenPath"),
		})),

		heading("Backend", nextOrder()),
		row(TextBoxSetting({
			name = "Blender",
			index = 1,
			description = "Blender executable used for rendering. Re-run the installer to change it.",
			value = text("blenderPath"),
			readOnly = true,
		})),
		row(TextBoxSetting({
			name = "Port",
			index = 2,
			description = "Port the backend listens on. Changing it restarts the backend on the new port.",
			value = function()
				return tostring(props.bridge.port())
			end,
			onCommit = function(value)
				const parsed = tonumber(value)
				if parsed == nil or parsed < 1024 or parsed > 65535 then
					store.setNotice("The port must be a number from 1024 to 65535.", "error")
					return
				end
				const port = math.floor(parsed)
				if not props.bridge.connected() then
					-- nothing to restart: point the plugin at a backend already on that port.
					props.bridge.setPort(port)
					return
				end
				store.changePort(port, function(ok, message)
					if not ok then
						store.setNotice(`Could not change the port: {message or "unknown error"}`, "error")
						return
					end
					props.bridge.setPort(port)
					store.setNotice(`Restarting the backend on port {port}…`, "info")
				end)
			end,
		})),

		new("Frame")({
			Name = "History",
			Size = UDim2.new(1, 0, 0, 44),
			LayoutOrder = nextOrder(),
			BackgroundTransparency = 1,

			Button({
				text = "Render and upload history",
				icon = Icons.history,
				position = UDim2.fromOffset(4, 14),
				size = UDim2.new(1, -8, 0, 30),
				activated = props.onOpenHistory,
			}),
		}),
		new("Frame")({
			Name = "About",
			Size = UDim2.new(1, 0, 0, 70),
			LayoutOrder = nextOrder(),
			BackgroundTransparency = 1,

			new("TextLabel")({
				Position = UDim2.fromOffset(4, 10),
				Size = UDim2.new(1, -280, 0, 50),
				BackgroundTransparency = 1,
				Text = function()
					const backend = if props.bridge.connected()
						then `Backend {props.bridge.version() or "?"} · Blender {props.bridge.blender() or "?"}`
						else "Backend offline"
					return `Prism v{props.pluginVersion}\n{backend}`
				end,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Top,
				TextColor3 = Theme.SUBTLE,
				Font = Enum.Font.SourceSans,
				TextSize = 14,
			}),
			Button({
				text = "Check for updates",
				size = UDim2.fromOffset(132, 28),
				position = UDim2.new(1, -134, 0, 10),
				anchorPoint = Vector2.new(1, 0),
				enabled = props.bridge.connected,
				activated = function()
					store.checkForUpdate(true, function(info, problem)
						if info and info.available then
							return
						elseif info and not info.canUpdate then
							store.setNotice("This backend runs from a source checkout; update it with git.", "info")
						elseif problem then
							store.setNotice(`Couldn't check for updates: {problem}`, "error")
						else
							-- after backend-only updates the backend holds the newest version number.
							store.setNotice(`Prism is up to date (v{info and info.current or props.pluginVersion}).`, "success")
						end
					end)
				end,
			}),
			Button({
				text = "Test connection",
				size = UDim2.fromOffset(124, 28),
				position = UDim2.new(1, -4, 0, 10),
				anchorPoint = Vector2.new(1, 0),
				activated = reconnect,
			}),
		}),
	}) :: ScrollingFrame
end

return SettingsPage
