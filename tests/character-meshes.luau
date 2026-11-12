local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local plastic = { Name = "Plastic" }
local children = {}
local humanoid = { RigType = "R6" }
local rig = {
	GetChildren = function() return children end,
	FindFirstChildOfClass = function(_, class) return if class == "Humanoid" then humanoid else nil end,
	FindFirstChild = function() return nil end,
}
local part = {
	Name = "Left Arm", Parent = rig, Transparency = 0, Color = roblox.Color3.new(1, 1, 1),
	Material = plastic, MaterialVariant = "", Size = roblox.Vector3.new(2, 6, 4),
	CFrame = roblox.CFrame.identity, Shape = "Block",
	IsA = function(_, class) return class == "Part" or class == "BasePart" or class == "PVInstance" end,
	GetDescendants = function() return {} end, GetChildren = function() return {} end,
	FindFirstChildWhichIsA = function() return nil end,
	GetPivot = function() return roblox.CFrame.identity end,
}
local body = {
	BodyPart = { Name = "LeftArm" }, MeshId = 123, BaseTextureId = 456, OverlayTextureId = 789,
	IsA = function(_, class) return class == "CharacterMesh" end,
}
local shirt = {
	ShirtTemplate = "rbxassetid://1000", Color3 = roblox.Color3.new(1, 1, 1),
	IsA = function(_, class) return class == "Shirt" end,
}
children = { body, shirt }
local services = {
	MarketplaceService = { GetProductInfoAsync = function() return { Creator = { CreatorType = "User", Id = 99 } } end },
	StudioService = { GetUserId = function() return 42 end },
	AssetService = {}, MaterialService = {},
}
local code = fs.readFile("src/Serializer.luau"):gsub("%f[%w]const%f[%W]", "local")
local serializer = luau.load(code, { environment = {
	require = function() return {} end,
	game = { GetService = function(_, name) return services[name] end, CreatorId = 10, CreatorType = "User" },
	Content = { fromUri = function(uri) return { SourceType = "Uri", Uri = uri } end },
	typeof = function(value) return if type(value) == "table" and value.SourceType then "Content" else typeof(value) end,
	Enum = {
		ContentSourceType = { Uri = "Uri", None = "None", Object = "Object" },
		HumanoidRigType = { R6 = "R6" },
		InfoType = { Asset = "Asset" }, CreatorType = { Group = "Group" },
		Material = { Plastic = plastic, SmoothPlastic = {} },
		PartType = { Block = "Block", Ball = "Ball", Cylinder = "Cylinder", Wedge = "Wedge", CornerWedge = "CornerWedge" },
		MeshType = { Brick = "Brick", Sphere = "Sphere", Cylinder = "Cylinder", Wedge = "Wedge", Head = "Head" },
	},
	Vector3 = roblox.Vector3, CFrame = roblox.CFrame,
} })()
local result = serializer.serialize(part)
local entry = result.payload.parts[1]
assert(entry.kind == "mesh" and entry.mesh.assetId == "123", "Numeric CharacterMesh IDs must reach backend recovery")
assert(entry.mesh.scale[1] == 2 and entry.mesh.scale[2] == 3 and entry.mesh.scale[3] == 4)
assert(entry.mesh.center == false, "Body geometry must keep its authored origin")
assert(entry.texture.assetId == "456" and entry.texture.mode == "overlay")
assert(#entry.layers == 2 and entry.layers[1].assetId == "1000")
assert(entry.layers[2].assetId == "789" and entry.layers[2].nativeUv, "Overlay must cover clothing using mesh UVs")
assert(#result.warnings == 0)
for name, bodyPart in { Torso = "Torso", ["Right Arm"] = "RightArm", ["Left Leg"] = "LeftLeg", ["Right Leg"] = "RightLeg", Head = "Head" } do
	part.Name = name
	body.BodyPart.Name = bodyPart
	assert(serializer.serialize(part).payload.parts[1].kind == "mesh", name)
end
part.Name = "Left Arm"
assert(serializer.serialize(part).payload.parts[1].kind == "block", "Unmatched body parts keep their own geometry")
body.BodyPart.Name = "LeftArm"
body.BaseTextureId, body.OverlayTextureId = 0, 0
entry = serializer.serialize(part).payload.parts[1]
assert(entry.texture == nil and #entry.layers == 1, "Zero texture IDs must not create asset requests")
body.MeshContent = { SourceType = "Uri", Uri = "rbxassetid://321" }
assert(serializer.serialize(part).payload.parts[1].mesh.assetId == "321", "Modern Content takes priority over legacy IDs")
humanoid.RigType = "R15"
assert(serializer.serialize(part).payload.parts[1].kind == "block", "R15 rigs ignore CharacterMesh")
humanoid = nil
assert(serializer.serialize(part).payload.parts[1].kind == "block", "CharacterMesh only applies to character rigs")
print("R6 CharacterMesh geometry, scaling, numeric IDs and texture ordering checks passed")
