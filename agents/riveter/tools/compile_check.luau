--!strict
-- compile_check.luau — real Luau compilation of every game script, taken from BOTH the source
-- tree and the exported place (so a stale export cannot hide a broken file).
-- Writes evidence/compile-report.json and exits non-zero on any failure.

local fs = require("@lune/fs")
local process = require("@lune/process")
local luau = require("@lune/luau")

local ROOT = process.cwd
local AGENT = ROOT .. "/agents/riveter"

local targets: { { path: string, source: string, origin: string } } = {}

local function collect(dir: string, origin: string)
	for _, entry in ipairs(fs.readDir(dir)) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			collect(full, origin)
		elseif string.match(entry, "%.luau$") then
			table.insert(targets, { path = full, source = fs.readFile(full), origin = origin })
		end
	end
end

collect(AGENT .. "/src", "source-tree")

-- Also pull the scripts out of the built place so export/script drift is caught here.
local hasPlace, roblox = pcall(require, "@lune/roblox")
if hasPlace and fs.isFile(AGENT .. "/releases/FLOODLINE.rbxlx") then
	local place = roblox.deserializePlace(fs.readFile(AGENT .. "/releases/FLOODLINE.rbxlx"))
	local function scan(instance: Instance)
		if instance:IsA("Script") or instance:IsA("LocalScript") or instance:IsA("ModuleScript") then
			table.insert(targets, {
				path = instance:GetFullName(),
				source = instance.Source or "",
				origin = "exported-place",
			})
		end
		for _, child in ipairs(instance:GetChildren()) do
			scan(child)
		end
	end
	scan(place)
end

local results = {}
local failures = 0
for _, target in ipairs(targets) do
	local success, bytecode = pcall(function()
		return luau.compile(target.source)
	end)
	local compiled = success and bytecode ~= nil
	local entry = {
		path = target.path,
		origin = target.origin,
		bytes = #target.source,
		lines = select(2, string.gsub(target.source, "\n", "")) + 1,
		compiled = compiled,
		error = nil,
	}
	if not compiled then
		entry.error = tostring(bytecode)
	end
	if not compiled then
		failures += 1
	end
	table.insert(results, entry)
end

table.sort(results, function(a, b)
	if a.origin ~= b.origin then
		return a.origin < b.origin
	end
	return a.path < b.path
end)

local lines = { "{" }
table.insert(lines, string.format('  "checked": %d,', #results))
table.insert(lines, string.format('  "failures": %d,', failures))
table.insert(lines, '  "scripts": [')
local rows = {}
for _, entry in ipairs(results) do
	table.insert(rows, string.format(
		'    { "path": "%s", "origin": "%s", "lines": %d, "compiled": %s%s }',
		entry.path, entry.origin, entry.lines, tostring(entry.compiled),
		entry.error and (', "error": "' .. (entry.error:gsub('"', "'"):gsub("\n", " ")) .. '"') or ""
	))
end
table.insert(lines, table.concat(rows, ",\n"))
table.insert(lines, "  ]")
table.insert(lines, "}")
fs.writeFile(AGENT .. "/evidence/compile-report.json", table.concat(lines, "\n") .. "\n")

for _, entry in ipairs(results) do
	local status = entry.compiled and "OK  " or "FAIL"
	print(string.format("[%s] %-58s %4d lines (%s)", status, entry.path, entry.lines, entry.origin))
	if entry.error then
		print("        " .. entry.error)
	end
end
print(string.format("compiled %d scripts, %d failures", #results, failures))
if failures > 0 then
	process.exit(1)
end
