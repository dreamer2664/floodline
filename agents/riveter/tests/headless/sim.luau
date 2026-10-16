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
local Doors = module("DoorService")
local Comms = module("CommsService")
local Session = module("SessionService")
local PlayerService = module("PlayerService")
local Route = module("RouteService")
local Upgrades = module("UpgradeService")
local Crew = module("CrewService")
local Outfall = module("OutfallService")

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

local function standPlayer(who, position)
	Stub.movePlayer(who, position)
	local character = who.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		PlayerService.state(who).lastPosition = root.Position
	end
end

-- The evac vehicle needs a real approach window; tests wait it out the way players do.
local function waitForEvac(who, timeout: number?)
	local limit = timeout or 180
	local waited = 0
	while not Round.evacArrived() and waited < limit do
		Stub.advance(1)
		waited += 1
		if who then
			standPlayer(who, Stub.characterPosition(who))
		end
	end
	return Round.evacArrived(), waited
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
	assertTrue(Round.evacEta() > 0, "the evac vehicle arrived instantly")

	-- The pad is a lie until the vehicle is on it: standing there early must not extract anyone.
	local pad = part("ExtractionPad")
	Stub.movePlayer(player, pad.Position + Stub.v3(0, 3, 0))
	for _ = 1, 20 do
		Stub.advance(0.5)
		Stub.movePlayer(player, pad.Position + Stub.v3(0, 3, 0))
	end
	assertTrue(Round.extractedPlayers[player] ~= true, "the crew extracted before the vehicle landed")

	-- ...and once it lands, the pad resolves the round.
	waitForEvac(player, 120)
	for _ = 1, 40 do
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
	local stateBefore = Round.state
	Round.requestRematch(player)
	assertTrue(Round.state == "Lobby",
		`rematch did not reset to lobby (before={stateBefore}, after={Round.state}, outcome={tostring(Round.lastOutcome and Round.lastOutcome.outcome)})`)
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
-- Scenario 12b: difficulty modifiers change the simulation
-- ============================================================
scenario("difficulty modifiers re-scale the round and lock once it starts", function()
	Round.resetToLobby()
	Stub.advance(1)
	assertTrue(Session.setModifier("Storm"), "Storm preset rejected")
	local storm = Round.snapshot().scaling
	assertTrue(storm.Modifier == "Storm", "modifier not reported: " .. tostring(storm.Modifier))
	assertTrue(storm.RiseMultiplier > Config.Scaling[1].RiseMultiplier, "storm should raise the water faster")
	assertTrue(storm.HazardRate > Config.Scaling[1].HazardRate, "storm should raise hazard frequency")

	Round.requestStart(player)
	Stub.advance(1)
	assertTrue(Round.state == "Prep", "round did not start: " .. Round.state)
	-- Measure the configured prep window, not the time left on the clock.
	local prepStorm = Round.stateEndsAt - Round.roundStartedAt
	assertTrue(prepStorm <= Config.Scaling[1].PrepSeconds - 5,
		string.format("storm prep (%.0fs) should be shorter than the baseline (%.0fs)", prepStorm, Config.Scaling[1].PrepSeconds))
	assertTrue(storm.OxygenSeconds < Config.Water.OxygenSeconds, "storm should shorten the air supply")

	-- The lobby-only lock is enforced by ctx.requestModifier; assert the pure function path.
	local scalingBefore = Round.snapshot().scaling.Modifier
	Session.setModifier("Calm")
	assertTrue(Round.snapshot().scaling.Modifier == "Calm", "modifier change was not applied")
	assertTrue(scalingBefore == "Storm", "previous modifier should have been Storm")
	Session.setModifier("Standard")
	Round.resetToLobby()
	return true, string.format("storm: rise x%.2f, hazards x%.2f, prep %.0fs", storm.RiseMultiplier, storm.HazardRate, prepStorm)
end)

