local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local process = require("@lune/process")

local ROOT = process.cwd
local AGENT = ROOT .. "/agents/riveter"
local GEN = AGENT .. "/generated"

if fs.isDir(GEN) then fs.removeDir(GEN) end
fs.writeDir(GEN)
fs.writeDir(GEN .. "/models")

local V3 = roblox.Vector3
local C3 = roblox.Color3
local Enum = roblox.Enum
local CF = roblox.CFrame

local function P(parent, name, size, pos, color, material, anchored, collide, transparency)
	local o = roblox.Instance.new("Part")
	o.Name = name or "Part"
	o.Size = size
	o.Position = pos
	o.Color = color or C3.fromRGB(120,120,120)
	o.Material = material or Enum.Material.Concrete
	o.Anchored = (anchored ~= false)
	if collide ~= nil then o.CanCollide = collide end
	if transparency ~= nil then o.Transparency = transparency end
	o.Parent = parent
	return o
end

local function M(parent, name)
	local m = roblox.Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function prompt(parent, action, object)
	local pr = roblox.Instance.new("ProximityPrompt")
	pr.ActionText = action
	pr.ObjectText = object or parent.Name
	pr.HoldDuration = 0.3
	pr.MaxActivationDistance = 12
	pr.Parent = parent
	return pr
end

local function writeModel(name, builder)
	local m = roblox.Instance.new("Model")
	m.Name = name
	builder(m)
	local xml = roblox.serializeModel({m}, true)
	fs.writeFile(GEN .. "/models/" .. name .. ".rbxmx", xml)
end

-- Materials/colors
local CONC = Enum.Material.Concrete
local METAL = Enum.Material.Metal
local WOOD = Enum.Material.Wood
local GLASS = Enum.Material.Glass
local C_DARK = C3.fromRGB(35,45,55)
local C_MID = C3.fromRGB(60,70,80)
local C_LIGHT = C3.fromRGB(90,100,110)
local C_SAFE = C3.fromRGB(220,150,60)
local C_WATER = C3.fromRGB(20,80,120)

