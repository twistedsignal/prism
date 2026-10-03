local fs = require('@lune/fs')
local luau = require('@lune/luau')
local roblox = require('@lune/roblox')
local function load(path, environment)
    return luau.load(fs.readFile(path):gsub('%f[%w]const%f[%W]', 'local'), { environment = environment })()
end
local base64 = load('src/Base64.luau', { game = { GetService = function() return nil end } })
local services = {}
local mesh = load('src/UnionMesh.luau', {
    require = function() return base64 end,
    game = { GetService = function(_, name) return services[name] end },
    task = { wait = function() end },
    Enum = { CompressionAlgorithm = { Zstd = 'Zstd' } },
})
local function number(value, width, writer)
    local b = buffer.create(width)
    writer(b, 0, value)
    return buffer.tostring(b)
end
local u32 = function(v) return number(v, 4, buffer.writeu32) end
local u16 = function(v) return number(v, 2, buffer.writeu16) end
local i16 = function(v) return number(v, 2, buffer.writei16) end
local f32 = function(v) return number(v, 4, buffer.writef32) end
local function floats(values)
    local out = {}
    for _, v in values do table.insert(out, f32(v)) end
    return table.concat(out)
end
local positions = floats({10, 20, 30, 12, 20, 30, 10, 23, 30})
local colors = floats({1, 0, 0, 0, 1, 0, 0, 0, 1})
local function section(count, values) return u32(count) .. u32(0) .. values end
local solid = string.rep('\0', 14) .. 'SolidMesh\0\0\0\0'
    .. section(3, positions) .. section(1, floats({0, 0, 1}))
    .. section(0, '') .. section(3, colors)
    .. section(3, '\0\1\1') .. section(3, '\0\0\0')
    .. section(0, '') .. section(3, '\0\1\1')
local legacy = '\x15\x7d\x29\x15\x75\x6c\x35\x04\x34\x69'
    .. u16(3) .. positions .. u16(3) .. u32(18)
    .. string.rep(i16(32767) .. i16(32767) .. i16(-2), 3)
    .. u16(3) .. '\xff\0\0\xff\0\xff\0\xff\0\0\xff\xff'
    .. u16(0) .. u16(3) .. floats({0, 0, 1, 0, 0, 1})
    .. u16(0) .. u32(0) .. u32(3) .. u32(3) .. '\0\1\1'
    .. '\2' .. u32(0) .. u32(0)
for _, data in {solid, legacy} do
    local decoded = mesh.parse(buffer.fromstring(data), true)
    local p = base64.decode(decoded.positions)
    assert(buffer.readf32(p, 0) == 10 and buffer.readf32(p, 32) == 30)
    local n = base64.decode(decoded.normals)
    assert(buffer.readf32(n, 8) == 1 and buffer.readf32(n, 0) == 0)
    local c = base64.decode(decoded.colors)
    assert(buffer.readf32(c, 0) == 1 and buffer.readf32(c, 16) == 1 and buffer.readf32(c, 32) == 1)
    assert(mesh.parse(buffer.fromstring(data), false).colors == nil, 'UsePartColor ignores stored colors')
    assert(not pcall(mesh.parse, buffer.fromstring(data:sub(1, -2)), true), 'Truncated data must fail')
