-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")

const new = vide.create

export type Variant = "default" | "accent" | "danger"

export type Props = {
	text: string | () -> string,
	variant: Variant?,
	size: UDim2?,
	position: UDim2?,
	anchorPoint: Vector2?,
	layoutOrder: number?,
	textSize: number?,
	enabled: (() -> boolean)?,
	activated: () -> (),
	name: string?,
	icon: string?,
}

const COLORS = {
	default = { background = Theme.BUTTON, border = Theme.BORDER },
	accent = { background = Theme.BLUE, border = Theme.BLUE_DARK },
	danger = { background = Theme.DANGER, border = Theme.DANGER_DARK },
}

const function Button(props: Props): TextButton
	const colors = COLORS[props.variant or "default"]
	const hovered = vide.source(false)
	const enabled = props.enabled or function()
		return true
	end

	return new("TextButton")({
		Name = props.name or (if type(props.text) == "string" then props.text else "Button"),
		Size = props.size or UDim2.fromOffset(100, 28),
		Position = props.position,
		AnchorPoint = props.anchorPoint,
		LayoutOrder = props.layoutOrder or 0,
		BackgroundColor3 = function()
			return if hovered() and enabled() then Theme.hover(colors.background) else colors.background
		end,
		BackgroundTransparency = function()
			return if enabled() then 0 else 0.45
		end,
		BorderSizePixel = 0,
		Text = if props.icon then "" else props.text,
		TextColor3 = Theme.TEXT,
		TextTransparency = function()
			return if enabled() then 0 else 0.4
		end,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Font = Enum.Font.SourceSansSemibold,
		TextSize = props.textSize or 15,
		AutoButtonColor = false,
		MouseEnter = function()
			hovered(true)
		end,
		MouseLeave = function()
			hovered(false)
		end,
		Activated = function()
			if enabled() then
				props.activated()
			end
		end,

		if props.icon then new("ImageLabel")({
			Name = "Icon",
			Size = UDim2.fromOffset(18, 18),
			Position = UDim2.new(0, 10, 0.5, -9),
			BackgroundTransparency = 1,
			Image = props.icon,
			ImageColor3 = Theme.TEXT,
		}) else nil,
		if props.icon then new("TextLabel")({
			Name = "Label",
			Size = UDim2.new(1, -44, 1, 0),
			Position = UDim2.fromOffset(34, 0),
			BackgroundTransparency = 1,
			Text = props.text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.TEXT,
			TextTransparency = function() return if enabled() then 0 else 0.4 end,
			Font = Enum.Font.SourceSansSemibold,
			TextSize = props.textSize or 15,
		}) else nil,
		Theme.stroke(colors.border),
		new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
	}) :: TextButton
end

return Button
