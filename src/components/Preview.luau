-- selene: allow(mixed_table)
-- live preview: a studio viewport ("3D") or the blender render streamed into an EditableImage.
const vide = require("../vide")
const Theme = require("./Theme")
const Segmented = require("./Segmented")
const Types = require("../Types")

const new = vide.create
const source = vide.source
const effect = vide.effect
const cleanup = vide.cleanup

const CAMERA_PADDING = 1.3
const ORTHOGRAPHIC_FOV = 4

export type View = "3d" | "blender"

export type Props = {
	currentModel: () -> Types.Model?,
	view: (View?) -> View,
	previewVersion: () -> number,
	previewImage: () -> EditableImage?,
	previewState: () -> string,
	previewError: () -> string?,
	connected: () -> boolean,
}

-- world-aligned bounds of every part in an instance.
const function bounds(root: Instance): (Vector3, Vector3)
	local minimum = Vector3.new(math.huge, math.huge, math.huge)
	local maximum = -minimum
	const parts = if root:IsA("BasePart") then { root } else {}
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Transparency < 1 then
			table.insert(parts, descendant)
		end
	end
	for _, part in parts do
		const cf = (part :: BasePart).CFrame
		const half = (part :: BasePart).Size / 2
		-- extents of a rotated box along the world axes.
		const extent = Vector3.new(
			math.abs(cf.XVector.X) * half.X + math.abs(cf.YVector.X) * half.Y + math.abs(cf.ZVector.X) * half.Z,
			math.abs(cf.XVector.Y) * half.X + math.abs(cf.YVector.Y) * half.Y + math.abs(cf.ZVector.Y) * half.Z,
			math.abs(cf.XVector.Z) * half.X + math.abs(cf.YVector.Z) * half.Y + math.abs(cf.ZVector.Z) * half.Z
		)
		minimum = minimum:Min(cf.Position - extent)
		maximum = maximum:Max(cf.Position + extent)
	end
	if minimum.X == math.huge then
		return Vector3.zero, Vector3.one
	end
	return (minimum + maximum) / 2, maximum - minimum
end

-- matches the renderer's stance and camera math, so the viewport frames the model like blender does.
const function frame(clone: Instance, camera: Camera, settings: Types.Settings)
	const pitch = math.rad(settings.pitch or 0)
	const yaw = math.rad(settings.yaw or 0)
	const roll = math.rad(settings.roll or 0)
	if clone:IsA("PVInstance") then
		clone:PivotTo(CFrame.fromOrientation(pitch, yaw, roll))
	end
	const center, size = bounds(clone)
	const diameter = math.max(size.X, size.Y, size.Z, 0.01)
	const width = diameter * CAMERA_PADDING / math.max(settings.zoom or 1, 0.01)

	local fov: number
	if settings.orthographic ~= false then
		fov = ORTHOGRAPHIC_FOV
	elseif settings.fovAuto ~= false then
		fov = math.deg(2 * math.atan((width / 2) / (diameter * 5)))
	else
		fov = settings.fov or 30
	end
	const distance = (width / 2) / math.tan(math.rad(fov) / 2)

	const rotation = math.rad(settings.cameraRotation or 0)
	const elevation = math.rad(settings.cameraElevation or 0)
	const direction = Vector3.new(
		math.sin(rotation) * math.cos(elevation),
		math.sin(elevation),
		-math.cos(rotation) * math.cos(elevation)
	)
	camera.FieldOfView = fov
	camera.CFrame = CFrame.lookAt(center + direction * distance, center)
		* CFrame.Angles(0, 0, math.rad(settings.cameraRoll or 0))
end

