-- turns selected instances into the backend's scene payload.
-- prefer editable content, then send asset references for backend recovery.
const AssetService = game:GetService("AssetService")
const Base64 = require("./Base64")
const UnionMesh = require("./UnionMesh")
const MarketplaceService = game:GetService("MarketplaceService")
const MaterialService = game:GetService("MaterialService")
const StudioService = game:GetService("StudioService")

const YIELD_EVERY = 3000
const PERMISSION_MESH_WARNING = "Mesh has no readable geometry or downloadable asset ID; using a box"
const PERMISSION_TEXTURE_WARNING = "Texture has no readable pixels or downloadable asset ID; using part color"

export type Payload = {
	warnings: { string }?,
	-- the place shows Roblox's pre-2022 built-in materials.
	legacyMaterials: boolean?,
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
	[Enum.MeshType.Head] = "head",
}

export type MaterialStyle = "auto" | "2022" | "legacy"

local materialStyle: MaterialStyle = "auto"

-- whether built-in materials use their pre-2022 look. Use2022Materials is usually
-- hidden from plugins, so "auto" assumes 2022 materials when it cannot be read.
const function legacyMaterials(): boolean
	if materialStyle ~= "auto" then
		return materialStyle == "legacy"
	end
	const ok, use2022 = pcall(function()
		return (MaterialService :: any).Use2022Materials
	end)
	return ok and use2022 == false
end

const function setMaterialStyle(style: MaterialStyle)
	materialStyle = style
end

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

const function assetId(content: Content?): string?
	if content == nil or content.SourceType ~= Enum.ContentSourceType.Uri then
		return nil
	end
	const uri = content.Uri :: string
	const id = string.match(uri, "^rbxassetid://(%d+)$") or string.match(uri, "[?&][Ii][Dd]=(%d+)")
	return if id and tonumber(id) and tonumber(id) > 0 then id else nil
end

-- Asset ownership and failed editable reads are remembered for this Studio session.
const ownership: { [string]: boolean } = {}
const failedMeshes: { [string]: number } = {}
const failedImages: { [string]: number } = {}
const meshCache: { [string]: { [string]: any } } = {}
const imageCache: { [string]: { width: number, height: number, pixels: string } } = {}
local cachedBytes = 0
const function remember(cache: { [string]: any }, key: string, value: any, bytes: number)
	if bytes > 32 * 1024 * 1024 then
		return
	end
	if cachedBytes + bytes > 64 * 1024 * 1024 then
		table.clear(meshCache)
		table.clear(imageCache)
		cachedBytes = 0
	end
	cache[key] = value
	cachedBytes += bytes
end

const function skipEditable(content: Content): boolean
	const id = assetId(content)
	if not id then
		return false
	end
	if ownership[id] == nil then
		const ok, info = pcall(function()
			return MarketplaceService:GetProductInfoAsync(tonumber(id) :: number, Enum.InfoType.Asset)
		end)
		if not ok or not info.Creator then
			return false -- Unknown ownership still gets a normal editable attempt.
		end
		const creator = info.Creator
		const creatorId = tonumber(creator.CreatorTargetId or creator.CreatorTargetID or creator.Id)
		const userOk, userId = pcall(function()
			return StudioService:GetUserId()
		end)
		ownership[id] = (creator.CreatorType == "User" and userOk and creatorId == userId)
			or (creatorId == game.CreatorId and creator.CreatorType == (if game.CreatorType == Enum.CreatorType.Group then "Group" else "User"))
	end
	return ownership[id] == false
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

