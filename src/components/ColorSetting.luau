-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const BaseSetting = require("./BaseSetting")
const ColorPicker = require("./ColorPicker")

const new = vide.create

export type Props = {
	name: string,
	index: number,
	description: string?,
	value: () -> string,
	onChange: (string) -> (),
	-- edit #RRGGBBAA with an opacity bar.
	alpha: boolean?,
}

const function ColorSetting(props: Props): Frame
	const row = BaseSetting({
		name = props.name,
		index = props.index,
		description = props.description,
		labelWidth = 0.36,
	})
	local button: TextButton

	button = new("TextButton")({
		Name = "Value",
		Size = UDim2.new(0.64, -8, 1, -8),
		Position = UDim2.new(0.36, 4, 0, 4),
		BackgroundColor3 = Theme.INPUT,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
		Activated = function()
			ColorPicker.open({
				value = props.value(),
				alpha = props.alpha,
				anchor = button,
				onChange = props.onChange,
			})
		end,
		Parent = row,

		Theme.stroke(Theme.BORDER),
		new("UICorner")({ CornerRadius = UDim.new(0, 3) }),
		new("Frame")({
			Name = "Swatch",
			Size = UDim2.new(0, 34, 1, -6),
			Position = UDim2.fromOffset(3, 3),
			BackgroundColor3 = function()
				const ok, color = pcall(Color3.fromHex, string.sub(string.gsub(props.value(), "#", ""), 1, 6))
				return if ok then color else Color3.new(1, 1, 1)
			end,
			BackgroundTransparency = function()
				const digits = string.match(props.value(), "^#?%x%x%x%x%x%x(%x%x)$")
				return if digits then 1 - (tonumber(digits, 16) :: number) / 255 else 0
			end,
			BorderSizePixel = 0,

			Theme.stroke(Theme.BORDER),
			new("UICorner")({ CornerRadius = UDim.new(0, 2) }),
		}),
		new("TextLabel")({
			Name = "Hex",
			Size = UDim2.new(1, -46, 1, 0),
			Position = UDim2.fromOffset(44, 0),
			BackgroundTransparency = 1,
			Text = props.value,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.TEXT,
			Font = Enum.Font.Code,
			TextSize = 14,
		}),
	}) :: TextButton

	return row
end

return ColorSetting
