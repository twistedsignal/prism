-- decides whether a setting or group with a schema "requires" is shown.
-- "key" needs that setting on (bool), non-zero (number) or non-empty (text); "!key" inverts it.

const function met(requires: string?, settings: { [string]: any }): boolean
	if requires == nil then
		return true
	end
	local key = requires
	local invert = false
	if string.sub(key, 1, 1) == "!" then
		invert = true
		key = string.sub(key, 2)
	end
	const value = settings[key]
	local truthy = false
	if type(value) == "boolean" then
		truthy = value
	elseif type(value) == "number" then
		truthy = value ~= 0
	elseif type(value) == "string" then
		truthy = string.match(value, "%S") ~= nil
	end
	return truthy ~= invert
end

return {
	met = met,
}
