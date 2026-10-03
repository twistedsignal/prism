-- Run with: lune run tests/model-cards.luau
-- Exercise the real page/card binding with Vide's actual collection lifecycle.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local source = require("../Packages/_Index/centau_vide@0.4.1/vide/src/source")
local root = require("../Packages/_Index/centau_vide@0.4.1/vide/src/root")
local cards
local vide = {
	source = source,
	values = require("../Packages/_Index/centau_vide@0.4.1/vide/src/values"),
	indexes = require("../Packages/_Index/centau_vide@0.4.1/vide/src/indexes"),
	effect = require("../Packages/_Index/centau_vide@0.4.1/vide/src/effect"),
	cleanup = function() end,
	changed = function() return {} end,
	show = function() return {} end,
	create = function()
		return function(properties)
			if properties.Name == "Cards" then cards = properties end
			return properties
		end
	end,
}
local enums = setmetatable({}, { __index = function(_, category)
	return setmetatable({}, { __index = function(_, value) return category .. "." .. value end })
end })
local environment = {
	game = { CreatorId = 0, GetService = function() return {} end },
	Enum = enums, Vector2 = roblox.Vector2, UDim = roblox.UDim, UDim2 = roblox.UDim2,
	Content = { none = "none", fromObject = function(image) return image end },
	task = { defer = function() end },
}
local modelCard
local function load(path)
	local globals = table.clone(environment)
	globals.require = function(name)
		if name == "../vide" then return vide end
		if name:match("Theme$") then return { stroke = function() return {} end } end
		if name:match("ModelCard$") then return modelCard end
		return function() return {} end
	end
	return luau.load(fs.readFile(path):gsub("%f[%w]const%f[%W]", "local"), { environment = globals })()
end
modelCard = load("src/components/ModelCard.luau")
local page = load("src/pages/RenderPage.luau")
local function model(name)
	return { name = name, state = source("ready"), warning = source(nil), assetId = source(nil),
		thumbnailVersion = source(1), thumbnail = name .. " image" }
end
local part, ronaldo, other = model("Part"), model("Ronaldo"), model("Other")
local store = { models = source({ part }), selected = source(1), config = source(nil), previewView = source("blender") }
store.select = function(index) store.selected(index) end
local dispose = root(function()
	page({ store = store, connected = function() return false end, rootSize = function() return roblox.Vector2.new(720, 860) end })
end)
local function list()
	for _, child in ipairs(cards) do
		if type(child) == "function" then return child() end
	end
	error("Card collection missing")
end
local function child(card, name)
	for _, item in ipairs(card) do
		if type(item) == "table" and item.Name == name then return item end
	end
	error(name .. " missing")
end
local oldCard = list()[1]
assert(child(oldCard, "Name").Text == "Part")
-- Replace the first selected part with a model, as in the reported screenshot.
part.thumbnail = nil -- Store destroys images belonging to deselected items.
store.models({ ronaldo })
local card = list()[1]
assert(card ~= oldCard, "The removed Part card was reused for Ronaldo")
assert(card.Name == "Ronaldo" and child(card, "Name").Text == "Ronaldo")
assert(child(card, "Thumbnail").ImageContent() == "Ronaldo image")
ronaldo.thumbnail = "updated render"
ronaldo.thumbnailVersion(2)
assert(child(card, "Thumbnail").ImageContent() == "updated render")
-- Retained cards follow the model when their positions change.
store.models({ other, ronaldo })
assert(table.find(list(), card))
assert(card.LayoutOrder() == 2)
card.Activated()
assert(store.selected() == 2)
store.models({ ronaldo })
assert(list()[1] == card and card.LayoutOrder() == 1)
card.Activated()
assert(store.selected() == 1)
store.models({})
assert(#list() == 0, "Deselecting all left a stale card")
dispose()
print("Model card replacement, thumbnail refresh, reorder and deselection checks passed")
