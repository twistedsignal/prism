-- turns selected instances into the backend's scene payload.
-- meshes and textures are read through EditableMesh/EditableImage.
const AssetService = game:GetService("AssetService")
const Base64 = require("./Base64")

const YIELD_EVERY = 3000
-- roblox only lets plugins read meshes and images owned by you or this experience's owner.
const PERMISSION_MESH_WARNING =
	"Some meshes are drawn as boxes: Roblox only lets plugins read meshes owned by you or this game's owner."
const PERMISSION_TEXTURE_WARNING =
	"Some textures were skipped: Roblox only lets plugins read images owned by you or this game's owner."

export type Payload = {
	name: string,
	parts: { { [string]: any } },
	textures: { [string]: { width: number, height: number, pixels: string } },
}

export type Result = {
	payload: Payload,
	warnings: { string },
}

const SHAPES = {
	[Enum.PartType.Block] = "block",
	[Enum.PartType.Ball] = "ball",
	[Enum.PartType.Cylinder] = "cylinder",
	[Enum.PartType.Wedge] = "wedge",
	[Enum.PartType.CornerWedge] = "cornerWedge",
}

const SPECIAL_SHAPES = {
	[Enum.MeshType.Brick] = "block",
	[Enum.MeshType.Sphere] = "ball",
	[Enum.MeshType.Cylinder] = "cylinder",
	[Enum.MeshType.Wedge] = "wedge",
	[Enum.MeshType.Head] = "ball",
}

const function isRoot(instance: Instance): boolean
	return instance:IsA("Model") or instance:IsA("BasePart") or instance:IsA("Folder") or instance:IsA("Accessory")
end

-- selected instances that can become models, without duplicates nested inside each other.
const function getRoots(selection: { Instance }): { Instance }
	const roots = {}
	const chosen = {}
	for _, instance in selection do
		if isRoot(instance) then
			chosen[instance] = true
		end
	end
	for _, instance in selection do
		if not chosen[instance] then
			continue
		end
		local ancestor = instance.Parent
		local nested = false
		while ancestor do
			if chosen[ancestor] then
				nested = true
				break
			end
			ancestor = ancestor.Parent
		end
		if not nested then
			table.insert(roots, instance)
		end
	end
	return roots
end

const function getParts(root: Instance): { BasePart }
	const parts = {}
	if root:IsA("BasePart") then
		table.insert(parts, root)
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

const function getPivot(root: Instance, parts: { BasePart }): CFrame
	if root:IsA("PVInstance") then
		return (root :: PVInstance):GetPivot()
	end
	return if parts[1] then parts[1].CFrame else CFrame.identity
end

const function toHex(color: Color3): string
	return `#{color:ToHex()}`
end

const function isEmpty(id: string?): boolean
	return id == nil or id == "" or string.match(id, "%d") == nil
end

const function contentOf(instance: Instance, contentProperty: string, idProperty: string): Content?
	const ok, content = pcall(function()
		return (instance :: any)[contentProperty]
	end)
	if ok and typeof(content) == "Content" and content.SourceType ~= Enum.ContentSourceType.None then
		return content
	end
	const idOk, id = pcall(function()
		return (instance :: any)[idProperty]
	end)
	if idOk and type(id) == "string" and not isEmpty(id) then
		return Content.fromUri(id)
	end
	return nil
end

const function contentKey(content: Content): string
	if content.SourceType == Enum.ContentSourceType.Uri then
		return content.Uri :: string
	end
	return tostring(content.Object)
end

const function writeVector(target: buffer, offset: number, value: Vector3)
	buffer.writef32(target, offset, value.X)
	buffer.writef32(target, offset + 4, value.Y)
	buffer.writef32(target, offset + 8, value.Z)
end

