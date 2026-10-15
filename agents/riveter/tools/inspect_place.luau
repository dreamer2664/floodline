--!strict
-- inspect_place.luau — structural evidence for the exported place.
-- Reads FLOODLINE.rbxlx, walks the DataModel and writes evidence/place-structure.json.
-- Run from the repository root:  lune run agents/riveter/tools/inspect_place.luau

local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local process = require("@lune/process")

local ROOT = process.cwd
local AGENT = ROOT .. "/agents/riveter"
local PLACE = AGENT .. "/releases/FLOODLINE.rbxlx"

local place = roblox.deserializePlace(fs.readFile(PLACE))

local out: any = {
	classes = {},
	parts = 0,
	trusses = 0,
	seats = 0,
	spawns = 0,
	prompts = 0,
	scripts = {},
	names = {},
	promptParents = {},
	placeBytes = #fs.readFile(PLACE),
	placeName = place.Name,
}

local function walk(instance: Instance, depth: number)
	local class = instance.ClassName
	out.classes[class] = (out.classes[class] or 0) + 1
	if instance:IsA("BasePart") then
		out.parts += 1
		if instance:IsA("TrussPart") then
			out.trusses += 1
		end
		if instance:IsA("Seat") then
			out.seats += 1
		end
	end
	if instance:IsA("SpawnLocation") then
		out.spawns += 1
	end
	if instance:IsA("ProximityPrompt") then
		out.prompts += 1
		local parent = instance.Parent
		if parent then
			local key = parent.ClassName .. ":" .. parent.Name
			out.promptParents[key] = (out.promptParents[key] or 0) + 1
		end
	end
	if instance:IsA("BasePart") or instance:IsA("Model") then
		out.names[instance.Name] = (out.names[instance.Name] or 0) + 1
	end
	if instance:IsA("Script") or instance:IsA("LocalScript") or instance:IsA("ModuleScript") then
		local source = instance.Source or ""
		table.insert(out.scripts, {
			path = instance:GetFullName(),
			class = class,
			bytes = #source,
			lines = select(2, string.gsub(source, "\n", "")) + 1,
		})
	end
	for _, child in ipairs(instance:GetChildren()) do
		walk(child, depth + 1)
	end
end

walk(place, 0)
table.sort(out.scripts, function(a, b)
	return a.path < b.path
end)

local workspace = place:FindFirstChild("Workspace")
local world = workspace and workspace:FindFirstChild("World")
local required = {
	"Terminal", "PumpHouse", "ApartmentBlock", "Workshop", "Clinic", "RelayTower",
	"BridgeGate", "SafeZone", "SpawnLocation", "EvacLift", "ExtractionPad", "Cells", "Survivors",
	"Socket_Pump", "Socket_Bridge", "Socket_Lift", "Charger", "Valve", "RelaySlot", "RelayFuse",
	"Medkit1", "Medkit2", "Medkit3", "Radio", "EvacConsole", "LiftCallTop", "LiveCable1", "LiveCable2",
}
local found: { [string]: boolean } = {}
if world then
	for _, descendant in ipairs(world:GetDescendants()) do
		found[descendant.Name] = true
	end
end
local missing = {}
for _, name in ipairs(required) do
	if not found[name] then
		table.insert(missing, name)
	end
end

local function jsonEscape(value: string): string
	return (value:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local lines = { "{" }
table.insert(lines, `  "placeName": "{jsonEscape(out.placeName)}",`)
table.insert(lines, `  "placeBytes": {out.placeBytes},`)
table.insert(lines, `  "parts": {out.parts},`)
table.insert(lines, `  "trusses": {out.trusses},`)
table.insert(lines, `  "seats": {out.seats},`)
table.insert(lines, `  "spawns": {out.spawns},`)
table.insert(lines, `  "prompts": {out.prompts},`)
table.insert(lines, string.format('  "scriptCount": %d,', #out.scripts))
table.insert(lines, string.format('  "scriptLines": %d,', (function()
	local total = 0
	for _, entry in ipairs(out.scripts) do
		total += entry.lines
	end
	return total
end)()))
table.insert(lines, '  "scripts": [')
local scriptLines = {}
for _, entry in ipairs(out.scripts) do
	table.insert(scriptLines, string.format(
		'    { "path": "%s", "class": "%s", "bytes": %d, "lines": %d }',
		jsonEscape(entry.path), entry.class, entry.bytes, entry.lines
	))
end
table.insert(lines, table.concat(scriptLines, ",\n"))
table.insert(lines, "  ],")
table.insert(lines, '  "classes": {')
local classKeys = {}
for key in pairs(out.classes) do
	table.insert(classKeys, key)
end
table.sort(classKeys)
local classLines = {}
for _, key in ipairs(classKeys) do
	table.insert(classLines, string.format('    "%s": %d', jsonEscape(key), out.classes[key]))
end
table.insert(lines, table.concat(classLines, ",\n"))
table.insert(lines, "  },")
local missingLines = {}
for _, name in ipairs(missing) do
	table.insert(missingLines, `"{jsonEscape(name)}"`)
end
table.insert(lines, '  "missingFeatures": [' .. table.concat(missingLines, ", ") .. "],")
local nameKeys = {}
for key in pairs(out.names) do
	table.insert(nameKeys, key)
end
table.sort(nameKeys)
local nameLines = {}
for _, key in ipairs(nameKeys) do
	table.insert(nameLines, string.format('    "%s": %d', jsonEscape(key), out.names[key]))
end
table.insert(lines, '  "names": {')
table.insert(lines, table.concat(nameLines, ",\n"))
table.insert(lines, "  },")
local promptKeys = {}
for key in pairs(out.promptParents) do
	table.insert(promptKeys, key)
end
table.sort(promptKeys)
local promptLines = {}
for _, key in ipairs(promptKeys) do
	table.insert(promptLines, string.format('    "%s": %d', jsonEscape(key), out.promptParents[key]))
end
table.insert(lines, '  "promptParents": {')
table.insert(lines, table.concat(promptLines, ",\n"))
table.insert(lines, "  }")
table.insert(lines, "}")

fs.writeFile(AGENT .. "/evidence/place-structure.json", table.concat(lines, "\n") .. "\n")

print(`place bytes: {out.placeBytes}`)
print(string.format("parts: %d  trusses: %d  seats: %d  prompts: %d  spawns: %d",
	out.parts, out.trusses, out.seats, out.prompts, out.spawns))
print(`scripts: {#out.scripts}`)
for _, entry in ipairs(out.scripts) do
	print(string.format("  %-13s %5d lines  %s", entry.class, entry.lines, entry.path))
end
if #missing > 0 then
	print("MISSING: " .. table.concat(missing, ", "))
	process.exit(1)
end
print("structure OK")
