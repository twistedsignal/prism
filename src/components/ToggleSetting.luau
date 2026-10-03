-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const BaseSetting = require("./BaseSetting")

const new = vide.create

export type Props = {
	name: string,
	index: number,
	description: string?,
	labelWidth: number?,
	value: () -> boolean,
	onChange: (boolean) -> (),
}

const function ToggleSetting(props: Props): Frame
	const row = BaseSetting({
		name = props.name,
		index = props.index,
		description = props.description,
		labelWidth = props.labelWidth,
	})
	const labelWidth = props.labelWidth or 0.5

	new("TextButton")({
		Name = "Value",
		Size = UDim2.fromScale(1 - labelWidth, 1),
		Position = UDim2.fromScale(labelWidth, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
		Activated = function()
			props.onChange(not props.value())
		end,
		Parent = row,

		new("Frame")({
			Name = "Box",
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.new(0, 6, 0.5, -7),
			BorderSizePixel = 0,
			BackgroundColor3 = function()
				return if props.value() then Color3.fromRGB(35, 48, 88) else Theme.TRACK
			end,

			Theme.stroke(Theme.BORDER),
			new("TextLabel")({
				Name = "Check",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Text = function()
					return if props.value() then "✓" else ""
				end,
				TextColor3 = Theme.BLUE,
				Font = Enum.Font.SourceSansBold,
				TextSize = 18,
			}),
		}),
		new("TextLabel")({
			Name = "State",
			Size = UDim2.new(1, -30, 1, 0),
			Position = UDim2.fromOffset(28, 0),
			BackgroundTransparency = 1,
			Text = function()
				return if props.value() then "On" else "Off"
			end,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.SUBTLE,
			Font = Enum.Font.SourceSans,
			TextSize = 14,
		}),
	})

	return row
end

return ToggleSetting