-- World root model
writeModel("World", function(world)
	-- Ground
	P(world, "Ground", V3.new(140,2,140), V3.new(0,-1,0), C3.fromRGB(45,55,65), CONC, true, true, 0)
	-- Streets (slightly raised)
	P(world, "StreetNS", V3.new(8,0.3,140), V3.new(0,0.15,0), C3.fromRGB(55,60,70), CONC, true, true, 0)
	P(world, "StreetEW", V3.new(140,0.3,8), V3.new(0,0.15,0), C3.fromRGB(55,60,70), CONC, true, true, 0)

	-- SafeZone in terminal
	local safe = P(world, "SafeZone", V3.new(12,0.3,12), V3.new(0,0.15,-28), C3.fromRGB(220,150,60), Enum.Material.Neon, true, false, 0.2)
	safe:SetAttribute("Safe", true)

	-- Bridge gate
	local bridge = P(world, "BridgeGate", V3.new(10,0.5,4), V3.new(18,1.5,10), C3.fromRGB(120,60,60), METAL, true, true, 0)
	bridge:SetAttribute("Consumer", "Bridge")

	-- EvacLift
	local liftModel = M(world, "EvacLift")
	P(liftModel, "Platform", V3.new(8,0.6,8), V3.new(0,1,-30), C3.fromRGB(80,120,160), METAL, true, true, 0)
	P(liftModel, "WallN", V3.new(8,4,0.4), V3.new(0,3.3,-33.8), C3.fromRGB(80,120,160), METAL, true, true, 0)
	P(liftModel, "WallS", V3.new(8,4,0.4), V3.new(0,3.3,-26.2), C3.fromRGB(80,120,160), METAL, true, true, 0)
	P(liftModel, "WallE", V3.new(0.4,4,8), V3.new(3.8,3.3,-30), C3.fromRGB(80,120,160), METAL, true, true, 0)
	P(liftModel, "WallW", V3.new(0.4,4,8), V3.new(-3.8,3.3,-30), C3.fromRGB(80,120,160), METAL, true, true, 0)

	-- Lift call button
	local callBtn = P(world, "LiftCall", V3.new(2,2,0.5), V3.new(4,2,-24), C3.fromRGB(60,160,220), Enum.Material.Neon, true, true, 0)
	prompt(callBtn, "Call Lift", "Lift Call")

	-- 1. Evacuation Terminal
	local term = M(world, "Terminal")
	P(term, "Floor", V3.new(22,0.5,18), V3.new(0,0.25,-28), C3.fromRGB(70,75,85), CONC, true, true, 0)
	P(term, "WallN", V3.new(22,10,0.5), V3.new(0,5.25,-37), C3.fromRGB(60,65,75), CONC, true, true, 0)
	P(term, "WallS", V3.new(22,10,0.5), V3.new(0,5.25,-19), C3.fromRGB(60,65,75), CONC, true, true, 0)
	P(term, "WallE", V3.new(0.5,10,18), V3.new(11,5.25,-28), C3.fromRGB(60,65,75), CONC, true, true, 0)
	P(term, "WallW", V3.new(0.5,10,18), V3.new(-11,5.25,-28), C3.fromRGB(60,65,75), CONC, true, true, 0)
	P(term, "Roof", V3.new(22,0.5,18), V3.new(0,10.5,-28), C3.fromRGB(50,55,65), CONC, true, true, 0)
	-- door opening (no wall segment) already gap in WallS? We'll leave WallS solid but small door cut not needed
	-- sockets
	local sPump = P(term, "Socket_Pump", V3.new(1.5,1.5,1.5), V3.new(-8,1.5,-32), C3.fromRGB(200,120,40), METAL, true, true, 0)
	prompt(sPump, "Insert/Remove Cell", "Pump Socket")
	local sBridge = P(term, "Socket_Bridge", V3.new(1.5,1.5,1.5), V3.new(-5,1.5,-32), C3.fromRGB(200,120,40), METAL, true, true, 0)
	prompt(sBridge, "Insert/Remove Cell", "Bridge Socket")
	local sLift = P(term, "Socket_Lift", V3.new(1.5,1.5,1.5), V3.new(-2,1.5,-32), C3.fromRGB(200,120,40), METAL, true, true, 0)
	prompt(sLift, "Insert/Remove Cell", "Lift Socket")
	-- start button
	local sb = P(term, "StartButton", V3.new(3,2,0.5), V3.new(0,2,-20), C3.fromRGB(220,140,40), Enum.Material.Neon, true, true, 0)
	prompt(sb, "Start Round", "Start")

	-- 2. Pump House
	local pump = M(world, "PumpHouse")
	P(pump, "Floor", V3.new(14,0.5,12), V3.new(-32,0.25,-18), C3.fromRGB(60,65,75), CONC, true, true, 0)
	P(pump, "WallN", V3.new(14,8,0.5), V3.new(-32,4.25,-24), C3.fromRGB(55,60,70), CONC, true, true, 0)
	P(pump, "WallS", V3.new(14,8,0.5), V3.new(-32,4.25,-12), C3.fromRGB(55,60,70), CONC, true, true, 0)
	P(pump, "WallE", V3.new(0.5,8,12), V3.new(-25,4.25,-18), C3.fromRGB(55,60,70), CONC, true, true, 0)
	P(pump, "WallW", V3.new(0.5,8,12), V3.new(-39,4.25,-18), C3.fromRGB(55,60,70), CONC, true, true, 0)
	P(pump, "Roof", V3.new(14,0.5,12), V3.new(-32,8.5,-18), C3.fromRGB(45,50,60), CONC, true, true, 0)
	P(pump, "Pump", V3.new(4,3,4), V3.new(-32,1.75,-18), C3.fromRGB(100,110,120), METAL, true, true, 0)
	P(pump, "Pipe", V3.new(1,1,8), V3.new(-28,1.5,-18), C3.fromRGB(80,90,100), METAL, true, true, 0)

	-- 3. Apartment Block
	local apt = M(world, "ApartmentBlock")
	for f = 0, 2 do
		local y = f*3.2 + 0.25
		P(apt, "Floor"..f, V3.new(16,0.4,14), V3.new(30,y, -8), C3.fromRGB(70,72,80), CONC, true, true, 0)
	end
	P(apt, "WallN", V3.new(16,10,0.5), V3.new(30,5.2,-15), C3.fromRGB(65,68,78), CONC, true, true, 0)
	P(apt, "WallS", V3.new(16,10,0.5), V3.new(30,5.2,-1), C3.fromRGB(65,68,78), CONC, true, true, 0)
	P(apt, "WallE", V3.new(0.5,10,14), V3.new(38,5.2,-8), C3.fromRGB(65,68,78), CONC, true, true, 0)
	P(apt, "WallW", V3.new(0.5,10,14), V3.new(22,5.2,-8), C3.fromRGB(65,68,78), CONC, true, true, 0)
	P(apt, "Roof", V3.new(16,0.4,14), V3.new(30,10.6,-8), C3.fromRGB(50,52,60), CONC, true, true, 0)
	-- stairs
	for i = 0, 5 do
		P(apt, "Stair"..i, V3.new(3,0.4,1.2), V3.new(24, i*0.6+0.4, -4 + i*0.1), C3.fromRGB(80,82,90), CONC, true, true, 0)
	end
	-- rooftop route
	P(apt, "RoofAccess", V3.new(4,0.4,4), V3.new(30,11,-8), C3.fromRGB(90,92,100), CONC, true, true, 0)

	-- 4. Workshop
	local ws = M(world, "Workshop")
	P(ws, "Floor", V3.new(18,0.5,14), V3.new(-18,0.25,30), C3.fromRGB(60,62,70), CONC, true, true, 0)
	P(ws, "WallN", V3.new(18,9,0.5), V3.new(-18,4.75,23), C3.fromRGB(55,57,65), CONC, true, true, 0)
	P(ws, "WallS", V3.new(18,9,0.5), V3.new(-18,4.75,37), C3.fromRGB(55,57,65), CONC, true, true, 0)
	P(ws, "WallE", V3.new(0.5,9,14), V3.new(-9,4.75,30), C3.fromRGB(55,57,65), CONC, true, true, 0)
	P(ws, "WallW", V3.new(0.5,9,14), V3.new(-27,4.75,30), C3.fromRGB(55,57,65), CONC, true, true, 0)
	P(ws, "Roof", V3.new(18,0.5,14), V3.new(-18,9.5,30), C3.fromRGB(45,47,55), CONC, true, true, 0)
	P(ws, "Bench", V3.new(6,1,2), V3.new(-22,1,26), C3.fromRGB(90,70,50), WOOD, true, true, 0)
	P(ws, "Crate1", V3.new(2,2,2), V3.new(-12,1,34), C3.fromRGB(100,80,50), WOOD, true, true, 0)
	P(ws, "AltExit", V3.new(4,7,0.5), V3.new(-18,3.75,37.3), C3.fromRGB(90,60,40), WOOD, true, false, 0.3)

	-- 5. Clinic
	local cl = M(world, "Clinic")
	P(cl, "Floor", V3.new(14,0.5,12), V3.new(24,0.25,24), C3.fromRGB(80,82,90), CONC, true, true, 0)
	P(cl, "WallN", V3.new(14,7,0.5), V3.new(24,3.75,18), C3.fromRGB(75,78,88), CONC, true, true, 0)
	P(cl, "WallS", V3.new(14,7,0.5), V3.new(24,3.75,30), C3.fromRGB(75,78,88), CONC, true, true, 0)
	P(cl, "WallE", V3.new(0.5,7,12), V3.new(31,3.75,24), C3.fromRGB(75,78,88), CONC, true, true, 0)
	P(cl, "WallW", V3.new(0.5,7,12), V3.new(17,3.75,24), C3.fromRGB(75,78,88), CONC, true, true, 0)
	P(cl, "Roof", V3.new(14,0.5,12), V3.new(24,7.5,24), C3.fromRGB(60,62,70), CONC, true, true, 0)
	P(cl, "Bed", V3.new(4,1,2), V3.new(20,1,22), C3.fromRGB(200,200,210), Enum.Material.Fabric, true, true, 0)

	-- 6. Relay Tower
	local rt = M(world, "RelayTower")
	for i = 0, 5 do
		P(rt, "Seg"..i, V3.new(6,2,6), V3.new(0, i*2+1, -38), C3.fromRGB(70,75,85), CONC, true, true, 0)
	end
	P(rt, "Platform", V3.new(10,0.5,10), V3.new(0,13,-38), C3.fromRGB(80,85,95), CONC, true, true, 0)
	P(rt, "Antenna", V3.new(0.5,8,0.5), V3.new(0,17,-38), C3.fromRGB(200,200,200), METAL, true, true, 0)
	-- ladder
	for i = 0, 6 do
		P(rt, "Rung"..i, V3.new(2,0.2,0.2), V3.new(3.2, i*2+1, -38), C3.fromRGB(150,150,150), METAL, true, true, 0)
	end

	-- Cells
	local cells = M(world, "Cells")
	local c1 = P(cells, "Cell1", V3.new(1.2,1.2,1.2), V3.new(-32,1.5,-18), C3.fromRGB(255,200,60), Enum.Material.Neon, true, true, 0)
	prompt(c1, "Pick up Cell", "Power Cell")
	local c2 = P(cells, "Cell2", V3.new(1.2,1.2,1.2), V3.new(24,1.5,24), C3.fromRGB(255,200,60), Enum.Material.Neon, true, true, 0)
	prompt(c2, "Pick up Cell", "Power Cell")

	-- Survivors
	local survs = M(world, "Survivors")
	local function surv(name, pos)
		local m = M(survs, name)
		m:SetAttribute("SpawnPos", pos)
		local hrp = P(m, "HumanoidRootPart", V3.new(2,2,1), pos, C3.fromRGB(200,180,160), Enum.Material.SmoothPlastic, true, true, 0)
		hrp.Transparency = 1
		P(m, "Head", V3.new(1.2,1.2,1.2), pos + V3.new(0,1.5,0), C3.fromRGB(230,200,180), Enum.Material.SmoothPlastic, true, true, 0)
		P(m, "Torso", V3.new(1.6,2,0.8), pos + V3.new(0,0,0), C3.fromRGB(100,140,200), Enum.Material.Fabric, true, true, 0)
		local hum = roblox.Instance.new("Humanoid")
		hum.Name = "Humanoid"
		hum.MaxHealth = 100
		hum.Health = 100
		hum.WalkSpeed = 8
		hum.Parent = m
		local pr = roblox.Instance.new("ProximityPrompt")
		pr.ActionText = "Lead Survivor"
		pr.ObjectText = name
		pr.HoldDuration = 0.3
		pr.MaxActivationDistance = 10
		pr.Parent = hrp
		return m
	end
	surv("Survivor1", V3.new(-10,1,-10))
	surv("Survivor2", V3.new(15,1,5))
	surv("Survivor3", V3.new(-20,1,20))
	surv("Survivor4", V3.new(28,1,-5))

	-- Interiors / rooms (revision 3)
	-- Terminal interior partitions
	P(term, "Partition1", V3.new(0.4,6,10), V3.new(4,3.25,-28), C3.fromRGB(70,72,82), CONC, true, true, 0)
	P(term, "Desk1", V3.new(4,1,2), V3.new(-6,1,-24), C3.fromRGB(90,70,50), WOOD, true, true, 0)
	P(term, "Chair1", V3.new(1.5,1.5,1.5), V3.new(-6,0.75,-22), C3.fromRGB(60,60,70), Enum.Material.Fabric, true, true, 0)
	-- Apartment interiors
	for _, f in ipairs({0,1,2}) do
		local y = f*3.2+0.25
		P(apt, "RoomDiv"..f, V3.new(0.4,2.8,14), V3.new(30,y+1.4,-8), C3.fromRGB(75,77,85), CONC, true, true, 0)
	end
	P(apt, "Bed1", V3.new(3,1,2), V3.new(24,1,-12), C3.fromRGB(180,180,200), Enum.Material.Fabric, true, true, 0)
	P(apt, "Table1", V3.new(2,1,2), V3.new(34,1,-4), C3.fromRGB(90,70,50), WOOD, true, true, 0)
	-- Clinic interiors
	P(cl, "Counter", V3.new(6,1,1.5), V3.new(24,1,20), C3.fromRGB(200,200,210), Enum.Material.SmoothPlastic, true, true, 0)
	P(cl, "Cabinet", V3.new(2,3,1), V3.new(30,1.75,28), C3.fromRGB(120,130,140), METAL, true, true, 0)
	-- Workshop extra
	P(ws, "Shelf", V3.new(8,0.3,1.5), V3.new(-18,4,26), C3.fromRGB(90,70,50), WOOD, true, true, 0)
	P(ws, "Toolbox", V3.new(2,1.5,1), V3.new(-12,1,26), C3.fromRGB(200,60,60), METAL, true, true, 0)
	-- Extra props / signage (revision 2)
	P(world, "Sign_Terminal", V3.new(6,2,0.3), V3.new(0,4,-19.3), C3.fromRGB(220,150,60), Enum.Material.Neon, true, true, 0)
	P(world, "Railing_Terminal", V3.new(22,1,0.3), V3.new(0,11,-28), C3.fromRGB(120,130,140), Enum.Material.Metal, true, true, 0)
	P(world, "Crate_Terminal", V3.new(2,2,2), V3.new(9,1,-20), C3.fromRGB(110,85,55), Enum.Material.Wood, true, true, 0)
	P(world, "Barrier_Street", V3.new(1,1.2,6), V3.new(6,0.6,0), C3.fromRGB(220,120,40), Enum.Material.Plastic, true, true, 0)
	-- Spawn
	local sp = roblox.Instance.new("SpawnLocation")
	sp.Name = "SpawnLocation"
	sp.Size = V3.new(6,1,6)
	sp.Position = V3.new(0,0.5,0)
	sp.Color = C3.fromRGB(255,200,80)
	sp.Material = Enum.Material.Neon
	sp.Anchored = true
	sp.CanCollide = true
	sp.Parent = world
end)

