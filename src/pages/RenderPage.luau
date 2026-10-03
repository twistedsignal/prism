-- selene: allow(mixed_table)
-- the main page: preview, upload row and model cards on the left, settings on the right.
const MarketplaceService = game:GetService("MarketplaceService")
const vide = require("../vide")
const Types = require("../Types")
const Theme = require("../components/Theme")
const Button = require("../components/Button")
const Dropdown = require("../components/Dropdown")
const Segmented = require("../components/Segmented")
const Section = require("../components/Section")
const SliderSetting = require("../components/SliderSetting")
const ToggleSetting = require("../components/ToggleSetting")
const ColorSetting = require("../components/ColorSetting")
const DropdownSetting = require("../components/DropdownSetting")
const TextBoxSetting = require("../components/TextBoxSetting")
const ModelCard = require("../components/ModelCard")
const Preview = require("../components/Preview")
const Modal = require("../components/Modal")
const Store = require("../Store")
const Requirements = require("../Requirements")

const new = vide.create
const source = vide.source
const effect = vide.effect
const cleanup = vide.cleanup

const WIDE_LAYOUT = 640
const CARD_SIZE = Vector2.new(84, 100)

type Target = { label: string, creator: string }

export type Props = {
	store: Store.Store,
	connected: () -> boolean,
	rootSize: () -> Vector2,
}

const function label(props: {
	text: string | () -> string,
	size: UDim2,
	position: (UDim2 | () -> UDim2)?,
	color: Color3?,
	bold: boolean?,
	textSize: number?,
	alignment: Enum.TextXAlignment?,
}): TextLabel
	return new("TextLabel")({
		Size = props.size,
		Position = props.position,
		BackgroundTransparency = 1,
		Text = props.text,
		TextXAlignment = props.alignment or Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = props.color or Theme.MUTED,
		Font = if props.bold then Enum.Font.SourceSansBold else Enum.Font.SourceSans,
		TextSize = props.textSize or 15,
	}) :: TextLabel
end

-- the creators this place can upload to: the game's owner, plus the default from settings.
const function useTargets(store: Store.Store): () -> { Target }
	const gameTarget = source(nil :: Target?)
	if game.CreatorId ~= 0 then
		const creator = if game.CreatorType == Enum.CreatorType.Group
			then `group:{game.CreatorId}`
			else `user:{game.CreatorId}`
		gameTarget({ label = "This game's owner", creator = creator })
		if game.PlaceId ~= 0 then
			task.spawn(function()
				const ok, info = pcall(function()
					return MarketplaceService:GetProductInfo(game.PlaceId)
				end)
				if ok and info and info.Name then
					gameTarget({ label = `{info.Name} (this game)`, creator = creator })
				end
			end)
		end
	end

	return function(): { Target }
		const targets = {}
		const current = gameTarget()
		if current then
			table.insert(targets, current)
		end
		const config = store.config()
		if config and config.defaultCreator ~= "" and (current == nil or current.creator ~= config.defaultCreator) then
			const kind = if string.sub(config.defaultCreator, 1, 6) == "group:" then "Group" else "My account"
			table.insert(targets, { label = `{kind} ({config.defaultCreator})`, creator = config.defaultCreator })
		end
		return targets
	end
end