const function Viewport(props: Props): ViewportFrame
	const camera = new("Camera")({ Name = "PreviewCamera" }) :: Camera
	cleanup(camera)
	const viewport = new("ViewportFrame")({
		Name = "Viewport",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		CurrentCamera = camera,
		Ambient = Color3.fromRGB(150, 150, 150),
		LightColor = Color3.fromRGB(255, 255, 255),
		LightDirection = Vector3.new(-1, -1.5, -1),

		camera,
		new("UIAspectRatioConstraint")({ AspectRatio = 1 }),
	}) :: ViewportFrame
	local clone: Instance? = nil
	local clonedFrom: Instance? = nil

	effect(function()
		const model = props.currentModel()
		const settings = if model then model.settings() else nil
		if model == nil or settings == nil then
			if clone then
				clone:Destroy()
				clone = nil
				clonedFrom = nil
			end
			return
		end
		if clonedFrom ~= model.instance then
			if clone then
				clone:Destroy()
			end
			const archivable = model.instance.Archivable
			model.instance.Archivable = true
			const ok, copy = pcall(function()
				return model.instance:Clone()
			end)
			model.instance.Archivable = archivable
			clone = if ok then copy else nil
			clonedFrom = model.instance
			if clone then
				-- keep only geometry; scripts and sounds have no business in a viewport.
				for _, descendant in clone:GetDescendants() do
					if descendant:IsA("LuaSourceContainer") or descendant:IsA("Sound") then
						descendant:Destroy()
					end
				end
				clone.Parent = viewport
			end
		end
		if clone then
			frame(clone, camera, settings)
		end
	end)

	cleanup(function()
		if clone then
			clone:Destroy()
		end
	end)

	return viewport
end

const function Preview(props: Props): Frame
	const status = function(): string
		if not props.connected() then
			return "Prism backend is offline. Start it or re-run the installer."
		end
		const model = props.currentModel()
		if model == nil then
			return "Select models in Studio, then click Use selection."
		end
		if model.state() == "serializing" then
			return "Reading model…"
		end
		if model.state() == "error" then
			return model.warning() or "This model could not be read."
		end
		if props.previewState() == "error" then
			return props.previewError() or "Render failed."
		end
		if props.previewVersion() == 0 then
			return "Rendering…"
		end
		return model.warning() or ""
	end
	const hasImage = source(false)

	effect(function()
		props.previewVersion()
		hasImage(props.previewImage() ~= nil)
	end)

	return new("Frame")({
		Name = "Preview",
		BackgroundColor3 = Theme.DARKER,
		BorderSizePixel = 0,

		Theme.stroke(Theme.BORDER),
		new("UICorner")({ CornerRadius = UDim.new(0, 6) }),
		new("TextLabel")({
			Name = "Title",
			Position = UDim2.fromOffset(10, 6),
			Size = UDim2.new(1, -170, 0, 24),
			BackgroundTransparency = 1,
			Text = function()
				const model = props.currentModel()
				return if model then model.name else "No model"
			end,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = Theme.TEXT,
			Font = Enum.Font.SourceSansBold,
			TextSize = 16,
		}),
		Segmented({
			options = { "3D", "Blender" },
			selected = function()
				return if props.view() == "3d" then 1 else 2
			end,
			onSelect = function(index)
				props.view(if index == 1 then "3d" else "blender")
			end,
			size = UDim2.fromOffset(140, 24),
			position = UDim2.new(1, -10, 0, 6),
			anchorPoint = Vector2.new(1, 0),
		}),
		new("Frame")({
			Name = "Body",
			Position = UDim2.fromOffset(8, 36),
			Size = UDim2.new(1, -16, 1, -44),
			BackgroundTransparency = 1,

			new("ImageLabel")({
				Name = "Render",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				ScaleType = Enum.ScaleType.Fit,
				Visible = function()
					return props.view() == "blender" and hasImage()
				end,
				ImageContent = function()
					props.previewVersion()
					const image = props.previewImage()
					return if image then Content.fromObject(image) else Content.none
				end,
				ImageTransparency = function()
					return if props.previewState() == "rendering" then 0.15 else 0
				end,
			}),
			vide.show(function()
				return props.view() == "3d"
			end, function()
				return Viewport(props)
			end),
			new("TextLabel")({
				Name = "Status",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -4),
				Size = UDim2.new(1, -20, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = Theme.SECTION,
				BackgroundTransparency = 0.1,
				BorderSizePixel = 0,
				Visible = function()
					return status() ~= "" and (props.view() == "blender" or props.currentModel() == nil)
				end,
				Text = status,
				TextWrapped = true,
				TextColor3 = Theme.MUTED,
				Font = Enum.Font.SourceSans,
				TextSize = 15,
				ZIndex = 2,

				new("UICorner")({ CornerRadius = UDim.new(0, 4) }),
				new("UIPadding")({
					PaddingLeft = UDim.new(0, 8),
					PaddingRight = UDim.new(0, 8),
					PaddingTop = UDim.new(0, 6),
					PaddingBottom = UDim.new(0, 6),
				}),
			}),
		}),
	}) :: Frame
end

return Preview
