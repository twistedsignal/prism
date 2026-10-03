-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const RunService = game:GetService("RunService")

return function(visible: () -> boolean): Frame
	local spinner: Frame
	const frame = vide.create("Frame")({
		Name = "LoadingCircle",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = Theme.SECTION,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Visible = visible,
		ZIndex = 5,
		vide.action(function(instance)
			spinner = instance :: Frame
		end),
		vide.create("UICorner")({ CornerRadius = UDim.new(1, 0) }),
		vide.create("Frame")({
			Size = UDim2.fromOffset(24, 24),
			Position = UDim2.fromOffset(6, 6),
			BackgroundTransparency = 1,
			ZIndex = 6,
			vide.create("UICorner")({ CornerRadius = UDim.new(1, 0) }),
			vide.create("UIStroke")({
				Color = Theme.BLUE,
				Thickness = 3,
				vide.create("UIGradient")({
					Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(0.5, 0.15),
						NumberSequenceKeypoint.new(1, 1),
					}),
				}),
			}),
		}),
	}) :: Frame
	vide.cleanup(RunService.RenderStepped:Connect(function(dt)
		if spinner.Visible then
			spinner.Rotation = (spinner.Rotation + dt * 270) % 360
		end
	end))
	return frame
end