-- Write Rojo project
local projectJson = [[{
  "name": "FLOODLINE",
  "tree": {
    "$className": "DataModel",
    "Workspace": {
      "$className": "Workspace",
      "World": { "$path": "generated/models/World.rbxmx" }
    },
    "ServerScriptService": {
      "$className": "ServerScriptService",
      "GameManager": { "$path": "src/GameManager.server.luau" }
    },
    "StarterPlayer": {
      "$className": "StarterPlayer",
      "StarterPlayerScripts": {
        "$className": "StarterPlayerScripts",
        "Client": { "$path": "src/Client.client.luau" }
      }
    }
  }
}]]
fs.writeFile(AGENT .. "/default.project.json", projectJson)

-- Run rojo
local rojo = "/home/user/.cache/floodline-tools/bin/rojo"
local outPath = AGENT .. "/releases/FLOODLINE.rbxlx"
local res = process.exec(rojo, {"build", AGENT .. "/default.project.json", "-o", outPath})
print("rojo stdout:", res.stdout)
print("rojo stderr:", res.stderr)
print("rojo code:", res.code)
if res.code ~= 0 then process.exit(res.code) end

-- Also binary companion via Lune serializePlace? Parse exported to verify, then write .rbxl
local data = fs.readFile(outPath)
print("place bytes:", #data)