const function showUploadResults(results: { Store.UploadResult })
	Modal.open({
		title = "Upload results",
		width = 420,
		height = math.min(110 + #results * 54, 460),
		buttons = {
			{
				text = "Done",
				variant = "accent",
				activated = function(close)
					close()
				end,
			},
		},
		body = function()
			const rows = {}
			for index, result in results do
				const failed = result.error ~= nil
				table.insert(rows, new("Frame")({
					Name = result.name,
					Size = UDim2.new(1, 0, 0, 48),
					LayoutOrder = index,
					BackgroundColor3 = if index % 2 == 0 then Theme.ROW_ALT else Theme.ROW,
					BorderSizePixel = 0,
					ZIndex = Theme.OVERLAY_Z + 1,

					Theme.stroke(Theme.BORDER),
					new("TextLabel")({
						Position = UDim2.fromOffset(8, 4),
						Size = UDim2.new(1, -16, 0, 18),
						BackgroundTransparency = 1,
						Text = result.name,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextTruncate = Enum.TextTruncate.AtEnd,
						TextColor3 = Theme.TEXT,
						Font = Enum.Font.SourceSansSemibold,
						TextSize = 15,
						ZIndex = Theme.OVERLAY_Z + 1,
					}),
					if failed
						then new("TextLabel")({
							Position = UDim2.fromOffset(8, 22),
							Size = UDim2.new(1, -16, 0, 22),
							BackgroundTransparency = 1,
							Text = result.error,
							TextXAlignment = Enum.TextXAlignment.Left,
							TextTruncate = Enum.TextTruncate.AtEnd,
							TextColor3 = Theme.RED,
							Font = Enum.Font.SourceSans,
							TextSize = 14,
							ZIndex = Theme.OVERLAY_Z + 1,
						})
						else new("TextBox")({
							Position = UDim2.fromOffset(8, 22),
							Size = UDim2.new(1, -138, 0, 22),
							BackgroundColor3 = Theme.INPUT,
							BorderSizePixel = 0,
							ClearTextOnFocus = false,
							TextEditable = false,
							-- ImageLabels need the image ID; fall back to the Decal if Roblox hasn't exposed it.
							Text = `rbxassetid://{result.imageId or result.assetId}`,
							TextXAlignment = Enum.TextXAlignment.Left,
							TextColor3 = Theme.TEXT,
							Font = Enum.Font.Code,
							TextSize = 14,
							ZIndex = Theme.OVERLAY_Z + 1,

							Theme.stroke(Theme.BORDER),
							new("UIPadding")({ PaddingLeft = UDim.new(0, 6) }),
						}),
					if failed
						then nil
						else new("TextLabel")({
							AnchorPoint = Vector2.new(1, 0),
							Position = UDim2.new(1, -8, 0, 22),
							Size = UDim2.fromOffset(120, 22),
							BackgroundTransparency = 1,
							Text = if result.imageId then result.moderation or "" else `Decal · {result.moderation or ""}`,
							TextXAlignment = Enum.TextXAlignment.Right,
							TextColor3 = if result.moderation == "Approved" then Theme.GREEN else Theme.YELLOW,
							Font = Enum.Font.SourceSans,
							TextSize = 14,
							ZIndex = Theme.OVERLAY_Z + 1,
						}),
				}))
			end
			return new("ScrollingFrame")({
				Name = "Results",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = Theme.BORDER,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ZIndex = Theme.OVERLAY_Z + 1,

				new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),
				rows,
			}) :: ScrollingFrame
		end,
	})
end

const function promptPresetName(onSave: (string) -> ())
	local box: TextBox
	Modal.open({
		title = "Save preset",
		height = 150,
		buttons = {
			{
				text = "Cancel",
				activated = function(close)
					close()
				end,
			},
			{
				text = "Save",
				variant = "accent",
				activated = function(close)
					const name = string.gsub(box.Text, "^%s*(.-)%s*$", "%1")
					if name ~= "" then
						close()
						onSave(name)
					end
				end,
			},
		},
		body = function()
			box = new("TextBox")({
				Name = "Name",
				BackgroundColor3 = Theme.INPUT,
				BorderSizePixel = 0,
				ClearTextOnFocus = false,
				PlaceholderText = "Preset name",
				PlaceholderColor3 = Theme.SUBTLE,
				Text = "",
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Theme.TEXT,
				Font = Enum.Font.SourceSans,
				TextSize = 16,
				ZIndex = Theme.OVERLAY_Z + 1,

				Theme.stroke(Theme.BORDER),
				new("UIPadding")({ PaddingLeft = UDim.new(0, 8) }),
				new("UISizeConstraint")({ MaxSize = Vector2.new(math.huge, 30) }),
			}) :: TextBox
			task.defer(function()
				box:CaptureFocus()
			end)
			return box
		end,
	})
end

