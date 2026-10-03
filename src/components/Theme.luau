const TweenService = game:GetService("TweenService")
const vide = require("../vide")

const TWEEN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

const Theme = {
	ARROW_IMAGE = "rbxassetid://72729959789633",
	TWEEN = TWEEN,
	BLUE = Color3.fromRGB(57, 98, 255),
	BLUE_DARK = Color3.fromRGB(39, 70, 196),
	DARK = Color3.fromRGB(25, 26, 31),
	DARKER = Color3.fromRGB(20, 21, 25),
	SECTION = Color3.fromRGB(32, 34, 40),
	ROW = Color3.fromRGB(24, 25, 30),
	ROW_ALT = Color3.fromRGB(28, 29, 35),
	BORDER = Color3.fromRGB(38, 40, 48),
	MUTED = Color3.fromRGB(170, 174, 188),
	SUBTLE = Color3.fromRGB(118, 122, 138),
	TEXT = Color3.fromRGB(232, 235, 245),
	INPUT = Color3.fromRGB(21, 22, 27),
	TRACK = Color3.fromRGB(37, 39, 48),
	BUTTON = Color3.fromRGB(47, 50, 62),
	DANGER = Color3.fromRGB(166, 45, 45),
	DANGER_DARK = Color3.fromRGB(108, 29, 29),
	GREEN = Color3.fromRGB(72, 199, 116),
	RED = Color3.fromRGB(230, 72, 72),
	YELLOW = Color3.fromRGB(240, 190, 70),
	ROW_HEIGHT = 30,
	SECTION_HEIGHT = 26,
	DROPDOWN_ROW_HEIGHT = 27,
	OVERLAY_Z = 50,
}

function Theme.tween(instance: Instance, goals: { [string]: any })
	TweenService:Create(instance, TWEEN, goals):Play()
end

function Theme.stroke(color: Color3)
	return vide.create("UIStroke")({
		Color = color,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

function Theme.hover(color: Color3): Color3
	return color:Lerp(Color3.new(1, 1, 1), 0.08)
end

return Theme
