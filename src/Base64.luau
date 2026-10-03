-- base64 for buffers. prefers EncodingService and falls back to luau.
const EncodingService = (function(): any
	const ok, service = pcall(function()
		return game:GetService("EncodingService" :: any)
	end)
	return if ok then service else nil
end)()

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const ENCODE = buffer.create(64)
const DECODE = buffer.create(256)
buffer.fill(DECODE, 0, 255)
for i = 1, 64 do
	const byte = string.byte(ALPHABET, i)
	buffer.writeu8(ENCODE, i - 1, byte)
	buffer.writeu8(DECODE, byte, i - 1)
end

const function encodeLuau(input: buffer): string
	const length = buffer.len(input)
	const output = buffer.create(math.ceil(length / 3) * 4)
	local o = 0
	for i = 0, length - 3, 3 do
		const chunk = bit32.bor(
			bit32.lshift(buffer.readu8(input, i), 16),
			bit32.lshift(buffer.readu8(input, i + 1), 8),
			buffer.readu8(input, i + 2)
		)
		buffer.writeu8(output, o, buffer.readu8(ENCODE, bit32.extract(chunk, 18, 6)))
		buffer.writeu8(output, o + 1, buffer.readu8(ENCODE, bit32.extract(chunk, 12, 6)))
		buffer.writeu8(output, o + 2, buffer.readu8(ENCODE, bit32.extract(chunk, 6, 6)))
		buffer.writeu8(output, o + 3, buffer.readu8(ENCODE, bit32.extract(chunk, 0, 6)))
		o += 4
	end
	const remaining = length % 3
	if remaining > 0 then
		const start = length - remaining
		local chunk = bit32.lshift(buffer.readu8(input, start), 16)
		if remaining == 2 then
			chunk = bit32.bor(chunk, bit32.lshift(buffer.readu8(input, start + 1), 8))
		end
		buffer.writeu8(output, o, buffer.readu8(ENCODE, bit32.extract(chunk, 18, 6)))
		buffer.writeu8(output, o + 1, buffer.readu8(ENCODE, bit32.extract(chunk, 12, 6)))
		buffer.writeu8(output, o + 2, if remaining == 2 then buffer.readu8(ENCODE, bit32.extract(chunk, 6, 6)) else 61)
		buffer.writeu8(output, o + 3, 61)
	end
	return buffer.tostring(output)
end

const function decodeLuau(input: string): buffer
	const source = buffer.fromstring(input)
	local length = buffer.len(source)
	while length > 0 and buffer.readu8(source, length - 1) == 61 do
		length -= 1
	end
	const output = buffer.create(length * 3 // 4)
	local o = 0
	local accumulator = 0
	local bits = 0
	for i = 0, length - 1 do
		const value = buffer.readu8(DECODE, buffer.readu8(source, i))
		if value == 255 then
			continue
		end
		accumulator = bit32.bor(bit32.lshift(bit32.band(accumulator, 0xFFFF), 6), value)
		bits += 6
		if bits >= 8 then
			bits -= 8
			if o < buffer.len(output) then
				buffer.writeu8(output, o, bit32.extract(accumulator, bits, 8))
				o += 1
			end
		end
	end
	return output
end

const Base64 = {}

function Base64.encode(input: buffer): string
	if EncodingService then
		const ok, result = pcall(function()
			return buffer.tostring(EncodingService:Base64Encode(input))
		end)
		if ok then
			return result
		end
	end
	return encodeLuau(input)
end

function Base64.decode(input: string): buffer
	if EncodingService then
		const ok, result = pcall(function()
			return EncodingService:Base64Decode(buffer.fromstring(input))
		end)
		if ok then
			return result
		end
	end
	return decodeLuau(input)
end

return Base64
