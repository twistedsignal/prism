-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")

const new = vide.create

export type Props = {
	options: { string | () -> string },
	selected: () -> number,
	onSelect: (index: number) -> (),
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
}

const function Segmented(props: Props): Frame
	const count = #props.options
	const buttons = {}
	for index, label in props.options do
		table.insert(buttons, new("TextButton")({
			Name = `Option{index}`,
			Size = UDim2.new(1 / count, if index < count then -1 else 0, 1, 0),
			LayoutOrder = index,
			BackgroundColor3 = function()
				return if props.selected() == index then Theme.BLUE else Theme.BUTTON
			end,
			BorderSizePixel = 0,
			Text = label,
			TextColor3 = function()
				return if props.selected() == index then Theme.TEXT else Theme.MUTED
			end,
			Font = Enum.Font.SourceSansSemibold,
			TextSize = 14,
			AutoButtonColor = true,
			Activated = function()
				props.onSelect(index)
			end,
		}))
	end

	return new("Frame")({
		Name = "Segmented",
		Size = props.size or UDim2.fromOffset(140, 24),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder or 0,
		BackgroundColor3 = Theme.BORDER,
		BorderSizePixel = 0,
		ClipsDescendants = true,

		Theme.stroke(Theme.BORDER),
		new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
		new("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 1),
		}),
		buttons,
	}) :: Frame
end

return Segmented
