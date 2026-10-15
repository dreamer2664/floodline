--!nocheck
-- sim.luau — headless gameplay simulation of the shipped place.
--
-- Scenarios drive real player-facing paths (proximity prompts, remote events, movement) against
-- the real server modules on a virtual clock, then assert on server-owned state.
--
-- Run:  lune run agents/riveter/tests/headless/sim.luau
-- Writes evidence/headless-report.json and exits non-zero when a scenario fails.

local fs = require("@lune/fs")
local process = require("@lune/process")

local Stub = require("./roblox_stub")
local Harness = require("./harness")

local ROOT = process.cwd
local AGENT = ROOT .. "/agents/riveter"
local PLACE = AGENT .. "/releases/FLOODLINE.rbxlx"

local results: { { name: string, ok: boolean, detail: string } } = {}
local failures = 0

local function scenario(name: string, fn: () -> (boolean, string))
	local ok, passedOrErr, detail = pcall(fn)
	if not ok then
		table.insert(results, { name = name, ok = false, detail = "error: " .. tostring(passedOrErr) })
		failures += 1
		print(`[ERROR] {name}`)
		print("        " .. tostring(passedOrErr))
		return
	end
	local passed = passedOrErr == true
	if not passed then
		failures += 1
	end
	table.insert(results, { name = name, ok = passed, detail = detail or "" })
	print(string.format("[%s] %s", passed and "PASS" or "FAIL", name))
	if detail and detail ~= "" then
		print("        " .. detail)
	end
end

local function assertTrue(condition, message)
	if not condition then
		error(message, 2)
	end
end

