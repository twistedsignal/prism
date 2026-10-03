local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local effects, cleanup = {}, {}
local vide = {
    effect = function(fn) table.insert(effects, fn) end,
    cleanup = function(item) table.insert(cleanup, item) end,
    create = function() return function(props) return props end end,
}
local modules = setmetatable({ ['../vide'] = vide }, { __index = function() return {} end })
local code = fs.readFile("src/components/Preview.luau"):gsub("%f[%w]const%f[%W]", "local")
    :gsub("return Preview%s*$", "return Viewport")
local viewport = luau.load(code, { environment = {
    require = function(path) return modules[path] end,
    Vector2 = roblox.Vector2, Vector3 = roblox.Vector3, UDim2 = roblox.UDim2,
    CFrame = roblox.CFrame, Color3 = roblox.Color3,
} })()
local copies = {}
local root = { Archivable = false, Shape = "Block" }
root.Clone = function()
    assert(root.Archivable, "Preview may clone non-archivable selections")
    local copy = {
        Shape = root.Shape, GetDescendants = function() return {} end,
        IsA = function() return false end,
        Destroy = function(self) self.destroyed = true end,
    }
    table.insert(copies, copy)
    return copy
end
local version = 0
local settings = { zoom = 1 }
local selected = { instance = root, settings = function() return settings end, visualVersion = function() return version end }
viewport({ currentModel = function() return selected end })
local function refresh()
    for _, fn in effects do fn() end
end
refresh()
assert(#copies == 1 and copies[1].Shape == "Block" and not root.Archivable)
settings.zoom = 2
refresh()
assert(#copies == 1, "Camera settings must reuse the same clone")
root.Shape = "Ball"
version += 1
refresh()
assert(#copies == 2 and copies[1].destroyed and copies[2].Shape == "Ball", "Visual revisions must refresh the clone of the same selected Part")
assert(not root.Archivable, "Cloning must restore the original Archivable property")
selected = nil
refresh()
assert(copies[2].destroyed, "Deselecting destroys the preview clone")
print("Viewport visual revision, clone replacement and camera reuse checks passed")