const function meshData(content: Content?): { [string]: any }?
	const id = assetId(content)
	if id and meshCache[id] then
		return table.clone(meshCache[id])
	end
	if content and id and ((failedMeshes[id] or 0) > os.clock() or skipEditable(content)) then
		return { assetId = id }
	end
	const mesh, owned = loadMesh(content)
	if mesh then
		const ok, data = pcall(readEditableMesh, mesh)
		if owned then
			mesh:Destroy()
		end
		if ok and data.positions and #data.positions > 0 then
			if id then
				remember(meshCache, id, data, #data.positions + #(data.uvs or "") + #(data.normals or ""))
			end
			return table.clone(data)
		end
	end
	if id then
		failedMeshes[id] = os.clock() + 300
	end
	return if id then { assetId = id } else nil
end

const function loadImage(content: Content): ({ width: number, height: number, pixels: string }?, string?)
	const id = assetId(content)
	if id and imageCache[id] then
		return imageCache[id], nil
	end
	if id and ((failedImages[id] or 0) > os.clock() or skipEditable(content)) then
		return nil, "asset requires backend recovery"
	end
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
			if id then
				failedImages[id] = os.clock() + 300
			end
			return nil, if string.find(tostring(result), "permission") then "no permission" else tostring(result)
		end
		image = result
		owned = true
	end
	if image == nil then
		if id then
			failedImages[id] = os.clock() + 300
		end
		return nil, "unsupported texture"
	end
	const size = image.Size
	const ok, pixels = pcall(function()
		return image:ReadPixelsBuffer(Vector2.zero, size)
	end)
	if owned then
		image:Destroy()
	end
	if not ok then
		if id then
			failedImages[id] = os.clock() + 300
		end
		return nil, tostring(pixels)
	end
	const result = { width = size.X, height = size.Y, pixels = Base64.encode(pixels) }
	if id then
		remember(imageCache, id, result, #result.pixels)
	end
	return result, nil
end

type Context = {
	textures: { [string]: { width: number, height: number, pixels: string } },
	failedTextures: { [string]: boolean },
	warnings: { string },
	-- MaterialVariants in MaterialService, by "<BaseMaterial>/<Name>"; built on first use.
	variants: { [string]: MaterialVariant }?,
}

-- materials that render as a plain color unless a MaterialVariant overrides them.
const PLAIN_MATERIALS = {
	[Enum.Material.Plastic] = true,
	[Enum.Material.SmoothPlastic] = true,
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
	const id = assetId(content)
	if context.failedTextures[key] then
		return if id then { id = key, assetId = id, mode = mode } :: any else nil
	end
	if context.textures[key] == nil then
		const texture, problem = loadImage(content)
		if texture == nil then
			context.failedTextures[key] = true
			if id then
				return { id = key, assetId = id, mode = mode } :: any
			end
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

const LIMBS = {
	Torso = { "torso", "torso" }, UpperTorso = { "torso", "torso" }, LowerTorso = { "torso", "torso" },
	["Right Arm"] = { "right", "arm" }, ["Left Arm"] = { "left", "arm" },
	["Right Leg"] = { "right", "leg" }, ["Left Leg"] = { "left", "leg" },
	RightUpperArm = { "right", "arm" }, RightLowerArm = { "right", "arm" }, RightHand = { "right", "arm" },
	LeftUpperArm = { "left", "arm" }, LeftLowerArm = { "left", "arm" }, LeftHand = { "left", "arm" },
	RightUpperLeg = { "right", "leg" }, RightLowerLeg = { "right", "leg" }, RightFoot = { "right", "leg" },
	LeftUpperLeg = { "left", "leg" }, LeftLowerLeg = { "left", "leg" }, LeftFoot = { "left", "leg" },
}

const function appearanceLayers(context: Context, part: BasePart): { any }
	const layers = {}
	const function add(content: Content?, properties: { [string]: any })
		const texture = addTexture(context, content, "alpha")
		if texture then
			const layer: any = table.clone(texture)
			for key, value in properties do
				layer[key] = value
			end
			table.insert(layers, layer)
		end
	end
	const limb = LIMBS[part.Name]
	const rig = part.Parent
	if limb and rig and rig:FindFirstChildOfClass("Humanoid") then
		local sequence = { part.Name }
		if string.find(part.Name, "Torso") and part.Name ~= "Torso" then
			sequence = { "UpperTorso", "LowerTorso" }
		elseif not string.find(part.Name, " ") and limb[2] ~= "torso" then
			const side = if limb[1] == "right" then "Right" else "Left"
			const kind = if limb[2] == "arm" then "Arm" else "Leg"
			sequence = { side .. "Upper" .. kind, side .. "Lower" .. kind, side .. (if kind == "Arm" then "Hand" else "Foot") }
		end
		local total, before = 0, 0
		local reached = false
		for _, name in sequence do
			const segment = rig:FindFirstChild(name)
			if segment and segment:IsA("BasePart") then
				if segment == part then
					reached = true
				end
				if not reached then
					before += segment.Size.Y
				end
				total += segment.Size.Y
			end
		end
		const range = { before / math.max(total, 0.001), (before + part.Size.Y) / math.max(total, 0.001) }
		const r15 = #sequence > 1
		-- Pants underneath shirts, then T-shirt graphics, as Studio layers them.
		for _, clothing in rig:GetChildren() do
			if clothing:IsA("Pants") and limb[2] ~= "arm" then
				add(contentOf(clothing, "PantsTemplateContent", "PantsTemplate"),
					{ region = limb[1], range = range, r15 = r15, tint = { clothing.Color3.R, clothing.Color3.G, clothing.Color3.B } })
			end
		end
		for _, clothing in rig:GetChildren() do
			if clothing:IsA("Shirt") and limb[2] ~= "leg" then
				add(contentOf(clothing, "ShirtTemplateContent", "ShirtTemplate"),
					{ region = limb[1], range = range, r15 = r15, tint = { clothing.Color3.R, clothing.Color3.G, clothing.Color3.B } })
			end
		end
		for _, clothing in rig:GetChildren() do
			if clothing:IsA("ShirtGraphic") and limb[2] == "torso" then
				add(contentOf(clothing, "GraphicContent", "Graphic"), { face = "Front", range = range, r15 = r15,
					tint = { clothing.Color3.R, clothing.Color3.G, clothing.Color3.B }, graphic = true })
			end
		end
	end
	local decals = {}
	for _, child in part:GetChildren() do
		if child:IsA("Decal") and child.Transparency < 1 then
			table.insert(decals, child)
		end
	end
	table.sort(decals, function(a, b)
		return a.ZIndex < b.ZIndex
	end)
	for _, decal in decals do
		const properties: { [string]: any } = { face = decal.Face.Name, transparency = decal.Transparency,
			tint = { decal.Color3.R, decal.Color3.G, decal.Color3.B } }
		if decal:IsA("Texture") then
			properties["repeat"] = { decal.StudsPerTileU, decal.StudsPerTileV }
			properties.offset = { decal.OffsetStudsU, decal.OffsetStudsV }
		end
		add(contentOf(decal, "ColorMapContent", "Texture") or contentOf(decal, "TextureContent", "Texture"), properties)
	end
	return layers
end

const function findVariant(context: Context, part: BasePart): MaterialVariant?
	local name = part.MaterialVariant
	if name == "" then
		-- MaterialService can replace a base material everywhere.
		const ok, override = pcall(function()
			return MaterialService:GetBaseMaterialOverride(part.Material)
		end)
		name = if ok and type(override) == "string" then override else ""
	end
	if name == "" then
		return nil
	end
	if context.variants == nil then
		const variants = {}
		for _, descendant in MaterialService:GetDescendants() do
			if descendant:IsA("MaterialVariant") then
				variants[`{descendant.BaseMaterial.Name}/{descendant.Name}`] = descendant
			end
		end
		context.variants = variants
	end
	return (context.variants :: any)[`{part.Material.Name}/{name}`]
end

-- the part's material: a MaterialVariant's ColorMap, or the built-in material name.
const function materialOf(context: Context, part: BasePart): { [string]: any }?
	const variant = findVariant(context, part)
	if variant == nil and PLAIN_MATERIALS[part.Material] then
		return nil
	end
	const material: { [string]: any } = { name = part.Material.Name }
	if variant then
		material.variant = variant.Name
		material.studsPerTile = variant.StudsPerTile
		material.texture = addTexture(context, contentOf(variant, "ColorMapContent", "ColorMap"), "overlay")
	end
	return material
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
		const data = meshData(contentOf(part, "MeshContent", "MeshId"))
		if data then
			const meshSize = part.MeshSize
			data.scale = {
				if meshSize.X > 0 then part.Size.X / meshSize.X else 1,
				if meshSize.Y > 0 then part.Size.Y / meshSize.Y else 1,
				if meshSize.Z > 0 then part.Size.Z / meshSize.Z else 1,
			}
			data.center = true
			entry.kind = "mesh"
			entry.mesh = data
		else
			entry.kind = "block"
			entry.warning = PERMISSION_MESH_WARNING
		end
		entry.texture = surfaceTexture(context, part)
			or addTexture(context, contentOf(part, "TextureContent", "TextureID"), "overlay")
	elseif specialMesh then
		const meshType = specialMesh.MeshType
		const scale = specialMesh.Scale
		if meshType == Enum.MeshType.FileMesh then
			const data = meshData(contentOf(specialMesh, "MeshContent", "MeshId"))
			if data then
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
			local size = part.Size * scale
			if meshType == Enum.MeshType.Head then
				-- Head constrains X/Z together and compensates for its built-in 1.25 scale.
				const xz = math.min(size.X, size.Z) / 1.25
				size = Vector3.new(xz, size.Y / 1.25, xz)
			end
			entry.size = { size.X, size.Y, size.Z }
			if specialMesh.Offset ~= Vector3.zero then
				entry.cframe = { (relative * CFrame.new(specialMesh.Offset)):GetComponents() }
			end
		end
	elseif part:IsA("PartOperation") then
		const data, cframe, problem = UnionMesh.read(part :: PartOperation)
		if data and cframe then
			entry.kind = "mesh"
			entry.mesh = data
			entry.cframe = { (relative * part.CFrame:ToObjectSpace(cframe)):GetComponents() }
		else
			entry.kind = "block"
			entry.warning = `Could not read union geometry ({problem}); using a box`
		end
	elseif part:IsA("WedgePart") then
		entry.kind = "wedge"
	elseif part:IsA("CornerWedgePart") then
		entry.kind = "cornerWedge"
	elseif part:IsA("Part") then
		entry.kind = SHAPES[(part :: Part).Shape] or "block"
	else
		entry.kind = "block"
	end

	-- TextureIDs and SurfaceAppearances replace the material's color.
	if entry.texture == nil then
		entry.material = materialOf(context, part)
	end
	entry.layers = appearanceLayers(context, part)
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
			legacyMaterials = legacyMaterials(),
		},
		warnings = context.warnings,
	}
end

return {
	getRoots = getRoots,
	getParts = getParts,
	serialize = serialize,
	legacyMaterials = legacyMaterials,
	setMaterialStyle = setMaterialStyle,
}