-- reads triangle corners from an EditableMesh into base64 float32 buffers.
const function readEditableMesh(mesh: EditableMesh): { [string]: any }
	const faces = mesh:GetFaces()
	const corners = #faces * 3
	const positions = buffer.create(corners * 12)
	const uvs = buffer.create(corners * 8)
	const normals = buffer.create(corners * 12)
	local hasUvs = true
	local hasNormals = true
	for faceIndex, face in faces do
		const vertices = mesh:GetFaceVertices(face)
		const faceUvs = if hasUvs then mesh:GetFaceUVs(face) else {}
		const faceNormals = if hasNormals then mesh:GetFaceNormals(face) else {}
		if #faceUvs < 3 then
			hasUvs = false
		end
		if #faceNormals < 3 then
			hasNormals = false
		end
		for corner = 1, 3 do
			const index = (faceIndex - 1) * 3 + corner - 1
			writeVector(positions, index * 12, mesh:GetPosition(vertices[corner]))
			if hasUvs then
				const uv = mesh:GetUV(faceUvs[corner])
				buffer.writef32(uvs, index * 8, uv.X)
				buffer.writef32(uvs, index * 8 + 4, uv.Y)
			end
			if hasNormals then
				writeVector(normals, index * 12, mesh:GetNormal(faceNormals[corner]) :: Vector3)
			end
		end
		if faceIndex % YIELD_EVERY == 0 then
			task.wait()
		end
	end
	return {
		positions = Base64.encode(positions),
		uvs = if hasUvs then Base64.encode(uvs) else nil,
		normals = if hasNormals then Base64.encode(normals) else nil,
	}
end

const function loadMesh(content: Content?): (EditableMesh?, boolean)
	if content == nil then
		return nil, false
	end
	if content.SourceType == Enum.ContentSourceType.Object then
		const object = content.Object
		if object and object:IsA("EditableMesh") then
			return object :: EditableMesh, false
		end
		return nil, false
	end
	const ok, mesh = pcall(function()
		return AssetService:CreateEditableMeshAsync(content, { FixedSize = true } :: any)
	end)
	return if ok then mesh else nil, ok
end

const function loadImage(content: Content): ({ width: number, height: number, pixels: string }?, string?)
	local image: EditableImage? = nil
	local owned = false
	if content.SourceType == Enum.ContentSourceType.Object then
		const object = content.Object
		if object and object:IsA("EditableImage") then
			image = object :: EditableImage
		end
	else
		const ok, result = pcall(function()
			return AssetService:CreateEditableImageAsync(content)
		end)
		if not ok then
			return nil, if string.find(tostring(result), "permission") then "no permission" else tostring(result)
		end
		image = result
		owned = true
	end
	if image == nil then
		return nil, "unsupported texture"
	end
	const size = image.Size
	const pixels = image:ReadPixelsBuffer(Vector2.zero, size)
	if owned then
		image:Destroy()
	end
	return { width = size.X, height = size.Y, pixels = Base64.encode(pixels) }, nil
end

type Context = {
	textures: { [string]: { width: number, height: number, pixels: string } },
	failedTextures: { [string]: boolean },
	warnings: { string },
}

const function warnOnce(context: Context, message: string)
	if not table.find(context.warnings, message) then
		table.insert(context.warnings, message)
	end
end

const function addTexture(context: Context, content: Content?, mode: string): { id: string, mode: string }?
	if content == nil then
		return nil
	end
	const key = contentKey(content)
	if context.failedTextures[key] then
		return nil
	end
	if context.textures[key] == nil then
		const texture, problem = loadImage(content)
		if texture == nil then
			context.failedTextures[key] = true
			if problem == "no permission" then
				warnOnce(context, PERMISSION_TEXTURE_WARNING)
			else
				warnOnce(context, `Could not load texture {key} ({problem}); using part color`)
			end
			return nil
		end
		context.textures[key] = texture
	end
	return { id = key, mode = mode }
end

const function surfaceTexture(context: Context, part: BasePart): { id: string, mode: string }?
	const appearance = part:FindFirstChildWhichIsA("SurfaceAppearance")
	if appearance then
		const mode = if appearance.AlphaMode == Enum.AlphaMode.Transparency then "alpha" else "overlay"
		return addTexture(context, contentOf(appearance, "ColorMapContent", "ColorMap"), mode)
	end
	return nil
