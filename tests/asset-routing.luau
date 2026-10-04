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
local code = fs.readFile('src/Serializer.luau'):gsub('%f[%w]const%f[%W]', 'local')
local serializer = luau.load(code, { environment = {
    require = function() return {} end,
    game = { GetService = function(_, name) return services[name] end, CreatorId = 10, CreatorType = 'User' },
    typeof = function(value) return if type(value) == 'table' and value.SourceType then 'Content' else typeof(value) end,
    Enum = { ContentSourceType = { Uri = 'Uri', None = 'None', Object = 'Object' },
        InfoType = { Asset = 'Asset' }, CreatorType = { Group = 'Group' }, Material = Materials,
        PartType = { Block = 'Block', Ball = 'Ball', Cylinder = 'Cylinder', Wedge = 'Wedge', CornerWedge = 'CornerWedge' },
        MeshType = { Brick = 'Brick', Sphere = 'Sphere', Cylinder = 'Cylinder', Wedge = 'Wedge', Head = 'Head' } },
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
