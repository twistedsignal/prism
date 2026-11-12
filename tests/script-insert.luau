-- Run with: lune run tests/script-insert.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local code = fs.readFile("src/ScriptInsert.luau"):gsub("%f[%w]const%f[%W]", "local")
local ScriptInsert = luau.load(code)()

local function eq(actual, expected, message)
	assert(actual == expected, `{message}\n  expected: {expected}\n  actual:   {actual}`)
end

local function item(name, id)
	return { name = name, text = `\{\n\tName = "{name}",\n\tImageContent = Content.fromAssetId({id}),\n},` }
end

local marker = "local Icons = {\n\t-- @prism\n}\nreturn Icons\n"
local result = ScriptInsert.insert(marker, { item("Sword", 1) })
eq(result.source, 'local Icons = {\n\t{\n\t\tName = "Sword",\n\t\tImageContent = Content.fromAssetId(1),\n\t},\n\t-- @prism\n}\nreturn Icons\n',
	"Items go above the marker at its indentation")
eq(result.inserted, 1, "One inserted")
eq(result.where, "above -- @prism", "Marker reported")

local module = "return {\n    Old = 1\n}\n"
result = ScriptInsert.insert(module, { { name = "New", text = "New = 2," } })
eq(result.source, "return {\n    Old = 1,\n    New = 2,\n}\n", "Before the closing brace, with a comma added and space indents")
eq(result.where, "in the returned table", "Returned table reported")

local empty = "return {\n}"
eq(ScriptInsert.insert(empty, { { name = "A", text = "A = 1," } }).source, "return {\n\tA = 1,\n}", "Empty tables get a tab indent")

local plain = "local x = 1\n\n"
result = ScriptInsert.insert(plain, { { name = "A", text = "print(1)" } })
eq(result.source, "local x = 1\nprint(1)\n", "Appends after the last line, keeping one trailing newline")
eq(result.where, "at the end", "Append reported")

local existing = 'return {\n\t{\n\t\tName = "Sword",\n\t\tImageContent = Content.fromAssetId(1),\n\t},\n\t{\n\t\tName = "Shield",\n\t\tImageContent = Content.fromAssetId(5),\n\t},\n}\n'
result = ScriptInsert.insert(existing, { item("Sword", 9), item("Bow", 3) }, true)
eq(result.replaced, 1, "Sword replaced")
eq(result.inserted, 1, "Bow inserted")
eq(result.source, 'return {\n\t{\n\t\tName = "Sword",\n\t\tImageContent = Content.fromAssetId(9),\n\t},\n\t{\n\t\tName = "Shield",\n\t\tImageContent = Content.fromAssetId(5),\n\t},\n'
	.. '\t{\n\t\tName = "Bow",\n\t\tImageContent = Content.fromAssetId(3),\n\t},\n}\n', "Replacement keeps the block in place")

local without = ScriptInsert.insert(existing, { item("Sword", 9) }, false)
eq(without.replaced, 0, "Replace off never replaces")
eq(without.inserted, 1, "Replace off inserts a duplicate")

local keyed = "return {\n\tSword = 1,\n\t[\"Fire Sword\"] = 2,\n}"
result = ScriptInsert.insert(keyed, { { name = "Sword", text = "Sword = 10," }, { name = "Fire Sword", text = '["Fire Sword"] = 20,' } }, true)
eq(result.source, "return {\n\tSword = 10,\n\t[\"Fire Sword\"] = 20,\n}", "Single-line keyed entries are replaced")
eq(result.replaced, 2, "Both replaced")

local differentShape = 'return {\n\tSword = { id = 1 },\n}'
result = ScriptInsert.insert(differentShape, { item("Sword", 9) }, true)
eq(result.replaced, 0, "Blocks with a different shape are not overwritten")
print("script insert ok")

for _, existingLine in {
	'Sword = 1 -- existing item',
	'Sword = "-- not a comment" -- existing item',
	'Sword = 1 --[[ trailing long comment ]]',
	'Sword = [[a -- string]] -- existing item',
	'Sword = 1 --[=[ multi-line\ncomment ]=]',
} do
	local source = "return {\n\t" .. existingLine .. "\n}\n"
	local updated = ScriptInsert.insert(source, { { name = "Shield", text = "Shield = 2," } })
	assert(pcall(luau.compile, updated.source), updated.source)
end
local Template = luau.load((fs.readFile("src/Template.luau"):gsub("%f[%w]const%f[%W]", "local")))()
for _, filter in { "upper_snake|key", "camel|key", "key", "replace:Sword:Blade|key" } do
	local template = { name = "Test", item = "{RENDER_NAME|" .. filter .. "} = {UPLOAD_ASSET_ID}," }
	for _, name in { "FireSword", 'Sword "Deluxe"', "123", "end" } do
		local first = Template.renderItems(template, { { name = name, assetId = "123" } })
		local second = Template.renderItems(template, { { name = name, assetId = "456" } })
		local initial = ScriptInsert.insert("return {\n}\n", first)
		local updated = ScriptInsert.insert(initial.source, second, true)
		assert(updated.replaced == 1 and updated.inserted == 0, updated.source)
		assert(not updated.source:find("123", 1, true) or name == "123")
		assert(pcall(luau.compile, updated.source), updated.source)
	end
end
local escaped = Template.renderItems(Template.defaults()[1], { { name = 'Sword "Deluxe"', assetId = "123" } })
local escapedNew = Template.renderItems(Template.defaults()[1], { { name = 'Sword "Deluxe"', assetId = "456" } })
local initial = ScriptInsert.insert("return {\n}\n", escaped)
assert(ScriptInsert.insert(initial.source, escapedNew, true).replaced == 1)