end
local function chunk(kind, content, uncompressed)
    return kind .. u32(if uncompressed then #content else 0) .. u32(uncompressed or #content) .. u32(0) .. content
end
local function model(content, uncompressed)
    return buffer.fromstring('<roblox!\x89\xff\x0d\x0a\x1a\x0a' .. u16(0) .. string.rep('\0', 16)
        .. chunk('JUNK', 'ignored') .. chunk('SSTR', content, uncompressed) .. chunk('END\0', ''))
end
-- Find the mesh by signature, even when unrelated shared strings precede it.
local strings = u32(0) .. u32(2) .. string.rep('\0', 16) .. u32(3) .. 'abc'
    .. string.rep('\0', 16) .. u32(#solid) .. solid
assert(buffer.tostring(mesh.extract(model(strings))) == solid)
local function literals(data)
    local length = #data - 15
    local bytes = {'\xf0'}
    while length >= 255 do table.insert(bytes, '\xff'); length -= 255 end
    table.insert(bytes, string.char(length))
    table.insert(bytes, data)
    return table.concat(bytes)
end
assert(buffer.tostring(mesh.extract(model(literals(strings), #strings))) == solid, 'LZ4 literals')
-- LZ4 overlapping matches produce the repeated bytes inside an unrelated shared string.
local zeros = u32(0) .. u32(1) .. string.rep('\0', 16) .. u32(#solid) .. solid
local compressed = '\xaa' .. zeros:sub(1, 10) .. '\1\0' .. literals(zeros:sub(25))
assert(buffer.tostring(mesh.extract(model(compressed, #zeros))) == solid, 'LZ4 overlapping match')
services.EncodingService = { DecompressBuffer = function(_, _, algorithm)
    assert(algorithm == 'Zstd')
    return buffer.fromstring(strings)
end }
-- The service is captured at module load, so reload for the Zstd test.
local zstdMesh = load('src/UnionMesh.luau', {
    require = function() return base64 end,
    game = { GetService = function(_, name) return services[name] end },
    Enum = { CompressionAlgorithm = { Zstd = 'Zstd' } },
})
assert(buffer.tostring(zstdMesh.extract(model('\x28\xb5\x2f\xfd', #strings))) == solid)
for _, bad in {'', solid:sub(1, 20), solid:sub(1, 27) .. u32(600001), string.rep('\0', 100)} do
    assert(not pcall(mesh.parse, buffer.fromstring(bad), true))
end
local unknown = solid:sub(1, 27) .. section(3, positions) .. section(1, floats({0,0,1})) .. section(1, floats({0,0}))
assert(not pcall(mesh.parse, buffer.fromstring(unknown), true))

local destroyed = 0
local source = { UsePartColor = false, CFrame = roblox.CFrame.identity }
local temporary = {
    CFrame = roblox.CFrame.new(1, 2, 3), MeshSize = roblox.Vector3.new(2, 3, 1),
    Size = roblox.Vector3.new(4, 9, 1),
    IsA = function(_, class) return class == 'PartOperation' end,
    Destroy = function() destroyed += 1 end,
}
services.GeometryService = { UnionAsync = function(_, input, others, options)
    assert(input == source and #others == 0 and options.SplitApart == false)
    return {temporary}
end }
local failSerialization = false
services.SerializationService = { SerializeInstancesAsync = function(_, instances)
    assert(instances[1] == temporary)
    if failSerialization then error('Fixture failure') end
    return model(strings)
end }
local live = load('src/UnionMesh.luau', {
    require = function() return base64 end,
    game = { GetService = function(_, name) return services[name] end },
    task = { wait = function() end },
})
local data, cframe = live.read(source)
assert(data.scale[1] == 2 and data.scale[2] == 3 and cframe == temporary.CFrame)
assert(source.CFrame == roblox.CFrame.identity and destroyed == 1)
failSerialization = true
local failed, _, problem = live.read(source)
assert(failed == nil and problem:find('Fixture failure') and destroyed == 2, 'Failures clean up temporary geometry')
print('Union formats, colors, RBXM compression, transforms and cleanup checks passed')

-- The serializer uses the extracted transform, keeps material/decal handling, and warns on failure.
local plastic = { Name = 'Plastic' }
local failure = false
local unionPart = {
    Name = 'Union', Transparency = 0.25, Color = roblox.Color3.new(1, 0, 0),
    Material = plastic, MaterialVariant = '', Size = roblox.Vector3.new(4, 9, 1),
    CFrame = roblox.CFrame.new(10, 0, 0),
    IsA = function(_, class) return class == 'BasePart' or class == 'PartOperation' or class == 'PVInstance' end,
    GetDescendants = function() return {} end, GetChildren = function() return {} end,
    FindFirstChildWhichIsA = function() return nil end,
    GetPivot = function() return roblox.CFrame.new(5, 0, 0) end,
}
local serializer = load('src/Serializer.luau', {
    require = function(name)
        if name == './UnionMesh' then
            return { read = function(input)
                assert(input == unionPart)
                if failure then return nil, nil, 'unsupported format' end
                return data, roblox.CFrame.new(11, 0, 0)
            end }
        end
        return base64
    end,
    game = { GetService = function() return {} end },
    Enum = { Material = { Plastic = plastic, SmoothPlastic = {} }, PartType = {
        Block = 'Block', Ball = 'Ball', Cylinder = 'Cylinder', Wedge = 'Wedge', CornerWedge = 'CornerWedge',
    }, MeshType = { Brick = 'Brick', Sphere = 'Sphere', Cylinder = 'Cylinder', Wedge = 'Wedge', Head = 'Head' } },
})
local serialized = serializer.serialize(unionPart)
local entry = serialized.payload.parts[1]
assert(entry.kind == 'mesh' and entry.mesh == data and entry.cframe[1] == 6)
assert(entry.transparency == 0.25 and #serialized.warnings == 0)
failure = true
serialized = serializer.serialize(unionPart)
assert(serialized.payload.parts[1].kind == 'block' and #serialized.warnings == 1)
assert(serialized.warnings[1]:find('unsupported format'))
print('Union serializer and fallback checks passed')
