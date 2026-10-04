-- snippet templates that turn uploads into code: {VARIABLE|filter:arg} placeholders,
-- repeated once per model, with an optional header, footer and separator.
-- only {UPPER_CASE} names are placeholders, so ordinary Lua braces stay as written.

export type Template = {
	name: string,
	item: string,
	header: string?,
	footer: string?,
	-- written with \n and \t escapes, so it fits in a single-line box.
	separator: string?,
	-- path to the ModuleScript that Insert writes to; empty uses the Studio selection.
	target: string?,
	replace: boolean?,
}

-- an upload result or a history entry.
export type Entry = {
	name: string?,
	assetId: string?,
	imageId: string?,
	moderation: string?,
	path: string?,
	source: string?,
	parent: string?,
	creator: string?,
}

export type Item = { text: string, name: string }

export type Variable = { name: string, description: string, example: string, item: boolean }
export type Filter = { name: string, description: string, example: string }

const variables: { Variable } = {
	{ name = "RENDER_NAME", description = "The model's name", example = "Sword", item = true },
	{
		name = "UPLOAD_ASSET_ID",
		description = "Image ID for ImageLabels and Content.fromAssetId (falls back to the Decal ID)",
		example = "123456789",
		item = true,
	},
	{ name = "DECAL_ID", description = "ID of the uploaded Decal", example = "123456700", item = true },
	{ name = "ASSET_URI", description = "rbxassetid:// URI of the image", example = "rbxassetid://123456789", item = true },
	{ name = "INDEX", description = "Position in this list, from 1", example = "1", item = true },
	{
		name = "INSTANCE_PATH",
		description = "Where the model is in Studio",
		example = "ReplicatedStorage/Weapons/Sword",
		item = true,
	},
	{ name = "PARENT_NAME", description = "Name of the model's parent", example = "Weapons", item = true },
	{ name = "FILE_NAME", description = "Saved PNG's file name", example = "Sword.png", item = true },
	{ name = "FILE_PATH", description = "Full path of the saved PNG", example = "/Pictures/Prism/Sword.png", item = true },
	{ name = "CREATOR", description = "Who it was uploaded to", example = "user:1", item = true },
	{ name = "MODERATION", description = "Roblox's moderation state", example = "Approved", item = true },
	{ name = "COUNT", description = "How many models are in the list", example = "3", item = false },
	{ name = "DATE", description = "Today's date", example = "2026-10-04", item = false },
	{ name = "TIME", description = "The current time", example = "14:05", item = false },
}

const filters: { Filter } = {
	{ name = "lower", description = "lowercase", example = "sword" },
	{ name = "upper", description = "UPPERCASE", example = "SWORD" },
	{ name = "camel", description = "camelCase", example = "fireSword" },
	{ name = "pascal", description = "PascalCase", example = "FireSword" },
	{ name = "snake", description = "snake_case", example = "fire_sword" },
	{ name = "upper_snake", description = "UPPER_SNAKE_CASE", example = "FIRE_SWORD" },
	{ name = "kebab", description = "kebab-case", example = "fire-sword" },
	{ name = "title", description = "Title Case", example = "Fire Sword" },
	{ name = "trim", description = "Remove surrounding spaces", example = "Sword" },
	{ name = "quote", description = "Lua string literal with escapes", example = '"Fire \\"Sword\\""' },
	{ name = "json", description = "JSON string literal", example = '"Fire Sword"' },
	{ name = "key", description = "Lua table key: Name, or [\"Odd Name\"]", example = '["Fire Sword"]' },
	{ name = "default:x", description = "x when the value is empty", example = "0" },
	{ name = "replace:a:b", description = "Replace every a with b", example = "Fire_Sword" },
	{ name = "pad:n", description = "Pad with zeros to n digits", example = "007" },
}

const variableInfo: { [string]: Variable } = {}
for _, variable in variables do
	variableInfo[variable.name] = variable
end

const KEYWORDS = {}
for _, keyword in
	{
		"and",
		"break",
		"continue",
		"do",
		"else",
		"elseif",
		"end",
		"false",
		"for",
		"function",
		"if",
		"in",
		"local",
		"nil",
		"not",
		"or",
		"repeat",
		"return",
		"then",
		"true",
		"until",
		"while",
	}
do
	KEYWORDS[keyword] = true
end

-- splits "FireSword", "fire_sword" or "Fire Sword 2" into words.
const function words(text: string): { string }
	local spaced = string.gsub(text, "(%l)(%u)", "%1 %2")
	spaced = string.gsub(spaced, "(%u)(%u%l)", "%1 %2")
	spaced = string.gsub(spaced, "(%a)(%d)", "%1 %2")
	const list = {}
	for word in string.gmatch(spaced, "%w+") do
		table.insert(list, word)
	end
	return list
