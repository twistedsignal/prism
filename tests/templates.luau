-- Run with: lune run tests/templates.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local code = fs.readFile("src/Template.luau"):gsub("%f[%w]const%f[%W]", "local")
local Template = luau.load(code)()

local function eq(actual, expected, message)
	assert(actual == expected, `{message}\n  expected: {expected}\n  actual:   {actual}`)
end

local sword = { name = "Fire Sword", assetId = "100", imageId = "200", moderation = "Approved",
	path = "/out/Fire Sword.png", source = "ReplicatedStorage/Weapons/Fire Sword", parent = "Weapons", creator = "user:7" }
local shield = { name = "WoodenShield", assetId = "300" }
local NOW = 1790000000

local itemIcon = Template.defaults()[1]
local text, warnings = Template.render(itemIcon, { sword, shield }, NOW)
eq(text, '{\n\tName = "Fire Sword",\n\tImageContent = Content.fromAssetId(200),\n},\n'
	.. '{\n\tName = "WoodenShield",\n\tImageContent = Content.fromAssetId(300),\n},',
	"itemIcon keeps Lua braces and falls back to the Decal ID")
eq(#warnings, 0, "itemIcon has no warnings")

local function one(item, entry)
	return (Template.render({ name = "t", item = item }, { entry or sword }, NOW))
end
eq(one("{ x = 1 } {} {lower} {RENDER_NAME x}"), "{ x = 1 } {} {lower} {RENDER_NAME x}", "Non-placeholders stay literal")
eq(one("{DECAL_ID} {ASSET_URI} {INDEX}"), "100 rbxassetid://200 1", "ID variables")
eq(one("{INSTANCE_PATH} {PARENT_NAME} {FILE_NAME} {CREATOR} {MODERATION}"),
	"ReplicatedStorage/Weapons/Fire Sword Weapons Fire Sword.png user:7 Approved", "Source variables")
eq(one("{FILE_PATH}"), "/out/Fire Sword.png", "File path")
eq(one("{ASSET_URI}", { name = "x" }), "", "No ID means an empty URI")

local cases = {
	{ "lower", "fire sword" }, { "upper", "FIRE SWORD" }, { "camel", "fireSword" }, { "pascal", "FireSword" },
	{ "snake", "fire_sword" }, { "upper_snake", "FIRE_SWORD" }, { "kebab", "fire-sword" }, { "title", "Fire Sword" },
	{ "quote", '"Fire Sword"' }, { "json", '"Fire Sword"' }, { "key", '["Fire Sword"]' },
	{ "replace: :_", "Fire_Sword" }, { "replace:Fire:Ice|lower", "ice sword" },
}
for _, case in cases do
	eq(one(`\{RENDER_NAME|{case[1]}}`), case[2], `Filter {case[1]}`)
end
eq(Template.applyFilter("WoodenShield", "snake"), "wooden_shield", "camel case splits into words")
eq(Template.applyFilter("HTTPServer2", "camel"), "httpServer2", "acronyms and digits split")
eq(Template.applyFilter("  hi  ", "trim"), "hi", "trim")
eq(Template.applyFilter('a"b\\c\n', "quote"), '"a\\"b\\\\c\\n"', "quote escapes")
eq(Template.applyFilter("Sword", "key"), "Sword", "identifiers stay bare keys")
eq(Template.applyFilter("end", "key"), '["end"]', "keywords are quoted keys")
eq(Template.applyFilter("", "default:none"), "none", "default fills empty values")
eq(Template.applyFilter("x", "default:none"), "x", "default keeps values")
eq(Template.applyFilter("", "default:a:b"), "a:b", "default keeps colons")
eq(Template.applyFilter("7", "pad:3"), "007", "pad")
eq(Template.applyFilter("1234", "pad:3"), "1234", "pad never truncates")
eq(Template.applyFilter("x", "nope"), nil, "Unknown filters return nil")

local _, unknown = Template.render({ name = "t", item = "{NOPE} {RENDER_NAME|nope} {NOPE}" }, { sword }, NOW)
eq(table.concat(unknown, ";"), "Unknown variable NOPE;Unknown filter nope", "Warnings are listed once each")
eq(one("{NOPE}"), "{NOPE}", "Unknown variables stay as written")

local module = { name = "m", header = "-- {COUNT} icons, {DATE}\nreturn {", item = "\t{RENDER_NAME|key} = {UPLOAD_ASSET_ID},",
	footer = "}", separator = "\\n" }
local out, moduleWarnings = Template.render(module, { sword, shield }, NOW)
eq(out, `-- 2 icons, {os.date("%Y-%m-%d", NOW)}\nreturn \{\n\t["Fire Sword"] = 200,\n\tWoodenShield = 300,\n}`, "Header and footer wrap items")
eq(#moduleWarnings, 0, "Module has no warnings")
local _, headerWarnings = Template.render({ name = "h", header = "{RENDER_NAME}", item = "" }, { sword }, NOW)
eq(headerWarnings[1], "RENDER_NAME only works in Item", "Item variables warn in the header")

local json = Template.render(Template.defaults()[5], { sword, shield }, NOW)
eq(json, '[\n\t{"name": "Fire Sword", "id": 200},\n\t{"name": "WoodenShield", "id": 300}\n]', "JSON separator escapes")
eq(Template.unescape("a\\tb\\\\n"), "a\tb\\n", "Separators unescape tabs and backslashes")
eq((Template.render({ name = "e", header = "[", item = "x", footer = "]" }, {}, NOW)), "[\n]", "No entries still writes the wrapper")

local items = Template.renderItems(itemIcon, { sword }, NOW)
eq(items[1].name, "Fire Sword", "Items carry their names")
print("templates ok")
