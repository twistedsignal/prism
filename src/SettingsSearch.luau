-- Match every search word literally, regardless of case or surrounding whitespace.
const function matches(query: string, text: string): boolean
	const haystack = string.lower(text)
	for word in string.gmatch(string.lower(query), "%S+") do
		if not string.find(haystack, word, 1, true) then
			return false
		end
	end
	return true
end

return { matches = matches }