end

const function capitalize(word: string): string
	return string.upper(string.sub(word, 1, 1)) .. string.lower(string.sub(word, 2))
end

const function joinWords(text: string, separator: string, transform: (string, number) -> string): string
	const list = words(text)
	for index, word in list do
		list[index] = transform(word, index)
	end
	return table.concat(list, separator)
end

const function quote(text: string): string
	const escaped = string.gsub(text, '[%c"\\]', function(char: string): string
		if char == "\n" then
			return "\\n"
		elseif char == "\t" then
			return "\\t"
		elseif char == "\r" then
			return "\\r"
		elseif char == '"' or char == "\\" then
			return "\\" .. char
		end
		return string.format("\\%03d", string.byte(char))
	end)
	return `"{escaped}"`
end

const function json(text: string): string
	const escaped = string.gsub(text, '[%c"\\]', function(char: string): string
		if char == "\n" then
			return "\\n"
		elseif char == "\t" then
			return "\\t"
		elseif char == "\r" then
			return "\\r"
		elseif char == '"' or char == "\\" then
			return "\\" .. char
		end
		return string.format("\\u%04x", string.byte(char))
	end)
	return `"{escaped}"`
end

const function key(text: string): string
	if string.match(text, "^[%a_][%w_]*$") and not KEYWORDS[text] then
		return text
	end
	return `[{quote(text)}]`
end

-- "a:b:c" into { "a", "b", "c" }; empty parts are kept.
const function splitArgs(text: string): { string }
	const parts = {}
	local start = 1
	while true do
		const at = string.find(text, ":", start, true)
		if at == nil then
			table.insert(parts, string.sub(text, start))
			return parts
		end
		table.insert(parts, string.sub(text, start, at - 1))
		start = at + 1
	end
end

const function plainReplace(text: string, find: string, replacement: string): string
	if find == "" then
		return text
	end
	const parts = {}
	local start = 1
	while true do
		const first, last = string.find(text, find, start, true)
		if first == nil then
			table.insert(parts, string.sub(text, start))
			break
		end
		table.insert(parts, string.sub(text, start, first - 1))
		table.insert(parts, replacement)
		start = last + 1
	end
	return table.concat(parts)
end

