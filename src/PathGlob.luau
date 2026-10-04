-- glob matching and autocomplete over instance paths such as "ReplicatedStorage/Content/**/Model".
-- "/" separates names. "*" and "?" match within a name, "**" spans any number of levels,
-- "[abc]", "[!abc]" and "{a,b}" work as in shell globs. matching ignores case.
-- "\" escapes the next character, so names containing "/" or "*" stay reachable.

-- every N instances visited, long searches call options.yield.
const YIELD_EVERY = 2000
const MAX_PARENTS = 2000
const SPECIAL = "[\\/%*%?%[%]{}]"
const LUA_MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"

export type Segment = { globstar: boolean, patterns: { string } }

export type Options = {
	limit: number?,
	filter: ((Instance) -> boolean)?,
	-- return false to cancel; match() then returns nil.
	yield: (() -> boolean)?,
}

export type Suggestion = {
	name: string,
	insert: string,
	className: string?,
	count: number,
	hasChildren: boolean,
}

type Candidate = {
	name: string,
	insert: string,
	className: string?,
	count: number,
	hasChildren: boolean,
	rank: number,
}

export type Completion = {
	items: { Suggestion },
	-- the rest of the first suggestion when it extends the typed text, else "".
	ghost: string,
}

const function escape(name: string): string
	return (string.gsub(name, SPECIAL, "\\%0"))
end

const function unescape(text: string): string
	return (string.gsub(text, "\\(.)", "%1"))
end

-- splits on unescaped "/", keeping escapes for later compilation.
const function split(text: string): { string }
	const parts = {}
	local current = {}
	local index = 1
	while index <= #text do
		const char = string.sub(text, index, index)
		if char == "\\" and index < #text then
			table.insert(current, string.sub(text, index, index + 1))
			index += 2
			continue
		end
		if char == "/" then
			table.insert(parts, table.concat(current))
			current = {}
		else
			table.insert(current, char)
		end
		index += 1
	end
	table.insert(parts, table.concat(current))
	return parts
end

-- "{a,b}c" becomes { "ac", "bc" }, including nested and repeated groups.
const function expandBraces(text: string): { string }
	local depth, open = 0, nil :: number?
	const commas = {}
	local index = 1
	while index <= #text do
		const char = string.sub(text, index, index)
		if char == "\\" then
			index += 2
			continue
		end
		if char == "{" then
			depth += 1
			if depth == 1 then
				open = index
				table.clear(commas)
			end
		elseif char == "}" and depth > 0 then
			depth -= 1
			if depth == 0 and open and #commas > 0 then
				const before, after = string.sub(text, 1, open - 1), string.sub(text, index + 1)
				const results = {}
				local start = open + 1
				table.insert(commas, index)
				for _, stop in commas do
					for _, tail in expandBraces(before .. string.sub(text, start, stop - 1) .. after) do
						table.insert(results, tail)
					end
					start = stop + 1
				end
				return results
			end
		elseif char == "," and depth == 1 then
			table.insert(commas, index)
		end
		index += 1
	end
	return { text }
end

const function literal(char: string): string
	return (string.gsub(string.lower(char), LUA_MAGIC, "%%%0"))
end

-- one glob alternative to an anchored, lowercase Lua pattern.
const function compile(glob: string): string
	const out = { "^" }
	local index = 1
	while index <= #glob do
		const char = string.sub(glob, index, index)
		if char == "\\" and index < #glob then
			table.insert(out, literal(string.sub(glob, index + 1, index + 1)))
			index += 2
		elseif char == "*" then
			-- "**" inside a name behaves like "*".
			while string.sub(glob, index + 1, index + 1) == "*" do
				index += 1
			end
			table.insert(out, ".*")
			index += 1
		elseif char == "?" then
			table.insert(out, ".")
			index += 1
		elseif char == "[" and string.find(glob, "]", index + 2, true) then
			const close = string.find(glob, "]", index + 2, true) :: number
			local body = string.sub(glob, index + 1, close - 1)
			local negate = ""
			const first = string.sub(body, 1, 1)
			if first == "!" or first == "^" then
				negate = "^"
				body = string.sub(body, 2)
			end
			-- keep "a-z" ranges; escape everything else Lua treats specially.
			body = string.gsub(string.lower(body), "[%^%]%[%%]", "%%%0")
			table.insert(out, `[{negate}{body}]`)
			index = close + 1
		else
			table.insert(out, literal(char))
			index += 1
		end
	end
	table.insert(out, "$")
	return table.concat(out)
end

const function hasGlob(text: string): boolean
	const stripped = string.gsub(text, "\\.", "")
	return string.find(stripped, "[%*%?%[{]") ~= nil
end

const function compileSegment(raw: string): Segment
	if raw == "**" then
		return { globstar = true, patterns = {} }
	end
	const patterns = {}
	for _, alternative in expandBraces(raw) do
		table.insert(patterns, compile(alternative))
	end
	return { globstar = false, patterns = patterns }
end

-- empty segments are ignored, and a leading "game" names the DataModel itself.
const function parse(text: string): { Segment }
	const raw = split(text)
	if #raw > 1 and string.lower(raw[1]) == "game" then
		table.remove(raw, 1)
	end
	const segments = {}
	for _, part in raw do
		if part ~= "" then
			table.insert(segments, compileSegment(part))
		end
	end
	-- "Folder/**" means everything inside the folder, not the folder too.
	if #segments > 0 and segments[#segments].globstar then
		table.insert(segments, compileSegment("*"))
	end
	return segments
end

