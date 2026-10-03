-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const HoverDescription = require("./HoverDescription")
const Overlay = require("../Overlay")

const new = vide.create

export type Props = {
	name: string,
	index: number,
	height: number?,
	labelWidth: number?,
	description: string?,
	parent: Instance?,
}

const function BaseSetting(props: Props): Frame
	const height = props.height or Theme.ROW_HEIGHT

	const row = new("Frame")({
		Name = props.name,
		Size = UDim2.new(1, 0, 0, height),
		LayoutOrder = props.index,
		BackgroundColor3 = if props.index % 2 == 0 then Theme.ROW_ALT else Theme.ROW,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = props.parent,

		new("TextLabel")({
			Name = "Label",
			Size = UDim2.fromScale(props.labelWidth or 0.5, 1),
			Position = UDim2.fromScale(0, 0),
			Text = `  {props.name}`,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.MUTED,
			Font = Enum.Font.SourceSans,
			TextSize = 15,
			BackgroundTransparency = 1,
		}),
	}) :: Frame
	if props.description then
		HoverDescription({
			root = Overlay.layer(),
			target = row,
			text = props.description,
		})
	end
	return row
end

return BaseSetting
