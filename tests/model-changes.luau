local fs = require("@lune/fs")
local luau = require("@lune/luau")
local code = fs.readFile("src/ModelChanges.luau"):gsub("%f[%w]const%f[%W]", "local")
local changes = luau.load(code)()
local function signal()
    local handlers = {}
    return {
        Connect = function(_, fn)
            handlers[fn] = true
            return { Disconnect = function() handlers[fn] = nil end }
        end,
        fire = function(...)
            for fn in handlers do fn(...) end
        end,
        count = function()
            local n = 0
            for _ in handlers do n += 1 end
            return n
        end,
    }
end
local function instance(classes)
    return {
        Changed = signal(), DescendantAdded = signal(), DescendantRemoving = signal(),
        IsA = function(_, class) return table.find(classes, class) ~= nil end,
        GetDescendants = function() return {} end,
    }
end
local root = instance({"Model"})
local part = instance({"Part", "BasePart"})
local mesh = instance({"SpecialMesh", "DataModelMesh"})
local texture = instance({"Texture", "Decal"})
local shirt = instance({"Shirt"})
root.GetDescendants = function() return {part, mesh, texture, shirt} end
local edits = 0
local stop = changes.watch(root, function() edits += 1 end)
part.Changed.fire("Shape")
part.Changed.fire("Color")
part.Changed.fire("CFrame")
mesh.Changed.fire("Scale")
texture.Changed.fire("Texture")
shirt.Changed.fire("ShirtTemplate")
assert(edits == 6, "Geometry, transform and appearance edits must refresh")
part.Changed.fire("Anchored")
part.Changed.fire("Archivable")
part.Changed.fire("AssemblyLinearVelocity")
assert(edits == 6, "Physics and cloning metadata must not refresh")
local added = instance({"MeshPart", "BasePart"})
root.DescendantAdded.fire(added)
added.Changed.fire("MeshContent")
assert(edits == 8, "New descendants must be watched")
root.DescendantRemoving.fire(added)
added.Changed.fire("Size")
assert(edits == 9 and added.Changed.count() == 0, "Removed descendants disconnect")
root.Changed.fire("WorldPivot")
assert(edits == 10, "Pivot changes affect the serialized scene")
stop()
part.Changed.fire("Shape")
root.DescendantAdded.fire(added)
assert(edits == 10 and part.Changed.count() == 0 and root.DescendantAdded.count() == 0)
local materialService = instance({"MaterialService"})
local variant = instance({"MaterialVariant"})
materialService.GetDescendants = function() return {variant} end
local stopMaterials = changes.watch(materialService, function() edits += 1 end)
variant.Changed.fire("ColorMap")
materialService.Changed.fire("PlasticName")
assert(edits == 12, "Shared material variants and overrides must refresh")
stopMaterials()
print("Model visual property, descendant, material and watcher cleanup checks passed")
