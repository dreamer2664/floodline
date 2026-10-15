-- Toolchain integration fixture ONLY. This is NOT the commissioned game.
local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local process = require("@lune/process")
local out = process.env.FLOODLINE_PROBE_DIR
assert(out and #out > 0, "Set FLOODLINE_PROBE_DIR to a disposable cache folder")
fs.writeDir(out)
local Instance = roblox.Instance
local Vector3 = roblox.Vector3
local Color3 = roblox.Color3
local model = Instance.new("Model")
model.Name = "TOOLCHAIN_FIXTURE_NOT_THE_GAME"
local floor = Instance.new("Part")
floor.Name = "BakedFloor"
floor.Anchored = true
floor.Size = Vector3.new(40, 2, 40)
floor.Position = Vector3.new(0, -1, 0)
floor.Color = Color3.fromRGB(28, 46, 58)
floor.Parent = model
local spawn = Instance.new("SpawnLocation")
spawn.Name = "ProbeSpawn"
spawn.Anchored = true
spawn.Size = Vector3.new(6, 1, 6)
spawn.Position = Vector3.new(0, 0.5, 0)
spawn.Parent = model
fs.writeFile(out .. "/fixture.rbxmx", roblox.serializeModel({model}, true))
fs.writeFile(out .. "/Probe.server.luau", 'print("TOOLCHAIN FIXTURE: export/parse proof, NOT a game or Studio playtest")\n')
fs.writeFile(out .. "/default.project.json", '{"name":"TOOLCHAIN_FIXTURE_NOT_A_GAME","tree":{"$className":"DataModel","Workspace":{"$className":"Workspace","Fixture":{"$path":"fixture.rbxmx"}},"ServerScriptService":{"$className":"ServerScriptService","Probe":{"$path":"Probe.server.luau"}}}}')
print("Wrote disposable Rojo inputs; build and round-trip verification happen next.")
