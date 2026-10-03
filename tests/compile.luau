-- Run with: lune run tests/compile.luau
-- Studio supports const; stock Luau needs local. Catches syntax errors in every plugin file.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local failed = false
local function walk(dir)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path)
		elseif name:match("%.luau$") and name ~= "vide.luau" then
			local code = fs.readFile(path):gsub("%f[%w]const%f[%W]", "local")
			local ok, err = pcall(luau.compile, code)
			if not ok then
				failed = true
				print("FAIL", path, err)
			end
		end
	end
end
walk("src")
print(if failed then "compile errors" else "all plugin files compile")
process.exit(if failed then 1 else 0)
