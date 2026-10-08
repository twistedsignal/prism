-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const HoverDescription = require("./HoverDescription")
const Overlay = require("../Overlay")

const new = vide.create
const source = vide.source
const effect = vide.effect

export type TabButton = {
	button: ImageButton,
	active: (boolean?) -> boolean,
}

const function TabButton(parent: Instance, text: string, icon: string, activated: (() -> ())?): TabButton
	const active = source(false)
	local indicator: Frame
	local image: ImageLabel
	const button = new("ImageButton")({
		Name = `{text}Tab`,
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = Theme.ROW_ALT,
		BorderSizePixel = 0,
		Image = "",
		AutoButtonColor = true,
		Activated = activated,
		Parent = parent,

		Theme.stroke(Theme.BORDER),
		new("ImageLabel")({
			Name = "Icon",
			Size = UDim2.fromOffset(20, 20),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			BackgroundTransparency = 1,
			Image = icon,
			ImageColor3 = Theme.MUTED,
			vide.action(function(instance)
				image = instance :: ImageLabel
			end),
		}),
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
	}) :: ImageButton

	HoverDescription({ root = Overlay.layer(), target = button, text = text, width = #text * 8 + 28 })
	effect(function()
		const isActive = active()
		button.BackgroundColor3 = if isActive then Theme.SECTION else Theme.ROW_ALT
		image.ImageColor3 = if isActive then Theme.TEXT else Theme.MUTED
		indicator.BackgroundTransparency = if isActive then 0 else 1
	end)

	return { button = button, active = active }
end

return TabButton
