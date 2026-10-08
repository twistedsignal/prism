-- selene: allow(mixed_table)
const Selection = game:GetService("Selection")
const vide = require("./vide")
const Theme = require("./components/Theme")
const TabButton = require("./components/TabButton")
const Button = require("./components/Button")
const StatusDot = require("./components/StatusDot")
const Overlay = require("./Overlay")
const Serializer = require("./Serializer")
const Store = require("./Store")
const ModelChanges = require("./ModelChanges")
const HistoryPage = require("./pages/HistoryPage")
const RenderPage = require("./pages/RenderPage")
const SelectPage = require("./pages/SelectPage")
const SettingsPage = require("./pages/SettingsPage")
const TemplatesPage = require("./pages/TemplatesPage")
const UpdatePrompt = require("./UpdatePrompt")
const VERSION = require("./Version")

const new = vide.create
const source = vide.source
const effect = vide.effect
const cleanup = vide.cleanup

const HEADER_HEIGHT = 56
const FOOTER_HEIGHT = 62

export type Props = {
	plugin: Plugin,
	bridge: any,
	visible: () -> boolean,
}

const function App(props: Props): Frame
	const bridge = props.bridge
	const store = Store.create(props.plugin, bridge)
	cleanup(store.destroy)

	cleanup(ModelChanges.watch(game:GetService("MaterialService"), function()
		for _, model in store.models() do
			store.refreshModel(model)
		end
	end))
	const watchers: { [Instance]: () -> () } = {}
	effect(function()
		const retained = {}
		for _, model in store.models() do
			retained[model.instance] = true
			if not watchers[model.instance] then
				watchers[model.instance] = ModelChanges.watch(model.instance, function()
					store.refreshModel(model)
				end)
			end
		end
		for instance, disconnect in watchers do
			if not retained[instance] then
				disconnect()
				watchers[instance] = nil
			end
		end
	end)
	cleanup(function()
		for _, disconnect in watchers do
			disconnect()
		end
	end)

	const page = source("render" :: "render" | "select" | "templates" | "settings" | "history")
	-- kept here so the search survives switching tabs.
	const selectQuery = source("")
	const selectFilter = source(1)
	const historyFilter = source(1)
	const rootSize = source(Vector2.new(720, 860))
	local selectionToken = 0
	const function importSelection()
		selectionToken += 1
		const token = selectionToken
		task.delay(0.15, function()
			-- while hidden, selecting elsewhere in studio must not read or drop models.
			if token == selectionToken and vide.untrack(props.visible) then
				store.useSelection(Serializer.getRoots(Selection:Get()))
			end
		end)
	end
	cleanup(Selection.SelectionChanged:Connect(importSelection))
	cleanup(function()
		selectionToken += 1
	end)
	-- runs once on mount and again whenever the widget is reopened.
	effect(function()
		if props.visible() then
			vide.untrack(importSelection)
		end
	end)

	-- the overlay must exist before any component that places hover text or popups in it.
	const overlay = new("Frame")({
		Name = "Overlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = Theme.OVERLAY_Z,
	}) :: Frame
	Overlay.setLayer(overlay)
	cleanup(function()
		Overlay.setLayer(nil)
	end)

	const header = new("Frame")({
		Name = "Header",
		Position = UDim2.fromOffset(0, 3),
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		BackgroundColor3 = Theme.DARKER,
		BorderSizePixel = 0,

		new("Frame")({
			Name = "Status",
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(0.5, -200, 1, 0),
			BackgroundTransparency = 1,

			new("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 8),
			}),
			StatusDot(bridge.connected),
			-- offline: click through to the troubleshooting help in settings.
			new("TextButton")({
				Size = UDim2.new(1, -16, 1, 0),
				BackgroundTransparency = 1,
				AutoButtonColor = false,
				Active = function()
					return not bridge.connected()
				end,
				Activated = function()
					if not bridge.connected() then
						page("settings")
					end
				end,
				Text = function()
					if not bridge.connected() then
						return if bridge.httpBlocked()
							then "HTTP access blocked · Fix"
							else "Backend offline · Fix"
					end
					return `Blender {string.match(bridge.blender() or "", "^[%d%.]+") or "?"}`
				end,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Theme.MUTED,
				Font = Enum.Font.SourceSans,
				TextSize = 15,
			}),
		}),
	}) :: Frame

	-- prompt once per studio session for each new version.
	local promptedVersion: string? = nil
	effect(function()
		const info = store.update()
		if info and info.available and info.latest and info.latest ~= promptedVersion then
			promptedVersion = info.latest
			task.defer(UpdatePrompt.open, store)
		end
	end)

	const dismissedVersion = source(nil :: string?)
	const bannerMode = function(): "restart" | "update" | nil
		if store.updateState() == "restart" then
			return "restart"
		end
		const info = store.update()
		if info and info.available and info.latest ~= dismissedVersion() then
			return "update"
		end
		return nil
	end
	const bannerHeight = function(): number
		return if bannerMode() then 30 else 0
	end

	const banner = new("Frame")({
		Name = "UpdateBanner",
		Position = UDim2.fromOffset(0, HEADER_HEIGHT + 3),
		Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = Theme.BLUE_DARK,
		BorderSizePixel = 0,
		Visible = function()
			return bannerMode() ~= nil
		end,
		ZIndex = 5,

		new("TextLabel")({
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, -200, 1, 0),
			BackgroundTransparency = 1,
			Text = function()
				if bannerMode() == "restart" then
					return `Prism v{store.installedVersion() or "?"} is installed. Restart Roblox Studio to finish updating.`
				end
				const info = store.update()
				return `Prism v{if info then info.latest else "?"} is available.`
			end,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.TEXT,
			Font = Enum.Font.SourceSansSemibold,
			TextSize = 14,
			ZIndex = 5,
		}),
		vide.show(function()
			return bannerMode() == "update"
		end, function()
			return new("Frame")({
				Name = "Actions",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Size = UDim2.fromOffset(176, 22),
				BackgroundTransparency = 1,
				ZIndex = 5,

				Button({
					text = "Later",
					size = UDim2.fromOffset(64, 22),
					textSize = 14,
					activated = function()
						const info = store.update()
						dismissedVersion(if info then info.latest else nil)
					end,
				}),
				Button({
					text = function()
						return if store.updateState() == "updating" then "Updating…" else "Update"
					end,
					variant = "accent",
					size = UDim2.fromOffset(106, 22),
					position = UDim2.fromScale(1, 0),
					anchorPoint = Vector2.new(1, 0),
					textSize = 14,
					enabled = function()
						return store.updateState() == "idle"
					end,
					activated = function()
						UpdatePrompt.open(store)
					end,
				}),
			})
		end),
	})

	const tabs = new("Frame")({
		Name = "Tabs",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(376, 32),
		BackgroundTransparency = 1,
		Parent = header,

		new("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
	})
	const renderTab = TabButton(tabs, "Render", function()
		page("render")
	end)
	const selectTab = TabButton(tabs, "Select", function()
		page("select")
	end)
	selectTab.button.LayoutOrder = 1
	const templatesTab = TabButton(tabs, "Templates", function()
		page("templates")
	end)
	templatesTab.button.LayoutOrder = 2
	const settingsTab = TabButton(tabs, "Settings", function()
		page("settings")
	end)
	settingsTab.button.LayoutOrder = 3
	effect(function()
		renderTab.active(page() == "render")
		selectTab.active(page() == "select")
		templatesTab.active(page() == "templates")
		-- history opens from settings, so settings stays highlighted there.
		settingsTab.active(page() == "settings" or page() == "history")
	end)

	const footer = new("Frame")({
		Name = "Footer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
		BackgroundColor3 = Theme.DARKER,
		BorderSizePixel = 0,

		new("TextLabel")({
			Name = "Folder",
			Position = UDim2.fromOffset(12, 4),
			Size = UDim2.new(1, -24, 0, 16),
			BackgroundTransparency = 1,
			Text = function()
				const config = store.config()
				return if config then `Saves to {config.outputFolder}` else "Output folder unknown until the backend connects"
			end,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.SUBTLE,
			Font = Enum.Font.SourceSans,
			TextSize = 13,
		}),
		Button({
			text = function()
				if store.busy() == "Rendering" then
					return "Rendering…"
				end
				const count = #store.models()
				return `Render {count} model{if count == 1 then "" else "s"}`
			end,
			variant = "accent",
			position = UDim2.fromOffset(10, 24),
			size = UDim2.new(0.62, -18, 0, 30),
			enabled = function()
				return bridge.connected() and #store.models() > 0 and store.busy() == nil
			end,
			activated = function()
				store.exportModels(store.models())
			end,
		}),
		Button({
			text = "Open Folder",
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.new(1, -10, 0, 24),
			size = UDim2.new(0.38, -14, 0, 30),
			enabled = bridge.connected,
			activated = store.openFolder,
		}),
	}) :: Frame

	const notice = new("TextLabel")({
		Name = "Notice",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(FOOTER_HEIGHT + 8)),
		Size = UDim2.new(1, -40, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = function()
			const current = store.notice()
			if current and current.kind == "error" then
				return Color3.fromRGB(70, 28, 30)
			elseif current and current.kind == "success" then
				return Color3.fromRGB(26, 56, 38)
			end
			return Theme.SECTION
		end,
		BorderSizePixel = 0,
		Visible = function()
			return store.notice() ~= nil
		end,
		Text = function()
			const current = store.notice()
			return if current then current.text else ""
		end,
		TextWrapped = true,
		TextColor3 = Theme.TEXT,
		Font = Enum.Font.SourceSans,
		TextSize = 15,
		ZIndex = Theme.OVERLAY_Z - 1,

		Theme.stroke(Theme.BORDER),
		new("UICorner")({ CornerRadius = UDim.new(0, 6) }),
		new("UIPadding")({
			PaddingLeft = UDim.new(0, 10),
			PaddingRight = UDim.new(0, 10),
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 8),
		}),
	})

	return new("Frame")({
		Name = "Prism",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.DARK,
		BorderSizePixel = 0,
		vide.changed("AbsoluteSize", rootSize),

		new("Frame")({
			Name = "AccentBar",
			Size = UDim2.new(1, 0, 0, 3),
			BackgroundColor3 = Theme.BLUE,
			BorderSizePixel = 0,
		}),
		header,
		banner,
		new("Frame")({
			Name = "Content",
			Position = function()
				return UDim2.fromOffset(0, HEADER_HEIGHT + 3 + 10 + bannerHeight())
			end,
			Size = function()
				return UDim2.new(1, 0, 1, -(HEADER_HEIGHT + 3 + 10 + FOOTER_HEIGHT + 10 + bannerHeight()))
			end,
			BackgroundTransparency = 1,

			vide.switch(page)({
				render = function()
					return RenderPage({
						store = store,
						connected = bridge.connected,
						rootSize = rootSize,
					})
				end,
				select = function()
					return SelectPage({
						query = selectQuery,
						filter = selectFilter,
						onSelected = function()
							page("render")
						end,
					})
				end,
				templates = function()
					return TemplatesPage({ store = store })
				end,
				settings = function()
					return SettingsPage({
						store = store,
						bridge = bridge,
						pluginVersion = VERSION,
						onOpenHistory = function()
							page("history")
						end,
					})
				end,
				history = function()
					return HistoryPage({
						store = store,
						connected = bridge.connected,
						filter = historyFilter,
						onBack = function()
							page("settings")
						end,
					})
				end,
			}),
		}),
		footer,
		notice,
		overlay,
	}) :: Frame
end

return App