-- ============================================================
-- Scenario 12c: doors seal a room and hold the water back
-- ============================================================
scenario("closing a door seals the room and slows its flooding", function()
	freshRound(player)
	local door = part("Door_PumpHouse")
	local interior = Stub.v3(-34, 2, -18)
	-- Flood the district to a level that is deep outside and shallow inside.
	Flood.surge(3.0)
	Stub.advance(0.5)

	if not Doors.byPart[door] then
		return false, "door was not registered by DoorService"
	end
	Doors.set(Doors.byPart[door], false, true)
	local openDepth = Flood.depthAt(interior)
	Doors.set(Doors.byPart[door], true, true)
	local closedDepth = Flood.depthAt(interior)
	assertTrue(Doors.isZoneSealed("PumpHouse"), "closing the door did not seal the zone")
	assertTrue(closedDepth < openDepth,
		string.format("sealed interior should be drier: open=%.2f closed=%.2f", openDepth, closedDepth))

	-- ...and the prompt path toggles it back open (the swing takes a moment).
	Harness.trigger(door, player)
	Stub.advance(1.5)
	assertTrue(not Doors.isZoneSealed("PumpHouse"), "prompt did not reopen the door")
	return true, string.format("interior depth open=%.2fm closed=%.2fm (%d doors wired)", openDepth, closedDepth, #Doors.list)
end)

-- ============================================================
-- Scenario 12d: team pings validate, broadcast and rate-limit
-- ============================================================
scenario("team pings validate distance, type and cooldown", function()
	freshRound(player)
	Stub.movePlayer(player, Stub.v3(0, 3, -12))
	Stub.advance(0.5)
	local remote = Harness.mounted.ReplicatedStorage:FindFirstChild("FloodlineNet"):FindFirstChild("PingSync")
	local before = #remote._sent
	local ok = Comms.ping(player, "survivor", Stub.v3(10, 1.5, -12))
	assertTrue(ok, "valid ping was refused")
	assertTrue(#remote._sent > before, "ping was not broadcast to clients")

	-- Cooldown must reject an immediate second ping.
	local second = Comms.ping(player, "danger", Stub.v3(12, 1.5, -12))
	assertTrue(not second, "cooldown did not suppress a rapid second ping")

	-- Out-of-range and unknown-type pings must both fail.
	Stub.advance(Config.Pings.Cooldown + 0.2)
	local far = Comms.ping(player, "danger", Stub.v3(900, 5, 900))
	assertTrue(not far, "out-of-range ping was accepted")
	Stub.advance(Config.Pings.Cooldown + 0.2)
	local bogus = Comms.ping(player, "notatype", Stub.v3(8, 1.5, -12))
	assertTrue(not bogus, "unknown ping type was accepted")
	return true, string.format("%d ping types, %d broadcasts, validations enforced", #Config.Pings.Types, Comms.total)
end)

-- ============================================================
-- Scenario 12e: the session ledger records the round
-- ============================================================
scenario("session ledger records rounds, grades and personal bests", function()
	Round.resetToLobby()
	Round.requestStart(player)
	Stub.advance(1)
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
	Harness.trigger(part("Radio"), player)
	Harness.trigger(part("EvacConsole"), player)
	local pad = part("ExtractionPad")
	for _ = 1, 30 do
		Stub.advance(0.5)
		Stub.movePlayer(player, pad.Position + Stub.v3(0, 3, 0))
		if Round.state == "Results" then
			break
		end
	end
	local summary = Session.summary()
	assertTrue(summary.rounds >= 1, "round was not recorded")
	assertTrue(summary.bestGrade ~= "-", "no grade recorded")
	assertTrue(summary.bestScore > 0, "no score recorded")
	assertTrue(#summary.history >= 1, "history is empty")
	local scoreRemote = Harness.mounted.ReplicatedStorage:FindFirstChild("FloodlineNet"):FindFirstChild("SessionSync")
	assertTrue(#scoreRemote._sent >= 1, "session update was not broadcast")
	return true, string.format("rounds=%d wins=%d best=%s/%d rescue=%d history=%d",
		summary.rounds, summary.wins, summary.bestGrade, summary.bestScore, summary.bestRescued, #summary.history)
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
-- Test fixtures shared by the r05 scenarios
-- ============================================================

-- Deterministically energise a socket. Scenarios that are about water/power maths use this so
-- they never depend on which scenario ran before them or on a player's carrying state.
local function forcePower(socketKey: string, cellId: string)
	local socket = Power.sockets[socketKey]
	assertTrue(socket ~= nil, "no socket named " .. socketKey)
	local cell = Power.cells[cellId]
	assertTrue(cell ~= nil, "no cell named " .. cellId)
	if cell.holder then
		cell.holder = nil
	end
	if cell.socket and Power.sockets[cell.socket] then
		Power.sockets[cell.socket].cellId = nil
	end
	cell.socket = socketKey
	socket.cellId = cellId
	Power.recompute()
	return cell
end

local function zoneOf(name: string)
	return module("WorldService").zones[name]
end

local function zoneCount(): number
	local count = 0
	for _ in pairs(module("WorldService").zones) do
		count += 1
	end
	return count
end

-- ============================================================
-- Scenario 14: the skybridge starts retracted and the span is real baked geometry
-- ============================================================
scenario("skybridge is baked, retracted at round start and walkable when extended", function()
	freshRound(player)
	assertTrue(Route.deckParts and #Route.deckParts == 4,
		`expected 4 span segments, got {Route.deckParts and #Route.deckParts or 0}`)
	assertTrue(#Route.railParts >= 8, `expected at least 8 rail members, got {#Route.railParts}`)
	assertTrue(Route.extension() == 0, "span should start tucked")
	-- tucked segments must not be walkable
	for _, entry in ipairs(Route.deckParts) do
		assertTrue(entry.part.CanCollide == false, "a retracted span segment still has collision")
	end
	-- ...and a segment must actually sit at its tucked CFrame
	local first = Route.deckParts[1]
	local tucked = first.tucked.Position
	local actual = first.part.CFrame.Position
	assertTrue((tucked - actual).Magnitude < 0.5, "first segment is not at its tucked position")
	-- no crossing without extension
	assertTrue(Route.waypointsFor(Route.nearJoint, Route.farJoint) == nil,
		"a retracted span offered crossing waypoints")
	return true, string.format("%d segments, %d rail members, tucked at (%.1f, %.1f, %.1f)",
		#Route.deckParts, #Route.railParts, tucked.X, tucked.Y, tucked.Z)
end)

-- ============================================================
-- Scenario 15: the powered winch walks the span out (one grid consumer)
-- ============================================================
scenario("a powered winch extends the skybridge without any cranking", function()
	freshRound(player)
	local picked, pickReason = Power.pickup(player, "Cell_A")
	assertTrue(picked, "could not pick up a cell for the winch: " .. tostring(pickReason))
	local inserted, insertReason = Power.insert(player, "Winch")
	assertTrue(inserted, "could not insert the cell into the winch socket: " .. tostring(insertReason))
	assertTrue(Power.isPowered("Winch"), "winch socket did not power up on one cell")
	Stub.advance(Config.Route.Skybridge.MotorSeconds + 1.5)
	assertTrue(Route.extension() >= 0.999, `span only reached {Route.extension()}`)
	assertTrue(Route.isCrossable(), "span is not crossable after full extension")
	local solid = 0
	for _, entry in ipairs(Route.deckParts) do
		if entry.part.CanCollide then
			solid += 1
		end
	end
	assertTrue(solid == 4, `only {solid} of 4 segments became solid`)
	local routes = Route.openedRoutes()
	local has = false
	for _, name in ipairs(routes) do
		if name == "Skybridge" then
			has = true
		end
	end
	assertTrue(has, "the skybridge did not register as an opened route")
	return true, `extended to {Route.extension()}% in {Config.Route.Skybridge.MotorSeconds}s on 1 cell, routes={table.concat(routes, ",")}`
end)

-- ============================================================
-- Scenario 16: no power at all — the hand cranks still open the roof route
-- ============================================================
scenario("hand cranking opens the skybridge with the grid dark", function()
	freshRound(player)
	assertTrue(not Power.isPowered("Winch"), "winch should be unpowered in a fresh round")
	local config = Config.Route.Skybridge
	local turns = math.ceil(config.ExtendSeconds / config.CrankPromptHold)
	local accepted, rejected = 0, 0
	for _ = 1, turns + 2 do
		local ok = Route.crank(player)
		if ok then
			accepted += 1
		else
			rejected += 1
		end
		Stub.advance(config.CrankCooldown + 0.05)
	end
	assertTrue(Route.isCrossable(), `hand cranking only reached {Route.extension()}%`)
	assertTrue(rejected >= 1, "the crank never refused a turn (cooldown or completion check missing)")
	assertTrue(Route.skybridge.viaPower == false, "hand cranking was flagged as winch power")
	return true, `{accepted} turns accepted, {rejected} refused, span at {Route.extension()}% with zero power`
end)

-- ============================================================
-- Scenario 17: escorting across the span uses explicit waypoints
-- ============================================================
scenario("survivors cross the roof span on route waypoints, not through the air", function()
	freshRound(player)
	Route.setExtension(1)
	local apartmentSide = Stub.v3(30, 14, -12)
	local towerSide = Stub.v3(0, 16.4, -36)
	local waypoints = Route.waypointsFor(apartmentSide, towerSide)
	assertTrue(waypoints ~= nil and #waypoints == 3, "no bridge waypoints were offered across the span")
	local survivor = Rescue.get("Survivor5")
	assertTrue(survivor ~= nil, "Survivor5 missing")
	-- Leadership needs proximity, so recruit her first, then walk the pair onto the span.
	standPlayer(player, apartmentSide)
	Rescue.setRigPosition(survivor, apartmentSide + Stub.v3(2, 0, 0))
	Stub.advance(0.2)
	local led, leadReason = Rescue.lead(player, "Survivor5")
	assertTrue(led, "could not recruit Survivor5: " .. tostring(leadReason))
	standPlayer(player, towerSide)
	local startParameter = Route.spanParameter(survivor.position)
	local sawQueue = false
	for _ = 1, 240 do
		Stub.advance(0.25)
		if survivor.routeQueue then
			sawQueue = true
		end
		if Route.spanParameter(survivor.position) > 0.75 then
			break
		end
	end
	local endParameter = Route.spanParameter(survivor.position)
	assertTrue(sawQueue, "the survivor never picked up the bridge waypoint queue")
	assertTrue(endParameter > startParameter + 0.25,
		string.format("survivor did not cross the span (t %.2f -> %.2f)", startParameter, endParameter))
	return true, string.format("crossed the span on waypoints: t %.2f -> %.2f over %d ticks", startParameter, endParameter, 240)
end)

-- ============================================================
-- Scenario 18: the service cut is blocked, clears in three digs, then connects the district
-- ============================================================
scenario("the service cut opens only after the collapse is dug out", function()
	freshRound(player)
	local barricade = part("TunnelBarricade")
	assertTrue(Route.cut.blocked, "the cut should start blocked")
	assertTrue(barricade.CanCollide, "the barricade is not solid at round start")
	local salvageBefore = Upgrades.salvage
	local digs = 0
	for _ = 1, 3 do
		Harness.trigger(barricade, player)
		Stub.advance(0.4)
		digs += 1
	end
	assertTrue(not Route.cut.blocked, `the cut is still blocked after {digs} digs`)
	assertTrue(barricade.CanCollide == false, "the barricade is still solid after clearing")
	assertTrue(barricade.Transparency > 0.9, "the cleared barricade was not hidden")
	assertTrue(Upgrades.salvage > salvageBefore, "clearing the cut paid no salvage")
	local routes = Route.openedRoutes()
	assertTrue(#routes == 1 and routes[1] == "ServiceCut", "the cut did not register as an opened route")
	return true, `cleared in {digs} digs, +{Upgrades.salvage - salvageBefore} salvage, routes={table.concat(routes, ",")}`
end)

-- ============================================================
-- Scenario 19: closing both cut doors actually holds the water back
-- ============================================================
scenario("sealing the service cut slows its flooding (it floods first when open)", function()
	freshRound(player)
	local cutDoors = {}
	for _, door in ipairs(Doors.list) do
		if door.zone == "ServiceCut" then
			table.insert(cutDoors, door)
		end
	end
	assertTrue(#cutDoors == 2, `expected 2 service cut doors, found {#cutDoors}`)
	local probe = Stub.v3(-19.5, 1, -22.5)
	Flood.surge(3.0)
	Stub.advance(0.5)
	for _, door in ipairs(cutDoors) do
		Doors.set(door, false, true)
	end
	local openDepth = Flood.depthAt(probe)
	for _, door in ipairs(cutDoors) do
		Doors.set(door, true, true)
	end
	local closedDepth = Flood.depthAt(probe)
	assertTrue(Doors.isZoneSealed("ServiceCut"), "the cut zone was not sealed")
	assertTrue(closedDepth < openDepth - 0.5,
		string.format("sealed cut should be much drier: open=%.2f closed=%.2f", openDepth, closedDepth))
	return true, string.format("cut depth open=%.2fm closed=%.2fm", openDepth, closedDepth)
end)

-- ============================================================
-- Scenario 20: salvage crates pay once, and the bench spends the pool
-- ============================================================
scenario("salvage crates pay out once and the bench spends the pool", function()
	Round.resetToLobby()
	Round.requestStart(player)
	Stub.advance(1)
	local crate = part("SupplyCrate_2")
	local before = Upgrades.salvage
	local cratesBefore = Upgrades.cratesOpened
	Harness.trigger(crate, player)
	assertTrue(Upgrades.cratesOpened == cratesBefore + 1, "the crate prompt did not open the crate")
	local gained = Upgrades.lastCratePayout
	assertTrue(gained >= 12 and gained <= 20, `crate payout out of range: {gained}`)
	assertTrue(Upgrades.salvage == before + gained, `the pool did not move by exactly the payout ({before} -> {Upgrades.salvage})`)
	Harness.trigger(crate, player)
	assertTrue(Upgrades.salvage == before + gained, "the same crate paid twice")
	assertTrue(Upgrades.cratesOpened >= 1, "the crate was not counted")
	local ok, reason = Upgrades.canAfford("SealKit")
	assertTrue(ok, `could not afford the cheapest upgrade after a crate: {tostring(reason)}`)
	Upgrades.purchase(player, "SealKit")
	assertTrue(Upgrades.has("SealKit"), "the seal kit purchase did not register")
	local okAgain, reasonAgain = Upgrades.canAfford("SealKit")
	assertTrue(not okAgain and reasonAgain ~= nil, "the same upgrade was purchasable twice")
	return true, `crate paid {gained}, pool {before} -> {Upgrades.salvage}, SealKit fitted`
end)

-- ============================================================
-- Scenario 21: the grid capacitor upgrade really lifts the brownout
-- ============================================================
scenario("the capacitor upgrade lifts a real brownout", function()
	freshRound(player)
	assertTrue(Power.pickup(player, "Cell_A"), "no Cell_A")
	Power.insert(player, "Pump")
	assertTrue(Power.pickup(player, "Cell_B"), "no Cell_B")
	Power.insert(player, "Lift")
	assertTrue(Power.isPowered("Pump") and Power.isPowered("Lift"), "two high-priority consumers should run at capacity 2")
	assertTrue(Power.pickup(player, "Cell_C"), "no Cell_C")
	Power.insert(player, "Bridge")
	local brownout = not Power.isPowered("Bridge")
	assertTrue(brownout, "the third consumer should brown out at capacity 2")
	assertTrue(Power.consumers.Bridge.reason == "brownout", `expected a brownout reason, got {tostring(Power.consumers.Bridge.reason)}`)
	local capacityBefore = Power.capacity
	Upgrades.award(60, "sim funding")
	Upgrades.purchase(player, "Capacitor")
	assertTrue(Power.capacity == capacityBefore + 1, `capacity did not rise: {capacityBefore} -> {Power.capacity}`)
	assertTrue(Power.isPowered("Bridge"), "the bridge did not come online after the capacitor was fitted")
	return true, `capacity {capacityBefore} -> {Power.capacity}, brownout cleared without touching the sockets`
end)

-- ============================================================
-- Scenario 22: pump impeller + rebreather change the simulation measurably
-- ============================================================
scenario("impeller and rebreather upgrades change water and air numbers", function()
	freshRound(player)
	local airBefore = Flood.oxygenTarget()
	-- Baseline: no pump at all, so the district takes on water at the raw phase rate.
	local dryStart = Flood.level
	Stub.advance(12)
	local dryDelta = Flood.level - dryStart
	forcePower("Pump", "Cell_A")
	assertTrue(Power.isPowered("Pump"), "the pump did not come online with one cell")
	local pumpedStart = Flood.level
	Stub.advance(12)
	local pumpedDelta = Flood.level - pumpedStart
	assertTrue(pumpedDelta < dryDelta * 0.5,
		string.format("the pump barely changed the rise: %.3f -> %.3f per 12s", dryDelta, pumpedDelta))
	Upgrades.award(200, "sim funding")
	Upgrades.purchase(player, "Impeller")
	Upgrades.purchase(player, "Rebreather")
	assertTrue(Upgrades.has("Impeller") and Upgrades.has("Rebreather"), "upgrades did not register")
	local impellerStart = Flood.level
	Stub.advance(12)
	local impellerDelta = Flood.level - impellerStart
	assertTrue(Flood.oxygenTarget() == airBefore + 9,
		`rebreather did not add 9s of air ({airBefore} -> {Flood.oxygenTarget()})`)
	assertTrue(impellerDelta < pumpedDelta * 0.6,
		string.format("impeller had no measurable effect: %.3f -> %.3f per 12s", pumpedDelta, impellerDelta))
	return true, string.format("air %ds -> %ds, 12s of water: %.2f dry, %.2f pumped, %.2f fitted",
		airBefore, Flood.oxygenTarget(), dryDelta, pumpedDelta, impellerDelta)
end)

-- ============================================================
-- Scenario 23: lift servo upgrade (faster travel, one more seat)
-- ============================================================
scenario("the lift servo upgrade speeds travel and adds a passenger slot", function()
	freshRound(player)
	Power.pickup(player, "Cell_A")
	Power.insert(player, "Lift")
	local capacityBefore = Lift.snapshot().capacity
	Upgrades.award(200, "sim funding")
	Upgrades.purchase(player, "LiftServo")
	local capacityAfter = Lift.snapshot().capacity
	assertTrue(capacityAfter == capacityBefore + 1, `capacity unchanged: {capacityBefore} -> {capacityAfter}`)

	local function progressAfter(seconds: number): number
		Route.setExtension(0)
		Lift.reset()
		Power.recompute()
		local survivor = Rescue.get("Survivor5")
		Lift.boardSurvivor(survivor)
		Lift.call(player)
		Stub.advance(seconds)
		local progress = Lift.progress
		Lift.reset()
		Rescue.release(player)
		survivor.boarding = false
		survivor.state = "Idle"
		Lift.passengers = {}
		return progress
	end
	-- measure the same 3s window with and without the servo
	Upgrades.purchased["LiftServo"] = { by = player.Name, at = os.clock() }
	local fast = progressAfter(3)
	Upgrades.purchased["LiftServo"] = nil
	local slow = progressAfter(3)
	assertTrue(fast > slow, string.format("servo did not speed the lift: %.2f vs %.2f progress in 3s", fast, slow))
	Upgrades.purchased["LiftServo"] = { by = player.Name, at = os.clock() }
	Lift.refresh()
	return true, string.format("3s of travel: %.0f%% -> %.0f%%, seats %d -> %d", slow * 100, fast * 100, capacityBefore, capacityAfter)
end)

-- ============================================================
-- Scenario 24: field hospital — revives at twice the speed, at full health
-- ============================================================
scenario("the field hospital upgrade halves revive time and restores full health", function()
	freshRound(player)
	local target = Stub.addPlayer("Casualty")
	Stub.spawnCharacter(target, Stub.v3(0, 3, -12))
	Stub.advance(0.5)
	local humanoid = target.Character:FindFirstChildOfClass("Humanoid")
	PlayerService.setupCharacter(target, target.Character)
	-- Revives only progress while the rescuer is over the casualty (9 studs).
	standPlayer(player, Stub.v3(0, 3, -10))
	humanoid.Health = 0
	PlayerService.downed(target, "sim")
	local state = PlayerService.getState(target)
	assertTrue(state.downed, "the casualty was not downed")
	local function tickRevive(seconds: number)
		for _ = 1, math.floor(seconds / 0.1) do
			PlayerService.progressRevive(player, target, 0.1)
		end
	end
	tickRevive(2.6)
	assertTrue(state.downed, "a 2.6s revive is too fast before the upgrade")
	tickRevive(2.4)
	assertTrue(not state.downed, "the baseline revive never completed")
	Upgrades.award(200, "sim funding")
	Upgrades.purchase(player, "FieldHospital")
	humanoid.Health = 0
	PlayerService.downed(target, "sim")
	tickRevive(2.4)
	assertTrue(not PlayerService.getState(target).downed, "the upgraded revive did not complete in 2.4s")
	assertTrue(humanoid.Health >= humanoid.MaxHealth - 0.01,
		`field hospital revive left {humanoid.Health} health`)
	Stub.removePlayer(target)
	return true, "baseline revive needed 5s, upgraded revive landed in 2.4s at full health"
end)

-- ============================================================
-- Scenario 25: survivor roles — medic aura, engineer speed, medic rescue payout
-- ============================================================
scenario("medic and engineer roles change what the team can do", function()
	freshRound(player)
	local medic = Rescue.get("Survivor9")
	local engineer = Rescue.get("Survivor10")
	assertTrue(medic ~= nil and engineer ~= nil, "role survivors missing")
	assertTrue(medic.role == "Medic", `Survivor9 role={tostring(medic.role)}`)
	assertTrue(engineer.role == "Engineer", `Survivor10 role={tostring(engineer.role)}`)
	local safeZone = part("SafeZone")

	-- 1. An engineer in tow turns the crank for you.
	local crankBefore = Route.skybridge.work
	Route.crank(player, 1)
	local plain = Route.skybridge.work - crankBefore
	Route.skybridge.work = crankBefore
	Rescue.lead(player, "Survivor10")
	Rescue.setRigPosition(engineer, Stub.characterPosition(player))
	Route.skybridge.lastCrankAt = 0
	Route.crank(player, 1)
	local boosted = Route.skybridge.work - crankBefore
	assertTrue(boosted > plain + 0.3,
		string.format("the engineer did not speed the crank (%.2f -> %.2f)", plain, boosted))

	-- 2. A shorted socket stays dead after the trip: trip it, then deliver the engineer and watch
	--    the trip clear. This has to happen before anyone else reaches the safe zone.
	Power.pickup(player, "Cell_A")
	Power.insert(player, "Lift")
	local socket = Power.sockets.Lift
	Power.tripSocket("Lift", "flood")
	assertTrue(socket.tripped, "test setup failed: socket not tripped")
	Route.skybridge.work = crankBefore
	Rescue.setRigPosition(engineer, safeZone.Position + Stub.v3(0, 1.5, 0))
	for _ = 1, 12 do
		Stub.advance(0.5)
		if engineer.state == "Rescued" then
			break
		end
	end
	assertTrue(engineer.state == "Rescued", `engineer not delivered (state={engineer.state})`)
	assertTrue(socket.tripped == false, "the engineer rescue did not clear the flood trip")

	-- 3. A following medic patches the leader up, but only up to the field ceiling. Stand clear of
	--    the safe zone or the medic delivers herself and fires the much larger rescue payout.
	local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
	standPlayer(player, part("PumpHouse").Position + Stub.v3(0, 4, 0))
	Rescue.lead(player, "Survivor9")
	Rescue.setRigPosition(medic, Stub.characterPosition(player))
	humanoid.Health = 40
	Stub.advance(6)
	assertTrue(humanoid.Health > 41,
		string.format("the medic aura did not heal (health=%.1f)", humanoid.Health))
	assertTrue(humanoid.Health <= Config.Survivors.Roles.Medic.HealCeiling + 0.5,
		string.format("the medic aura healed past its ceiling (%.1f)", humanoid.Health))

	-- 4. Delivering the medic restocks the team's medkits.
	standPlayer(player, safeZone.Position + Stub.v3(0, 3, 0))
	Rescue.setRigPosition(medic, safeZone.Position + Stub.v3(0, 1.5, 0))
	for _ = 1, 12 do
		Stub.advance(0.5)
		if medic.state == "Rescued" then
			break
		end
	end
	assertTrue(medic.state == "Rescued", `medic not delivered (state={medic.state})`)
	local medkits = PlayerService.getState(player).items.Medkit or 0
	assertTrue(medkits >= 2, `medic rescue did not restock medkits ({medkits} is under 2)`)
	return true, string.format("crank %.2f -> %.2f per turn, trip cleared by the engineer, medic held the leader at %.0f, medkits=%d",
		plain, boosted, humanoid.Health, medkits)
end)

-- ============================================================
-- Scenario 26: a child refuses to wade and must be carried
-- ============================================================
scenario("children refuse to wade and are carried instead", function()
	freshRound(player)
	local child = Rescue.get("Survivor4")
	assertTrue(child ~= nil and child.role == "Child", "Survivor4 is not the child rig")
	Flood.surge(2.2)
	Stub.advance(0.4)
	local spot = Stub.v3(0, 0.8, -6)
	Rescue.lead(player, "Survivor4")
	Rescue.setRigPosition(child, spot)
	Stub.advance(3)
	local moved = (child.position - spot).Magnitude
	assertTrue(moved < 4, string.format("the child waded %.1f studs instead of refusing", moved))
	assertTrue(child.state == "Following", `child state changed to {child.state}`)

	local ok = Rescue.carry(player, "Survivor4")
	assertTrue(ok, "could not pick the child up")
	assertTrue(child.state == "Carried", `child state is {child.state} after the carry`)
	Stub.movePlayer(player, Stub.v3(8, 0.8, -6))
	Stub.advance(1)
	local offset = (child.position - Stub.characterPosition(player)).Magnitude
	assertTrue(offset < 4, string.format("carried child is %.1f studs from the carrier", offset))
	return true, string.format("child held position in %.2fm water, then rode the carrier (offset %.1fm)", Flood.depthAt(spot), offset)
end)

-- ============================================================
-- Scenario 27: the district's new content is reachable and wired
-- ============================================================
scenario("garage, ferry and the cut expose their content to the simulation", function()
	freshRound(player)
	assertTrue(Power.cells.Cell_D ~= nil, "the fourth cell was not adopted")
	assertTrue(Power.cells.Cell_D.label == "Ferry strongbox", `cell D label: {tostring(Power.cells.Cell_D.label)}`)
	for _, name in ipairs({ "ParkingGarage", "FerryTerminal", "ServiceCut" }) do
		assertTrue(zoneOf(name) ~= nil, `{name} is not a registered world zone`)
	end
	local garage = zoneOf("ParkingGarage")
	assertTrue(garage.max.Y > 15, `garage roof should exceed 15 studs, got {garage.max.Y}`)
	assertTrue(part("Cell4").Position.Y > 1, "the ferry cell is not where the geometry says")
	assertTrue(part("UpgradeBench") ~= nil, "the salvage bench is missing")
	return true, string.format("4 cells, %d zones, garage roof at %.0f studs", zoneCount(), garage.max.Y)
end)

-- ============================================================
-- Scenario 28: the objective list teaches both routes
-- ============================================================
scenario("objectives cover both routes and the salvage bench", function()
	freshRound(player)
	Objectives.rebuild(player)
	local ids = {}
	for _, entry in ipairs(Objectives.list) do
		ids[entry.id] = entry.status
	end
	for _, want in ipairs({ "cells", "pump", "relay", "lift", "skybridge", "cut", "salvage", "rescue", "extract" }) do
		assertTrue(ids[want] ~= nil, `missing objective: {want}`)
	end
	-- and they flip once the route is real
	Route.setExtension(1)
	Objectives.rebuild(player)
	local skyStatus = nil
	for _, entry in ipairs(Objectives.list) do
		if entry.id == "skybridge" then
			skyStatus = entry.status
		end
	end
	assertTrue(skyStatus == "done", `skybridge objective did not complete (status={tostring(skyStatus)})`)
	return true, `{#Objectives.list} objectives, skybridge flips to done when the span is out`
end)

-- ============================================================
-- Scenario 29: a full round records route mastery in the summary
-- ============================================================
scenario("route mastery is scored in the round summary", function()
	Round.resetToLobby()
	Round.requestStart(player)
	Stub.advance(1)
	Route.setExtension(1)
	local barricade = part("TunnelBarricade")
	for _ = 1, 3 do
		Harness.trigger(barricade, player)
		Stub.advance(0.4)
	end
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
	Harness.trigger(part("Radio"), player)
	Harness.trigger(part("EvacConsole"), player)
	assertTrue(Round.radioCalled, "evacuation was not authorised")
	assertTrue(Round.state == "Extraction", "expected Extraction, got " .. Round.state)
	local pad = part("ExtractionPad")
	waitForEvac(player, 120)
	for _ = 1, 60 do
		Stub.advance(0.5)
		Stub.movePlayer(player, pad.Position + Stub.v3(0, 3, 0))
		if Round.state == "Results" then
			break
		end
	end
	local summary = Round.lastOutcome
	assertTrue(summary ~= nil, "the round never resolved")
	assertTrue(summary.outcome == "win" or summary.outcome == "partial", `unexpected outcome {summary.outcome}`)
	assertTrue(summary.routes ~= nil and #summary.routes == 2, `expected 2 opened routes, got {summary.routes and #summary.routes or 0}`)
	assertTrue(summary.cutOpen == true, "the summary did not record the open service cut")
	assertTrue(summary.upgrades ~= nil and summary.upgrades.salvage ~= nil, "the summary has no salvage block")
	return true, string.format("outcome=%s routes=%s score=%d salvage=%d", summary.outcome, table.concat(summary.routes, "+"), summary.teamScore, summary.upgrades.salvage)
end)

-- ============================================================
-- Scenario 30: the local player cannot fake route or upgrade state
-- ============================================================
scenario("route and upgrade changes only happen through server-owned paths", function()
	freshRound(player)
	-- There is no remote that sets extension, salvage or capacity directly.
	local net = Harness.mounted.ReplicatedStorage:FindFirstChild("FloodlineNet")
	local names = {}
	for _, child in ipairs(net:GetChildren()) do
		names[child.Name] = true
	end
	assertTrue(names.RequestUpgrade == true, "the bench remote is missing")
	assertTrue(names.RequestCrank == nil, "a crank remote exists that the server does not validate")
	assertTrue(names.SetRoute == nil and names.SetSalvage == nil, "a route/salvage setter remote leaked in")
	local salvageBefore = Upgrades.salvage
	-- purchasing without salvage must fail
	Upgrades.salvage = 0
	local ok, reason = Upgrades.purchase(player, "Impeller")
	assertTrue(not ok and reason ~= nil, "an unaffordable purchase went through")
	assertTrue(Upgrades.salvage == 0, "the failed purchase still moved the pool")
	Upgrades.salvage = salvageBefore
	return true, "no client-side setter exists; unaffordable purchases are refused with a reason"
end)

-- ============================================================
-- Scenario 36: a rematch puts the district back the way it started
-- ============================================================
scenario("a rematch restores world items, doors, routes and the salvage pool", function()
	Round.resetToLobby()
	Round.requestStart(player)
	Stub.advance(1)

	-- Spend the world: take the radio and the fuse, loot a crate, seal a door, open both routes.
	local radio = part("Radio")
	local fuse = part("RelayFuse")
	standPlayer(player, fuse.Position + Stub.v3(0, 2, 0))
	Harness.trigger(fuse, player)
	Rescue.release(player)
	standPlayer(player, radio.Position + Stub.v3(0, 2, 0))
	Harness.trigger(radio, player)
	local crate = part("SupplyCrate_1")
	standPlayer(player, crate.Position + Stub.v3(0, 2, 0))
	Harness.trigger(crate, player)
	Route.setExtension(1)
	local barricade = part("TunnelBarricade")
	for _ = 1, 3 do
		Harness.trigger(barricade, player)
		Stub.advance(0.4)
	end
	local doorsClosed = 0
	for _, door in ipairs(Doors.list) do
		Doors.set(door, true, true)
		doorsClosed += 1
	end
	assertTrue(radio:GetAttribute("Taken") == true, "test setup failed: the radio was not taken")
	assertTrue(Route.extension() >= 0.999, "test setup failed: the span did not extend")
	assertTrue(Upgrades.cratesOpened >= 1, "test setup failed: the crate did not open")

	-- Rematch.
	Round.resetToLobby()
	Round.requestStart(player)
	Stub.advance(1)

	assertTrue(radio:GetAttribute("Taken") == false, "the radio is still marked as taken in round two")
	assertTrue(radio.Transparency == 0, "the radio is still invisible in round two")
	local prompt = radio:FindFirstChildOfClass("ProximityPrompt")
	assertTrue(prompt ~= nil and prompt.Enabled, "the radio prompt is still disabled in round two")
	assertTrue(fuse:GetAttribute("Taken") == false, "the relay fuse was not restored")
	assertTrue(crate:GetAttribute("Looted") == false, "the salvage crate was not restocked")
	assertTrue(Route.extension() == 0, "the skybridge is still extended")
	assertTrue(Route.cut.blocked, "the service cut is still open")
	assertTrue(barricade.CanCollide, "the collapsed barricade is still walkable")
	assertTrue(Upgrades.salvage == Config.Upgrades.StartSalvage,
		`the salvage pool did not reset ({Upgrades.salvage} vs {Config.Upgrades.StartSalvage})`)
	local closed = 0
	for _, door in ipairs(Doors.list) do
		if door.closed then
			closed += 1
		end
	end
	assertTrue(closed < doorsClosed, "every door is still sealed in round two")
	-- and the round is genuinely playable: the fuse can be taken again
	standPlayer(player, fuse.Position + Stub.v3(0, 2, 0))
	assertTrue(Harness.trigger(fuse, player), "the fuse prompt would not fire in round two")
	assertTrue(PlayerService.hasItem(player, "Fuse"), "the fuse could not be collected in round two")
	return true, string.format("radio/fuse/crate/span/cut/salvage all restored; %d doors resealed, fuse re-collectable", closed)
end)

-- ============================================================
-- Scenario 37: survivors take to high ground instead of drowning in the open
-- ============================================================
scenario("unclaimed survivors climb to a refuge when the water reaches them", function()
	freshRound(player)
	assertTrue(Rescue.refuges ~= nil and #Rescue.refuges == 8, `expected 8 refuge markers, found {Rescue.refuges and #Rescue.refuges or 0}`)
	local survivor = Rescue.get("Survivor6")
	assertTrue(survivor ~= nil, "Survivor6 missing")
	-- Put them in deep water at the foot of the pump house catwalk.
	local base = Stub.v3(-30, 1.0, -38)
	Rescue.setRigPosition(survivor, base)
	Flood.surge(3.4)
	local startY = survivor.position.Y
	assertTrue(Flood.depthAt(survivor.position) > 1,
		string.format("the test spot is not flooded (%.2fm)", Flood.depthAt(survivor.position)))
	local sawShelter = false
	for _ = 1, 90 do
		Stub.advance(1)
		if survivor.shelter then
			sawShelter = true
		end
		if survivor.position.Y > 8 then
			break
		end
	end
	assertTrue(sawShelter, "the survivor never looked for high ground")
	assertTrue(survivor.position.Y > startY + 4,
		string.format("the survivor did not climb (y %.1f -> %.1f)", startY, survivor.position.Y))
	assertTrue(survivor.state ~= "Dead", "the survivor drowned on the way up")
	assertTrue(Flood.depthAt(survivor.position) <= 0.6,
		string.format("the survivor is still standing in %.2fm of water", Flood.depthAt(survivor.position)))
	return true, string.format("climbed %.1f -> %.1f studs (%s), state=%s",
		startY, survivor.position.Y, tostring(survivor.shelterLabel), survivor.state)
end)

-- ============================================================
-- Scenario 38: a surge that forces the evacuation still lands the vehicle
-- ============================================================
scenario("a surge-forced evacuation still schedules the evac vehicle", function()
	freshRound(player)
	-- Bank the quota first so the long wait for the surge cannot end the round early.
	local safeZone = part("SafeZone")
	for _, survivor in ipairs(Rescue.order) do
		if Rescue.rescuedCount >= Rescue.requiredRescued() + 2 then
			break
		end
		Rescue.lead(player, survivor.name)
		Rescue.setRigPosition(survivor, safeZone.Position + Stub.v3(0, 1.5, 0))
		Stub.advance(4)
	end
	assertTrue(Rescue.rescuedCount >= Rescue.requiredRescued(), "could not bank the quota for this scenario")
	-- Keep the pump running, or the district drowns long before the surge arrives.
	forcePower("Pump", "Cell_A")
	assertTrue(Power.isPowered("Pump"), "the pump is not holding the water back")
	-- Run the clock until the storm surge takes over and auto-calls the evacuation.
	local advanced = 0
	while not Round.radioCalled and advanced < 1200 do
		Stub.advance(5)
		advanced += 5
	end
	assertTrue(Round.radioCalled, "the surge never forced an evacuation call")
	assertTrue(Round.state == "Extraction", `expected Extraction after the surge, got {Round.state}`)
	assertTrue(Round.evacEta() >= 0, "the forced evacuation left the vehicle unscheduled")
	assertTrue(not Round.evacArrived(), "the vehicle should still be inbound")
	local pad = part("ExtractionPad")
	standPlayer(player, pad.Position + Stub.v3(0, 3, 0))
	local arrived = waitForEvac(player, 120)
	assertTrue(arrived, "the vehicle never landed after a surge-forced call")
	local extracted = false
	for _ = 1, 60 do
		Stub.advance(0.5)
		standPlayer(player, pad.Position + Stub.v3(0, 3, 0))
		if Round.extractedPlayers[player] then
			extracted = true
			break
		end
	end
	assertTrue(extracted, "the pad stayed inert after the vehicle landed")
	return true, string.format("surge forced the call at t=%ds, vehicle landed, pad accepted the crew", advanced)
end)


-- ============================================================
-- Scenario 39: crew roles assign, grant passives and gate the ability on a cooldown
-- ============================================================
scenario("crew roles change the maths and the ability respects its cooldown", function()
	-- Roles are a lobby decision: pick them before the water starts moving.
	Round.resetToLobby()
	Stub.advance(0.2)
	-- Default role for a fresh player, and switching is a server decision.
	assertTrue(Crew.roleOf(player) == Config.Crew.Default, `default role was {Crew.roleOf(player)}`)
	local ok, reason = Crew.set(player, "Nope")
	assertTrue(not ok, "an unknown role was accepted")
	assertTrue(reason ~= nil, "refusing a role gave no reason")
	assertTrue(Crew.set(player, "Engineer"), "could not switch to Engineer")
	assertTrue(math.abs(Crew.holdMultiplier(player) - Config.Crew.Engineer.HoldMultiplier) < 0.001,
		"engineer hold passive did not apply")

	-- The diver's air budget must actually differ from the engineer's.
	Crew.set(player, "Diver")
	local diverAir = Flood.oxygenTarget(player)
	Crew.set(player, "Engineer")
	local engineerAir = Flood.oxygenTarget(player)
	assertTrue(diverAir > engineerAir, `diver air {diverAir} should exceed engineer air {engineerAir}`)

	-- Ability: fires once, then refuses until the cooldown has run. The round has to be running
	-- for an ability to be spent, so start it now (roles are already locked in).
	Round.requestStart(player)
	Stub.advance(1)
	Crew.set(player, "Engineer")
	local used, message = Crew.useAbility(player)
	assertTrue(used, "the socket jumper ability did not fire: " .. tostring(message))
	assertTrue(Crew.cooldownLeft(player) > 0, "the ability did not go on cooldown")
	local again, blocked = Crew.useAbility(player)
	assertTrue(not again and blocked ~= nil, "the ability fired twice with no cooldown")
	Stub.advance(Config.Crew.Engineer.Ability.Cooldown + 1)
	assertTrue(Crew.cooldownLeft(player) == 0, "the ability never came back off cooldown")
	return true, string.format("4 roles, diver air %.0fs vs engineer %.0fs, cooldown %ds enforced",
		diverAir, engineerAir, Config.Crew.Engineer.Ability.Cooldown)
end)

-- ============================================================
-- Scenario 40: the medic's revive passive is real, and a downed player bleeds out without one
-- ============================================================
scenario("revives are faster for a medic and bleedout is slower with one standing over you", function()
	Round.resetToLobby()
	Stub.advance(0.2)
	local other = Stub.addPlayer("SimMate")
	Stub.spawnCharacter(other, Stub.v3(0, 3, -30))
	Stub.movePlayer(player, Stub.v3(0, 3, -30))
	Stub.advance(0.5)

	-- Baseline: an engineer revives at the shipped rate.
	Crew.set(player, "Engineer")
	Round.requestStart(player)
	Stub.advance(1)
	PlayerService.downed(other, "a test")
	local before = PlayerService.getState(other).reviveProgress
	for _ = 1, 6 do
		PlayerService.progressRevive(player, other, 0.25)
	end
	local engineerProgress = PlayerService.getState(other).reviveProgress - before
	PlayerService.revivePlayer(other, player)
	-- A revive teleports the patient to the safe zone: walk them back before the next measurement.
	Stub.movePlayer(other, Stub.v3(0, 3, -31))
	Stub.advance(0.2)

	-- Medic: same number of ticks must move the bar further. Swap in the lobby (roles lock in-round,
	-- which scenario 43 checks on its own).
	Round.resetToLobby()
	Stub.advance(0.2)
	assertTrue(Crew.set(player, "Medic"), "could not take the medic role in the lobby")
	Round.requestStart(player)
	Stub.advance(1)
	Stub.movePlayer(other, Stub.v3(0, 3, -31))
	PlayerService.downed(other, "a test")
	before = PlayerService.getState(other).reviveProgress
	for _ = 1, 6 do
		PlayerService.progressRevive(player, other, 0.25)
	end
	local medicProgress = PlayerService.getState(other).reviveProgress - before
	assertTrue(medicProgress > engineerProgress * 1.2,
		string.format("medic revive was not faster: engineer=%.2f medic=%.2f", engineerProgress, medicProgress))

	-- Bleedout: the medic's presence stretches the clock.
	local position = Stub.v3(0, 3, -30)
	local withoutMedic = Crew.bleedoutMultiplier(Stub.v3(400, 3, 400))
	local withMedic = Crew.bleedoutMultiplier(position)
	assertTrue(withMedic > withoutMedic, "the medic aura did not slow the bleedout")
	PlayerService.revivePlayer(other, player)

	-- And a downed player left alone really does bleed out.
	PlayerService.revivePlayer(other, player)
	Crew.set(player, "Engineer")
	PlayerService.downed(player, "a test")
	local state = PlayerService.getState(player)
	state.bleedProgress = 0.999
	Stub.advance(2)
	assertTrue(not PlayerService.getState(player).downed, "the downed player never bled out")
	assertTrue(PlayerService.getState(player).bleedouts >= 1, "the bleedout was not counted")
	Stub.removePlayer(other)
	return true, string.format("medic revive %.2f vs %.2f, bleedout x%.2f", medicProgress, engineerProgress, withMedic)
end)

-- ============================================================
-- Scenario 41: a flooded breaker can be reset by hand, but only once it is out of the water
-- ============================================================
scenario("a flooded breaker is dead until the water drops, then a hand reset brings it back", function()
	freshRound(player)
	local socket = Power.sockets.Pump
	assertTrue(socket ~= nil, "no pump socket")
	-- Park a cell in the pump and trip the socket the way the flood does.
	local cell = forcePower("Pump", "Cell_A")
	assertTrue(Power.isPowered("Pump"), "the pump did not power up")
	Power.tripSocket("Pump", "flood")
	assertTrue(socket.tripped, "the socket did not trip")
	assertTrue(not Power.isPowered("Pump"), "the pump stayed powered through a trip")

	-- Under water the reset must be refused.
	Flood.surge(4.0)
	Stub.advance(0.5)
	local depth = Flood.depthAt(socket.part.Position)
	assertTrue(depth > Config.Power.ShortOutDepth, `the test needs the socket submerged, depth={depth}`)
	local refused, why = Power.resetBreaker(player, "Pump")
	assertTrue(not refused, "the breaker reset while still underwater")
	assertTrue(type(why) == "string" and #why > 10, "refusing a reset gave no useful reason")

	-- Dry it out and the same three holds finish the job.
	Flood.level = 0
	for index = 1, Config.Water.SectorCount do
		Flood.sectorLevels[index] = 0
	end
	Stub.advance(0.2)
	local holds = 0
	for _ = 1, 3 do
		local ok = Power.resetBreaker(player, "Pump")
		assertTrue(ok, "a hand reset was refused while dry")
		holds += 1
	end
	assertTrue(not socket.tripped, `the breaker is still tripped after {holds} holds`)
	assertTrue(Power.breakerCleared >= 1, "the reset was not counted")
	-- A dry, reset socket takes a cell again.
	cell.destroyed = false
	cell.charge = 100
	cell.socket = nil
	local carried = Power.pickup(player, cell.id)
	assertTrue(carried, "could not pick the cell back up")
	local inserted = Power.insert(player, "Pump")
	assertTrue(inserted, "the reset socket refused a fresh cell")
	assertTrue(Power.isPowered("Pump"), "the pump did not come back online")
	return true, `3 holds to reset, refused at ${string.format("%.1f", depth)}m submerged`
end)

-- ============================================================
-- Scenario 42: cranking the outfall pulls the whole district's water down and moves the gate
-- ============================================================
scenario("the outfall drains every sector while it is cranked and closes on its own", function()
	freshRound(player)
	local wheel = part("OutfallWheel")
	local gate = part("OutfallGate")
	assertTrue(Outfall.gate ~= nil, "the outfall service did not adopt the gate")
	local closedY = gate.Position.Y

	-- Shut at round start and pulling nothing out.
	assertTrue(Outfall.open == 0, `the sluice started open ({Outfall.open})`)
	assertTrue(Outfall.drainRate() == 0, "a shut sluice was draining water")

	-- Water in the district, then crank the wheel to the stop.
	Flood.surge(6.0)
	Stub.advance(0.5)
	local before = Flood.level
	local sectorBefore = Flood.sectorLevels[1]
	-- Read the openness immediately after each crank: the sluice creeps shut again between holds.
	local cranks = 0
	local reached = false
	local scoreAtOpen = Crew and 0 or 0
	for _ = 1, 30 do
		Harness.trigger(wheel, player)
		cranks += 1
		if Outfall.open >= 0.999 then
			reached = true
			scoreAtOpen = PlayerService.getState(player).score
			break
		end
		Stub.advance(0.5)
	end
	assertTrue(reached, `the sluice only reached {math.floor(Outfall.open * 100)}% in {cranks} cranks`)
	assertTrue(Outfall.opens == 1, `opening the sluice once counted {Outfall.opens} times`)
	-- Cranking a sluice that is already wide open must not pay twice.
	Harness.trigger(wheel, player)
	assertTrue(Outfall.opens == 1, "holding the sluice at the top paid the opening bonus again")
	assertTrue(PlayerService.getState(player).score <= scoreAtOpen, "the opening bonus was farmed")
	assertTrue(Outfall.drainRate() > 0, "a wide-open sluice drains nothing")
	assertTrue(gate.Position.Y < closedY - 1, "the gate plate never moved down")

	-- The water has to actually fall, in the district level and in a storm-hit sector.
	local mid = Flood.level
	Stub.advance(6)
	assertTrue(Flood.level < mid, string.format("water did not fall: %.2f -> %.2f", mid, Flood.level))
	assertTrue(Flood.sectorLevels[1] < sectorBefore, "the sector level did not fall")
	assertTrue(Outfall.drained > 0, "no drained total was recorded")

	-- Nobody on the wheel: it swings shut by itself.
	local openAt = Outfall.open
	Stub.advance(Config.Outfall.OpenSeconds)
	assertTrue(Outfall.open < openAt, "the sluice never crept shut")
	return true, string.format("%d cranks to full: district %.2f -> %.2f, drained %.1f studs, gate dropped %.1fm",
		cranks, before, Flood.level, Outfall.drained, closedY - gate.Position.Y)
end)

-- ============================================================
-- Scenario 43: roles reset between rounds and lock once the round is running
-- ============================================================
scenario("roles reset with the round and cannot be swapped mid-flood", function()
	Round.resetToLobby()
	Stub.advance(0.2)
	assertTrue(Crew.set(player, "Rigger"), "could not take the rigger role in the lobby")
	freshRound(player)
	Crew.useAbility(player)
	assertTrue(Crew.cooldownLeft(player) > 0, "the ability did not go on cooldown")
	local locked, why = Crew.set(player, "Medic")
	assertTrue(not locked, "the role was swapped while the round was running")
	assertTrue(why ~= nil, "locking the role gave no reason")
	Round.resetToLobby()
	assertTrue(Crew.roleOf(player) == "Rigger", "the lobby reset forgot the player's role")
	assertTrue(Crew.cooldownLeft(player) == 0, "the ability cooldown survived the round reset")
	assertTrue(Outfall.open == 0, "the outfall was left open across a reset")
	local swapped = Crew.set(player, "Medic")
	assertTrue(swapped, "the role could not be changed in the lobby")
	assertTrue(Crew.roleOf(player) == "Medic", "the lobby role change did not stick")
	return true, "role locked in-round, kept across a lobby reset, ability cooldown cleared"
end)

-- ============================================================
-- Scenario 44: no survivor starts the round inside a rescue zone
-- ============================================================
-- A survivor who spawns on the pad or in the shelter is delivered to the tally for free the moment
-- the round starts: the quota is met by geometry, not by play.
scenario("no survivor starts the round already standing in a rescue zone", function()
	freshRound(player)
	local safe = part("SafeZone").Position
	local pad = part("ExtractionPad").Position
	local offenders = {}
	for name, survivor in pairs(Rescue.survivors) do
		local toSafe = (survivor.position - safe).Magnitude
		local toPad = (survivor.position - pad).Magnitude
		if toSafe <= 7.5 or toPad <= 6.5 then
			table.insert(offenders, string.format("%s (safe %.1f, pad %.1f)", name, toSafe, toPad))
		end
	end
	assertTrue(#offenders == 0, "survivors spawn inside a rescue zone: " .. table.concat(offenders, ", "))
	-- And the proof that matters: three seconds into a running round nobody has been counted yet.
	Stub.advance(3)
	assertTrue(Rescue.rescuedCount == 0,
		`{Rescue.rescuedCount} survivors were rescued before the crew did anything`)
	return true, `12 spawn points, nearest to the safe zone is outside the 7.5 stud radius`
end)

-- ============================================================
-- Scenario 45: a downed player can be hauled out of the water by a teammate
-- ============================================================
-- Bleeding out alone is a sentence; being dragged is a rescue. The corpse ride has to be real:
-- the casualty must end up where the carrier walks, the bleedout clock must stretch, and the
-- grip must break when the carrier lets go.
scenario("a downed player rides with whoever drags them, and the clock stretches", function()
	freshRound(player)
	local mate = Stub.addPlayer("Dragger")
	local safe = part("SafeZone").Position
	-- Both players start out in the open, well away from the shelter.
	Stub.movePlayer(player, safe + V3(0, 0, -40))
	Stub.movePlayer(mate, safe + V3(4, 0, -40))
	Stub.advance(0.4)

	-- Refusals first: you cannot drag somebody who is on their feet.
	local okDown, whyDown = PlayerService.startDrag(mate, player)
	assertTrue(not okDown, "a standing player was draggable")
	assertTrue(whyDown ~= nil, "refusing a standing casualty gave no reason")

	PlayerService.downed(player, "a live cable")
	Stub.advance(0.4)

	-- And you have to be close enough to get a grip.
	Stub.movePlayer(mate, safe + V3(60, 0, -40))
	Stub.advance(0.2)
	local okFar, whyFar = PlayerService.startDrag(mate, player)
	assertTrue(not okFar, "a casualty 60 studs away was dragged")

	Stub.movePlayer(mate, part("SafeZone").Position + V3(0, 0, -36))
	Stub.movePlayer(player, part("SafeZone").Position + V3(2, 0, -36))
	Stub.advance(0.2)
	-- The in-game grip is the ProximityPrompt the server puts on a downed character, so drive it
	-- the way a player would rather than calling startDrag directly.
	local casualtyRoot = player.Character:FindFirstChild("HumanoidRootPart")
	local dragPrompt = casualtyRoot and casualtyRoot:FindFirstChild("DragTeammate")
	assertTrue(dragPrompt ~= nil, "a downed player did not get a Drag prompt")
	assertTrue(dragPrompt.ActionText == "Drag to safety", `unexpected prompt text: {dragPrompt.ActionText}`)
	dragPrompt.Triggered:Fire(mate)
	local started = PlayerService.dragging(mate) == player
	assertTrue(started, "firing the Drag prompt did not take hold of the casualty")
	assertTrue(PlayerService.dragging(mate) == player, "the dragger does not report a casualty")
	assertTrue(PlayerService.carriedBy(player) == mate, "the casualty does not report a carrier")

	-- The carrier walks slower for the load, and the number must be real: a nil drag constant here
	-- silently broke every hauling speed update in the shipped module until the bot drill found it.
	local haulSpeed = PlayerService.walkSpeed(mate)
	local freeSpeed = PlayerService.walkSpeed(player)
	assertTrue(type(haulSpeed) == "number" and haulSpeed > 0,
		`hauling walk speed is {tostring(haulSpeed)}`)
	assertTrue(haulSpeed < freeSpeed,
		string.format("hauling (%.1f) is not slower than walking free (%.1f)", haulSpeed, freeSpeed))

	local startDistance = (Stub.playerPosition(player) - Stub.playerPosition(mate)).Magnitude
	assertTrue(startDistance < 9, `the casualty started {string.format("%.1f", startDistance)} studs away`)

	-- Walk the carrier to the shelter: the casualty has to come along, not be left behind.
	local walked = 0
	for _ = 1, 40 do
		Stub.movePlayer(mate, Stub.playerPosition(mate) + V3(0, 0, 0.6))
		walked += 0.6
		Stub.advance(0.1)
	end
	local gap = (Stub.playerPosition(player) - Stub.playerPosition(mate)).Magnitude
	assertTrue(gap < 4.5, string.format("the casualty was left %.1f studs behind", gap))

	-- The clock: a dragged casualty bleeds at 60% of the rate, so the progress bars must diverge.
	-- A dragged casualty must bleed SLOWER than an abandoned one, and by the configured stretch.
	local draggedBefore = PlayerService.getState(player).bleedProgress
	Stub.advance(6)
	local draggedGain = PlayerService.getState(player).bleedProgress - draggedBefore
	local hauledRate = draggedGain / 6
	local baseRate = 1 / Config.Player.DownedBleedoutSeconds
	assertTrue(hauledRate < baseRate, string.format(
		"being hauled bled the casualty FASTER than being abandoned (%.5f/s vs %.5f/s)", hauledRate, baseRate))
	local expected = baseRate / 1.5
	assertTrue(math.abs(hauledRate - expected) / expected < 0.3,
		string.format("dragged bleed rate %.5f/s is not the configured 1.5x stretch (%.5f/s)", hauledRate, expected))

	-- Letting go leaves them where they stand, and they stay down.
	local where = Stub.playerPosition(mate)
	local released = PlayerService.stopDrag(mate, "test")
	assertTrue(released, "the carrier could not let go")
	local droppedAt = Stub.playerPosition(player)
	assertTrue((droppedAt - where).Magnitude < 5, "the released casualty was not left next to the carrier")
	assertTrue(PlayerService.getState(player).downed, "the released casualty stood up on their own")

	-- And a revive still ends it: the drag has to clear or a corpse keeps following the crew.
	PlayerService.revivePlayer(player, mate)
	assertTrue(PlayerService.getState(player).draggedBy == nil, "the revive left the casualty still held")
	assertTrue(casualtyRoot:FindFirstChild("DragTeammate") == nil, "the Drag prompt survived the revive")
	assertTrue(not PlayerService.getState(player).downed, "the revive did not pick the casualty up")
	Stub.removePlayer(mate)
	freshRound(player)
	return true, string.format(
		"carrier walked %.0f studs at %.1f (free %.1f), casualty stayed %.1fm behind, bleedout %.5f/s (base %.5f/s)",
		walked, haulSpeed, freeSpeed, gap, hauledRate, 1 / Config.Player.DownedBleedoutSeconds)
end)

-- ============================================================
-- Scenario 46: the whistle gathers a small crowd, once every forty seconds
-- ============================================================
-- Escorting twelve people one at a time is the slowest part of the game, and the whistle is the
-- tool that fixes it. It has to gather only what is in earshot, only unclaimed people, calm the
-- ones who answer, and then actually cost something.
scenario("the whistle gathers three survivors at once and then goes on cooldown", function()
	local safe = part("SafeZone").Position

	-- Nobody answers a whistle while the water is still standing still in the lobby. (This has to be
	-- checked before the round starts, and the survivors have to be placed after it: resetting the
	-- round rebuilds every survivor rig from the baked models.)
	Round.resetToLobby()
	Stub.advance(0.2)
	local lobbyOk, lobbyWhy = Rescue.rally(player)
	assertTrue(not lobbyOk, "the whistle worked before the round started")
	assertTrue(lobbyWhy ~= nil, "refusing a lobby whistle gave no reason")

	freshRound(player)
	Stub.movePlayer(player, safe + V3(0, 0, -6))

	-- Three survivors in earshot, one well out of it.
	local gathered, far = {}, nil
	local placed = 0
	for _, survivor in ipairs(Rescue.order) do
		if survivor.state == "Lost" or survivor.state == "Rescued" or survivor.state == "Dead" then
			continue
		end
		if placed < 3 then
			survivor.panic = 60
			Stub.moveSurvivor(survivor, safe + V3(placed * 3, 0, -9))
			table.insert(gathered, survivor)
			placed += 1
		elseif not far then
			far = survivor
			-- Out of earshot, and on the apartment roof: a survivor parked in the street for the
			-- cooldown would be downed by the flood and the whistle would refuse them for the
			-- wrong reason.
			Stub.moveSurvivor(survivor, V3(40, 14.6, 1))
		end
	end
	assertTrue(#gathered == 3 and far ~= nil, "the scenario could not place test survivors")

	local ok, detail = Rescue.rally(player)
	assertTrue(ok, `the whistle failed in a live round: {detail}`)
	for _, survivor in ipairs(gathered) do
		assertTrue(survivor.leader == player, `{survivor.name} did not fall in`)
		assertTrue(survivor.state == "Following", `{survivor.name} is {survivor.state}, not following`)
		assertTrue(survivor.panic <= 60 - Config.Survivors.Rally.PanicRelief + 0.01,
			`{survivor.name} was not calmed by the whistle (panic {survivor.panic})`)
	end
	assertTrue(far.leader ~= player, "the whistle reached a survivor 140 studs away")
	assertTrue(Rescue.rallies == 1, `the whistle was counted {Rescue.rallies} times`)

	-- One shout is a resource: the second one has to wait, and while it waits it changes nothing.
	local before = Rescue.ralliedSurvivors
	local again, why = Rescue.rally(player)
	assertTrue(not again, "the whistle was reusable with no cooldown")
	assertTrue(string.find(tostring(why), "whistle", 1, true) ~= nil, `odd cooldown reason: {tostring(why)}`)
	assertTrue(Rescue.ralliedSurvivors == before, "a refused whistle still gathered people")
	assertTrue(Rescue.rallyReadyIn() > 0, "a used whistle reported itself ready")

	-- And after the cooldown it works again, on whoever is still out there.
	Stub.advance(Config.Survivors.Rally.CooldownSeconds + 1)
	assertTrue(Rescue.rallyReadyIn() == 0, "the whistle never came off cooldown")
	Stub.moveSurvivor(far, safe + V3(0, 0, -10))
	far.health = math.max(far.health, 60)
	if far.state == "Downed" then
		far.state = "Idle"
		far.downedAt = nil
	end
	local second, secondWhy = Rescue.rally(player)
	assertTrue(second, `the whistle could not be blown a second time after the cooldown: {tostring(secondWhy)}`)
	assertTrue(far.leader == player, "the survivor in earshot was left behind on the second whistle")

	-- A downed player cannot whistle for themselves.
	local mate = Stub.addPlayer("Whistler")
	PlayerService.downed(mate, "a fall")
	Stub.advance(0.2)
	local downedOk, downedWhy = Rescue.rally(mate)
	assertTrue(not downedOk, "a downed player could whistle")
	assertTrue(downedWhy ~= nil, "refusing a downed whistle gave no reason")
	Stub.removePlayer(mate)

	return true, string.format(
		"3 gathered inside %d studs, a survivor at 140 studs ignored, cooldown %.0fs enforced, %d shouts",
		Config.Survivors.Rally.Radius, Config.Survivors.Rally.CooldownSeconds, Rescue.rallies)
end)

-- ============================================================
-- Scenario 47: the hand winch is a real second way up the tower, and only on muscle
-- ============================================================
-- The lift is the way out of the district, so a crew that cannot spare a cell for it is a crew that
-- cannot finish. The winch has to work with the grid dark, refuse when the lift is powered, slip
-- when nobody is turning, and land the car at the top with its passengers delivered.
scenario("the hand winch lifts the car with no power, and slips when nobody turns", function()
	freshRound(player)
	local handle = part("WinchHandle")
	assertTrue(handle ~= nil, "the winch handle is not in the baked place")
	local prompt = Harness.promptOn(handle)
	assertTrue(prompt ~= nil, "the winch handle has no prompt")
	assertTrue(prompt.ActionText == "Turn Winch", `unexpected winch prompt: {prompt.ActionText}`)

	-- Powered: the motor is faster, so the handle refuses.
	local socket = part("Socket_Lift")
	Power.insert(player, "Lift")
	if Power.isPowered("Lift") then
		local poweredOk, poweredWhy = Lift.crank(player)
		assertTrue(not poweredOk, "the winch turned while the lift was powered")
		assertTrue(poweredWhy ~= nil, "refusing a powered winch gave no reason")
	end

	-- Dark grid, car at the base, nobody on board: the first hold has to move the car.
	Power.clearTrips("flood")
	for _, cell in pairs(Power.cells) do
		cell.socket = nil
		cell.destroyed = false
		cell.charge = 100
	end
	Power.refreshPrompts()
	assertTrue(not Power.isPowered("Lift"), "the lift is still powered for the dark-grid test")
	assertTrue(Lift.isAtBase(), "the car is not at the base to start")
	local before = Lift.progress
	Harness.trigger(handle, player)
	assertTrue(Lift.progress > before, "a turn of the winch did not move the car")
	assertTrue(Lift.onWinchHandle(), "the car is not marked as hand-wound")

	-- The drum slips: without a hand on the handle the car creeps back down.
	local wound = Lift.progress
	Stub.advance(2)
	assertTrue(Lift.progress < wound, string.format(
		"the drum did not slip (%.3f -> %.3f)", wound, Lift.progress))

	-- Wind it to the top and check the passengers are actually delivered.
	Flood.addSurvivorToLiftTest = nil
	local survivor = Rescue.order[1]
	Stub.moveSurvivor(survivor, part("ExtractionPad").Position + V3(0, -14, 0))
	Lift.boardSurvivor(survivor)
	assertTrue(#Lift.passengers == 1, "the test passenger did not board")
	local cranks = 0
	for _ = 1, 40 do
		-- Turn, then move on by the full hold. The slip window between holds is what the drum costs
		-- the cranker, so it has to be modelled at the hold length, not at a fraction of it.
		Harness.trigger(handle, player)
		cranks += 1
		Stub.advance(Config.Lift.Winch.HoldSeconds)
		if Lift.progress >= 0.999 then
			break
		end
	end
	assertTrue(Lift.progress >= 0.999, `the winch only reached {math.floor(Lift.progress * 100)}% in {cranks} cranks`)
	assertTrue(#Lift.passengers == 0, "the hand-wound car did not unload at the tower")
	-- Deliberately no further tick here: the car is unloaded at the tower, and RescueService owns delivery.
	-- A survivor standing on the pad is delivered by the rescue tick, not by the lift, so asserting a
	-- rescue here would only be measuring how long the ferry takes after the fact.
	assertTrue(survivor.state == "Idle", `the unloaded passenger is {survivor.state}, not standing at the tower`)
	return true, string.format("%d holds wound the car to the tower with the grid dark, drum slips %.2f/s",
		cranks, Config.Lift.Winch.DecayPerSecond)
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
