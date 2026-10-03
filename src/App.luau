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
const RenderPage = require("./pages/RenderPage")
const SettingsPage = require("./pages/SettingsPage")
const VERSION = require("./Version")

const new = vide.create
const source = vide.source
const effect = vide.effect
const cleanup = vide.cleanup

const HEADER_HEIGHT = 42
const FOOTER_HEIGHT = 62

export type Props = {
	plugin: Plugin,
	bridge: any,
}

const function App(props: Props): Frame
	const bridge = props.bridge
	const store = Store.create(props.plugin, bridge)
	cleanup(store.destroy)

	const page = source("render" :: "render" | "settings")
	const rootSize = source(Vector2.new(720, 860))
	const selectionCount = source(0)

	const function countSelection()
		selectionCount(#Serializer.getRoots(Selection:Get()))
	end
	cleanup(Selection.SelectionChanged:Connect(countSelection))
	countSelection()

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
			Size = UDim2.new(0.5, -120, 1, 0),
			BackgroundTransparency = 1,

			new("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, 8),
			}),
			StatusDot(bridge.connected),
			new("TextLabel")({
				Size = UDim2.new(1, -16, 1, 0),
				BackgroundTransparency = 1,
				Text = function()
					if not bridge.connected() then
						return "Bridge offline"
					end
					return `Bridge connected · Blender {string.match(bridge.blender() or "", "^[%d%.]+") or "?"}`
				end,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Theme.MUTED,
				Font = Enum.Font.SourceSans,
				TextSize = 15,
			}),
		}),
		Button({
			text = function()
				return `Use selection ({selectionCount()})`
			end,
			size = UDim2.fromOffset(140, 28),
			position = UDim2.new(1, -10, 0.5, 0),
			anchorPoint = Vector2.new(1, 0.5),
			enabled = function()
				return selectionCount() > 0
			end,
			activated = function()
				page("render")
				store.useSelection(Serializer.getRoots(Selection:Get()))
			end,
		}),
	}) :: Frame

	const tabs = new("Frame")({
		Name = "Tabs",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(0, 200, 1, -6),
		BackgroundTransparency = 1,
		Parent = header,

		new("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 4),
		}),
	})
	const renderTab = TabButton(tabs, "Render", function()
		page("render")
	end)
	const settingsTab = TabButton(tabs, "Settings", function()
		page("settings")
	end)
	settingsTab.button.LayoutOrder = 1
	effect(function()
		renderTab.active(page() == "render")
		settingsTab.active(page() == "settings")
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
			size = UDim2.new(0.62, -15, 0, 30),
			enabled = function()
				return bridge.connected() and #store.models() > 0 and store.busy() == nil
			end,
			activated = function()
				store.exportModels(store.models())
			end,
		}),
		Button({
			text = "Open folder",
			anchorPoint = Vector2.new(1, 0),
			position = UDim2.new(1, -10, 0, 24),
			size = UDim2.new(0.38, -5, 0, 30),
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
		new("Frame")({
			Name = "Content",
			Position = UDim2.fromOffset(0, HEADER_HEIGHT + 3 + 10),
			Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + 3 + 10 + FOOTER_HEIGHT + 10)),
			BackgroundTransparency = 1,

			vide.switch(page)({
				render = function()
					return RenderPage({
						store = store,
						connected = bridge.connected,
						rootSize = rootSize,
					})
				end,
				settings = function()
					return SettingsPage({
						store = store,
						bridge = bridge,
						pluginVersion = VERSION,
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