-- applies one filter, returning nil when the filter is unknown.
const function applyFilter(value: string, spec: string): string?
	const args = splitArgs(spec)
	const name = table.remove(args, 1) :: string
	if name == "lower" then
		return string.lower(value)
	elseif name == "upper" then
		return string.upper(value)
	elseif name == "camel" then
		return joinWords(value, "", function(word, index)
			return if index == 1 then string.lower(word) else capitalize(word)
		end)
	elseif name == "pascal" then
		return joinWords(value, "", capitalize)
	elseif name == "snake" then
		return joinWords(value, "_", string.lower)
	elseif name == "upper_snake" then
		return joinWords(value, "_", string.upper)
	elseif name == "kebab" then
		return joinWords(value, "-", string.lower)
	elseif name == "title" then
		return joinWords(value, " ", capitalize)
	elseif name == "trim" then
		return (string.match(value, "^%s*(.-)%s*$"))
	elseif name == "quote" then
		return quote(value)
	elseif name == "json" then
		return json(value)
	elseif name == "key" then
		return key(value)
	elseif name == "default" then
		return if value == "" then table.concat(args, ":") else value
	elseif name == "replace" then
		return plainReplace(value, args[1] or "", table.concat(args, ":", 2))
	elseif name == "pad" then
		const width = math.clamp(tonumber(args[1]) or 0, 0, 64)
		return string.rep("0", width - #value) .. value
	end
	return nil
end

const function fileName(path: string): string
	return string.match(path, "([^/\\]+)$") or path
end

const function itemValues(entry: Entry, index: number): { [string]: string }
	const id = entry.imageId or entry.assetId or ""
	return {
		RENDER_NAME = entry.name or "",
		UPLOAD_ASSET_ID = id,
		DECAL_ID = entry.assetId or "",
		ASSET_URI = if id ~= "" then `rbxassetid://{id}` else "",
		INDEX = tostring(index),
		INSTANCE_PATH = entry.source or "",
		PARENT_NAME = entry.parent or "",
		FILE_NAME = if entry.path then fileName(entry.path) else "",
		FILE_PATH = entry.path or "",
		CREATOR = entry.creator or "",
		MODERATION = entry.moderation or "",
	}
end

const function globalValues(count: number, now: number): { [string]: string }
	return {
		COUNT = tostring(count),
		DATE = os.date("%Y-%m-%d", now) :: string,
		TIME = os.date("%H:%M", now) :: string,
	}
end

-- fills placeholders in text. values may be nil for item variables outside the item text.
const function fill(text: string, values: { [string]: string }, warn: (string) -> ()): string
	return (string.gsub(text, "{([%u_][%u%d_]*)([^{}\n]*)}", function(name: string, rest: string): string?
		if rest ~= "" and string.sub(rest, 1, 1) ~= "|" then
			return nil
		end
		local value = values[name]
		if value == nil then
			if variableInfo[name] then
				warn(`{name} only works in Item`)
			else
				warn(`Unknown variable {name}`)
			end
			return nil
		end
		if rest ~= "" then
			for spec in string.gmatch(string.sub(rest, 2), "[^|]+") do
				const result = applyFilter(value, spec)
				if result == nil then
					warn(`Unknown filter {spec}`)
				else
					value = result
				end
			end
		end
		return value
	end))
end

-- turns the \n, \t and \\ escapes a separator is written with into characters.
const function unescape(text: string): string
	return (string.gsub(text, "\\(.)", function(char: string): string
		if char == "n" then
			return "\n"
		elseif char == "t" then
			return "\t"
		end
		return char
	end))
end

const function collector(): ({ string }, (string) -> ())
	const warnings = {}
	const seen = {}
	return warnings, function(message: string)
		if not seen[message] then
			seen[message] = true
			table.insert(warnings, message)
		end
	end
end

-- each entry's filled item text, with its name for matching existing entries.
const function renderItems(template: Template, entries: { Entry }, now: number?): ({ Item }, { string })
	const warnings, warn = collector()
	const globals = globalValues(#entries, now or os.time())
	const items = {}
	for index, entry in entries do
		const values = itemValues(entry, index)
		for name, value in globals do
			values[name] = value
		end
		table.insert(items, { text = fill(template.item, values, warn), name = entry.name or "" })
	end
	return items, warnings
end

-- the whole output: header, every item joined by the separator, then the footer.
const function render(template: Template, entries: { Entry }, now: number?): (string, { string })
	const items, warnings = renderItems(template, entries, now)
	const seen = {}
	for _, message in warnings do
		seen[message] = true
	end
	const function warn(message: string)
		if not seen[message] then
			seen[message] = true
			table.insert(warnings, message)
		end
	end
	const globals = globalValues(#entries, now or os.time())
	const texts = {}
	for index, item in items do
		texts[index] = item.text
	end
	const parts = {}
	if template.header and template.header ~= "" then
		table.insert(parts, fill(template.header, globals, warn))
	end
	if #texts > 0 then
		table.insert(parts, table.concat(texts, unescape(template.separator or "\\n")))
	end
	if template.footer and template.footer ~= "" then
		table.insert(parts, fill(template.footer, globals, warn))
	end
	return table.concat(parts, "\n"), warnings
end

const DEFAULTS: { Template } = {
	{
		name = "itemIcon",
		item = '{\n\tName = "{RENDER_NAME}",\n\tImageContent = Content.fromAssetId({UPLOAD_ASSET_ID}),\n},',
		separator = "\\n",
	},
	{
		name = "Dictionary",
		header = "return {",
		item = '\t{RENDER_NAME|key} = "{ASSET_URI}",',
		footer = "}",
		separator = "\\n",
	},
	{
		name = "Constants",
		item = "{RENDER_NAME|upper_snake} = {UPLOAD_ASSET_ID},",
		separator = "\\n",
	},
	{
		name = "IDs only",
		item = "{UPLOAD_ASSET_ID}",
		separator = "\\n",
	},
	{
		name = "JSON",
		header = "[",
		item = '\t{"name": {RENDER_NAME|json}, "id": {UPLOAD_ASSET_ID}}',
		footer = "]",
		separator = ",\\n",
	},
}

const function defaults(): { Template }
	const list = {}
	for _, template in DEFAULTS do
		table.insert(list, table.clone(template))
	end
	return list
end

-- sample uploads for previews before anything has been uploaded.
const SAMPLES: { Entry } = {
	{
		name = "Fire Sword",
		assetId = "123456700",
		imageId = "123456789",
		moderation = "Approved",
		path = "/Pictures/Prism/Fire Sword.png",
		source = "ReplicatedStorage/Items/Weapons/Fire Sword",
		parent = "Weapons",
		creator = "user:1",
	},
	{
		name = "WoodenShield",
		assetId = "223456700",
		imageId = "223456789",
		moderation = "Approved",
		path = "/Pictures/Prism/WoodenShield.png",
		source = "ReplicatedStorage/Items/Armor/WoodenShield",
		parent = "Armor",
		creator = "user:1",
	},
}

return {
	render = render,
	renderItems = renderItems,
	applyFilter = applyFilter,
	unescape = unescape,
	defaults = defaults,
	variables = variables,
	filters = filters,
	samples = SAMPLES,
}
