--!strict
-- FLOODLINE build tool.
-- 1. Generates the baked district model (edit-mode visible geometry, no runtime construction).
-- 2. Writes the Rojo project that maps the real source tree into the place.
-- 3. Builds FLOODLINE.rbxlx and reports byte counts.
--
-- Run from the repository root:  lune run agents/riveter/tools/build_game.luau

local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local process = require("@lune/process")

local ROOT = process.cwd
local AGENT = ROOT .. "/agents/riveter"
local GEN = AGENT .. "/generated"

if fs.isDir(GEN) then
	fs.removeDir(GEN)
end
fs.writeDir(GEN)
fs.writeDir(GEN .. "/models")

local V3 = roblox.Vector3
local C3 = roblox.Color3
local Enum = roblox.Enum

local CONC = Enum.Material.Concrete
local METAL = Enum.Material.Metal
local WOOD = Enum.Material.Wood
local GLASS = Enum.Material.Glass
local FABRIC = Enum.Material.Fabric
local PLASTIC = Enum.Material.Plastic
local NEON = Enum.Material.Neon
local SLATE = Enum.Material.Slate
local SMOOTH = Enum.Material.SmoothPlastic

local C_DARK = C3.fromRGB(30, 38, 48)
local C_MID = C3.fromRGB(55, 62, 72)
local C_LIGHT = C3.fromRGB(85, 92, 102)
local C_SAFE = C3.fromRGB(220, 150, 60)
local C_WATER = C3.fromRGB(20, 80, 120)
local C_STEEL = C3.fromRGB(110, 118, 128)
local C_WOOD = C3.fromRGB(100, 78, 52)

local function P(parent, name, size, pos, color, material, anchored, collide, transparency)
	local o = roblox.Instance.new("Part")
	o.Name = name
	o.Size = size
	o.Position = pos
	o.Color = color or C_LIGHT
	o.Material = material or CONC
	o.Anchored = anchored ~= false
	o.CanCollide = collide ~= false
	o.Transparency = transparency or 0
	o.Parent = parent
	return o
end

local function TR(parent, name, size, pos, color)
	local o = roblox.Instance.new("TrussPart")
	o.Name = name
	o.Size = size
	o.Position = pos
	o.Color = color or C_STEEL
	o.Material = METAL
	o.Anchored = true
	o.CanCollide = true
	o.Parent = parent
	return o
end

local function SEAT(parent, name, size, pos, color)
	local o = roblox.Instance.new("Seat")
	o.Name = name
	o.Size = size
	o.Position = pos
	o.Color = color or C_DARK
	o.Material = SMOOTH
	o.Anchored = true
	o.CanCollide = false
	o.Transparency = 0.4
	o.Parent = parent
	return o
end

local function M(parent, name)
	local m = roblox.Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function prompt(parent, action, object, hold)
	local pr = roblox.Instance.new("ProximityPrompt")
	pr.ActionText = action
	pr.ObjectText = object or parent.Name
	pr.HoldDuration = hold or 0.25
	pr.MaxActivationDistance = 14
	pr.Parent = parent
	return pr
end

local function script_(parent, name, source, className)
	local o = roblox.Instance.new(className or "Script")
	o.Name = name
	o.Source = source
	o.Parent = parent
	return o
end

local function copyModel(name: string, builder)
	local m = roblox.Instance.new("Model")
	m.Name = name
	builder(m)
	fs.writeFile(GEN .. "/models/" .. name .. ".rbxmx", roblox.serializeModel({ m }, true))
end

