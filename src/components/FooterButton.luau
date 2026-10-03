-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")

const new = vide.create

type Variant = "default" | "accent" | "danger"

const function FooterButton(parent: Instance, text: string, variant: Variant, activated: (() -> ())?): TextButton
	const backgroundColor = if variant == "accent"
		then Theme.BLUE
		elseif variant == "danger"
			then Color3.fromRGB(166, 45, 45)
			else Color3.fromRGB(47, 50, 62)
	const borderColor = if variant == "accent"
		then Theme.BLUE_DARK
		elseif variant == "danger"
			then Color3.fromRGB(108, 29, 29)
			else Theme.BORDER

	return new("TextButton")({
		Name = text,
		Size = UDim2.new(0.5, -5, 1, 0),
		BackgroundColor3 = backgroundColor,
		BorderSizePixel = 0,
		Text = text,
		TextColor3 = Theme.TEXT,
		Font = Enum.Font.SourceSansBold,
		TextSize = 15,
		AutoButtonColor = true,
		Activated = activated,
		Parent = parent,

		Theme.stroke(borderColor),
	}) :: TextButton
end

return FooterButton