const function SettingsSections(store: Store.Store, schema: () -> Types.Schema): Frame
	const settings = function(): Types.Settings
		const model = store.currentModel()
		return if model then model.settings() else schema().defaults
	end

	const container = new("Frame")({
		Name = "Sections",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,

		new("UIListLayout")({
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 8),
		}),
	}) :: Frame

	const function bindVisibility(instance: GuiObject, requires: string?)
		if requires then
			effect(function()
				instance.Visible = Requirements.met(requires, settings())
			end)
		end
	end

	const function buildRow(setting: Types.SettingSchema, rowIndex: number): Frame
		const key = setting.key
		local row: Frame
		if setting.type == "number" then
			const autoKey = setting.auto
			row = SliderSetting({
				name = setting.label,
				index = rowIndex,
				description = setting.description,
				min = setting.min or 0,
				max = setting.max or 1,
				step = setting.step or 0.01,
				value = function()
					return settings()[key]
				end,
				onChange = function(value)
					store.setValue(key, value)
				end,
				auto = if autoKey
					then {
						value = function()
							return settings()[autoKey] == true
						end,
						onChange = function(value)
							store.setValue(autoKey, value)
						end,
					}
					else nil,
			})
		elseif setting.type == "bool" then
			row = ToggleSetting({
				name = setting.label,
				index = rowIndex,
				description = setting.description,
				labelWidth = 0.36,
				value = function()
					return settings()[key] == true
				end,
				onChange = function(value)
					store.setValue(key, value)
				end,
			})
		elseif setting.type == "select" then
			const options = function(): { Dropdown.Option }
				const list: { Dropdown.Option } = {}
				for _, option in setting.options or {} do
					table.insert(list, { value = option.value, label = option.label })
				end
				if setting.optionsSource == "fonts" then
					for _, font in store.fonts() do
						-- preview fonts Roblox also has in their own typeface.
						table.insert(list, {
							value = font.value,
							label = font.label,
							font = if font.robloxFont then Font.new(font.robloxFont) else nil,
						})
					end
				end
				return list
			end
			row = DropdownSetting({
				name = setting.label,
				index = rowIndex,
				description = setting.description,
				text = function()
					const current = settings()[key]
					for _, option in options() do
						if option.value == current then
							return option.label
						end
					end
					-- a saved font that isn't installed on this computer.
					return if current == "" then "Default" else `{current} (missing)`
				end,
				options = options,
				font = function(): Font?
					const current = settings()[key]
					for _, option in options() do
						if option.value == current then
							return option.font
						end
					end
					return nil
				end,
				onSelect = function(value)
					store.setValue(key, value)
				end,
			})
		elseif setting.type == "text" then
			row = TextBoxSetting({
				name = setting.label,
				index = rowIndex,
				description = setting.description,
				placeholderText = "None",
				value = function()
					return settings()[key] or ""
				end,
				onCommit = function(value)
					store.setValue(key, string.sub(value, 1, setting.maxLength or 120))
				end,
			})
		else
			row = ColorSetting({
				name = setting.label,
				index = rowIndex,
				description = setting.description,
				alpha = setting.type == "rgba",
				value = function()
					return settings()[key]
				end,
				onChange = function(value)
					store.setValue(key, value)
				end,
			})
		end
		bindVisibility(row, setting.requires)
		return row
	end

	-- adds settings and nested groups to a section body; groups are collapsible sub-sections.
	local buildItems: (Instance, { any }) -> ()
	buildItems = function(parent: Instance, items: { any })
		for index, item in items do
			if item.type == "group" then
				const group = item :: Types.GroupSchema
				const holder = new("Frame")({
					Name = group.label,
					Size = UDim2.fromScale(1, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					LayoutOrder = index,
					Parent = parent,

					new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),
					new("UIPadding")({ PaddingLeft = UDim.new(0, 10) }),
				}) :: Frame
				const sub = Section(holder, group.label, 0, group.collapsed, true)
				sub.header.LayoutOrder = 1
				sub.body.LayoutOrder = 2
				const function updateHeight()
					sub.setHeight(sub.layout.AbsoluteContentSize.Y)
				end
				cleanup(sub.layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateHeight))
				buildItems(sub.body, group.settings)
				task.defer(updateHeight)
				bindVisibility(holder, group.requires)
			elseif not item.hidden then
				buildRow(item :: Types.SettingSchema, index).Parent = parent
			end
		end
	end

	for sectionIndex, sectionSchema in schema().sections do
		const section = Section(container, sectionSchema.label, 0, sectionSchema.collapsed)
		section.header.LayoutOrder = sectionIndex * 2
		section.body.LayoutOrder = sectionIndex * 2 + 1
		const function updateHeight()
			section.setHeight(section.layout.AbsoluteContentSize.Y)
		end
		cleanup(section.layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateHeight))
		buildItems(section.body, sectionSchema.settings)
		task.defer(updateHeight)
	end

	return container
