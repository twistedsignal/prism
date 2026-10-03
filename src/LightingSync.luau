-- Snapshot global Roblox lighting into Prism's editable render settings.
-- Workbench has no sky/environment renderer, so colors and fill are approximations.
const LightingSync = {}

const function linear(value: number): number
	return if value <= 0.04045 then value / 12.92 else ((value + 0.055) / 1.055) ^ 2.4
end

const function display(value: number): number
	return if value <= 0.0031308 then value * 12.92 else 1.055 * value ^ (1 / 2.4) - 0.055
end

const function energy(color: Color3): Vector3
	return Vector3.new(linear(color.R), linear(color.G), linear(color.B))
end

-- Separate linear intensity from hue; the backend converts hex colors back to linear RGB.
const function colorAndIntensity(rgb: Vector3, maximum: number): (string, number)
	const intensity = math.max(rgb.X, rgb.Y, rgb.Z)
	if intensity <= 0 then
		return "#FFFFFF", 0
	end
	const color = Color3.new(display(rgb.X / intensity), display(rgb.Y / intensity), display(rgb.Z / intensity))
	return `#{color:ToHex()}`, math.clamp(intensity, 0, maximum)
end

function LightingSync.capture(lighting: Lighting): { [string]: any }
	const sun = lighting:GetSunDirection()
	const night = sun.Y < 0
	const direction = if night then lighting:GetMoonDirection() else sun
	-- Fade the directional light near the horizon. Moonlight is weaker and cooler.
	const daylight = math.clamp(sun.Y / 0.1, 0, 1)
	const strength = math.max(lighting.Brightness, 0) * math.clamp(direction.Y / 0.1, 0, 1)
		* (if night then 0.15 else 1)
	const base = if night then Color3.fromRGB(190, 205, 255) else Color3.new(1, 1, 1)
	const top = lighting.ColorShift_Top
	const tint = base:Lerp(top, math.max(top.R, top.G, top.B))
	const sunColor, sunIntensity = colorAndIntensity(energy(tint) * strength, 3)
	const ambient = energy(lighting.Ambient)
	const outdoor = energy(lighting.OutdoorAmbient)
	local ambientEnergy = if lighting.GlobalShadows then Vector3.new(
		math.max(ambient.X, outdoor.X), math.max(ambient.Y, outdoor.Y), math.max(ambient.Z, outdoor.Z)
	) else ambient
	-- Neutral sky fill is an estimate; Workbench cannot sample Roblox's cubemap.
	ambientEnergy += Vector3.one * math.clamp(lighting.EnvironmentDiffuseScale, 0, 1) * (0.05 + 0.15 * daylight)
	const ambientColor, ambientIntensity = colorAndIntensity(ambientEnergy, 2)
	-- Remove Prism's default studio fill/rim unless the place supplies a bottom color shift.
	const secondaryColor, secondaryIntensity = colorAndIntensity(energy(lighting.ColorShift_Bottom) * strength * 0.25, 3)
	const total = sunIntensity + ambientIntensity
	return {
		direction = direction.Unit,
		values = {
			sunColor = sunColor,
			sunIntensity = sunIntensity,
			ambientColor = ambientColor,
			ambientIntensity = ambientIntensity,
			secondaryColor = secondaryColor,
			secondaryIntensity = secondaryIntensity,
			exposure = math.clamp(lighting.ExposureCompensation, -3, 3),
			castShadows = lighting.GlobalShadows and sunIntensity > 0,
			shadowIntensity = if total > 0 then math.clamp(sunIntensity / total, 0, 1) else 0,
			specular = math.clamp(lighting.EnvironmentSpecularScale, 0, 1),
		},
	}
end

function LightingSync.forModel(snapshot: { [string]: any }, settings: { [string]: any }, pivot: CFrame): { [string]: any }
	const stance = CFrame.fromOrientation(math.rad(settings.pitch or 0), math.rad(settings.yaw or 0), math.rad(settings.roll or 0))
	const direction = stance:VectorToWorldSpace(pivot:VectorToObjectSpace(snapshot.direction))
	const rotation, elevation = math.rad(settings.cameraRotation or 0), math.rad(settings.cameraElevation or 0)
	const eye = Vector3.new(math.sin(rotation) * math.cos(elevation), math.sin(elevation), -math.cos(rotation) * math.cos(elevation))
	-- Match Blender's -Z tracking camera with Y up, including its local Z roll.
	const right = Vector3.new(-math.cos(rotation), 0, -math.sin(rotation))
	const up = Vector3.new(-math.sin(rotation) * math.sin(elevation), math.cos(elevation), math.cos(rotation) * math.sin(elevation))
	const roll = math.rad(settings.cameraRoll or 0)
	const cameraRight = right * math.cos(roll) + up * math.sin(roll)
	const cameraUp = up * math.cos(roll) - right * math.sin(roll)
	const view = Vector3.new(direction:Dot(cameraRight), direction:Dot(cameraUp), direction:Dot(eye)).Unit
	const values = table.clone(snapshot.values)
	values.sunRotation = (math.deg(math.atan2(view.X, view.Z)) + 180) % 360 - 180
	values.sunElevation = math.clamp(math.deg(math.asin(math.clamp(view.Y, -1, 1))), -89, 89)
	return values
end

return LightingSync