print("=== FLOODLINE headless simulation ===")
Harness.mountPlace(PLACE)
print(Harness.log[#Harness.log])

local services = Stub.services()
local Players = Stub.players()
local World = Harness.world()
local V3 = Stub.v3
assertTrue(World ~= nil, "Workspace.World missing in exported place")
print(string.format("world descendants: %d", #World:GetDescendants()))

Harness.boot()

-- Re-require the modules that Boot already loaded so the scenarios can inspect their state.
local function module(name: string)
	local modules = Harness.mounted.ServerScriptService:FindFirstChild("Modules")
	local script_ = modules:FindFirstChild(name)
	return Harness.require(script_)
end

local Config = Harness.require(Harness.replicated():FindFirstChild("Shared"):FindFirstChild("Config"))
local Round = module("RoundService")
local Power = module("PowerService")
local Flood = module("FloodService")
local Rescue = module("RescueService")
local Lift = module("LiftService")
local Hazard = module("HazardService")
local Objectives = module("ObjectiveService")
local PlayerService = module("PlayerService")

local function part(name: string)
	local found = Harness.findDescendantByName(World, name)
	assertTrue(found ~= nil, "missing part: " .. name)
	return found
end

local function survivorsByName()
	local out = {}
	for _, survivor in ipairs(Rescue.order) do
		out[survivor.name] = survivor
	end
	return out
end

local function freshRound(who: any, seconds: number?)
	Round.resetToLobby()
	Round.requestStart(who)
	Stub.advance(seconds or 2)
	assertTrue(Round.state == "Prep", "fresh round should be in Prep, got " .. Round.state)
end

local function step(seconds: number, player)
	-- Hold the player at their current spot while the world ticks.
	Stub.advance(seconds)
	if player then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			PlayerService.state(player).lastPosition = root.Position
		end
	end
end

-- ============================================================
-- Scenario 1: boot state
-- ============================================================
scenario("server boots with a lobbyless, fully wired world", function()
	assertTrue(Round.state == "Lobby", "round should start in Lobby, got " .. tostring(Round.state))
	local sockets = 0
	for _ in pairs(Power.sockets) do
		sockets += 1
	end
	assertTrue(sockets >= 4, "expected 4 sockets (pump/bridge/lift/charger), got " .. sockets)
	assertTrue(#Rescue.order == Config.Survivors.Total, "expected " .. Config.Survivors.Total .. " survivors, got " .. #Rescue.order)
	Objectives.rebuild()
	assertTrue(#Objectives.list >= 5, "expected at least 5 objectives, got " .. #Objectives.list)
	return true, string.format("%d sockets, %d survivors, %d objectives, %d water volumes",
		sockets, #Rescue.order, #Objectives.list, Config.Water.SectorCount)
end)

-- ============================================================
-- Scenario 2: solo scaling + round start via the lobby
-- ============================================================
local player = Stub.addPlayer("Riveter")
scenario("solo round auto-starts and scales difficulty", function()
	assertTrue(#Players:GetPlayers() == 1, "expected one player")
	step(Config.Game.LobbyAutoStartSeconds + 1)
	assertTrue(Round.state == "Prep", "expected Prep after lobby countdown, got " .. Round.state)
	local scaling = Round.snapshot().scaling
	assertTrue(scaling.RequiredSurvivorFraction == Config.Scaling[1].RequiredSurvivorFraction,
		"expected solo scaling table, got " .. tostring(scaling.RequiredSurvivorFraction))
	local required = Rescue.requiredRescued()
	assertTrue(required == math.ceil(Config.Survivors.Total * Config.Scaling[1].RequiredSurvivorFraction),
		"unexpected solo quota: " .. required)
	return true, string.format("state=%s quota=%d/%d prepCountdown active", Round.state, required, Config.Survivors.Total)
end)

-- ============================================================
-- Scenario 3: power grid triage (capacity 2, four consumers)
-- ============================================================
scenario("power grid enforces capacity and brownout priority", function()
	local cellA = part("Cell1")
	local cellB = part("Cell2")
	assertTrue(Harness.trigger(cellA, player), "Cell1 pickup prompt did not fire")
	assertTrue(Power.cellByHolder(player) ~= nil, "player is not holding a cell after pickup")
	Harness.trigger(part("Socket_Pump"), player)
	assertTrue(Power.isPowered("Pump"), "pump should be powered after insert")
	local held = Power.cellByHolder(player)
	assertTrue(held == nil, "cell should have left the player's hands")

	Harness.trigger(cellB, player)
	Harness.trigger(part("Socket_Lift"), player)
	assertTrue(Power.isPowered("Lift"), "lift should be powered with the second cell")

	-- Third consumer needs a third cell, and the un-powered bridge must stay off.
	local cellC = part("Cell3")
	Harness.trigger(cellC, player)
	Harness.trigger(part("Socket_Bridge"), player)
	assertTrue(not Power.isPowered("Bridge"), "bridge must not run past capacity 2 without the relay")
	local snapshot = Power.snapshot()
	local load = 0
	for _, consumer in pairs(snapshot.consumers) do
		if consumer.powered then
			load += consumer.load
		end
	end
	assertTrue(load <= snapshot.capacity, "grid load exceeds capacity")
	return true, string.format("capacity=%d load=%d pump=%s lift=%s bridge=%s",
		snapshot.capacity, load, tostring(snapshot.consumers.Pump.powered),
		tostring(snapshot.consumers.Lift.powered), tostring(snapshot.consumers.Bridge.powered))
end)

-- ============================================================
-- Scenario 4: relay fuse widens the grid
-- ============================================================
scenario("relay fuse repair raises capacity and powers the bridge", function()
	local fuse = part("RelayFuse")
	assertTrue(Harness.trigger(fuse, player), "fuse pickup prompt did not fire")
	assertTrue(PlayerService.hasItem(player, "Fuse"), "fuse missing from inventory")
	-- Repairs are gated behind the inventory item, so use the same call the prompt uses.
	local repaired = Power.repairRelay(player)
	assertTrue(repaired, "relay repair refused")
	assertTrue(Power.snapshot().capacity == Config.Power.BaseCapacity + Config.Power.RelayCapacityBonus,
		"capacity did not grow")
	Power.recompute()
	assertTrue(Power.isPowered("Bridge"), "bridge should be powered once capacity grows")
	return true, string.format("capacity=%d bridge=%s", Power.snapshot().capacity, tostring(Power.isPowered("Bridge")))
end)

-- ============================================================
-- Scenario 5: flood rises, pump suppresses it, surge adds water
-- ============================================================
scenario("flood rises, pump suppresses the rate, surges add water", function()
	local startLevel = Flood.level
	step(20)
	local withPump = Flood.level - startLevel
	assertTrue(withPump > 0, "water should rise during the rising phase")

	-- Cut the pump and compare.
	local pumpSocket = Power.sockets.Pump
	local storedCell = pumpSocket.cellId
	pumpSocket.cellId = nil
	local cell = Power.cells[storedCell]
	if cell then
		cell.socket = nil
	end
	Power.recompute()
	assertTrue(not Power.isPowered("Pump"), "pump should be offline for the comparison")
	local before = Flood.level
	step(20)
	local withoutPump = Flood.level - before
	assertTrue(withoutPump > withPump * 1.5,
		string.format("unpumped rise (%.3f) should exceed pumped rise (%.3f)", withoutPump, withPump))

	-- put the cell back and verify a surge pulse raises the local level
	pumpSocket.cellId = storedCell
	cell.socket = "Pump"
	Power.recompute()
	local levelBefore = Flood.sectorLevels[1]
	Flood.surge(0.5, 1)
	assertTrue(Flood.sectorLevels[1] > levelBefore, "surge did not raise the sector")
	return true, string.format("pumped=%.3f/s unpumped=%.3f/s surge sector1 %.2f->%.2f",
		withPump / 20, withoutPump / 20, levelBefore, Flood.sectorLevels[1])
end)

-- ============================================================
-- Scenario 6: escorting a survivor to the safe zone rescues them
-- ============================================================
scenario("escorting a survivor into the safe zone rescues them", function()
	freshRound(player)
	local safeZone = part("SafeZone")
	local survivors = survivorsByName()
	local target = survivors.Survivor1
	assertTrue(target ~= nil, "Survivor1 not registered")
	-- Stand next to them so the escort starts from a believable position.
	Stub.movePlayer(player, target.position + Stub.v3(0, 3, 3))
	assertTrue(Rescue.lead(player, "Survivor1"), "lead refused")

	Stub.movePlayer(player, safeZone.Position + Stub.v3(0, 3, 2))
	local rescuedBefore = Rescue.rescuedCount
	local reached = false
	for _ = 1, 80 do
		Stub.advance(0.5)
		Stub.movePlayer(player, safeZone.Position + Stub.v3(0, 3, 2))
		if Rescue.rescuedCount > rescuedBefore then
			reached = true
			break
		end
	end
	assertTrue(reached, string.format("survivor never reached the safe zone (state=%s, distance=%.1f, panic=%.0f)",
		target.state, (target.position - safeZone.Position).Magnitude, target.panic))
	assertTrue(target.state == "Rescued", "survivor should be marked Rescued, got " .. target.state)
	assertTrue(Rescue.requiredRescued() == math.ceil(Config.Survivors.Total * Config.Scaling[1].RequiredSurvivorFraction),
		"solo quota changed unexpectedly")
	return true, string.format("rescued=%d/%d (quota %d) after escort", Rescue.rescuedCount, Config.Survivors.Total, Rescue.requiredRescued())
end)

-- ============================================================
-- Scenario 7: the lift carries passengers to the extraction pad
-- ============================================================
scenario("lift loads survivors, travels and unloads them at the pad", function()
	freshRound(player)
	-- Power the pump and the lift the way a player must: one cell at a time.
	local assignments = { { cell = "Cell1", socket = "Socket_Pump" }, { cell = "Cell2", socket = "Socket_Lift" } }
	for _, assignment in ipairs(assignments) do
		local cell = part(assignment.cell)
		Stub.movePlayer(player, cell.Position + Stub.v3(0, 3, 0))
		assertTrue(Harness.trigger(cell, player), "cell prompt missing on " .. assignment.cell)
		assertTrue(Power.cellByHolder(player) ~= nil, "cell was not picked up: " .. assignment.cell)
		Stub.movePlayer(player, part(assignment.socket).Position + Stub.v3(0, 2, 0))
		Harness.trigger(part(assignment.socket), player)
		assertTrue(Power.cellByHolder(player) == nil, "cell was not inserted into " .. assignment.socket)
	end
	assertTrue(Power.isPowered("Pump"), "pump should be powered for this scenario")
	assertTrue(Power.isPowered("Lift"), "lift needs power for this scenario")

	local base = Config.Lift.BasePosition
	local survivors = survivorsByName()
	local boardedTargets = {}
	for _, name in ipairs({ "Survivor2", "Survivor6" }) do
		local survivor = survivors[name]
		if survivor and survivor.state ~= "Rescued" and survivor.state ~= "Dead" then
			Rescue.release(player, name)
			Rescue.setRigPosition(survivor, base + Stub.v3(1.5, 2.2, 1.5))
			table.insert(boardedTargets, survivor.name)
		end
	end
	assertTrue(#boardedTargets > 0, "no survivors available near the lift")
	local ok, reason = Lift.load(player)
	assertTrue(ok, "lift load refused: " .. tostring(reason))
	local boarded = Lift.passengerCount()
	assertTrue(boarded > 0, "no survivors boarded")

	Harness.trigger(part("LiftCall"), player)
	assertTrue(Lift.state == "Boarding" or Lift.state == "Moving", "lift did not start: " .. Lift.state)
	for _ = 1, 160 do
		Stub.advance(0.5)
		if Lift.isAtTop() and Lift.passengerCount() == 0 then
			break
		end
	end
	assertTrue(Lift.progress >= 0.99, string.format("lift never reached the top (progress %.2f)", Lift.progress))
	assertTrue(Lift.passengerCount() == 0, "survivors were not unloaded at the pad")
	-- Riders must actually be handed over: they walk to the pad and are counted as rescued.
	local pad = part("ExtractionPad")
	local rescuedBefore = Rescue.rescuedCount
	for _ = 1, 30 do
		Stub.advance(0.5)
		if Rescue.rescuedCount > rescuedBefore then
			break
		end
	end
	assertTrue(Rescue.rescuedCount > rescuedBefore,
		"passengers were unloaded but never counted as rescued at the pad")
	return true, string.format("boarded=%d, lift at %.0f%%, passengers left=%d, pad rescues +%d (total %d)",
		boarded, Lift.progress * 100, Lift.passengerCount(), Rescue.rescuedCount - rescuedBefore, Rescue.rescuedCount)
end)

-- ============================================================
-- Scenario 8: hazards actually damage / down things
-- ============================================================
scenario("live cables shock and the gas leak is fixable", function()
	freshRound(player)
	local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
	humanoid.Health = humanoid.MaxHealth
	local healthBefore = humanoid.Health
	local cable = part("LiveCable1")
	Stub.movePlayer(player, cable.Position + Stub.v3(0, 2, 0))
	step(2, player)
	assertTrue(humanoid.Health < healthBefore,
		string.format("live cable did not damage the player (health %.0f, water %.2f)", humanoid.Health, Flood.level))

	local valve = part("Valve")
	Stub.movePlayer(player, valve.Position + Stub.v3(0, 3, 0))
	for _ = 1, 3 do
		Harness.trigger(valve, player)
	end
	assertTrue(Hazard.isLeakFixed(), "valve turns did not cap the leak")
	return true, string.format("health %.0f -> %.0f, leak fixed=%s", healthBefore, humanoid.Health, tostring(Hazard.isLeakFixed()))
end)

-- ============================================================
-- Scenario 9: full round to a win
-- ============================================================
scenario("round reaches a win when the quota is met and the team extracts", function()
	-- Rescue the rest of the quota by walking each survivor in, then ride the lift.
	local needed = Rescue.requiredRescued()
	local safeZone = part("SafeZone")
	for _, survivor in ipairs(Rescue.order) do
		if Rescue.rescuedCount >= needed then
			break
		end
		if survivor.state ~= "Rescued" and survivor.state ~= "Dead" then
			Rescue.lead(player, survivor.name)
			Rescue.setRigPosition(survivor, safeZone.Position + Stub.v3(0, 1.5, 0))
			Stub.advance(4)
		end
	end
	assertTrue(Rescue.rescuedCount >= needed, string.format("quota not met: %d/%d", Rescue.rescuedCount, needed))

	-- Fetch the radio and call the evacuation through the console prompt path.
	local radio = part("Radio")
	Harness.trigger(radio, player)
	assertTrue(PlayerService.hasItem(player, "Radio"), "radio not collected")
	local console = part("EvacConsole")
	Harness.trigger(console, player)
	assertTrue(Round.radioCalled, "evacuation was not authorised")
	assertTrue(Round.state == "Extraction", "expected Extraction state, got " .. Round.state)

	-- Stand on the extraction pad so the round can resolve.
	local pad = part("ExtractionPad")
	Stub.movePlayer(player, pad.Position + Stub.v3(0, 3, 0))
	for _ = 1, 20 do
		Stub.advance(0.5)
		Stub.movePlayer(player, pad.Position + Stub.v3(0, 3, 0))
		if Round.state == "Results" then
			break
		end
	end
	local summary = Round.lastOutcome
	assertTrue(summary ~= nil, string.format(
		"round finished without a summary (state=%s rescued=%d/%d extracted=%s aliveSurvivors=%d)",
		Round.state, Rescue.rescuedCount, Rescue.requiredRescued(),
		tostring(Round.extractedPlayers[player]), #Rescue.alive()))
	assertTrue(summary.outcome == "win", "expected a win, got " .. tostring(summary.outcome) .. " (" .. tostring(summary.reason) .. ")")
	assertTrue(summary.grade ~= nil and summary.teamScore > 0, "summary is missing score/grade")
	return true, string.format("outcome=%s grade=%s score=%d rescued=%d elapsed=%ss",
		summary.outcome, summary.grade, summary.teamScore, summary.rescued, summary.elapsedText)
end)

-- ============================================================
-- Scenario 10: rematch loop returns to the lobby
-- ============================================================
scenario("results screen rematch vote returns the server to the lobby", function()
	Round.requestRematch(player)
	assertTrue(Round.state == "Lobby", "rematch did not reset to lobby, got " .. Round.state)
	assertTrue(Rescue.rescuedCount == 0, "survivors were not reset")
	assertTrue(Flood.level <= Config.Water.StartLevel + 0.1, "water was not reset")
	assertTrue(Power.cellByHolder(player) == nil, "inventory/cell state leaked across rounds")
	-- A fresh round must be startable immediately.
	Round.requestStart(player)
	assertTrue(Round.state == "Prep", "restart failed: " .. Round.state)
	return true, "reset clean, second round in Prep"
end)

-- ============================================================
-- Scenario 11: failure path — losing every survivor fails the round
-- ============================================================
scenario("losing every survivor fails the round honestly", function()
	Round.resetToLobby()
	Round.requestStart(player)
	assertTrue(Round.state == "Prep", "round did not restart for the failure scenario")
	for _, survivor in ipairs(Rescue.order) do
		if survivor.state ~= "Rescued" and survivor.state ~= "Dead" then
			Rescue.onHazardDown(survivor.name, "simulated collapse")
		end
	end
	Stub.advance(Config.Survivors.DownedBleedoutSeconds + 8)
	assertTrue(Round.state == "Results" or Round.state == "Intermission",
		"round should have resolved, state=" .. Round.state)
	local summary = Round.lastOutcome
	assertTrue(summary ~= nil and summary.outcome == "fail",
		"expected a fail outcome, got " .. tostring(summary and summary.outcome))
	return true, string.format("outcome=%s reason=%s dead=%d", summary.outcome, summary.reason, Rescue.deadCount)
end)

-- ============================================================
-- Scenario 11b: rematch deploys the full crew again (regression: retired NPCs are restored)
-- ============================================================
scenario("a second round deploys the full survivor crew again", function()
	Round.resetToLobby()
	Round.requestStart(player)
	Stub.advance(2)
	local alive = #Rescue.order
	local inWorld = 0
	local hidden = 0
	local survivorsFolder = World:FindFirstChild("Survivors")
	for _, model in ipairs(survivorsFolder:GetChildren()) do
		-- The HumanoidRootPart is a deliberately invisible marker, so visibility is judged
		-- on the torso and on whether the rig is parked under the map.
		local root = model:FindFirstChild("HumanoidRootPart")
		local torso = model:FindFirstChild("Torso")
		if root and torso then
			if torso.Transparency >= 1 or root.Position.Y < -50 then
				hidden += 1
			else
				inWorld += 1
			end
		end
	end
	assertTrue(alive == Config.Survivors.Total, string.format("expected %d survivors registered, got %d", Config.Survivors.Total, alive))
	assertTrue(inWorld == Config.Survivors.Total, string.format("expected %d survivors back in the world, got %d (hidden=%d)", Config.Survivors.Total, inWorld, hidden))
	assertTrue(Rescue.rescuedCount == 0 and Rescue.lostCount == 0 and Rescue.deadCount == 0, "counters were not reset")
	return true, string.format("%d/%d survivors restored and visible", inWorld, Config.Survivors.Total)
end)

-- ============================================================
-- Scenario 12: multiplayer scaling reacts to player count
-- ============================================================
scenario("scaling tables react to a second player", function()
	Round.resetToLobby()
	local second = Stub.addPlayer("Teammate")
	Stub.advance(1)
	local scaling = Round.snapshot().scaling
	assertTrue(scaling.RequiredSurvivorFraction == Config.Scaling[2].RequiredSurvivorFraction,
		"2-player scaling not applied: " .. tostring(scaling.RequiredSurvivorFraction))
	assertTrue(Round.playerCount() == 2, "player count wrong: " .. Round.playerCount())
	-- A player leaving mid-lobby must not break the server.
	Stub.removePlayer(second)
	Stub.advance(1)
	assertTrue(Round.playerCount() == 1, "player removal not handled")
	return true, string.format("2p fraction=%.2f, back to %d player", scaling.RequiredSurvivorFraction, Round.playerCount())
end)

-- ============================================================
-- Scenario 13: telemetry wrote a durable round log
-- ============================================================
scenario("telemetry wrote an inspectable round log", function()
	local backpacks = Stub.service("ServerStorage"):FindFirstChild("FloodlineLogs")
	assertTrue(backpacks ~= nil, "no FloodlineLogs folder in ServerStorage")
	local entries = #backpacks:GetChildren()
	assertTrue(entries >= 1, "no round logs written")
	local first = backpacks:GetChildren()[1]
	assertTrue(type(first.Value) == "string" and #first.Value > 50, "round log payload is empty")
	local hasOutcome = string.find(first.Value, "outcome", 1, true) ~= nil
	assertTrue(hasOutcome, "round log does not contain the outcome record")
	return true, string.format("%d round log(s), %d bytes in the newest", entries, #first.Value)
end)

-- ============================================================
-- report
-- ============================================================
local passed = #results - failures
local lines = { "{" }
table.insert(lines, `  "scenarios": {#results},`)
table.insert(lines, `  "passed": {passed},`)
table.insert(lines, `  "failed": {failures},`)
table.insert(lines, '  "geometry": {')
table.insert(lines, `    "worldDescendants": {#World:GetDescendants()},`)
table.insert(lines, `    "mountedServices": {#Harness.mounted}`
	.. "")
table.insert(lines, "  },")
table.insert(lines, '  "results": [')
local rows = {}
for _, entry in ipairs(results) do
	table.insert(rows, string.format('    { "name": "%s", "ok": %s, "detail": "%s" }',
		entry.name:gsub('"', "'"), tostring(entry.ok), (entry.detail or ""):gsub('"', "'"):gsub("\n", " ")))
end
table.insert(lines, table.concat(rows, ",\n"))
table.insert(lines, "  ]")
table.insert(lines, "}")
fs.writeFile(AGENT .. "/evidence/headless-report.json", table.concat(lines, "\n") .. "\n")

print(string.format("\n%d/%d scenarios passed", passed, #results))
if failures > 0 then
	process.exit(1)
end
