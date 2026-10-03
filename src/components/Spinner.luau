-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")
const RunService = game:GetService("RunService")

return function(visible: () -> boolean): Frame
	local spinner: Frame
	const frame = vide.create("Frame")({
		Name = "LoadingCircle",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 8, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Visible = visible,
		ZIndex = 5,
		vide.action(function(instance)
			spinner = instance :: Frame
		end),
		vide.create("UICorner")({ CornerRadius = UDim.new(1, 0) }),
		vide.create("Frame")({
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromOffset(0, 0),
			BackgroundTransparency = 1,
			ZIndex = 6,
			vide.create("UICorner")({ CornerRadius = UDim.new(1, 0) }),
			vide.create("UIStroke")({
				Color = Theme.BLUE,
				Thickness = 2,
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
