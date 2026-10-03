-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")

const new = vide.create
const source = vide.source
const effect = vide.effect

export type TabButton = {
	button: TextButton,
	active: (boolean?) -> boolean,
}

const function TabButton(parent: Instance, text: string, activated: (() -> ())?): TabButton
	const active = source(false)
	local indicator: Frame
	const button = new("TextButton")({
		Name = `{text}Tab`,
		Size = UDim2.new(0.5, -4, 1, 0),
		BackgroundColor3 = Theme.ROW_ALT,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = Theme.MUTED,
		Font = Enum.Font.SourceSansBold,
		TextSize = 15,
		AutoButtonColor = true,
		Activated = activated,
		Parent = parent,

		Theme.stroke(Theme.BORDER),
		new("Frame")({
			Name = "Indicator",
			Size = UDim2.new(1, 0, 0, 3),
			Position = UDim2.new(0, 0, 1, -3),
			BackgroundColor3 = Theme.BLUE,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			vide.action(function(instance)
				indicator = instance :: Frame
			end),
		}),
	}) :: TextButton

	effect(function()
		const isActive = active()
		button.BackgroundColor3 = if isActive then Theme.SECTION else Theme.ROW_ALT
		button.TextColor3 = if isActive then Theme.TEXT else Theme.MUTED
		indicator.BackgroundTransparency = if isActive then 0 else 1
	end)

	return {
		button = button,
		active = active,
	}
end

return TabButton
