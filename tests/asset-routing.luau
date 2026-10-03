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
local content = function(id) return { SourceType = 'Uri', Uri = 'rbxassetid://' .. tostring(id) } end
local part = {
    Name = 'Handle', Transparency = 0, Color = roblox.Color3.new(1, 1, 1),
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
        InfoType = { Asset = 'Asset' }, CreatorType = { Group = 'Group' },
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
assert(head.size[1] == 1.25 and head.size[2] == 2 and head.size[3] == 0.75)
assert(head.cframe[1] == 0.25 and head.cframe[2] == 0.5 and head.cframe[3] == -0.25)
specialMesh.MeshType = 'Sphere'
assert(serializer.serialize(part).payload.parts[1].kind == 'ball')
part.FindFirstChildWhichIsA = function() return nil end
part.Shape = 'Block'
assert(serializer.serialize(part).payload.parts[1].kind == 'block', 'A part named Head must retain its actual shape')
print('Built-in head shape, scale and offset checks passed')