end

const function RenderPage(props: Props): Frame
	const store = props.store
	const view = store.previewView
	const targets = useTargets(store)
	const selectedTarget = source(nil :: string?)
	const leftSize = source(Vector2.new(400, 700))

	const wide = function(): boolean
		return props.rootSize().X >= WIDE_LAYOUT
	end
	const modelCount = function(): number
		return #store.models()
	end
	const target = function(): Target?
		const list = targets()
		for _, entry in list do
			if entry.creator == selectedTarget() then
				return entry
			end
		end
		return list[1]
	end
	const previewHeight = function(): number
		const size = leftSize()
		return math.clamp(size.X, 160, math.max(160, size.Y - 204))
	end

	const function upload(models: { Types.Model })
		const chosen = target()
		if chosen == nil then
			store.setNotice("Set a default creator in Settings to upload from an unpublished place.", "error")
			return
		end
		store.uploadModels(models, chosen.creator, showUploadResults)
	end

	-- Refresh after the bridge reconnects. View changes never trigger another render.
	effect(function()
		if props.connected() then
			task.defer(store.requestPreview)
		end
	end)

	const left = new("Frame")({
		Name = "Left",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 0),
		Size = function()
			return if wide() then UDim2.new(0.58, -15, 1, 0) else UDim2.new(1, -20, 0.55, -4)
		end,
		vide.changed("AbsoluteSize", leftSize),

		new("Frame")({
			Name = "PreviewHolder",
			Size = function()
				return UDim2.new(1, 0, 0, previewHeight())
			end,
			BackgroundTransparency = 1,

			Preview({
				currentModel = store.currentModel,
				auto3d = store.auto3d,
				view = function(value: Preview.View?): Preview.View
					if value then
						view(value)
						if value == "blender" then
							store.requestPreview()
						end
					end
					return view()
				end,
				previewVersion = store.previewVersion,
				previewTextBounds = store.previewTextBounds,
				previewImage = store.previewImage,
				previewState = store.previewState,
				previewError = store.previewError,
				setCamera = store.setCamera,
				setTextOffset = store.setTextOffset,
				busy = store.busy,
				connected = props.connected,
			}),
		}),

		new("Frame")({
			Name = "UploadRow",
			Position = function()
				return UDim2.fromOffset(0, previewHeight() + 12)
			end,
			Size = UDim2.new(1, 0, 0, 72),
			BackgroundTransparency = 1,

			Dropdown({
				text = function()
					const chosen = target()
					return if chosen then `Upload to: {chosen.label}` else "Upload to: set a creator in Settings"
				end,
				options = function()
					const options = {}
					for _, entry in targets() do
						table.insert(options, { label = entry.label, value = entry.creator })
					end
					return options
				end,
				onSelect = selectedTarget,
				emptyText = "Set a default creator in Settings",
				size = UDim2.new(1, 0, 0, 32),
			}),
			Button({
				text = function()
					return if store.busy() == "Uploading" then "Uploading…" else "Upload"
				end,
				size = UDim2.new(0.5, -4, 0, 32),
				position = UDim2.fromOffset(0, 40),
				enabled = function()
					return props.connected() and store.currentModel() ~= nil and store.busy() == nil
				end,
				activated = function()
					const model = store.currentModel()
					if model then
						upload({ model })
					end
				end,
			}),
			Button({
				text = function()
					return `Upload All ({modelCount()})`
				end,
				variant = "accent",
				size = UDim2.new(0.5, -4, 0, 32),
				position = UDim2.new(1, 0, 0, 40),
				anchorPoint = Vector2.new(1, 0),
				enabled = function()
					return props.connected() and modelCount() > 0 and store.busy() == nil
				end,
				activated = function()
					upload(store.models())
				end,
			}),
		}),

		new("ScrollingFrame")({
			Name = "Cards",
			Position = function()
				return UDim2.fromOffset(0, previewHeight() + 92)
			end,
			Size = function()
				return UDim2.new(1, 0, 1, -(previewHeight() + 92))
			end,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.BORDER,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,

			new("UIGridLayout")({
				CellSize = UDim2.fromOffset(CARD_SIZE.X, CARD_SIZE.Y),
				CellPadding = UDim2.fromOffset(6, 6),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			new("UIPadding")({
				PaddingTop = UDim.new(0, 2),
				PaddingLeft = UDim.new(0, 2),
			}),
			vide.values(store.models, function(model, index)
				return ModelCard({
					model = model,
					index = index,
					selected = function()
						return store.selected() == index()
					end,
					onSelect = function()
						store.select(index())
					end,
				})
			end),
		}),
	}) :: Frame

	const right = new("Frame")({
		Name = "Right",
		BackgroundTransparency = 1,
		Position = function()
			return if wide() then UDim2.new(0.58, 5, 0, 0) else UDim2.new(0, 10, 0.55, 4)
		end,
		Size = function()
			return if wide() then UDim2.new(0.42, -15, 1, 0) else UDim2.new(1, -20, 0.45, -4)
		end,

		label({
			text = function()
				if store.mode() == "all" then
					return "Settings · all models"
				end
				const model = store.currentModel()
				return `Settings · {if model then model.name else "no model"}`
			end,
			size = UDim2.new(1, -160, 0, 26),
			color = Theme.TEXT,
			bold = true,
		}),
		Segmented({
			options = {
				"This model",
				function()
					return `All ({modelCount()})`
				end,
			},
			selected = function()
				return if store.mode() == "one" then 1 else 2
			end,
			onSelect = function(index)
				store.mode(if index == 1 then "one" else "all")
			end,
			size = UDim2.fromOffset(150, 24),
			position = UDim2.new(1, 0, 0, 1),
			anchorPoint = Vector2.new(1, 0),
		}),

		new("Frame")({
			Name = "Presets",
			Position = UDim2.fromOffset(0, 32),
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,

			Dropdown({
				text = function()
					const active = store.activePreset()
					return if active then `Preset: {active}` else "Preset: custom"
				end,
				options = function()
					const names = {}
					for name in store.presets() do
						table.insert(names, name)
					end
					table.sort(names)
					const options = {}
					for _, name in names do
						table.insert(options, { label = name, value = name })
					end
					return options
				end,
				onSelect = store.applyPreset,
				emptyText = "No presets yet. Click Save as.",
				size = UDim2.new(1, -140, 1, 0),
			}),
			Button({
				text = "Save as",
				size = UDim2.fromOffset(68, 28),
				position = UDim2.new(1, -70, 0, 0),
				anchorPoint = Vector2.new(1, 0),
				enabled = function()
					return props.connected() and store.currentModel() ~= nil
				end,
				activated = function()
					promptPresetName(store.savePreset)
				end,
			}),
			Button({
				text = "Delete",
				variant = "danger",
				size = UDim2.fromOffset(64, 28),
				position = UDim2.fromScale(1, 0),
				anchorPoint = Vector2.new(1, 0),
				enabled = function()
					return store.activePreset() ~= nil
				end,
				activated = function()
					const active = store.activePreset()
					if active then
						store.deletePreset(active)
					end
				end,
			}),
		}),

		new("ScrollingFrame")({
			Name = "Settings",
			Position = UDim2.fromOffset(0, 66),
			Size = UDim2.new(1, 0, 1, -102),
			BackgroundColor3 = Theme.DARKER,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = Theme.BORDER,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,

			Theme.stroke(Theme.BORDER),
			vide.show(store.schema, function(schema)
				return SettingsSections(store, schema :: any)
			end, function()
				return label({
					text = function()
						return if props.connected() then "Loading settings…" else "Connect to the Prism backend to edit render settings."
					end,
					size = UDim2.new(1, -16, 0, 40),
					position = UDim2.fromOffset(8, 0),
					color = Theme.SUBTLE,
				})
			end),
		}),

		new("Frame")({
			Name = "SettingsActions",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 28),
			BackgroundTransparency = 1,

			Button({
				text = "Copy to all models",
				size = UDim2.new(0.5, -3, 1, 0),
				enabled = function()
					return modelCount() > 1
				end,
				activated = store.copyToAll,
			}),
			Button({
				text = "Reset to defaults",
				size = UDim2.new(0.5, -3, 1, 0),
				position = UDim2.fromScale(1, 0),
				anchorPoint = Vector2.new(1, 0),
				enabled = function()
					return store.schema() ~= nil
				end,
				activated = store.resetToDefaults,
			}),
		}),
	}) :: Frame

	return new("Frame")({
		Name = "RenderPage",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,

		left,
		right,
	}) :: Frame
end

return RenderPage