-- ============================================================
-- 1. THE DISTRICT
-- ============================================================
copyModel("World", function(world)
	-- ---------- ground, streets, canal ----------
	P(world, "Ground", V3.new(200, 2, 200), V3.new(0, -1, 0), C3.fromRGB(40, 48, 58), CONC, true, true, 0)
	P(world, "StreetNS", V3.new(11, 0.3, 200), V3.new(0, 0.15, 0), C3.fromRGB(56, 60, 68), CONC, true, true, 0)
	P(world, "StreetEW", V3.new(200, 0.3, 11), V3.new(0, 0.15, 14), C3.fromRGB(56, 60, 68), CONC, true, true, 0)
	P(world, "SidewalkN", V3.new(200, 0.45, 2.4), V3.new(0, 0.22, 9), C3.fromRGB(70, 72, 80), CONC, true, true, 0)
	P(world, "SidewalkS", V3.new(200, 0.45, 2.4), V3.new(0, 0.22, -9), C3.fromRGB(70, 72, 80), CONC, true, true, 0)
	P(world, "CanalBed", V3.new(8, 2, 200), V3.new(20, -1.2, 0), C3.fromRGB(34, 44, 52), SLATE, true, true, 0)
	P(world, "CanalWallE", V3.new(0.8, 3.4, 200), V3.new(24.2, 0.4, 0), C3.fromRGB(62, 66, 74), CONC, true, true, 0)
	P(world, "CanalWallW", V3.new(0.8, 3.4, 200), V3.new(15.8, 0.4, 0), C3.fromRGB(62, 66, 74), CONC, true, true, 0)
	-- district sea wall on the far side
	P(world, "SeaWall", V3.new(200, 9, 2), V3.new(0, 3.5, 52), C3.fromRGB(58, 62, 70), CONC, true, true, 0)
	P(world, "SeaWallCap", V3.new(200, 0.6, 3), V3.new(0, 8.2, 52), C3.fromRGB(74, 78, 86), CONC, true, true, 0)

	-- ---------- rubble & broken infrastructure ----------
	for i = -4, 4 do
		local x = i * 14
		P(world, "Rubble" .. i, V3.new(6, 2.2, 5), V3.new(x + 3, 1.1, -46), C3.fromRGB(66, 62, 58), SLATE, true, true, 0)
		P(world, "Slab" .. i, V3.new(9, 0.6, 4), V3.new(x - 2, 0.4, 44), C3.fromRGB(72, 70, 68), CONC, true, true, 0)
	end
	for i = -2, 2 do
		P(world, "Sleeper" .. i, V3.new(3, 0.5, 1.6), V3.new(-46, 0.35, i * 16), C3.fromRGB(84, 66, 52), WOOD, true, true, 0)
	end

	-- ---------- skyline shells (baked silhouette, adds scale) ----------
	local skyline = {
		{ 62, 34, 26, -70, -52 }, { 48, 22, 30, 74, -44 }, { 40, 28, 22, 66, 60 },
		{ 54, 18, 24, -72, 58 }, { 36, 40, 20, -18, -80 }, { 44, 26, 28, 30, -76 },
	}
	for index, spec in ipairs(skyline) do
		local shell = M(world, "Skyline" .. index)
		P(shell, "Tower", V3.new(spec[1], spec[2], spec[3]), V3.new(spec[4], spec[2] / 2, spec[5]), C3.fromRGB(46, 50, 58), CONC, true, true, 0)
		P(shell, "Cap", V3.new(spec[1] + 2, 1.2, spec[3] + 2), V3.new(spec[4], spec[2] + 0.6, spec[5]), C3.fromRGB(38, 42, 50), CONC, true, true, 0)
		for floor = 1, math.floor(spec[2] / 4) do
			P(shell, "Band" .. floor, V3.new(spec[1] + 0.4, 0.3, spec[3] + 0.4), V3.new(spec[4], floor * 4, spec[5]), C3.fromRGB(30, 34, 40), CONC, true, true, 0)
		end
	end

	-- ================= 1. TERMINAL (command + power hub) =================
	local term = M(world, "Terminal")
	P(term, "Floor", V3.new(28, 0.6, 22), V3.new(0, 0.3, -30), C3.fromRGB(74, 78, 88), CONC, true, true, 0)
	P(term, "WallN", V3.new(28, 12, 0.7), V3.new(0, 6.3, -41), C3.fromRGB(62, 66, 76), CONC, true, true, 0)
	P(term, "WallE", V3.new(0.7, 12, 22), V3.new(14, 6.3, -30), C3.fromRGB(62, 66, 76), CONC, true, true, 0)
	P(term, "WallW", V3.new(0.7, 12, 22), V3.new(-14, 6.3, -30), C3.fromRGB(62, 66, 76), CONC, true, true, 0)
	P(term, "WallS_L", V3.new(8, 12, 0.7), V3.new(-10, 6.3, -19), C3.fromRGB(62, 66, 76), CONC, true, true, 0)
	P(term, "WallS_R", V3.new(8, 12, 0.7), V3.new(10, 6.3, -19), C3.fromRGB(62, 66, 76), CONC, true, true, 0)
	P(term, "DoorLintel", V3.new(12, 2.4, 0.7), V3.new(0, 11, -19), C3.fromRGB(72, 76, 86), CONC, true, true, 0)
	P(term, "Roof", V3.new(28, 0.6, 22), V3.new(0, 12.6, -30), C3.fromRGB(52, 56, 66), CONC, true, true, 0)
	P(term, "RoofRail", V3.new(28, 1.1, 0.3), V3.new(0, 13.2, -30), C3.fromRGB(118, 126, 136), METAL, true, true, 0)
	P(term, "Mezzanine", V3.new(10, 0.5, 7), V3.new(8, 5, -35), C3.fromRGB(80, 84, 94), CONC, true, true, 0)
	for i = 0, 6 do
		P(term, "MezzStep" .. i, V3.new(3, 0.4, 1.1), V3.new(3.6 + i * 0.9, 0.4 + i * 0.72, -30 + i * 0.9), C3.fromRGB(86, 90, 100), CONC, true, true, 0)
	end
	P(term, "Desk", V3.new(6, 1.1, 2.4), V3.new(-8, 0.85, -24), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	P(term, "Chair", V3.new(1.7, 1.7, 1.7), V3.new(-8, 0.85, -21.5), C3.fromRGB(56, 56, 66), FABRIC, true, true, 0)
	P(term, "Monitor", V3.new(1.8, 1.2, 0.3), V3.new(-7, 1.9, -25), C3.fromRGB(40, 44, 52), PLASTIC, true, true, 0)
	P(term, "MonitorGlow", V3.new(1.6, 1, 0.1), V3.new(-7, 1.9, -24.8), C3.fromRGB(70, 190, 220), NEON, true, false, 0.1)
	-- the wall of sockets
	P(term, "PanelWall", V3.new(12, 4.6, 0.5), V3.new(-4, 2.6, -40.6), C3.fromRGB(48, 52, 62), METAL, true, true, 0)
	P(term, "Socket_Pump", V3.new(1.8, 1.8, 1.8), V3.new(-9, 1.4, -38.6), C3.fromRGB(206, 124, 44), METAL, true, true, 0)
	P(term, "Socket_Bridge", V3.new(1.8, 1.8, 1.8), V3.new(-4, 1.4, -38.6), C3.fromRGB(206, 124, 44), METAL, true, true, 0)
	P(term, "Socket_Lift", V3.new(1.8, 1.8, 1.8), V3.new(1, 1.4, -38.6), C3.fromRGB(206, 124, 44), METAL, true, true, 0)
	prompt(term.Socket_Pump, "Use Socket", "Pump Socket")
	prompt(term.Socket_Bridge, "Use Socket", "Bridge Socket")
	prompt(term.Socket_Lift, "Use Socket", "Lift Socket")
	P(term, "Charger", V3.new(2.6, 1.4, 2.6), V3.new(6, 1, -38.6), C3.fromRGB(80, 190, 120), METAL, true, true, 0)
	prompt(term.Charger, "Dock Cell", "Cell Charger", 0.3)
	P(term, "Switchboard", V3.new(5, 3.4, 0.5), V3.new(10, 2, -40.6), C3.fromRGB(58, 60, 70), METAL, true, true, 0)
	for i = 0, 3 do
		P(term, "Breaker" .. i, V3.new(0.5, 0.9, 0.4), V3.new(8.6 + i * 0.9, 2.6, -40.3), C3.fromRGB(200, 78, 60), PLASTIC, true, true, 0)
	end
	P(term, "EvacConsole", V3.new(2.4, 1.6, 1.4), V3.new(11, 1.1, -22), C3.fromRGB(70, 80, 96), METAL, true, true, 0)
	P(term, "EvacConsoleGlow", V3.new(1.6, 0.8, 0.1), V3.new(11, 1.35, -21.3), C3.fromRGB(90, 210, 160), NEON, true, false, 0.15)
	prompt(term.EvacConsole, "Call Evacuation", "Evacuation Console", 0.6)
	-- power room dressing
	P(term, "Generator", V3.new(5, 2.6, 3), V3.new(-11, 1.6, -34), C3.fromRGB(92, 96, 106), METAL, true, true, 0)
	P(term, "GeneratorPipe", V3.new(1, 1, 6), V3.new(-11, 3.4, -37), C3.fromRGB(84, 88, 98), METAL, true, true, 0)
	P(term, "ToolRack", V3.new(4, 2.4, 0.6), V3.new(-13, 1.5, -25), C3.fromRGB(90, 70, 50), WOOD, true, true, 0)
	P(term, "Bench", V3.new(6, 0.8, 1.6), V3.new(10, 0.9, -34), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	P(term, "Medkit1Source", V3.new(1.2, 1.2, 0.8), V3.new(12.2, 1.7, -34), C3.fromRGB(210, 210, 216), SMOOTH, true, true, 0)
	P(term, "Medkit1", V3.new(1, 0.7, 0.5), V3.new(12.2, 2.5, -34), C3.fromRGB(235, 235, 240), PLASTIC, true, true, 0)
	P(term, "Medkit1Cross", V3.new(0.7, 0.16, 0.55), V3.new(12.2, 2.5, -33.7), C3.fromRGB(220, 70, 60), NEON, true, false, 0)
	prompt(term.Medkit1, "Take Medkit", "Medkit", 0.35)
	P(term, "Sign_Terminal", V3.new(9, 2.2, 0.4), V3.new(0, 5, -19.2), C3.fromRGB(224, 154, 62), NEON, true, true, 0)
	P(term, "StartButton", V3.new(3.2, 2.2, 0.6), V3.new(0, 1.9, -23.5), C3.fromRGB(226, 140, 44), NEON, true, true, 0)
	prompt(term.StartButton, "Start Round", "Round Console")
	for i = -1, 1 do
		P(term, "CeilingLamp" .. i, V3.new(0.7, 0.5, 2.4), V3.new(i * 7, 11.8, -30), C3.fromRGB(255, 232, 186), NEON, true, false, 0.15)
	end
	-- live cable runs (electrified until the water reaches them)
	P(term, "LiveCable1", V3.new(0.4, 0.4, 14), V3.new(6, 0.5, -32), C3.fromRGB(255, 120, 60), NEON, true, true, 0.15)
	P(term, "LiveCable2", V3.new(12, 0.4, 0.4), V3.new(-4, 0.5, -36), C3.fromRGB(255, 120, 60), NEON, true, true, 0.15)

	-- ================= 2. PUMP HOUSE =================
	local pump = M(world, "PumpHouse")
	P(pump, "Floor", V3.new(18, 0.6, 16), V3.new(-34, 0.3, -18), C3.fromRGB(64, 68, 78), CONC, true, true, 0)
	P(pump, "PitFloor", V3.new(12, 0.4, 10), V3.new(-34, -1.4, -18), C3.fromRGB(44, 48, 56), SLATE, true, true, 0)
	P(pump, "WallN", V3.new(18, 10, 0.7), V3.new(-34, 5.3, -26), C3.fromRGB(58, 62, 72), CONC, true, true, 0)
	P(pump, "WallS", V3.new(18, 10, 0.7), V3.new(-34, 5.3, -10), C3.fromRGB(58, 62, 72), CONC, true, true, 0)
	P(pump, "WallE_L", V3.new(0.7, 10, 6), V3.new(-25, 5.3, -23), C3.fromRGB(58, 62, 72), CONC, true, true, 0)
	P(pump, "WallE_R", V3.new(0.7, 10, 6), V3.new(-25, 5.3, -13), C3.fromRGB(58, 62, 72), CONC, true, true, 0)
	P(pump, "WallW", V3.new(0.7, 10, 16), V3.new(-43, 5.3, -18), C3.fromRGB(58, 62, 72), CONC, true, true, 0)
	P(pump, "Roof", V3.new(18, 0.6, 16), V3.new(-34, 10.6, -18), C3.fromRGB(48, 52, 62), CONC, true, true, 0)
	P(pump, "PumpBody", V3.new(5.4, 3.6, 5.4), V3.new(-34, 2.1, -18), C3.fromRGB(102, 112, 122), METAL, true, true, 0)
	P(pump, "PumpBase", V3.new(6.4, 0.7, 6.4), V3.new(-34, 0.65, -18), C3.fromRGB(82, 88, 98), CONC, true, true, 0)
	P(pump, "PumpMotor", V3.new(2.4, 2.4, 2.4), V3.new(-34, 4.6, -18), C3.fromRGB(180, 90, 60), METAL, true, true, 0)
	P(pump, "PipeIn", V3.new(1.3, 1.3, 9), V3.new(-27.5, 1.9, -18), C3.fromRGB(96, 102, 112), METAL, true, true, 0)
	P(pump, "PipeOut", V3.new(1.3, 1.3, 9), V3.new(-40.5, 1.9, -18), C3.fromRGB(96, 102, 112), METAL, true, true, 0)
	P(pump, "RiserPipe", V3.new(1.3, 8, 1.3), V3.new(-38, 4, -24), C3.fromRGB(96, 102, 112), METAL, true, true, 0)
	P(pump, "Valve", V3.new(1.6, 1.6, 1.6), V3.new(-38, 2.4, -22.4), C3.fromRGB(206, 96, 60), METAL, true, true, 0)
	prompt(pump.Valve, "Turn Valve", "Gas Line Valve", 0.5)
	P(pump, "ValveWheel", V3.new(2.6, 0.3, 2.6), V3.new(-38, 3.4, -22.4), C3.fromRGB(200, 90, 60), METAL, true, true, 0)
	P(pump, "Gauge", V3.new(0.4, 2.2, 2.2), V3.new(-26.2, 2.4, -18), C3.fromRGB(220, 222, 230), GLASS, true, true, 0)
	P(pump, "GaugeNeedle", V3.new(0.5, 0.16, 1.4), V3.new(-26, 2.4, -18), C3.fromRGB(220, 60, 50), NEON, true, false, 0.1)
	P(pump, "Ladder", V3.new(2, 10, 0.4), V3.new(-42.6, 5, -12), C3.fromRGB(120, 128, 138), METAL, true, true, 0)
	P(pump, "ControlPanel", V3.new(3, 2.2, 1), V3.new(-30, 1.9, -25), C3.fromRGB(70, 74, 84), METAL, true, true, 0)
	P(pump, "ControlGlow", V3.new(2, 0.3, 0.2), V3.new(-30, 2.7, -24.5), C3.fromRGB(120, 220, 140), NEON, true, false, 0.2)
	P(pump, "CrateWork", V3.new(2.4, 2.4, 2.4), V3.new(-40, 1.5, -13), C3.fromRGB(104, 84, 54), WOOD, true, true, 0)
	P(pump, "LiveCablePump", V3.new(0.4, 0.4, 12), V3.new(-31, 0.5, -20), C3.fromRGB(255, 120, 60), NEON, true, true, 0.15)

	-- ================= 3. APARTMENT BLOCK =================
	local apt = M(world, "ApartmentBlock")
	P(apt, "Base", V3.new(20, 0.6, 18), V3.new(33, 0.3, -6), C3.fromRGB(74, 76, 84), CONC, true, true, 0)
	P(apt, "WallN", V3.new(20, 13.6, 0.7), V3.new(33, 7, -15), C3.fromRGB(66, 68, 78), CONC, true, true, 0)
	P(apt, "WallS", V3.new(20, 13.6, 0.7), V3.new(33, 7, 3), C3.fromRGB(66, 68, 78), CONC, true, true, 0)
	P(apt, "WallE", V3.new(0.7, 13.6, 18), V3.new(43, 7, -6), C3.fromRGB(66, 68, 78), CONC, true, true, 0)
	P(apt, "WallW_L", V3.new(0.7, 13.6, 7), V3.new(23, 7, -11.5), C3.fromRGB(66, 68, 78), CONC, true, true, 0)
	P(apt, "WallW_R", V3.new(0.7, 13.6, 7), V3.new(23, 7, -0.5), C3.fromRGB(66, 68, 78), CONC, true, true, 0)
	for floor = 0, 3 do
		local y = floor * 3.2 + 0.6
		P(apt, "Slab" .. floor, V3.new(20, 0.5, 18), V3.new(33, y, -6), C3.fromRGB(74, 76, 84), CONC, true, true, 0)
		P(apt, "DivN" .. floor, V3.new(0.4, 2.7, 7), V3.new(33, y + 1.6, -10.5), C3.fromRGB(78, 80, 88), CONC, true, true, 0)
		P(apt, "DivS" .. floor, V3.new(0.4, 2.7, 7), V3.new(33, y + 1.6, -1.5), C3.fromRGB(78, 80, 88), CONC, true, true, 0)
		P(apt, "Win" .. floor, V3.new(5, 2, 0.3), V3.new(43, y + 1.8, -6), C3.fromRGB(150, 180, 200), GLASS, true, false, 0.5)
	end
	P(apt, "Roof", V3.new(20, 0.6, 18), V3.new(33, 13.4, -6), C3.fromRGB(54, 56, 64), CONC, true, true, 0)
	P(apt, "RoofRail", V3.new(20, 1.1, 0.3), V3.new(33, 14, -15), C3.fromRGB(118, 126, 136), METAL, true, true, 0)
	P(apt, "RoofHatch", V3.new(3.4, 0.4, 3.4), V3.new(29, 13.8, -3), C3.fromRGB(92, 96, 106), METAL, true, true, 0)
	-- switchback stairwell: 16 climbable steps to the roof
	for step = 0, 15 do
		local lane = (step % 2 == 0) and 30.6 or 35.4
		local forward = math.floor(step / 2)
		P(apt, "Step" .. step, V3.new(4.2, 0.4, 1.3), V3.new(lane, 0.8 + step * 0.8, -12 + forward * 1.35), C3.fromRGB(88, 92, 102), CONC, true, true, 0)
	end
	P(apt, "StairCore", V3.new(9, 13, 12), V3.new(33, 6.5, -6.4), C3.fromRGB(58, 60, 68), CONC, false, false, 0.86)
	P(apt, "Bed1", V3.new(3.4, 1.1, 2.2), V3.new(27, 1.7, -11.5), C3.fromRGB(190, 192, 206), FABRIC, true, true, 0)
	P(apt, "Bed2", V3.new(3.4, 1.1, 2.2), V3.new(40, 8.1, -11.5), C3.fromRGB(190, 192, 206), FABRIC, true, true, 0)
	P(apt, "Bed3", V3.new(3.4, 1.1, 2.2), V3.new(27, 4.9, -0.5), C3.fromRGB(190, 192, 206), FABRIC, true, true, 0)
	P(apt, "Table1", V3.new(2.4, 1.1, 2.4), V3.new(40, 1.7, -0.5), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	P(apt, "Chair1", V3.new(1.6, 1.6, 1.6), V3.new(40, 1.4, 1.6), C3.fromRGB(56, 56, 66), FABRIC, true, true, 0)
	P(apt, "Shelf1", V3.new(4, 0.3, 1.2), V3.new(26, 5.4, -3), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	P(apt, "CellCacheStand", V3.new(3, 0.6, 3), V3.new(38, 13.9, -3), C3.fromRGB(88, 92, 102), METAL, true, true, 0)
	P(apt, "LiveCableApt", V3.new(0.4, 0.4, 10), V3.new(31, 0.5, -6), C3.fromRGB(255, 120, 60), NEON, true, true, 0.15)

	-- ================= 4. WORKSHOP =================
	local ws = M(world, "Workshop")
	P(ws, "Floor", V3.new(22, 0.6, 18), V3.new(-18, 0.3, 30), C3.fromRGB(62, 64, 72), CONC, true, true, 0)
	P(ws, "WallN_L", V3.new(8, 11, 0.7), V3.new(-25, 5.8, 21), C3.fromRGB(56, 58, 66), CONC, true, true, 0)
	P(ws, "WallN_R", V3.new(8, 11, 0.7), V3.new(-11, 5.8, 21), C3.fromRGB(56, 58, 66), CONC, true, true, 0)
	P(ws, "WallS", V3.new(22, 11, 0.7), V3.new(-18, 5.8, 39), C3.fromRGB(56, 58, 66), CONC, true, true, 0)
	P(ws, "WallE", V3.new(0.7, 11, 18), V3.new(-7, 5.8, 30), C3.fromRGB(56, 58, 66), CONC, true, true, 0)
	P(ws, "WallW", V3.new(0.7, 11, 18), V3.new(-29, 5.8, 30), C3.fromRGB(56, 58, 66), CONC, true, true, 0)
	P(ws, "Roof", V3.new(22, 0.6, 18), V3.new(-18, 11.6, 30), C3.fromRGB(46, 48, 56), CONC, true, true, 0)
	P(ws, "Step1", V3.new(7, 0.4, 1.4), V3.new(-18, 0.5, 22.4), C3.fromRGB(84, 86, 94), CONC, true, true, 0)
	P(ws, "WorkBench", V3.new(8, 1.1, 2.6), V3.new(-23, 0.85, 26), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	P(ws, "Vice", V3.new(1.4, 1.4, 1.4), V3.new(-20, 1.5, 26), C3.fromRGB(122, 122, 132), METAL, true, true, 0)
	P(ws, "ToolWall", V3.new(7, 3, 0.4), V3.new(-23, 3.2, 24.4), C3.fromRGB(58, 58, 66), METAL, true, true, 0)
	P(ws, "Crate1", V3.new(2.6, 2.6, 2.6), V3.new(-11.5, 1.6, 35), C3.fromRGB(104, 84, 54), WOOD, true, true, 0)
	P(ws, "Crate2", V3.new(2.6, 2.6, 2.6), V3.new(-11.5, 1.6, 31.5), C3.fromRGB(104, 84, 54), WOOD, true, true, 0)
	P(ws, "FuseCrate", V3.new(2.2, 2.2, 2.2), V3.new(-14.5, 1.4, 35), C3.fromRGB(96, 78, 50), WOOD, true, true, 0)
	P(ws, "RelayFuse", V3.new(0.9, 0.5, 0.5), V3.new(-14.5, 2.9, 35), C3.fromRGB(235, 200, 90), NEON, true, true, 0.05)
	prompt(ws.RelayFuse, "Take Fuse", "Relay Fuse", 0.35)
	P(ws, "Pallet", V3.new(3.4, 0.4, 2.2), V3.new(-16, 0.5, 35), C3.fromRGB(122, 96, 60), WOOD, true, true, 0)
	P(ws, "Machine", V3.new(4.4, 3.2, 3.4), V3.new(-25, 2, 34), C3.fromRGB(92, 98, 108), METAL, true, true, 0)
	P(ws, "MachineDrum", V3.new(1.6, 1.6, 6), V3.new(-25, 3.4, 34), C3.fromRGB(140, 140, 150), METAL, true, true, 0)
	P(ws, "ShelfA", V3.new(9, 0.3, 1.6), V3.new(-18, 4.4, 26), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	P(ws, "ShelfB", V3.new(9, 0.3, 1.6), V3.new(-18, 6.4, 26), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	P(ws, "Toolbox", V3.new(2.4, 1.7, 1.3), V3.new(-12.5, 1.2, 26), C3.fromRGB(200, 62, 60), METAL, true, true, 0)
	P(ws, "GasPipe", V3.new(0.7, 0.7, 14), V3.new(-28, 7.5, 30), C3.fromRGB(150, 120, 80), METAL, true, true, 0)
	P(ws, "GasLeak", V3.new(0.9, 0.9, 0.9), V3.new(-28, 6.9, 25), C3.fromRGB(180, 220, 160), NEON, true, false, 0.25)
	P(ws, "Ladder", V3.new(2, 11, 0.4), V3.new(-27.6, 5.8, 24), C3.fromRGB(120, 128, 138), METAL, true, true, 0)
	P(ws, "Medkit2", V3.new(1, 0.7, 0.5), V3.new(-19.5, 2, 26), C3.fromRGB(235, 235, 240), PLASTIC, true, true, 0)
	P(ws, "Medkit2Cross", V3.new(0.7, 0.16, 0.55), V3.new(-19.5, 2, 25.7), C3.fromRGB(220, 70, 60), NEON, true, false, 0)
	prompt(ws.Medkit2, "Take Medkit", "Medkit", 0.35)

	-- ================= 5. CLINIC =================
	local cl = M(world, "Clinic")
	P(cl, "Floor", V3.new(18, 0.6, 16), V3.new(24, 0.4, 27), C3.fromRGB(84, 86, 94), CONC, true, true, 0)
	P(cl, "WallN", V3.new(18, 9, 0.7), V3.new(24, 4.5, 19), C3.fromRGB(78, 80, 90), CONC, true, true, 0)
	P(cl, "WallS", V3.new(18, 9, 0.7), V3.new(24, 4.5, 35), C3.fromRGB(78, 80, 90), CONC, true, true, 0)
	P(cl, "WallE", V3.new(0.7, 9, 16), V3.new(33, 4.5, 27), C3.fromRGB(78, 80, 90), CONC, true, true, 0)
	P(cl, "WallW", V3.new(0.7, 9, 16), V3.new(15, 4.5, 27), C3.fromRGB(78, 80, 90), CONC, true, true, 0)
	P(cl, "Roof", V3.new(18, 0.6, 16), V3.new(24, 9.3, 27), C3.fromRGB(64, 66, 74), CONC, true, true, 0)
	P(cl, "Bed1", V3.new(4.4, 1.1, 2.2), V3.new(20, 1.1, 22.5), C3.fromRGB(206, 206, 216), FABRIC, true, true, 0)
	P(cl, "Bed2", V3.new(4.4, 1.1, 2.2), V3.new(29, 1.1, 22.5), C3.fromRGB(206, 206, 216), FABRIC, true, true, 0)
	P(cl, "Bed3", V3.new(4.4, 1.1, 2.2), V3.new(20, 1.1, 32), C3.fromRGB(206, 206, 216), FABRIC, true, true, 0)
	P(cl, "IVStand", V3.new(0.4, 3.4, 0.4), V3.new(22.5, 2.5, 22.5), C3.fromRGB(190, 190, 198), METAL, true, true, 0)
	P(cl, "Counter", V3.new(7.5, 1.1, 1.8), V3.new(24, 0.9, 31), C3.fromRGB(200, 200, 210), SMOOTH, true, true, 0)
	P(cl, "Cabinet", V3.new(2.4, 3.4, 1.3), V3.new(32, 2.2, 30), C3.fromRGB(122, 132, 142), METAL, true, true, 0)
	P(cl, "CabinetGlow", V3.new(2, 0.3, 0.2), V3.new(32, 3.5, 29.4), C3.fromRGB(90, 200, 220), NEON, true, false, 0.2)
	P(cl, "Shelf", V3.new(6, 0.3, 1.3), V3.new(17, 4.4, 27), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	P(cl, "Sign_Clinic", V3.new(7, 1.8, 0.4), V3.new(24, 5, 19.2), C3.fromRGB(84, 206, 130), NEON, true, true, 0)
	P(cl, "Medkit3", V3.new(1, 0.7, 0.5), V3.new(26, 1.7, 31), C3.fromRGB(235, 235, 240), PLASTIC, true, true, 0)
	P(cl, "Medkit3Cross", V3.new(0.7, 0.16, 0.55), V3.new(26, 1.7, 30.7), C3.fromRGB(220, 70, 60), NEON, true, false, 0)
	prompt(cl.Medkit3, "Take Medkit", "Medkit", 0.35)
	TR(cl, "LadderClinic", V3.new(1.6, 9, 1.6), V3.new(33.6, 4.8, 34), C3.fromRGB(120, 128, 138))

	-- ================= 6. RELAY TOWER (extraction) =================
	local rt = M(world, "RelayTower")
	for i = 0, 7 do
		P(rt, "Seg" .. i, V3.new(7, 2, 7), V3.new(0, i * 2 + 1, -40), C3.fromRGB(74, 78, 88), CONC, true, true, 0)
		P(rt, "Brace" .. i, V3.new(9, 0.4, 0.5), V3.new(0, i * 2 + 2, -43.4), C3.fromRGB(96, 100, 110), METAL, true, true, 0)
	end
	P(rt, "Platform", V3.new(13, 0.6, 13), V3.new(0, 16, -40), C3.fromRGB(84, 88, 98), CONC, true, true, 0)
	P(rt, "PlatformRailN", V3.new(13, 1.1, 0.3), V3.new(0, 16.6, -46), C3.fromRGB(118, 126, 136), METAL, true, true, 0)
	P(rt, "Mast", V3.new(0.7, 12, 0.7), V3.new(-4, 21.5, -43), C3.fromRGB(202, 202, 210), METAL, true, true, 0)
	P(rt, "Dish", V3.new(4.4, 0.4, 4.4), V3.new(-4, 27.5, -43), C3.fromRGB(214, 214, 222), METAL, true, true, 0)
	P(rt, "ControllerBox", V3.new(3, 2.4, 1.6), V3.new(3, 17.2, -38), C3.fromRGB(62, 62, 72), METAL, true, true, 0)
	P(rt, "RelaySlot", V3.new(1.4, 1.4, 0.6), V3.new(3, 17.2, -37.1), C3.fromRGB(90, 90, 100), METAL, true, true, 0)
	prompt(rt.RelaySlot, "Fit Fuse", "Relay Control Box", 1.1)
	P(rt, "Radio", V3.new(1.4, 0.9, 0.9), V3.new(1.4, 17.3, -38), C3.fromRGB(70, 190, 200), NEON, true, true, 0.05)
	prompt(rt.Radio, "Take Radio", "Relay Radio", 0.4)
	P(rt, "CableTray", V3.new(0.5, 0.5, 16), V3.new(2.4, 15.4, -34), C3.fromRGB(44, 44, 52), PLASTIC, true, true, 0)
	TR(rt, "LadderTower", V3.new(1.6, 16, 1.6), V3.new(4.4, 8, -40), C3.fromRGB(126, 134, 144))
	P(rt, "WarningLight", V3.new(0.8, 0.8, 0.8), V3.new(0, 28.6, -40), C3.fromRGB(255, 90, 70), NEON, true, false, 0.1)

	-- ---------- evacuation pad, catwalk and the lift ----------
	local evac = M(world, "EvacComplex")
	P(evac, "ExtractionPad", V3.new(9, 0.5, 9), V3.new(0, 16.2, -33), C3.fromRGB(96, 220, 150), NEON, true, true, 0.35)
	prompt(evac.ExtractionPad, "Call Lift", "Extraction Pad", 0.3)
	P(evac, "PadRailW", V3.new(0.3, 1.1, 9), V3.new(-4.4, 16.9, -33), C3.fromRGB(118, 126, 136), METAL, true, true, 0)
	P(evac, "Catwalk", V3.new(4.4, 0.5, 8), V3.new(-5.6, 15.6, -36), C3.fromRGB(86, 90, 100), CONC, true, true, 0)
	P(evac, "CatwalkRail", V3.new(0.3, 1.1, 8), V3.new(-7.6, 16.2, -36), C3.fromRGB(118, 126, 136), METAL, true, true, 0)
	P(evac, "CatwalkFloor", V3.new(4.4, 0.5, 6), V3.new(-5.6, 15.6, -31.6), C3.fromRGB(86, 90, 100), CONC, true, true, 0)
	P(evac, "LiftShaftMarker", V3.new(10, 0.3, 10), V3.new(0, 0.5, -32), C3.fromRGB(60, 66, 76), CONC, true, false, 0.7)
	P(evac, "LiftCallTop", V3.new(1.6, 1.6, 0.6), V3.new(4.4, 16.9, -33), C3.fromRGB(60, 160, 220), NEON, true, true, 0)
	prompt(evac.LiftCallTop, "Call Lift", "Evac Lift (Pad)", 0.3)
	P(evac, "LiftCall", V3.new(2.6, 2.6, 0.6), V3.new(6, 2, -27), C3.fromRGB(60, 160, 220), NEON, true, true, 0)
	prompt(evac.LiftCall, "Call Lift", "Evac Lift", 0.3)
	P(evac, "LiftSign", V3.new(6, 1.6, 0.4), V3.new(0, 7.4, -27.4), C3.fromRGB(60, 160, 220), NEON, true, true, 0)

	local lift = M(world, "EvacLift")
	P(lift, "Platform", V3.new(9, 0.7, 9), V3.new(0, 1, -32), C3.fromRGB(84, 124, 164), METAL, true, true, 0)
	P(lift, "WallS", V3.new(9, 4.6, 0.4), V3.new(0, 3.6, -27.7), C3.fromRGB(84, 124, 164), METAL, true, true, 0)
	P(lift, "WallE", V3.new(0.4, 4.6, 9), V3.new(4.3, 3.6, -32), C3.fromRGB(84, 124, 164), METAL, true, true, 0)
	P(lift, "WallW", V3.new(0.4, 4.6, 9), V3.new(-4.3, 3.6, -32), C3.fromRGB(84, 124, 164), METAL, true, true, 0)
	P(lift, "Roof", V3.new(9, 0.4, 9), V3.new(0, 6, -32), C3.fromRGB(72, 112, 152), METAL, true, true, 0)
	P(lift, "Lamp", V3.new(3, 0.3, 3), V3.new(0, 5.7, -32), C3.fromRGB(255, 236, 190), NEON, true, false, 0.2)
	P(lift, "ControlBox", V3.new(1.6, 1.6, 1), V3.new(3.4, 2.4, -29), C3.fromRGB(70, 74, 84), METAL, true, true, 0)
	prompt(lift.Platform, "Load Survivors", "Evac Lift", 0.35)
	for i = 1, 4 do
		local column = ((i - 1) % 2)
		local row = math.floor((i - 1) / 2)
		SEAT(lift, "LiftSeat" .. i, V3.new(1.6, 0.4, 1.6), V3.new(column * 2.6 - 1.3, 1.55, row * 2.6 - 1.3), C3.fromRGB(60, 90, 120))
	end

	-- ================= street furniture, hazards, routes =================
	for i = -4, 4 do
		P(world, "Barrier" .. i, V3.new(1.3, 1.4, 0.5), V3.new(i * 5, 0.7, 6), C3.fromRGB(222, 122, 44), PLASTIC, true, true, 0)
		P(world, "BarrierTop" .. i, V3.new(1.3, 0.2, 0.5), V3.new(i * 5, 1.5, 6), C3.fromRGB(240, 236, 228), PLASTIC, true, true, 0)
	end
	for i = -3, 3 do
		local x = i * 13
		P(world, "LampPost" .. i, V3.new(0.5, 6.6, 0.5), V3.new(x, 3.3, 10), C3.fromRGB(92, 92, 102), METAL, true, true, 0)
		P(world, "LampArm" .. i, V3.new(2.4, 0.3, 0.3), V3.new(x + 1, 6.5, 10), C3.fromRGB(92, 92, 102), METAL, true, true, 0)
		P(world, "LampHead" .. i, V3.new(1.3, 0.5, 1.3), V3.new(x + 2, 6.3, 10), C3.fromRGB(255, 232, 186), NEON, true, false, 0.15)
	end
	P(world, "BusShelter", V3.new(7, 0.3, 3), V3.new(-8, 2.8, 12), C3.fromRGB(88, 92, 100), METAL, true, true, 0)
	P(world, "BusShelterBack", V3.new(7, 3, 0.3), V3.new(-8, 1.6, 13.4), C3.fromRGB(120, 160, 180), GLASS, true, true, 0.4)
	P(world, "BusBenchSeat", V3.new(5, 0.3, 1.2), V3.new(-8, 1, 12.6), C3.fromRGB(96, 74, 52), WOOD, true, true, 0)
	for i = -2, 2 do
		P(world, "Drain" .. i, V3.new(1.8, 0.35, 1.8), V3.new(i * 9, 0.15, 2), C3.fromRGB(52, 54, 62), SLATE, true, true, 0)
	end
	P(world, "Hydrant", V3.new(0.8, 1.6, 0.8), V3.new(9, 0.8, 4), C3.fromRGB(200, 60, 50), METAL, true, true, 0)
	P(world, "ToolCart", V3.new(2.2, 1.3, 1.6), V3.new(-10, 0.9, 8), C3.fromRGB(140, 100, 60), METAL, true, true, 0)
	P(world, "Barrels1", V3.new(2, 2.6, 2), V3.new(-6, 1.3, -14), C3.fromRGB(180, 130, 50), METAL, true, true, 0)
	P(world, "Barrels2", V3.new(2, 2.6, 2), V3.new(-3.4, 1.3, -13), C3.fromRGB(160, 90, 60), METAL, true, true, 0)
	P(world, "Sign_Pump", V3.new(4.4, 1.4, 0.3), V3.new(-34, 5.6, -26.4), C3.fromRGB(224, 154, 62), NEON, true, true, 0)
	P(world, "Sign_Apt", V3.new(4.4, 1.4, 0.3), V3.new(33, 5.6, -15.4), C3.fromRGB(224, 154, 62), NEON, true, true, 0)
	P(world, "Sign_Workshop", V3.new(4.4, 1.4, 0.3), V3.new(-18, 5.6, 21.4), C3.fromRGB(224, 154, 62), NEON, true, true, 0)

	-- ---------- safe zone ----------
	local safe = P(world, "SafeZone", V3.new(15, 0.35, 15), V3.new(0, 0.35, -12), C3.fromRGB(226, 156, 62), NEON, true, false, 0.35)
	P(world, "SafeZoneRing", V3.new(17, 0.2, 1), V3.new(0, 0.5, -19.5), C3.fromRGB(240, 190, 110), NEON, true, false, 0.5)
	P(world, "SafeZonePost", V3.new(0.6, 3.4, 0.6), V3.new(-7, 1.7, -19), C3.fromRGB(200, 140, 60), METAL, true, true, 0)

	-- ---------- bridge gate ----------
	local gate = M(world, "BridgeGate")
	P(gate, "Slab", V3.new(14, 0.6, 6), V3.new(0, 1.2, 14), C3.fromRGB(90, 94, 104), CONC, true, true, 0)
	P(gate, "BarrierA", V3.new(6.4, 4, 0.6), V3.new(-3.6, 3.4, 14), C3.fromRGB(150, 68, 62), METAL, true, true, 0)
	P(gate, "BarrierB", V3.new(6.4, 4, 0.6), V3.new(3.6, 3.4, 14), C3.fromRGB(150, 68, 62), METAL, true, true, 0)
	P(gate, "Motor", V3.new(2, 2, 2), V3.new(-7.4, 2.4, 14), C3.fromRGB(90, 92, 100), METAL, true, true, 0)
	P(gate, "MotorLamp", V3.new(1, 0.4, 0.3), V3.new(-7.4, 3.6, 14.4), C3.fromRGB(220, 70, 60), NEON, true, false, 0.2)
	P(gate, "Sign_Gate", V3.new(4, 1.2, 0.3), V3.new(0, 6, 14.4), C3.fromRGB(224, 154, 62), NEON, true, true, 0)

	-- ---------- power cells ----------
	local cells = M(world, "Cells")
	local c1 = P(cells, "Cell1", V3.new(1.5, 1.5, 1.5), V3.new(-34, 1.6, -20), C3.fromRGB(255, 200, 60), NEON, true, true, 0)
	prompt(c1, "Pick up Cell", "Power Cell", 0.3)
	local c2 = P(cells, "Cell2", V3.new(1.5, 1.5, 1.5), V3.new(28, 1.6, 31), C3.fromRGB(255, 200, 60), NEON, true, true, 0)
	prompt(c2, "Pick up Cell", "Power Cell", 0.3)
	local c3 = P(cells, "Cell3", V3.new(1.5, 1.5, 1.5), V3.new(38, 14.9, -3), C3.fromRGB(255, 200, 60), NEON, true, true, 0)
	prompt(c3, "Pick up Cell", "Power Cell", 0.3)

	-- ---------- survivors ----------
	local survs = M(world, "Survivors")
	local function survivor(name, position)
		local m = M(survs, name)
		P(m, "HumanoidRootPart", V3.new(2, 2, 1), position, C3.fromRGB(200, 180, 160), SMOOTH, true, true, 1)
		P(m, "Head", V3.new(1.3, 1.3, 1.3), position + V3.new(0, 1.55, 0), C3.fromRGB(232, 202, 180), SMOOTH, true, true, 0)
		P(m, "Torso", V3.new(1.7, 2.1, 0.9), position + V3.new(0, 0, 0), C3.fromRGB(96, 138, 196), FABRIC, true, true, 0)
		P(m, "LegL", V3.new(0.75, 1.9, 0.75), position + V3.new(-0.42, -1.95, 0), C3.fromRGB(58, 58, 76), FABRIC, true, true, 0)
		P(m, "LegR", V3.new(0.75, 1.9, 0.75), position + V3.new(0.42, -1.95, 0), C3.fromRGB(58, 58, 76), FABRIC, true, true, 0)
		local hum = roblox.Instance.new("Humanoid")
		hum.Name = "Humanoid"
		hum.MaxHealth = 100
		hum.Health = 100
		hum.WalkSpeed = 9
		hum.Parent = m
		local pr = roblox.Instance.new("ProximityPrompt")
		pr.ActionText = "Lead"
		pr.ObjectText = name
		pr.HoldDuration = 0.2
		pr.MaxActivationDistance = 12
		pr.Parent = m.HumanoidRootPart
		return m
	end
	-- Placement is a deliberate route puzzle: two shells need the bridge, one needs the tower.
	survivor("Survivor1", V3.new(-9, 1.2, -12)) -- terminal forecourt (easy)
	survivor("Survivor2", V3.new(-33, 1.2, -18)) -- pump house pit (with cell 1)
	survivor("Survivor3", V3.new(24, 1.4, 27)) -- clinic ward
	survivor("Survivor4", V3.new(-18, 1.4, 30)) -- workshop
	survivor("Survivor5", V3.new(33, 7.6, -11.4)) -- apartment 2nd floor (needs stairwell)
	survivor("Survivor6", V3.new(-2, 1.2, 12)) -- street by the shelter
	survivor("Survivor7", V3.new(40, 1.6, -1)) -- apartment ground floor
	survivor("Survivor8", V3.new(0, 16.6, -40)) -- tower platform (lift route or ladder)

	-- ---------- spawn ----------
	local sp = roblox.Instance.new("SpawnLocation")
	sp.Name = "SpawnLocation"
	sp.Size = V3.new(6, 1, 6)
	sp.Position = V3.new(0, 0.5, -12)
	sp.Color = C3.fromRGB(255, 200, 80)
	sp.Material = NEON
	sp.Anchored = true
	sp.CanCollide = true
	sp.Parent = world
end)

-- ============================================================
-- 2. ROJO PROJECT — maps the real source tree into the place
-- ============================================================
local sourceFiles = {
	shared = { "Config", "Net", "Util" },
	server = {
		"FloodService", "HazardService", "InteractService", "LiftService", "ObjectiveService",
		"PlayerService", "PowerService", "RescueService", "RoundService", "ScoringService",
		"Telemetry", "WorldService",
	},
	client = { "Effects", "Hud", "Markers", "Results" },
}

local function countLines(path: string): number
	local content = fs.readFile(path)
	local lines = 0
	for _ in string.gmatch(content, "\n") do
		lines += 1
	end
	return lines
end

local stats = { server = 0, client = 0, shared = 0 }
for _, name in ipairs(sourceFiles.shared) do
	stats.shared += countLines(AGENT .. "/src/shared/" .. name .. ".luau")
end
for _, name in ipairs(sourceFiles.server) do
	stats.server += countLines(AGENT .. "/src/server/Modules/" .. name .. ".luau")
end
stats.server += countLines(AGENT .. "/src/server/Bootstrap.server.luau")
for _, name in ipairs(sourceFiles.client) do
	stats.client += countLines(AGENT .. "/src/client/Modules/" .. name .. ".luau")
end
stats.client += countLines(AGENT .. "/src/client/Client.client.luau")

local project = [[{
  "name": "FLOODLINE",
  "tree": {
    "$className": "DataModel",
    "Workspace": {
      "$className": "Workspace",
      "$properties": { "StreamingEnabled": false, "FilteringEnabled": true },
      "World": { "$path": "generated/models/World.rbxmx" }
    },
    "ReplicatedStorage": {
      "$className": "ReplicatedStorage",
      "Shared": {
        "$className": "Folder",
        "Config": { "$path": "src/shared/Config.luau" },
        "Net": { "$path": "src/shared/Net.luau" },
        "Util": { "$path": "src/shared/Util.luau" }
      }
    },
    "ServerScriptService": {
      "$className": "ServerScriptService",
      "Bootstrap": { "$path": "src/server/Bootstrap.server.luau" },
      "Modules": {
        "$className": "Folder",
        "FloodService": { "$path": "src/server/Modules/FloodService.luau" },
        "HazardService": { "$path": "src/server/Modules/HazardService.luau" },
        "InteractService": { "$path": "src/server/Modules/InteractService.luau" },
        "LiftService": { "$path": "src/server/Modules/LiftService.luau" },
        "ObjectiveService": { "$path": "src/server/Modules/ObjectiveService.luau" },
        "PlayerService": { "$path": "src/server/Modules/PlayerService.luau" },
        "PowerService": { "$path": "src/server/Modules/PowerService.luau" },
        "RescueService": { "$path": "src/server/Modules/RescueService.luau" },
        "RoundService": { "$path": "src/server/Modules/RoundService.luau" },
        "ScoringService": { "$path": "src/server/Modules/ScoringService.luau" },
        "Telemetry": { "$path": "src/server/Modules/Telemetry.luau" },
        "WorldService": { "$path": "src/server/Modules/WorldService.luau" }
      }
    },
    "StarterPlayer": {
      "$className": "StarterPlayer",
      "$properties": { "CharacterWalkSpeed": 16, "CharacterJumpPower": 50, "CameraMaxZoomDistance": 34, "EnableMouseLockOption": true },
      "StarterPlayerScripts": {
        "$className": "StarterPlayerScripts",
        "Client": { "$path": "src/client/Client.client.luau" },
        "Modules": {
          "$className": "Folder",
          "Effects": { "$path": "src/client/Modules/Effects.luau" },
          "Hud": { "$path": "src/client/Modules/Hud.luau" },
          "Markers": { "$path": "src/client/Modules/Markers.luau" },
          "Results": { "$path": "src/client/Modules/Results.luau" }
        }
      }
    },
    "Lighting": {
      "$className": "Lighting",
      "$properties": { "Brightness": 1.6, "ClockTime": 17.2, "Ambient": [0.18, 0.2, 0.24], "OutdoorAmbient": [0.22, 0.25, 0.3], "FogEnd": 420, "FogStart": 90 }
    },
    "SoundService": {
      "$className": "SoundService",
      "$properties": { "RespectFilteringEnabled": true }
    }
  }
}]]

fs.writeFile(AGENT .. "/default.project.json", project)
fs.writeFile(GEN .. "/project.json", project)

local rojo = "/home/user/.cache/floodline-tools/bin/rojo"
local outPath = AGENT .. "/releases/FLOODLINE.rbxlx"
fs.writeDir(AGENT .. "/releases")
local res = process.exec(rojo, { "build", AGENT .. "/default.project.json", "-o", outPath })
if res.code ~= 0 then
	print("rojo stderr:", res.stderr)
	process.exit(res.code)
end

local bytes = #fs.readFile(outPath)
print(`built {outPath}`)
print(`bytes={bytes} serverLines={stats.server} clientLines={stats.client} sharedLines={stats.shared}`)
fs.writeFile(AGENT .. "/evidence/build-stats.json", string.format(
	'{\n  "place": "agents/riveter/releases/FLOODLINE.rbxlx",\n  "bytes": %d,\n  "serverLines": %d,\n  "clientLines": %d,\n  "sharedLines": %d,\n  "totalLines": %d\n}\n',
	bytes, stats.server, stats.client, stats.shared, stats.server + stats.client + stats.shared
))
