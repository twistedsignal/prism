-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")

const new = vide.create
const source = vide.source
const effect = vide.effect

export type Section = {
	header: TextButton,
	body: Frame,
	layout: UIListLayout,
	setHeight: (number) -> (),
	isExpanded: () -> boolean,
}

const function Section(parent: Instance, text: string, initialBodyHeight: number): Section
	const bodyHeight = source(initialBodyHeight)
	const expanded = source(true)
	local body: Frame
	local arrowIcon: ImageLabel
	local bodyLayout: UIListLayout

	const header = new("TextButton")({
		Name = `{text}Header`,
		Size = UDim2.new(1, 0, 0, Theme.SECTION_HEIGHT),
		BackgroundColor3 = Theme.SECTION,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
		Activated = function()
			expanded(not expanded())
		end,
		Parent = parent,

		Theme.stroke(Theme.BORDER),
		new("ImageLabel")({
			Name = "Arrow",
			Size = UDim2.fromOffset(12, 12),
			Position = UDim2.new(0, 7, 0.5, -6),
			BackgroundTransparency = 1,
			Image = Theme.ARROW_IMAGE,
			ImageColor3 = Theme.TEXT,
			vide.action(function(instance)
				arrowIcon = instance :: ImageLabel
			end),
		}),
		new("TextLabel")({
			Name = "Label",
			Size = UDim2.new(1, -30, 1, 0),
			Position = UDim2.fromOffset(28, 0),
			BackgroundTransparency = 1,
			Text = text,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = Theme.TEXT,
			Font = Enum.Font.SourceSansSemibold,
			TextSize = 15,
		}),
	})

	body = new("Frame")({
		Name = `{text}Body`,
		Size = UDim2.new(1, 0, 0, initialBodyHeight),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = parent,

		new("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 0),
			vide.action(function(instance)
				bodyLayout = instance :: UIListLayout
			end),
		}),
	}) :: Frame

	effect(function()
		const isExpanded = expanded()
		Theme.tween(body, {
			Size = UDim2.new(1, 0, 0, if isExpanded then bodyHeight() else 0),
		})
		Theme.tween(arrowIcon, {
			Rotation = if isExpanded then 0 else -90,
		})
	end)

	return {
		header = header,
		body = body,
		layout = bodyLayout,
		setHeight = function(nextHeight: number)
			bodyHeight(nextHeight)
		end,
		isExpanded = expanded,
	}
end

return Section
