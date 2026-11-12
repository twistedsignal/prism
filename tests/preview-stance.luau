local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local code = fs.readFile("src/components/Preview.luau")
local first = assert(code:find("const function Viewport", 1, true))
local frame = luau.load(code:sub(1, first - 1):gsub("%f[%w]const%f[%W]", "local") .. "\nreturn frame", { environment = {
	require = function() return {} end, Vector3 = roblox.Vector3, CFrame = roblox.CFrame,
} })()
for _, class in { "Folder", "Tool", "Accessory" } do
	local pivot = roblox.CFrame.new(10, 4, -2) * roblox.CFrame.Angles(0, 0.4, 0)
	local parts = {}
	for index = 1, 2 do
		parts[index] = {
			CFrame = pivot * roblox.CFrame.new(index - 1, 0, 0), Size = roblox.Vector3.one, Transparency = 0,
			IsA = function(_, name) return name == "BasePart" end,
		}
	end
	local root = { ClassName = class, IsA = function() return false end, GetDescendants = function() return parts end }
	local settings = { pitch = 20, yaw = 90, roll = 15 }
	local stance = frame(root, {}, settings)
	local expected = roblox.CFrame.fromOrientation(math.rad(20), math.rad(90), math.rad(15))
	assert(parts[1].CFrame:FuzzyEq(expected, 1e-5), class)
	assert(parts[2].CFrame:FuzzyEq(expected * roblox.CFrame.new(1, 0, 0), 1e-5), class)
	frame(root, {}, settings, stance)
	assert(parts[1].CFrame:FuzzyEq(expected, 1e-5), "Repeated camera updates must not accumulate stance")
end
print("Folder, Tool and Accessory preview stance and pivot checks passed")
