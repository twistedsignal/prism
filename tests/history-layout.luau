local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local function source(value)
	return function(...)
		if select("#", ...) > 0 then value = ... end
		return value
	end
end
local buttons, filter, updateSize, entries = {}, nil, nil, nil
local vide = {
	source = source, untrack = function(value) return value() end,
	changed = function(_, callback) updateSize = callback; return {} end,
	values = function() return {} end,
	create = function() return function(properties)
		if properties.Name == "Entries" then entries = properties end
		return properties
	end end,
}
local code = fs.readFile("src/pages/HistoryPage.luau"):gsub("%f[%w]const%f[%W]", "local")
local page = luau.load(code, { environment = {
	require = function(name)
		if name == "../vide" then return vide end
		if name:match("Theme$") then return { stroke = function() return {} end } end
		if name:match("Button$") then return function(properties) table.insert(buttons, properties); return properties end end
		if name:match("Segmented$") then return function(properties) filter = properties; return properties end end
		return {}
	end,
	UDim2 = roblox.UDim2, Vector2 = roblox.Vector2, Enum = roblox.Enum,
} })()
page({ store = { history = source({}), loadHistory = function() end }, filter = source(1), connected = function() return true end })
for _, widgetWidth in { 560, 640, 720 } do
	local width = widgetWidth - 24
	updateSize(roblox.Vector2.new(width, 500))
	local rectangles = { { 88, 2, 298, 28 } }
	for _, button in buttons do
		local position = if type(button.position) == "function" then button.position() else button.position or roblox.UDim2.new()
		local size = button.size
		local anchor = button.anchorPoint or roblox.Vector2.zero
		local x = position.X.Scale * width + position.X.Offset - anchor.X * size.X.Offset
		local y = position.Y.Offset - anchor.Y * size.Y.Offset
		table.insert(rectangles, { x, y, x + size.X.Offset, y + size.Y.Offset })
	end
	for firstIndex, firstRect in rectangles do
		assert(firstRect[1] >= 0 and firstRect[3] <= width)
		for secondIndex = firstIndex + 1, #rectangles do
			local secondRect = rectangles[secondIndex]
			assert(firstRect[3] <= secondRect[1] or secondRect[3] <= firstRect[1]
				or firstRect[4] <= secondRect[2] or secondRect[4] <= firstRect[2], `Toolbar overlap at {widgetWidth}`)
		end
		assert(firstRect[4] <= entries.Position().Y.Offset)
	end
end
print("History toolbar stays separated at supported widget widths")
