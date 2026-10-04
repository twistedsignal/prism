-- Run with: lune run tests/path-glob.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local code = fs.readFile("src/PathGlob.luau"):gsub("%f[%w]const%f[%W]", "local")
local PathGlob = luau.load(code)()

local function node(name, className, list)
	local instance = { Name = name, ClassName = className, children = list or {} }
	function instance.GetChildren(self)
		if self.locked then
			error("The current thread cannot access this service")
		end
		return table.clone(self.children)
	end
	for _, child in instance.children do
		child.Parent = instance
	end
	return instance
end

local sword = node("Sword", "Model", { node("Handle", "Part") })
local shield = node("Shield", "Model", { node("Handle", "Part") })
local crate = node("Crate", "Model")
local slash = node("A/B", "Model")
local locked = node("CoreSecrets", "Folder")
locked.locked = true
local game = node("Game", "DataModel", {
	node("ReplicatedStorage", "ReplicatedStorage", {
		node("Content", "Folder", {
			node("Weapons", "Folder", { sword, shield }),
			node("Props", "Folder", { node("Boxes", "Folder", { crate }) }),
			slash,
		}),
	}),
	node("Workspace", "Workspace", { node("Model", "Model") }),
	locked,
})

local function names(list)
	local result = {}
	for _, instance in list do
		table.insert(result, instance.Name)
	end
	return table.concat(result, ",")
end

local function check(pattern, expected, message)
	local found = PathGlob.match(game, pattern)
	assert(names(found) == expected, `{message}: {pattern} -> {names(found)}`)
end

check("ReplicatedStorage/Content/Weapons/*", "Sword,Shield", "A star matches every child")
check("replicatedstorage/content/weapons/SWORD", "Sword", "Matching ignores case")
check("game/ReplicatedStorage/Content/Weapons/Sword", "Sword", "A leading game names the DataModel")
check("ReplicatedStorage/Content/**/Handle", "Handle,Handle", "Globstar spans several levels")
check("ReplicatedStorage/Content/**/**/Crate", "Crate", "Repeated globstars visit each instance once")
check("ReplicatedStorage/**", "Content,Weapons,Sword,Handle,Shield,Handle,Props,Boxes,Crate,A/B",
	"A trailing globstar lists descendants in tree order")
check("ReplicatedStorage/Content/Weapons/S?ord", "Sword", "A question mark matches one character")
check("ReplicatedStorage/Content/Weapons/[!s]*", "", "Negated classes exclude names")
check("ReplicatedStorage/Content/Weapons/S[a-i]*", "Shield", "Character ranges match")
check("ReplicatedStorage/Content/{Weapons,Props}/{B,Sh}*", "Shield,Boxes", "Braces expand within names")
check("ReplicatedStorage/Content/Weapons/{Sword,Shield}", "Sword,Shield", "Braces list alternatives")
check("ReplicatedStorage/Content/A\\/B", "A/B", "Escaped slashes match literal names")
check("ReplicatedStorage/Content/Weapons/Sw.rd", "", "Lua pattern characters are literal")
check("**/CoreSecrets/*", "", "Services that refuse access are skipped")
check("", "", "An empty pattern matches nothing")
check("Workspace/", "Workspace", "A trailing slash is ignored")

local limited, truncated = PathGlob.match(game, "**/Handle", { limit = 1 })
assert(#limited == 1 and truncated, "Limits stop early and report truncation")
local models = PathGlob.match(game, "**", { filter = function(instance) return instance.ClassName == "Model" end })
assert(names(models) == "Sword,Shield,Crate,A/B,Model", "Filters keep only accepted instances")
local yields = 0
assert(PathGlob.match(game, "**", { yield = function() yields += 1 return false end }) ~= nil,
	"Small searches finish before the first yield")
assert(PathGlob.pathOf(slash, game) == "ReplicatedStorage/Content/A\\/B", "Paths escape special names")
assert(PathGlob.match(game, PathGlob.pathOf(slash, game))[1] == slash, "Escaped paths round-trip")

local function labels(completion)
	local result = {}
	for _, item in completion.items do
		table.insert(result, item.name)
	end
	return table.concat(result, ",")
end

local root = PathGlob.complete(game, "")
assert(labels(root) == "CoreSecrets,ReplicatedStorage,Workspace,**", labels(root))
local typed = PathGlob.complete(game, "rep")
assert(labels(typed) == "ReplicatedStorage", "Prefixes filter services")
assert(typed.ghost == "licatedStorage/", `Ghost text completes the first match: {typed.ghost}`)
assert(typed.items[1].insert == "ReplicatedStorage/", "Containers complete with a slash")
local nested = PathGlob.complete(game, "ReplicatedStorage/Content/Weapons/s")
assert(labels(nested) == "Shield,Sword", labels(nested))
assert(nested.items[1].insert == "ReplicatedStorage/Content/Weapons/Shield/", nested.items[1].insert)
assert(nested.ghost == "hield/", nested.ghost)
local deep = PathGlob.complete(game, "ReplicatedStorage/**/Ha")
assert(labels(deep) == "Handle" and deep.items[1].count == 2, "Globstar parents merge duplicate names")
assert(deep.items[1].insert == "ReplicatedStorage/**/Handle", "Leaves complete without a slash")
local inner = PathGlob.complete(game, "ReplicatedStorage/Content/Weapons/ie")
assert(labels(inner) == "Shield" and inner.ghost == "", "Substring matches suggest without ghost text")
local star = PathGlob.complete(game, "ReplicatedStorage/Content/*")
assert(star.items[1].name == "**" and star.ghost == "*/", "A typed star offers the globstar first")
local globbed = PathGlob.complete(game, "ReplicatedStorage/Content/Weapons/*d")
assert(labels(globbed) == "Shield,Sword", "Glob partials filter suggestions")
local escaped = PathGlob.complete(game, "ReplicatedStorage/Content/A")
assert(escaped.items[1].insert == "ReplicatedStorage/Content/A\\/B", "Suggestions escape special names")
assert(#PathGlob.complete(game, "Nowhere/").items == 0, "Missing parents have no suggestions")

print("Path glob checks passed")
