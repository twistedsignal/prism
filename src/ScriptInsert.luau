-- writes template items into a script's source: above a "-- @prism" marker, before the
-- closing brace of "return {", or at the end. can replace entries with the same name.

export type Item = { text: string, name: string }
export type Result = { source: string, inserted: number, replaced: number, where: string }

const function splitLines(text: string): { string }
	const lines = {}
	local start = 1
	while true do
		const at = string.find(text, "\n", start, true)
		if at == nil then
			table.insert(lines, string.sub(text, start))
			return lines
		end
		table.insert(lines, string.sub(text, start, at - 1))
		start = at + 1
	end
end

const function indentOf(line: string): string
	return string.match(line, "^[ \t]*") or ""
end

const function trim(text: string): string
	return (string.match(text, "^%s*(.-)%s*$"))
end

-- one indent level in this file's style.
const function indentUnit(lines: { string }): string
	for _, line in lines do
		if string.match(line, "^\t") then
			return "\t"
		end
	end
	for _, line in lines do
		const spaces = string.match(line, "^( +)%S")
		if spaces then
			return if #spaces >= 4 then "    " else spaces
		end
	end
	return "\t"
end

-- the item's lines, re-indented to sit at indent.
const function indented(text: string, indent: string): { string }
	const lines = splitLines(text)
	-- strip the indent the template already has, so nesting is kept but not doubled.
	local common: string? = nil
	for _, line in lines do
		if trim(line) ~= "" then
			const own = indentOf(line)
			if common == nil or #own < #common then
				common = own
			end
		end
	end
	for index, line in lines do
		lines[index] = if trim(line) == "" then "" else indent .. string.sub(line, #(common or "") + 1)
	end
	return lines
end

-- forms the name takes in a line that identifies an entry.
const function nameNeedles(name: string): { string }
	const needles = { `"{name}"`, `'{name}'` }
	if string.match(name, "^[%a_][%w_]*$") then
		table.insert(needles, `{name} =`)
		table.insert(needles, `{name}=`)
	end
	return needles
end

const function lineHas(line: string, needles: { string }): boolean
	for _, needle in needles do
		if string.find(line, needle, 1, true) then
			return true
		end
	end
	return false
end

-- where an existing entry like item sits: the item line naming the entry lines up with a
-- source line naming it, and the rest of the block must have the same shape.
const function findExisting(lines: { string }, item: Item): (number?, number?)
	if item.name == "" then
		return nil, nil
	end
	const needles = nameNeedles(item.name)
	const itemLines = splitLines(item.text)
	local offset: number? = nil
	for index, line in itemLines do
		if lineHas(line, needles) then
			offset = index
			break
		end
	end
	if offset == nil then
		return nil, nil
	end
	for index, line in lines do
		if lineHas(line, needles) then
			const first = index - offset + 1
			const last = first + #itemLines - 1
			if first >= 1 and last <= #lines then
				-- the first and last lines (such as "{" and "},") must match the template's.
				if trim(lines[first]) == trim(itemLines[1]) or offset == 1 then
					if #itemLines == 1 or trim(lines[last]) == trim(itemLines[#itemLines]) then
						return first, last
					end
				end
			end
		end
	end
	return nil, nil
end

-- adds a separator to the line before an insertion so the table stays valid.
const function ensureSeparator(lines: { string }, before: number)
	for index = before - 1, 1, -1 do
		const content = trim(lines[index])
		if content == "" or string.sub(content, 1, 2) == "--" then
			continue
		end
		const last = string.sub(content, -1)
		if last ~= "," and last ~= ";" and last ~= "{" and last ~= "(" then
			lines[index] ..= ","
		end
		return
	end
end

const function insert(source: string, items: { Item }, replace: boolean?): Result
	const lines = splitLines(source)
	local replaced = 0
	const pending: { Item } = {}
	for _, item in items do
		if replace then
			const first, last = findExisting(lines, item)
			if first and last then
				const indent = indentOf(lines[first])
				const fresh = indented(item.text, indent)
				for _ = first, last do
					table.remove(lines, first)
				end
				for offset, line in fresh do
					table.insert(lines, first + offset - 1, line)
				end
				replaced += 1
				continue
			end
		end
		table.insert(pending, item)
	end

	local where = "at the end"
	if #pending > 0 then
		local at: number? = nil
		local indent = ""
		for index, line in lines do
			if string.match(line, "^%s*%-%-%s*@prism") then
				at = index
				indent = indentOf(line)
				where = "above -- @prism"
				break
			end
		end
		if at == nil then
			local returnLine: number? = nil
			for index, line in lines do
				if string.match(line, "^%s*return%s*{%s*$") then
					returnLine = index
				end
			end
			if returnLine then
				for index = #lines, returnLine + 1, -1 do
					if string.match(lines[index], "^%s*}%s*$") then
						at = index
						indent = indentOf(lines[index]) .. indentUnit(lines)
						where = "in the returned table"
						break
					end
				end
			end
		end
		const added = {}
		for _, item in pending do
			for _, line in indented(item.text, indent) do
				table.insert(added, line)
			end
		end
		if at then
			if where == "in the returned table" then
				ensureSeparator(lines, at)
			end
			for offset, line in added do
				table.insert(lines, at + offset - 1, line)
			end
		else
			-- append after the last non-empty line, keeping the file's trailing newline.
			local last = #lines
			while last > 0 and lines[last] == "" do
				last -= 1
			end
			const trailing = #lines - last
			for _ = 1, trailing do
				table.remove(lines)
			end
			for _, line in added do
				table.insert(lines, line)
			end
			if trailing > 0 then
				table.insert(lines, "")
			end
		end
	end
	return { source = table.concat(lines, "\n"), inserted = #pending, replaced = replaced, where = where }
end

-- writes into a script in Studio as one undoable change.
const function apply(script: LuaSourceContainer, items: { Item }, replace: boolean?): Result
	const ScriptEditorService = game:GetService("ScriptEditorService")
	const ChangeHistoryService = game:GetService("ChangeHistoryService")
	const recording = ChangeHistoryService:TryBeginRecording("Prism: insert template")
	local result: Result? = nil
	const ok, problem = pcall(function()
		ScriptEditorService:UpdateSourceAsync(script, function(old: string): string
			result = insert(old, items, replace)
			return (result :: Result).source
		end)
	end)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		error(problem, 0)
	end
	return result :: Result
end

return {
	insert = insert,
	apply = apply,
}
