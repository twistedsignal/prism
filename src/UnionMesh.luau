-- Union render meshes live in serialized RBXM shared strings, not readable properties.
-- Format reference: EgoMoose/rbx-csg-to-mesh-plugin (MIT), krakow10/rbx_mesh.
--[[
MIT License

Copyright (c) 2025 EgoMoose

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

]]
const Base64 = require("./Base64")
const GeometryService = game:GetService("GeometryService")
const SerializationService = game:GetService("SerializationService")
const EncodingService = game:GetService("EncodingService")

const MAX_BYTES = 128 * 1024 * 1024
const MAX_ITEMS = 600000
const LEGACY_HEADER = "\x15\x7d\x29\x15\x75\x6c\x35\x04\x34\x69"
const SOLID_HEADER = "SolidMesh\x00\x00\x00\x00"

const function reader(data: buffer)
	local offset = 0
	const function take(length: number): number
		assert(length >= 0 and offset + length <= buffer.len(data), "Truncated union data")
		const start = offset
		offset += length
		return start
	end
	return {
		u8 = function() return buffer.readu8(data, take(1)) end,
		u16 = function() return buffer.readu16(data, take(2)) end,
		i16 = function() return buffer.readi16(data, take(2)) end,
		u32 = function() return buffer.readu32(data, take(4)) end,
		f32 = function()
			const value = buffer.readf32(data, take(4))
			assert(value == value and math.abs(value) < math.huge, "Non-finite union attribute")
			return value
		end,
		string = function(length: number) return buffer.readstring(data, take(length), length) end,
		skip = function(length: number) take(length) end,
	}
end

const function count(value: number): number
	assert(value <= MAX_ITEMS, "Union exceeds geometry limit")
	return value
end

-- RBXM's older chunks use raw LZ4 blocks. Newer chunks may use Zstd frames.
const function lz4(data: buffer, length: number): buffer
	const input = reader(data)
	const output = buffer.create(length)
	local written = 0
	local consumed = 0
	const function byte(): number
		consumed += 1
		return input.u8()
	end
	const function extended(value: number): number
		if value == 15 then
			local nextByte = 255
			while nextByte == 255 do
				nextByte = byte()
				value += nextByte
			end
		end
		return value
	end
	while consumed < buffer.len(data) do
		const token = byte()
		const literals = extended(bit32.rshift(token, 4))
		assert(written + literals <= length, "Invalid LZ4 literal length")
		for _ = 1, literals do
			buffer.writeu8(output, written, byte())
			written += 1
		end
		if consumed == buffer.len(data) then break end
		const low = byte()
		const distance = low + byte() * 256
		assert(distance > 0 and distance <= written, "Invalid LZ4 match offset")
		const matches = extended(bit32.band(token, 15)) + 4
		assert(written + matches <= length, "Invalid LZ4 match length")
		for _ = 1, matches do
			buffer.writeu8(output, written, buffer.readu8(output, written - distance))
			written += 1
		end
	end
	assert(written == length, "Invalid LZ4 output length")
	return output
end

