-- Camera gestures edit the same settings used by Blender and exported renders.
const CameraControls = {}

function CameraControls.orbit(settings: { [string]: any }, dx: number, dy: number): { [string]: number }
	return {
		cameraRotation = ((settings.cameraRotation or 0) + dx * 0.5 + 180) % 360 - 180,
		cameraElevation = math.clamp((settings.cameraElevation or 0) + dy * 0.5, -89, 89),
	}
end

function CameraControls.zoom(settings: { [string]: any }, steps: number): { [string]: number }
	return { zoom = math.clamp((settings.zoom or 1) * 1.12 ^ steps, 0.1, 5) }
end

return CameraControls
