-- Run with: lune run tests/requirements.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local code = fs.readFile("src/Requirements.luau"):gsub("%f[%w]const%f[%W]", "local")
local Requirements = luau.load(code)()
local met = Requirements.met

assert(met(nil, {}), "No requirement must always show")
assert(met("xray", { xray = true }) and not met("xray", { xray = false }), "Bools gate their settings")
assert(not met("xray", {}), "Missing settings count as off")
assert(met("outlineSize", { outlineSize = 3 }) and not met("outlineSize", { outlineSize = 0 }), "Numbers gate on non-zero")
assert(met("text", { text = "Hi" }) and not met("text", { text = "  " }), "Text gates on non-blank")
assert(met("!orthographic", { orthographic = false }) and not met("!orthographic", { orthographic = true }), "! inverts")

print("Setting visibility requirement checks passed")
