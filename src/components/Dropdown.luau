-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const Overlay = require("../Overlay")

const new = vide.create

const MAX_LIST_HEIGHT = 220

export type Option = { label: string, value: any }

export type Props = {
	text: () -> string,
	options: () -> { Option },
	onSelect: (value: any) -> (),
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	emptyText: string?,
}

const function openList(button: GuiObject, options: { Option }, onSelect: (any) -> (), emptyText: string?)
	const layer = Overlay.layer()
	const position = Overlay.toLocal(button.AbsolutePosition)
	const count = math.max(#options, 1)
	const height = math.min(count * Theme.DROPDOWN_ROW_HEIGHT, MAX_LIST_HEIGHT)
	const below = position.Y + button.AbsoluteSize.Y + height <= layer.AbsoluteSize.Y - 4
	const y = if below then position.Y + button.AbsoluteSize.Y + 2 else position.Y - height - 2

	Overlay.mount(function(close)
		const rows = {}
		for index, option in options do
			table.insert(rows, new("TextButton")({
				Name = option.label,
				Size = UDim2.new(1, 0, 0, Theme.DROPDOWN_ROW_HEIGHT),
				LayoutOrder = index,
				BackgroundColor3 = if index % 2 == 0 then Theme.ROW_ALT else Theme.ROW,
				BorderSizePixel = 0,
				Text = `  {option.label}`,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextColor3 = Theme.TEXT,
				Font = Enum.Font.SourceSans,
				TextSize = 15,
				AutoButtonColor = true,
				ZIndex = Theme.OVERLAY_Z + 1,
				Activated = function()
					close()
					onSelect(option.value)
				end,
			}))
		end
		if #options == 0 then
			table.insert(rows, new("TextLabel")({
				Size = UDim2.new(1, 0, 0, Theme.DROPDOWN_ROW_HEIGHT),
				BackgroundTransparency = 1,
				Text = `  {emptyText or "Nothing here yet"}`,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextColor3 = Theme.SUBTLE,
				Font = Enum.Font.SourceSans,
				TextSize = 15,
				ZIndex = Theme.OVERLAY_Z + 1,
			}))
		end

		return new("Frame")({
			Name = "DropdownLayer",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			ZIndex = Theme.OVERLAY_Z,

			Overlay.dismissLayer(close),
			new("ScrollingFrame")({
				Name = "List",
				Size = UDim2.fromOffset(math.max(button.AbsoluteSize.X, 140), height),
				Position = UDim2.fromOffset(position.X, y),
				BackgroundColor3 = Theme.DARKER,
				BorderSizePixel = 0,
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = Theme.BORDER,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				ZIndex = Theme.OVERLAY_Z + 1,

				Theme.stroke(Theme.BORDER),
				new("UIListLayout")({ SortOrder = Enum.SortOrder.LayoutOrder }),
				rows,
			}),
		}) :: Frame
	end)
end

const function Dropdown(props: Props): TextButton
	local button: TextButton
	button = new("TextButton")({
		Name = "Dropdown",
		Size = props.size or UDim2.new(1, 0, 0, 28),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder or 0,
		BackgroundColor3 = Theme.INPUT,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
		Activated = function()
			openList(button, props.options(), props.onSelect, props.emptyText)
		end,

		Theme.stroke(Theme.BORDER),
		new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
		new("TextLabel")({
			Name = "Text",
			Size = UDim2.new(1, -30, 1, 0),
			Position = UDim2.fromOffset(8, 0),
			BackgroundTransparency = 1,
			Text = props.text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Font = Enum.Font.SourceSans,
			TextSize = 15,
			TextColor3 = Theme.TEXT,
		}),
		new("ImageLabel")({
			Name = "Arrow",
			Size = UDim2.fromOffset(12, 12),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			BackgroundTransparency = 1,
			Image = Theme.ARROW_IMAGE,
			ImageColor3 = Theme.MUTED,
		}),
	}) :: TextButton
	return button
end

return Dropdown