const function format(data: buffer): string?
	if buffer.len(data) >= 27 and buffer.readstring(data, 14, #SOLID_HEADER) == SOLID_HEADER then
		return "solid"
	end
	if buffer.len(data) >= #LEGACY_HEADER and buffer.readstring(data, 0, #LEGACY_HEADER) == LEGACY_HEADER then
		return "legacy"
	end
	return nil
end

const function extract(data: buffer): buffer
	assert(buffer.len(data) <= MAX_BYTES, "Serialized union exceeds 128 MB")
	const stream = reader(data)
	assert(stream.string(14) == "<roblox!\x89\xff\x0d\x0a\x1a\x0a", "Invalid RBXM header")
	assert(stream.u16() == 0, "Unsupported RBXM version")
	stream.skip(16)
	local total = 0
	while true do
		const kind = stream.string(4)
		const compressed, uncompressed = stream.u32(), stream.u32()
		stream.skip(4)
		assert(compressed <= MAX_BYTES and uncompressed <= MAX_BYTES, "RBXM chunk exceeds 128 MB")
		if kind == "END\0" then break end
		const content = stream.string(if compressed > 0 then compressed else uncompressed)
		if kind ~= "SSTR" then continue end
		total += uncompressed
		assert(total <= MAX_BYTES, "Shared strings exceed 128 MB")
		local chunk = buffer.fromstring(content)
		if compressed > 0 then
			chunk = if #content >= 4 and string.sub(content, 1, 4) == "\x28\xb5\x2f\xfd"
				then EncodingService:DecompressBuffer(chunk, Enum.CompressionAlgorithm.Zstd)
				else lz4(chunk, uncompressed)
		end
		assert(buffer.len(chunk) == uncompressed, "Invalid RBXM chunk length")
		const strings = reader(chunk)
		assert(strings.u32() == 0, "Unsupported shared string version")
		const nStrings = count(strings.u32())
		for _ = 1, nStrings do
			strings.skip(16)
			const length = strings.u32()
			assert(length <= MAX_BYTES, "Shared string exceeds 128 MB")
			const candidate = buffer.fromstring(strings.string(length))
			if format(candidate) then return candidate end
		end
	end
	error("Serialized union has no supported render mesh")
end

const function indices(stream: any, n: number): { number }
	const result = table.create(count(n))
	local index = 0
	for i = 1, n do
		const first = stream.u8()
		if bit32.band(first, 128) == 0 then
			index += if bit32.band(first, 64) == 0 then first else first - 128
		else
			const second, third = stream.u8(), stream.u8()
			index += bit32.bor(bit32.lshift(bit32.band(first, 127), 16), bit32.lshift(second, 8), third)
		end
		result[i] = bit32.band(index, 0x7fffff) + 1
	end
	return result
end

const function vectors(stream: any, n: number, width: number): { { number } }
	const result = table.create(count(n))
	for i = 1, n do
		const value = table.create(width)
		for j = 1, width do
			value[j] = stream.f32()
		end
		result[i] = value
	end
	return result
end

const function parse(data: buffer, useColors: boolean): { [string]: any }
	const kind = format(data)
	assert(kind, "Unsupported union mesh format")
	const stream = reader(data)
	local positions, normals, colors, uvs, faces, faceNormals, faceColors
	if kind == "solid" then
		stream.skip(27)
		const function section(width: number)
			const n = count(stream.u32())
			stream.skip(4)
			return vectors(stream, n, width)
		end
		positions = section(3)
		normals = section(3)
		const unknown = section(2)
		assert(#unknown == 0, "Unsupported SolidMesh UV attributes")
		colors = section(3)
		const function indexSection()
			const n = count(stream.u32())
			stream.skip(4)
			return indices(stream, n)
		end
		faces = indexSection()
		faceNormals = indexSection()
		assert(#indexSection() == 0, "Unsupported SolidMesh UV indices")
		faceColors = indexSection()
	else
		stream.skip(10)
		positions = vectors(stream, stream.u16(), 3)
		const nNormals = stream.u16()
		assert(stream.u32() == nNormals * 6, "Invalid union normal buffer")
		normals = {}
		for i = 1, nNormals do
			local value = {}
			for j = 1, 3 do
				value[j] = ((stream.i16() - 32767 + 32768) % 65536 - 32768) / 32767
			end
			normals[i] = value
		end
		colors = {}
		const nColors = stream.u16()
		for i = 1, nColors do
			colors[i] = { stream.u8() / 255, stream.u8() / 255, stream.u8() / 255 }
			stream.skip(1)
		end
		stream.skip(stream.u16()) -- NormalId face projections.
		uvs = vectors(stream, stream.u16(), 2)
		const nTangents = stream.u16()
		assert(stream.u32() == nTangents * 6, "Invalid union tangent buffer")
		stream.skip(nTangents * 6)
		const nFaces, nBytes = count(stream.u32()), stream.u32()
		assert(nBytes <= MAX_BYTES, "Union index data exceeds 128 MB")
		const encoded = reader(buffer.fromstring(stream.string(nBytes)))
		const nMarkers = stream.u8()
		assert(nMarkers >= 2, "Missing union range markers")
		const markers = {}
		for i = 1, nMarkers do
			markers[i] = stream.u32()
		end
		const all = indices(encoded, nFaces)
		const first = markers[1]
		const last = if nMarkers >= 3 then #all else #all - (markers[2] - first)
		assert(first <= last and last <= #all and markers[2] >= first, "Invalid union ranges")
		faces = {}
		for i = first + 1, last do
			table.insert(faces, all[i])
		end
		faceNormals, faceColors = faces, faces
	end
	assert(#positions > 0, "Union has no positions")
	assert(#faces > 0 and #faces % 3 == 0, "Union has no complete triangles")
	assert(#faceNormals == #faces or #normals == 0, "Invalid union normal indices")
	assert(not useColors or #colors == 0 or #faceColors == #faces, "Invalid union color indices")
	const function pack(values: any, ids: any, width: number): string?
		if values == nil or #values == 0 then return nil end
		const output = buffer.create(#faces * width * 4)
		for i, id in ids do
			const value = values[id]
			assert(value, "Union index is out of bounds")
			for axis = 1, width do
				buffer.writef32(output, ((i - 1) * width + axis - 1) * 4, value[axis])
			end
			if i % 3000 == 0 then
				task.wait()
			end
		end
		return Base64.encode(output)
	end
	return {
		positions = pack(positions, faces, 3),
		normals = pack(normals, faceNormals, 3),
		uvs = pack(uvs, faces, 2),
		colors = if useColors then pack(colors, faceColors, 3) else nil,
		center = true,
	}
end

const function read(part: PartOperation): ({ [string]: any }?, CFrame?, string?)
	local temporary: any = nil
	local results: { any } = {}
	const ok, result = pcall(function()
		results = GeometryService:UnionAsync(part, {}, {
			SplitApart = false,
			CollisionFidelity = part.CollisionFidelity,
			RenderFidelity = part.RenderFidelity,
			FluidFidelity = part.FluidFidelity,
		})
		assert(#results == 1 and results[1]:IsA("PartOperation"), "Union did not produce one PartOperation")
		temporary = results[1]
		const data = parse(extract(SerializationService:SerializeInstancesAsync({ temporary })), not part.UsePartColor)
		const sourceSize = temporary.MeshSize
		data.scale = {
			if sourceSize.X > 0 then temporary.Size.X / sourceSize.X else 1,
			if sourceSize.Y > 0 then temporary.Size.Y / sourceSize.Y else 1,
			if sourceSize.Z > 0 then temporary.Size.Z / sourceSize.Z else 1,
		}
		return { mesh = data, cframe = temporary.CFrame }
	end)
	for _, instance in results do
		instance:Destroy()
	end
	if ok then return result.mesh, result.cframe, nil end
	return nil, nil, tostring(result)
end

return { read = read, extract = extract, parse = parse }