end

const function serializePart(context: Context, part: BasePart, relative: CFrame): { [string]: any }?
	if part.Transparency >= 1 then
		return nil
	end
	const entry: { [string]: any } = {
		cframe = { relative:GetComponents() },
		size = { part.Size.X, part.Size.Y, part.Size.Z },
		color = toHex(part.Color),
		transparency = part.Transparency,
	}

	const specialMesh = part:FindFirstChildWhichIsA("SpecialMesh")
	if part:IsA("MeshPart") then
		const mesh, owned = loadMesh(contentOf(part, "MeshContent", "MeshId"))
		if mesh then
			const data = readEditableMesh(mesh)
			if owned then
				mesh:Destroy()
			end
			const meshSize = part.MeshSize
			data.scale = {
				if meshSize.X > 0 then part.Size.X / meshSize.X else 1,
				if meshSize.Y > 0 then part.Size.Y / meshSize.Y else 1,
				if meshSize.Z > 0 then part.Size.Z / meshSize.Z else 1,
			}
			data.center = true
			entry.kind = "mesh"
			entry.mesh = data
			entry.texture = surfaceTexture(context, part)
				or addTexture(context, contentOf(part, "TextureContent", "TextureID"), "overlay")
		else
			entry.kind = "block"
			entry.warning = PERMISSION_MESH_WARNING
		end
	elseif specialMesh then
		const meshType = specialMesh.MeshType
		const scale = specialMesh.Scale
		if meshType == Enum.MeshType.FileMesh then
			const mesh, owned = loadMesh(contentOf(specialMesh, "MeshContent", "MeshId"))
			if mesh then
				const data = readEditableMesh(mesh)
				if owned then
					mesh:Destroy()
				end
				data.scale = { scale.X, scale.Y, scale.Z }
				data.offset = { specialMesh.Offset.X, specialMesh.Offset.Y, specialMesh.Offset.Z }
				data.center = false
				entry.kind = "mesh"
				entry.mesh = data
				entry.texture = addTexture(context, contentOf(specialMesh, "TextureContent", "TextureId"), "alpha")
			else
				entry.kind = "block"
				entry.warning = PERMISSION_MESH_WARNING
			end
		else
			entry.kind = SPECIAL_SHAPES[meshType] or "block"
			const size = part.Size * scale
			entry.size = { size.X, size.Y, size.Z }
			if specialMesh.Offset ~= Vector3.zero then
				entry.cframe = { (relative * CFrame.new(specialMesh.Offset)):GetComponents() }
			end
		end
	elseif part:IsA("PartOperation") then
		entry.kind = "block"
		entry.warning = "Unions are drawn as boxes: plugins can't read union geometry."
	elseif part:IsA("WedgePart") then
		entry.kind = "wedge"
	elseif part:IsA("CornerWedgePart") then
		entry.kind = "cornerWedge"
	elseif part:IsA("Part") then
		entry.kind = SHAPES[(part :: Part).Shape] or "block"
	else
		entry.kind = "block"
	end

	if entry.warning then
		warnOnce(context, entry.warning)
	end
	return entry
end

const function serialize(root: Instance, onProgress: ((done: number, total: number) -> ())?): Result
	const parts = getParts(root)
	const pivot = getPivot(root, parts)
	const context: Context = { textures = {}, failedTextures = {}, warnings = {} }
	const entries = {}
	for index, part in parts do
		const entry = serializePart(context, part, pivot:ToObjectSpace(part.CFrame))
		if entry then
			table.insert(entries, entry)
		end
		if onProgress then
			onProgress(index, #parts)
		end
	end
	return {
		payload = {
			name = root.Name,
			parts = entries,
			textures = context.textures,
		},
		warnings = context.warnings,
	}
end

return {
	getRoots = getRoots,
	getParts = getParts,
	serialize = serialize,
}
