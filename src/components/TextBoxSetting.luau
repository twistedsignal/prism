-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const BaseSetting = require("./BaseSetting")
const Button = require("./Button")

const new = vide.create

export type Props = {
	name: string,
	index: number,
	description: string?,
	placeholderText: string?,
	value: () -> string,
	onCommit: ((string) -> ())?,
	readOnly: boolean?,
	button: { text: string, activated: () -> () }?,
}

const BUTTON_WIDTH = 70

const function TextBoxSetting(props: Props): Frame
	const row = BaseSetting({
		name = props.name,
		index = props.index,
		description = props.description,
		labelWidth = 0.35,
	})
	const buttonSpace = if props.button then BUTTON_WIDTH + 4 else 0
	local box: TextBox

	box = new("TextBox")({
		Name = "Value",
		Size = UDim2.new(0.65, -6 - buttonSpace, 1, -6),
		Position = UDim2.new(0.35, 3, 0, 3),
		BackgroundColor3 = Theme.INPUT,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		TextEditable = not props.readOnly,
		Text = props.value,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = Enum.Font.SourceSans,
		TextSize = 15,
		TextColor3 = if props.readOnly then Theme.MUTED else Theme.TEXT,
		PlaceholderText = props.placeholderText or "",
		PlaceholderColor3 = Theme.SUBTLE,
		FocusLost = function()
			if props.onCommit and box.Text ~= props.value() then
				props.onCommit(box.Text)
			end
		end,
		Parent = row,

		Theme.stroke(Theme.BORDER),
		new("UIPadding")({
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
		}),
	}) :: TextBox

	if props.button then
		const button = Button({
			text = props.button.text,
			size = UDim2.new(0, BUTTON_WIDTH, 1, -6),
			position = UDim2.new(1, -(BUTTON_WIDTH + 3), 0, 3),
			textSize = 14,
			activated = props.button.activated,
		})
		button.Parent = row
	end

	return row
end

return TextBoxSetting
