local fs = require('@lune/fs')
local luau = require('@lune/luau')
local roblox = require('@lune/roblox')
local editableCalls, metadataCalls = 0, 0
local services = {
    AssetService = {
        CreateEditableMeshAsync = function() editableCalls += 1; error('Unavailable') end,
        CreateEditableImageAsync = function() editableCalls += 1; error('Unavailable') end,
    },
    MarketplaceService = { GetProductInfoAsync = function(_, id)
        metadataCalls += 1
        return { Creator = { CreatorType = 'User', CreatorTargetId = if id == 123 then 99 else 42 } }
    end },
    StudioService = { GetUserId = function() return 42 end },
}
local material = function(name) return { Name = name } end
local Materials = { Plastic = material('Plastic'), SmoothPlastic = material('SmoothPlastic'),
    Wood = material('Wood'), Brick = material('Brick') }
local variants, overrides = {}, {}
services.MaterialService = {
    GetDescendants = function() return variants end,
    GetBaseMaterialOverride = function(_, base) return overrides[base.Name] or '' end,
}
local content = function(id) return { SourceType = 'Uri', Uri = 'rbxassetid://' .. tostring(id) } end
local part = {
    Name = 'Handle', Transparency = 0, Color = roblox.Color3.new(1, 1, 1),
    Material = Materials.Plastic, MaterialVariant = '',
    Size = roblox.Vector3.one, MeshSize = roblox.Vector3.one, CFrame = roblox.CFrame.identity,
    MeshContent = content(123), TextureContent = content(123),
    IsA = function(_, class) return class == 'BasePart' or class == 'MeshPart' or class == 'PVInstance' end,
    GetDescendants = function() return {} end, GetChildren = function() return {} end,
    FindFirstChildWhichIsA = function() return nil end,
    GetPivot = function() return roblox.CFrame.identity end,
}
local alphaModes = {
	Transparency = { Name = "Transparency" }, Overlay = { Name = "Overlay" }, TintMask = { Name = "TintMask" },
}
local code = fs.readFile('src/Serializer.luau'):gsub('%f[%w]const%f[%W]', 'local')
local serializer = luau.load(code, { environment = {
    require = function() return {} end,
    game = { GetService = function(_, name) return services[name] end, CreatorId = 10, CreatorType = 'User' },
    typeof = function(value) return if type(value) == 'table' and value.SourceType then 'Content' else typeof(value) end,
    Enum = { AlphaMode = alphaModes, ContentSourceType = { Uri = 'Uri', None = 'None', Object = 'Object' },
        InfoType = { Asset = 'Asset' }, CreatorType = { Group = 'Group' }, Material = Materials,
        PartType = { Block = 'Block', Ball = 'Ball', Cylinder = 'Cylinder', Wedge = 'Wedge', CornerWedge = 'CornerWedge' },
        MeshType = { FileMesh = 'FileMesh', Brick = 'Brick', Sphere = 'Sphere', Cylinder = 'Cylinder', Wedge = 'Wedge', Head = 'Head' } },
    Vector3 = roblox.Vector3, CFrame = roblox.CFrame,
} })()
local result = serializer.serialize(part)
assert(result.payload.parts[1].mesh.assetId == '123')
assert(result.payload.parts[1].texture.assetId == '123')
assert(editableCalls == 0 and metadataCalls == 1, 'Foreign ownership must bypass editable reads')
serializer.serialize(part)
assert(editableCalls == 0 and metadataCalls == 1, 'Known ownership must be reused')
part.MeshContent = content(456)
part.TextureContent = content(456)
serializer.serialize(part)
assert(editableCalls == 2, 'Owned assets must still try both editable APIs')
serializer.serialize(part)
assert(editableCalls == 2, 'Failed editable reads must be remembered')
print('Ownership routing and failed-read cache checks passed')

-- Built-in Head meshes must retain their own geometry, scale and offset.
local specialMesh = {
    MeshType = 'Head', Scale = roblox.Vector3.new(1.25, 2, 0.75),
    Offset = roblox.Vector3.new(0.25, 0.5, -0.25),
}
part.Name = 'Head'
part.Size = roblox.Vector3.new(2, 1, 1)
part.IsA = function(_, class) return class == 'BasePart' or class == 'Part' or class == 'PVInstance' end
part.FindFirstChildWhichIsA = function(_, class) return if class == 'SpecialMesh' then specialMesh else nil end
local head = serializer.serialize(part).payload.parts[1]
assert(head.kind == 'head', 'MeshType.Head must never become a sphere')
assert(math.abs(head.size[1] - 0.6) < 1e-6 and math.abs(head.size[2] - 1.6) < 1e-6)
assert(head.size[1] == head.size[3])
assert(head.cframe[1] == 0.25 and head.cframe[2] == 0.5 and head.cframe[3] == -0.25)
specialMesh.Scale = roblox.Vector3.new(1.25, 1.25, 1.25)
local classic = serializer.serialize(part).payload.parts[1]
assert(classic.size[1] == 1 and classic.size[2] == 1 and classic.size[3] == 1)
part.Size = roblox.Vector3.new(0.8, 0.4, 0.4)
local small = serializer.serialize(part).payload.parts[1]
assert(math.abs(small.size[1] - 0.4) < 1e-6 and math.abs(small.size[2] - 0.4) < 1e-6)
assert(small.size[1] == small.size[3], 'Head width and depth must stay constrained')
specialMesh.MeshType = 'Sphere'
assert(serializer.serialize(part).payload.parts[1].kind == 'ball')
part.FindFirstChildWhichIsA = function() return nil end
part.Shape = 'Block'
assert(serializer.serialize(part).payload.parts[1].kind == 'block', 'A part named Head must retain its actual shape')
print('Built-in head shape, scale and offset checks passed')

