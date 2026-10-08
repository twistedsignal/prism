-- selene: allow(mixed_table)
const vide = require("../vide")
const Theme = require("./Theme")

const new = vide.create

const function StatusDot(connected: () -> boolean, visible: (() -> boolean)?): Frame
	return new("Frame")({
		Name = "StatusDot",
		Visible = visible,
		Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = function()
			return if connected() then Theme.GREEN else Theme.RED
		end,
		BorderSizePixel = 0,

		new("UICorner")({ CornerRadius = UDim.new(1, 0) }),
	}) :: Frame
end

return StatusDot
