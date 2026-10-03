const vide = require("../vide")
const Theme = require("./Theme")

const new = vide.create
const HOVER_DELAY = 1

export type Props = {
	root: Frame,
	target: GuiObject,
	text: string,
}

const function HoverDescription(props: Props): TextLabel
	const description = new("TextLabel")({
		Name = "HoverDescription",
		Size = UDim2.new(1, -24, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromOffset(12, 0),
		BackgroundColor3 = Theme.SECTION,
		BorderSizePixel = 0,
		Text = props.text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextColor3 = Theme.TEXT,
		Font = Enum.Font.SourceSans,
		TextSize = 16,
		LineHeight = 1.15,
		Visible = false,
		ZIndex = 100,
		Active = false,
		Parent = props.root,
		Theme.stroke(Theme.BORDER),
		new("UICorner")({
			CornerRadius = UDim.new(0, 6),
		}),
		new("UIPadding")({
			PaddingLeft = UDim.new(0, 14),
			PaddingRight = UDim.new(0, 14),
			PaddingTop = UDim.new(0, 11),
			PaddingBottom = UDim.new(0, 11),
		}),
	}) :: TextLabel

	const function positionDescription()
		const rootPosition = props.root.AbsolutePosition
		const targetPosition = props.target.AbsolutePosition
		const descriptionHeight = description.AbsoluteSize.Y
		const descriptionWidth = description.AbsoluteSize.X
		const maxX = math.max(12, props.root.AbsoluteSize.X - descriptionWidth - 12)
		const x = math.clamp(targetPosition.X - rootPosition.X + 8, 12, maxX)
		const belowY = targetPosition.Y - rootPosition.Y + props.target.AbsoluteSize.Y + 4
		const aboveY = targetPosition.Y - rootPosition.Y - descriptionHeight - 4
		const y = if belowY + descriptionHeight <= props.root.AbsoluteSize.Y - 8
			then belowY
			else math.max(8, aboveY)
		description.Position = UDim2.fromOffset(x, y)
	end

	local hoverToken = 0
	props.target.MouseEnter:Connect(function()
		hoverToken += 1
		const currentHoverToken = hoverToken
		task.delay(HOVER_DELAY, function()
			if currentHoverToken ~= hoverToken or props.target.Parent == nil then
				return
			end
			description.Visible = true
			task.defer(function()
				if currentHoverToken ~= hoverToken or props.target.Parent == nil then
					return
				end
				positionDescription()
			end)
		end)
	end)
	props.target.MouseLeave:Connect(function()
		hoverToken += 1
		description.Visible = false
	end)
	props.target.Destroying:Connect(function()
		hoverToken += 1
		description:Destroy()
	end)

	return description
end

return HoverDescription