-- Built-in materials are sent by name; MaterialVariants send their ColorMap and tiling.
part.MeshContent, part.TextureContent = nil, nil
assert(serializer.serialize(part).payload.parts[1].material == nil, 'Plastic must stay a plain color')
part.Material = Materials.Wood
local wood = serializer.serialize(part).payload.parts[1]
assert(wood.material.name == 'Wood' and wood.material.texture == nil)
table.insert(variants, {
    Name = 'Oak', BaseMaterial = Materials.Wood, StudsPerTile = 6, ColorMapContent = content(789),
    IsA = function(_, class) return class == 'MaterialVariant' end,
})
part.MaterialVariant = 'Oak'
local oak = serializer.serialize(part).payload.parts[1]
assert(oak.material.variant == 'Oak' and oak.material.studsPerTile == 6)
assert(oak.material.texture.assetId == '789', 'Variant ColorMaps must reach the backend')
part.MaterialVariant = ''
overrides.Wood = 'Oak'
assert(serializer.serialize(part).payload.parts[1].material.variant == 'Oak', 'Base material overrides apply')
part.Material = Materials.Brick
assert(serializer.serialize(part).payload.parts[1].material.variant == nil, 'Variants only match their base material')
-- Use2022Materials is hidden from plugins in Studio; an explicit style takes over then.
setmetatable(services.MaterialService, { __index = function(_, key)
    if key == 'Use2022Materials' then error('lacking capability RobloxScript') end
end })
assert(serializer.serialize(part).payload.legacyMaterials == false, 'Unreadable places assume 2022 materials')
serializer.setMaterialStyle('legacy')
assert(serializer.serialize(part).payload.legacyMaterials == true, 'The legacy style marks the payload')
setmetatable(services.MaterialService, nil)
services.MaterialService.Use2022Materials = false
serializer.setMaterialStyle('2022')
assert(serializer.serialize(part).payload.legacyMaterials == false, 'An explicit 2022 style wins over the place')
serializer.setMaterialStyle('auto')
assert(serializer.serialize(part).payload.legacyMaterials == true, 'Automatic follows a readable Use2022Materials')
services.MaterialService.Use2022Materials = nil
print('Material and MaterialVariant serialization checks passed')

part.Material = Materials.Plastic
for _, face in {'Right', 'Left', 'Top', 'Bottom', 'Back', 'Front'} do
    part[face .. 'Surface'] = {Name = 'Studs'}
end
local surfaces = serializer.serialize(part).payload.parts[1].surfaces
for _, face in {'Right', 'Left', 'Top', 'Bottom', 'Back', 'Front'} do
    assert(surfaces[face] == 'Studs', face .. 'Surface must reach the renderer')
end
for _, name in {'Smooth', 'Glue', 'Weld', 'Studs', 'Inlet', 'Universal', 'Hinge', 'Motor', 'SteppingMotor', 'SmoothNoOutlines'} do
    part.TopSurface = {Name = name}
    local top = serializer.serialize(part).payload.parts[1].surfaces.Top
    assert(top == (if name == 'Smooth' or name == 'SmoothNoOutlines' then nil else name))
end
part.Material = Materials.SmoothPlastic
part.TopSurface = {Name = 'Studs'}
assert(serializer.serialize(part).payload.parts[1].surfaces == nil, 'SmoothPlastic hides surface textures')
part.TopSurface = {Name = 'Motor'}
assert(serializer.serialize(part).payload.parts[1].surfaces.Top == 'Motor', 'Pins are visible on other materials')
part.Material = Materials.Plastic
part.TopSurface = {Name = 'Studs'}
table.insert(variants, {Name = 'CustomPlastic', BaseMaterial = Materials.Plastic,
    StudsPerTile = 2, IsA = function(_, class) return class == 'MaterialVariant' end})
overrides.Plastic = 'CustomPlastic'
assert(serializer.serialize(part).payload.parts[1].surfaces == nil, 'Plastic overrides replace the stud detail')
overrides.Plastic = nil
part.IsA = function(_, class) return class == 'BasePart' or class == 'MeshPart' or class == 'PVInstance' end
part.MeshContent = content(123)
assert(serializer.serialize(part).payload.parts[1].surfaces == nil, 'MeshParts do not draw legacy surfaces')
print('All face surface types, material visibility and pin serialization checks passed')

local appearance = { ColorMapContent = content(456), Color = roblox.Color3.new(1, 0.5, 0) }
part.FindFirstChildWhichIsA = function(_, class) return if class == "SurfaceAppearance" then appearance else nil end
for mode, expected in { Transparency = "alpha", Overlay = "overlay", TintMask = "tintMask" } do
	appearance.AlphaMode = alphaModes[mode]
	local entry = serializer.serialize(part).payload.parts[1]
	assert(entry.texture.mode == expected)
	assert(entry.texture.tint[1] == 1 and entry.texture.tint[2] == 0.5 and entry.texture.tint[3] == 0)
end
local fileMesh = {
	MeshType = "FileMesh", MeshContent = content(123), TextureContent = content(456),
	Scale = roblox.Vector3.one, Offset = roblox.Vector3.zero, VertexColor = roblox.Vector3.new(1, 0.5, 0),
}
part.IsA = function(_, class) return class == "Part" or class == "BasePart" or class == "PVInstance" end
part.FindFirstChildWhichIsA = function(_, class) return if class == "SpecialMesh" then fileMesh else nil end
local tinted = serializer.serialize(part).payload.parts[1]
assert(tinted.texture.mode == "alpha" and tinted.texture.tint[2] == 0.5 and tinted.texture.tint[3] == 0)
print("SurfaceAppearance tint, TintMask and SpecialMesh VertexColor serialization checks passed")