const function nameMatches(segment: Segment, name: string): boolean
	const lowered = string.lower(name)
	for _, pattern in segment.patterns do
		if string.find(lowered, pattern) then
			return true
		end
	end
	return false
end

const function children(instance: Instance): { Instance }
	-- some services refuse plugin access; treat them as empty.
	const ok, list = pcall(instance.GetChildren, instance)
	return if ok then list else {}
end

-- adds the segments a globstar can skip, since "**" may span zero levels.
const function closure(states: { number }, segments: { Segment }): { number }
	const result, added = {}, {}
	for _, index in states do
		while not added[index] do
			added[index] = true
			table.insert(result, index)
			if not (segments[index] and segments[index].globstar) then
				break
			end
			index += 1
		end
	end
	return result
end

-- instances matching the pattern below root, in tree order. returns nil when cancelled.
const function match(root: Instance, pattern: string, options: Options?): ({ Instance }?, boolean)
	const opts: Options = options or {}
	const limit = opts.limit or math.huge
	const segments = parse(pattern)
	const results = {}
	if #segments == 0 then
		return results, false
	end
	-- each instance carries the pattern positions it can be at, so globstars
	-- never visit an instance twice and results come out in tree order.
	const stack: { { any } } = { { root, closure({ 1 }, segments) } }
	local visits = 0
	while #stack > 0 do
		const entry = table.remove(stack) :: { any }
		const instance, states = entry[1] :: Instance, entry[2] :: { number }
		visits += 1
		if opts.yield and visits % YIELD_EVERY == 0 and not opts.yield() then
			return nil, false
		end
		if instance ~= root and table.find(states, #segments + 1) and (not opts.filter or opts.filter(instance)) then
			table.insert(results, instance)
			if #results >= limit then
				return results, true
			end
		end
		const list = children(instance)
		-- push in reverse, so the stack pops children in order.
		for position = #list, 1, -1 do
			const child = list[position]
			const next = {}
			for _, index in states do
				const segment = segments[index]
				if not segment then
					continue
				elseif segment.globstar then
					table.insert(next, index)
				elseif nameMatches(segment, child.Name) then
					table.insert(next, index + 1)
				end
			end
			if #next > 0 then
				table.insert(stack, { child, closure(next, segments) })
			end
		end
	end
	return results, false
end

-- "Parent/Child" path from root, escaped so it can be pasted back into a pattern.
const function pathOf(instance: Instance, root: Instance): string
	const names = {}
	local current: Instance? = instance
	while current and current ~= root do
		table.insert(names, 1, escape(current.Name))
		current = current.Parent
	end
	return table.concat(names, "/")
end

-- suggestions for the last path segment of text, like a shell's tab completion.
const function complete(root: Instance, text: string, limit: number?, yield: (() -> boolean)?): Completion?
	const max = limit or 50
	local slash = 0
	local index = 1
	while index <= #text do
		const char = string.sub(text, index, index)
		if char == "\\" then
			index += 2
			continue
		end
		if char == "/" then
			slash = index
		end
		index += 1
	end
	const head, partial = string.sub(text, 1, slash), string.sub(text, slash + 1)

	local parents: { Instance } = { root }
	if #parse(head) > 0 then
		const matched = match(root, head, { limit = MAX_PARENTS, yield = yield })
		if matched == nil then
			return nil
		end
		parents = matched
	end

	const globbed = hasGlob(partial) and partial ~= "*"
	const segment = if globbed then compileSegment(partial) else nil
	const typed = string.lower(unescape(partial))
	const byName: { [string]: Candidate } = {}
	local visits = 0
	for _, parent in parents do
		for _, child in children(parent) do
			visits += 1
			if yield and visits % YIELD_EVERY == 0 and not yield() then
				return nil
			end
			const name = child.Name
			const key = string.lower(name)
			local rank: number
			if segment then
				if not nameMatches(segment, name) then
					continue
				end
				rank = 0
			elseif typed == "" or typed == "*" or string.sub(key, 1, #typed) == typed then
				rank = 0
			elseif string.find(key, typed, 1, true) then
				rank = 1
			else
				continue
			end
			const existing = byName[key]
			if existing then
				existing.count += 1
				existing.hasChildren = existing.hasChildren or #children(child) > 0
			else
				const hasChildren = #children(child) > 0
				byName[key] = {
					name = name,
					insert = head .. escape(name) .. if hasChildren then "/" else "",
					className = child.ClassName,
					count = 1,
					hasChildren = hasChildren,
					rank = rank,
				}
			end
		end
	end

	const sorted = {}
	for _, item in byName do
		table.insert(sorted, item)
	end
	table.sort(sorted, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		return string.lower(a.name) < string.lower(b.name)
	end)
	const items: { Suggestion } = {}
	const globstar: Suggestion = {
		name = "**",
		insert = head .. "**/",
		className = nil,
		count = 0,
		hasChildren = true,
	}
	-- "**" leads once a "*" is typed; otherwise it trails the real names.
	if partial == "*" then
		table.insert(items, globstar)
	end
	for _, item in sorted do
		if #items >= max then
			break
		end
		table.insert(items, {
			name = item.name,
			insert = item.insert,
			className = item.className,
			count = item.count,
			hasChildren = item.hasChildren,
		})
	end
	if partial == "" and #items < max and #parents > 0 then
		table.insert(items, globstar)
	end

	local ghost = ""
	const first = items[1]
	if first and string.lower(string.sub(first.insert, 1, #text)) == string.lower(text) then
		ghost = string.sub(first.insert, #text + 1)
	end
	return { items = items, ghost = ghost }
end

return {
	escape = escape,
	parse = parse,
	match = match,
	pathOf = pathOf,
	complete = complete,
}
