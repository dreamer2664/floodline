--!nocheck
-- client_smoke.luau — runs the SHIPPED client scripts (Hud, Markers, Effects, Results and the
-- client bootstrap) against the stub runtime, then pushes real payload shapes through every
-- remote the server actually sends, asserting the interface builds and reacts without errors.
--
-- This is not a render test: nothing here validates pixels, layout aesthetics or input devices.
-- It proves the UI code constructs, wires its remote handlers and survives live updates.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Stub = require("./roblox_stub")
local Harness = require("./harness")

local ROOT = process.cwd
local AGENT = ROOT .. "/agents/riveter"
local PLACE = AGENT .. "/releases/FLOODLINE.rbxlx"

local errors: { string } = {}
local checks: { { name: string, ok: boolean, detail: string } } = {}

local function check(name: string, fn: () -> (boolean, string))
	local ok, passed, detail = pcall(fn)
	if not ok then
		table.insert(checks, { name = name, ok = false, detail = "error: " .. tostring(passed) })
		table.insert(errors, name .. ": " .. tostring(passed))
		print("[ERROR] " .. name)
		print("        " .. tostring(passed))
		return
	end
	table.insert(checks, { name = name, ok = passed == true, detail = detail or "" })
	print(string.format("[%s] %s", passed and "PASS" or "FAIL", name))
	if detail and detail ~= "" then
		print("        " .. detail)
	end
	if not passed then
		table.insert(errors, name)
	end
end

print("=== FLOODLINE client smoke test ===")

local players = Stub.players()
local RunService = Stub.runService()
local Workspace = Stub.workspace()

local player = Stub.addPlayer("ClientTester")
players.LocalPlayer = player
Stub.attachCamera()

-- Mount the place (server side too: the remotes live in ReplicatedStorage and both realms share them).
Harness.mountPlace(PLACE)
Harness.boot()

local starterPlayer = Harness.mounted.StarterPlayer
local playerScripts = starterPlayer and starterPlayer:FindFirstChild("StarterPlayerScripts")

-- Client bootstrap needs the remotes the server created.
local netFolder = Harness.replicated():FindFirstChild("FloodlineNet")
local Config = Harness.require(Harness.replicated():FindFirstChild("Shared"):FindFirstChild("Config"))

local modules = playerScripts:FindFirstChild("Modules")
local hudScript = modules:FindFirstChild("Hud")
local markersScript = modules:FindFirstChild("Markers")
local effectsScript = modules:FindFirstChild("Effects")
local resultsScript = modules:FindFirstChild("Results")
local minimapScript = modules:FindFirstChild("Minimap")
local systemsScript = modules:FindFirstChild("Systems")
local clientScript = playerScripts:FindFirstChild("Client")

check("client scripts are present in the shipped place", function()
	return hudScript ~= nil and markersScript ~= nil and effectsScript ~= nil
		and resultsScript ~= nil and clientScript ~= nil
		and minimapScript ~= nil and systemsScript ~= nil,
		string.format("modules=%s minimap=%s systems=%s client=%s",
			tostring(modules ~= nil), tostring(minimapScript ~= nil), tostring(systemsScript ~= nil), tostring(clientScript ~= nil))
end)

-- Load the client modules through the same loader the harness uses for the server.
local Hud = Harness.require(hudScript)
local Markers = Harness.require(markersScript)
local Effects = Harness.require(effectsScript)
local Results = Harness.require(resultsScript)
local Minimap = Harness.require(minimapScript)
local Systems = Harness.require(systemsScript)

check("HUD builds its full interface tree", function()
	Hud.Init()
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	assert(gui, "ScreenGui missing")
	local required = { "TopBanner", "Objectives", "PowerGrid", "Roster", "StatusStrip", "WaterGauge", "Notifications", "LobbyBanner" }
	local missing = {}
	for _, name in ipairs(required) do
		if not gui:FindFirstChild(name) then
			table.insert(missing, name)
		end
	end
	return #missing == 0, #missing == 0 and string.format("%d panels built", #required) or ("missing: " .. table.concat(missing, ", "))
end)

check("objective + power + roster panels accept live payloads", function()
	Hud.updateObjectives({
		{ id = "pump", title = "Hold back the water", detail = "Feed the pump socket", status = "active", target = Stub.v3(-9, 1.4, -38) },
		{ id = "cells", title = "Recover power cells", detail = "2 still out there", status = "active" },
		{ id = "relay", title = "Repair the relay tower", detail = "Find the fuse", status = "pending" },
	})
	Hud.updatePower({
		capacity = 2,
		relayRepaired = false,
		consumers = {
			Pump = { powered = true, load = 1, label = "Flood Pump" },
			Lift = { powered = true, load = 1, label = "Evac Lift" },
			Bridge = { powered = false, load = 1, label = "Bridge Gate", reason = "brownout" },
			Relay = { powered = false, load = 1, label = "Relay Tower", reason = "unpowered" },
		},
		cells = {
			Cell_A = { id = "Cell_A", charge = 82, holder = "ClientTester" },
			Cell_B = { id = "Cell_B", charge = 100, socket = "Lift" },
			Cell_C = { id = "Cell_C", charge = 0, destroyed = true },
		},
	})
	Hud.updateSurvivors({
		rescued = 2, total = 8, required = 3, lost = 1, dead = 0,
		list = {
			{ name = "Survivor1", label = "Mara (duty engineer)", trait = "Worker", state = "Following", health = 88, panic = 42, grouped = true, groupCount = 2, position = Stub.v3(-9, 1.2, -12) },
			{ name = "Survivor2", label = "Tobin (crushed leg)", trait = "Injured", state = "Downed", health = 0, panic = 96, position = Stub.v3(-33, 1.2, -18) },
			{ name = "Survivor3", label = "Idris (caretaker)", trait = "Elderly", state = "Rescued", health = 100, panic = 0, position = Stub.v3(0, 1, -12) },
			{ name = "Survivor4", label = "Nell (schoolteacher)", trait = "Deaf", state = "Idle", health = 74, panic = 88, comfortTarget = "Mara", position = Stub.v3(-24, 1.2, -6) },
		},
	})
	local power = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud"):FindFirstChild("PowerGrid")
	local roster = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud"):FindFirstChild("Roster")
	local powerRows = #power:FindFirstChild("List"):GetChildren()
	local rosterRows = #roster:FindFirstChild("List"):GetChildren()
	return powerRows >= 4 and rosterRows >= 3,
		string.format("power rows=%d roster rows=%d", powerRows, rosterRows)
end)

check("the roster says who has company, and how much", function()
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local roster = gui:FindFirstChild("Roster")
	local count = roster:FindFirstChild("CountLabel") :: TextLabel
	local list = roster:FindFirstChild("List") :: Frame
	local groupedRow = list:FindFirstChild("Survivor1") :: Frame
	local walkingRow = list:FindFirstChild("Survivor4") :: Frame
	assert(groupedRow, "the rostered survivor has no row")
	assert(walkingRow, "the survivor walking to company has no row")
	local grouped = groupedRow:FindFirstChild("Status") :: TextLabel
	local walking = walkingRow:FindFirstChild("Status") :: TextLabel
	assert(grouped.Text == "Following +2", `a grouped survivor reads {grouped.Text}`)
	assert(walking.Text == "Idle →Mara", `a survivor walking to company reads {walking.Text}`)
	assert(string.find(count.Text, "1 steadied", 1, true) ~= nil, `the header does not count company: {count.Text}`)
	assert(string.find(count.Text, "1 walking in", 1, true) ~= nil, `the header does not count walkers: {count.Text}`)
	return true, string.format("grouped=%q walking=%q header=%q", grouped.Text, walking.Text, count.Text)
end)

check("the roster fits the district, and folds the rescued away", function()
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local roster = gui:FindFirstChild("Roster") :: Frame
	local list = roster:FindFirstChild("List") :: Frame
	local rows = 0
	local stale = 0
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") then
			rows += 1
			if child.Visible == false then
				stale += 1
			end
		end
	end
	local hidden = list:FindFirstChild("Survivor3")
	-- Survivor3 is out of the district: counted in the header, no row of its own.
	assert(hidden == nil, "a rescued survivor still takes a row")
	-- Twelve compact rows plus the header have to fit inside the panel.
	local needed = (Config and Config.Survivors.Total or 12) * 17 + 40
	assert(roster.Size.Y.Offset >= needed,
		`the roster panel is too short for the district ({roster.Size.Y.Offset} < {needed})`)
	assert(stale == 0, `{stale} roster row(s) are hidden but still parented`)
	return rows == 3, string.format("roster rows=%d panel=%d needed=%d", rows, roster.Size.Y.Offset, needed)
end)

check("state/water/tick updates drive the banner, gauge and status strip", function()
	Hud.setState({ state = "Rising", duration = 150, players = 2, phaseIndex = 2 })
	Hud.setTick({ timeLeft = 92.4, phaseIndex = 2, players = 2, required = 4 })
	Hud.setWater({ level = 12.4, sectorLevels = { 15, 12.4, 13.5 }, pumped = true })
	Hud.setStatus({
		ClientTester = {
			stamina = 62, sprinting = false, carrying = true, items = { Medkit = 2, Radio = 1 },
			downed = false, reviveProgress = 0, score = 340, waterSeconds = 41, oxygen = 18, submerged = false,
		},
	})
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local timer = gui:FindFirstChild("TopBanner"):FindFirstChild("TimerLabel")
	local gauge = gui:FindFirstChild("WaterGauge"):FindFirstChild("Bg"):FindFirstChild("Fill")
	local carry = gui:FindFirstChild("StatusStrip"):FindFirstChild("CarryingLabel")
	return timer.Text == "01:32" and gauge.Size.Y.Scale > 0.2 and string.find(carry.Text, "power cell", 1, true) ~= nil,
		string.format("timer=%s gauge=%.2f carry=%q", timer.Text, gauge.Size.Y.Scale, carry.Text)
end)

check("notifications stack and expire", function()
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local notes = gui:FindFirstChild("Notifications")
	local before = #notes:GetChildren()
	Hud.notify({ text = "Pump offline — the water is rising unchecked.", tone = "bad" })
	Hud.notify({ text = "Mara rescued via the safe zone.", tone = "good" })
	local after = #notes:GetChildren()
	Stub.advance(9)
	local expired = #notes:GetChildren()
	return after == before + 2 and expired < after,
		string.format("notes %d -> %d, %d after expiry", before, after, expired)
end)

check("world markers bind to survivors and the active objective", function()
	Markers.Init()
	Markers.syncSurvivors({
		list = {
			{ name = "Survivor1", label = "Mara", state = "Following", health = 88, panic = 10, position = Stub.v3(-9, 1.2, -12) },
			{ name = "Survivor2", label = "Tobin", state = "Downed", health = 4, panic = 80, position = Stub.v3(-33, 1.2, -18) },
		},
	})
	Markers.setObjective({ id = "pump", title = "Hold back the water", status = "active", target = Stub.v3(-9, 1.4, -38) })
	local container = Workspace:FindFirstChild("FloodlineMarkers")
	assert(container, "marker container missing")
	local tags = 0
	for _, child in ipairs(container:GetChildren()) do
		if child.ClassName == "BillboardGui" or child.Name == "Tag" then
			tags += 1
		end
	end
	return container:FindFirstChild("ObjectiveAnchorPart") ~= nil and tags >= 2,
		string.format("markers=%d, objective anchor=%s", tags, tostring(container:FindFirstChild("ObjectiveAnchorPart") ~= nil))
end)

check("minimap builds the district plan and tracks live state", function()
	local hudGui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	Minimap.Init(hudGui)
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud"):FindFirstChild("Minimap")
	assert(gui, "minimap frame missing")
	local canvas = gui:FindFirstChild("Canvas")
	assert(canvas, "minimap canvas missing")
	local landmarks = 0
	for key in pairs(Minimap.static) do
		if key ~= "Water" then
			landmarks += 1
		end
	end
	assert(landmarks >= 6, string.format("only %d static map layers measured", landmarks))
	-- The span line has to read as "not walkable yet" before RouteSync says otherwise.
	Minimap.setState({ route = { extended = 0, crossable = false, cutOpen = false } })
	Minimap.update()
	local sky = Minimap.static.Skybridge
	assert(sky ~= nil, "the skybridge is not drawn on the map at all")
	local skyTucked = sky.BackgroundTransparency
	local tuckedColor = sky.BackgroundColor3
	Minimap.setState({
		survivors = { list = {
			{ name = "Survivor1", label = "Mara", state = "Following", health = 90, panic = 5, position = Stub.v3(-9, 1.2, -12) },
			{ name = "Survivor4", label = "Pia", state = "Carried", health = 100, panic = 0, position = Stub.v3(-4, 1.2, -8) },
			{ name = "Survivor7", label = "Nadia", state = "Rescued", health = 100, panic = 0, position = Stub.v3(0, 1.2, -10) },
		} },
		water = { level = 6.2, sectorLevels = { 8, 6.2, 7.4 } },
		power = {
			cells = {
				Cell_A = { id = "Cell_A", charge = 70, position = Stub.v3(-34, 1.6, -20) },
				Cell_B = { id = "Cell_B", charge = 0, destroyed = true, position = Stub.v3(28, 1.6, 31) },
			},
			sockets = { Lift = { position = Stub.v3(1, 1.4, -38.6), tripped = false } },
		},
		route = { extended = 100, crossable = true, cutOpen = false, nearJoint = Stub.v3(28.5, 14.35, -13.5), farJoint = Stub.v3(5.5, 16.45, -36.5) },
		objectives = { { id = "lift", title = "Power the lift", status = "active", target = Stub.v3(1, 1.4, -38.6) } },
	})
	Minimap.update()
	local keys = {}
	local visible = {}
	for key, frame in pairs(Minimap.dots) do
		table.insert(keys, key)
		if frame.Visible then
			visible[key] = true
		end
	end
	table.sort(keys)
	assert(visible.p_ClientTester, "the local player is not on the map: " .. table.concat(keys, ","))
	assert(visible.s_1, "a following survivor is not on the map: " .. table.concat(keys, ","))
	assert(not visible.s_2, "a carried survivor should ride the carrier, not sit on the map")
	assert(not visible.s_3, "a rescued survivor is still drawn on the map")
	assert(visible.c_Cell_A, "a loose power cell is not on the map")
	assert(not visible.c_Cell_B, "a destroyed cell is still drawn on the map")
	assert(visible.k_Lift, "a power socket is not on the map")
	assert(visible.o_lift, "the active objective is not on the map")
	assert(Minimap.snapshot().dots == 5, `expected 5 live dots, got {Minimap.snapshot().dots}`)
	-- The span line reads as walkable once RouteSync says it is out.
	assert(sky.BackgroundTransparency < skyTucked - 0.3,
		string.format("the skybridge line did not thicken when the span extended (%.2f -> %.2f)",
			skyTucked, sky.BackgroundTransparency))
	assert(tuckedColor ~= sky.BackgroundColor3, "the span line did not change colour when it opened")
	assert(sky.BackgroundColor3 == Config.Ui.Colors.Good, "the walkable span is not drawn in the 'open' colour")
	Minimap.addPing({ type = "danger", label = "Danger", player = "Teammate", position = Stub.v3(2, 1, -6), lifetime = 0.4 })
	Minimap.update()
	assert(#Minimap.pings >= 1, "ping did not reach the minimap")
	Stub.advance(1)
	Minimap.update()
	assert(#Minimap.pings == 0, "ping did not fade off the minimap")
	assert(Minimap.toggle() == false and gui.Visible == false, "M toggle did not hide the map")
	assert(Minimap.toggle() == true and gui.Visible == true, "M toggle did not restore the map")
	local final = Minimap.snapshot()
	assert(final.enabled == true and final.dots == 5 and final.pings == 0 and final.statics == landmarks + 1,
		string.format("minimap snapshot disagrees with the widgets: dots=%s statics=%s pings=%s",
			tostring(final.dots), tostring(final.statics), tostring(final.pings)))
	return true, string.format("%d map layers, 5 live dots (cells/sockets/objective/survivors), 2 hidden, span line solid, ping fade + M toggle verified",
		landmarks)
end)

check("systems board shows both routes and buys an upgrade through the server", function()
	local hudGui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local remotes = {}
	for _, name in ipairs({ "RequestUpgrade", "RequestCrank", "GetSnapshot" }) do
		remotes[name] = netFolder:FindFirstChild(name)
	end
	assert(remotes.RequestUpgrade ~= nil, "RequestUpgrade remote missing from the shipped net folder")
	Systems.Init(hudGui, remotes)
	local panel = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud"):FindFirstChild("Systems")
	assert(panel, "systems panel missing")
	assert(panel:FindFirstChild("Lift") ~= nil and panel:FindFirstChild("Skybridge") ~= nil and panel:FindFirstChild("Cut") ~= nil,
		"the three route rows are not on the board")
	for _, id in ipairs(Config.Upgrades.Order) do
		assert(Systems.rows[id] ~= nil, "upgrade row missing: " .. id)
	end

	Systems.setState({
		route = {
			extended = 40, crossable = false, winchPowered = true, cutOpen = false, cutProgress = 33,
			recommended = "Lift", liftPowered = false,
		},
		lift = { state = "Stalled" },
		upgrades = {
			salvage = 34, earned = 34, spent = 0, crates = 1, owned = { FieldHospital = true },
			items = {
				{ id = "SealKit", label = "Door Seal Kit", desc = "Sealed rooms hold twice as long", cost = 20, kind = "seal", owned = false, affordable = true },
				{ id = "Impeller", label = "Pump Impeller", desc = "The pump eats more of the rise", cost = 35, kind = "flood", owned = false, affordable = false },
				{ id = "Rebreather", label = "Rebreather", desc = "+9s of air", cost = 25, kind = "oxygen", owned = false, affordable = false },
				{ id = "Capacitor", label = "Grid Capacitor", desc = "+1 capacity", cost = 40, kind = "capacity", owned = false, affordable = false },
				{ id = "LiftServo", label = "Lift Servo", desc = "Faster lift, extra seat", cost = 45, kind = "lift", owned = false, affordable = false },
				{ id = "FieldHospital", label = "Field Hospital", desc = "Revives twice as fast", cost = 40, kind = "revive", owned = true, buyer = "ClientTester" },
			},
		},
	})
	assert(string.find(Systems.routeRows.Skybridge.Text, "winch powered", 1, true) ~= nil,
		"skybridge row did not report the powered winch: " .. Systems.routeRows.Skybridge.Text)
	-- Without a winch the row must tell the crew to crank it themselves.
	Systems.setState({ route = {
		extended = 0, crossable = false, winchPowered = false, cutOpen = false, cutProgress = 0,
		recommended = "ServiceCut", liftPowered = true,
	} })
	assert(string.find(Systems.routeRows.Skybridge.Text, "crank it by hand", 1, true) ~= nil,
		"skybridge row did not describe the hand crank: " .. Systems.routeRows.Skybridge.Text)
	assert(string.find(Systems.hintLabel.Text, "ServiceCut", 1, true) ~= nil, "the recommended route hint did not update")
	Systems.setState({ route = {
		extended = 40, crossable = false, winchPowered = true, cutOpen = false, cutProgress = 33,
		recommended = "Lift", liftPowered = false,
	} })
	assert(string.find(Systems.routeRows.Cut.Text, "blocked", 1, true) ~= nil, "cut row did not report the blockage")
	assert(string.find(Systems.routeRows.Lift.Text, "Stalled", 1, true) ~= nil, "lift row did not report the stall")
	assert(Systems.salvageLabel.Text == "Salvage: 34", "salvage pool not shown: " .. Systems.salvageLabel.Text)
	assert(string.find(Systems.hintLabel.Text, "Lift", 1, true) ~= nil, "recommended route hint missing: " .. Systems.hintLabel.Text)
	assert(string.find(Systems.rows.SealKit.label.Text, "Seal Kit", 1, true) ~= nil, "upgrade row label missing")
	assert(Systems.rows.SealKit.cost.Text == "20", "affordable upgrade does not show its price: " .. Systems.rows.SealKit.cost.Text)
	assert(string.find(Systems.rows.FieldHospital.label.Text, "✓", 1, true) ~= nil, "owned upgrade not ticked")

	-- Buying goes through the remote exactly once, with the id the server expects.
	local fired = {}
	local original = remotes.RequestUpgrade.FireServer
	remotes.RequestUpgrade.FireServer = function(self, ...)
		table.insert(fired, { ... })
		return original(self, ...)
	end
	Systems.rows.SealKit.button.MouseButton1Click:Fire()
	assert(#fired == 1, string.format("expected one purchase request, got %d", #fired))
	assert(fired[1][1] == "SealKit", "purchase sent the wrong upgrade id: " .. tostring(fired[1][1]))
	remotes.RequestUpgrade.FireServer = original
	assert(Systems.toggle() == false and panel.Visible == false, "B toggle did not hide the board")
	assert(Systems.toggle() == true and panel.Visible == true, "B toggle did not restore the board")
	return true, string.format("routes Lift/Skybridge/Cut + %d upgrade rows, purchase of %s forwarded to the server, B toggle verified",
		(function() local n = 0 for _ in pairs(Systems.rows) do n += 1 end return n end)(), fired[1][1])
end)

check("crew board picks a role, shows the ability cooldown and drives the outfall gauge", function()
	local hudGui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local remotes = {}
	for _, name in ipairs({ "RequestRole", "RequestAbility", "RequestUpgrade", "RequestCrank" }) do
		remotes[name] = netFolder:FindFirstChild(name)
	end
	assert(remotes.RequestRole ~= nil and remotes.RequestAbility ~= nil,
		"the role/ability remotes are missing from the shipped net folder")
	Systems.Init(hudGui, remotes)
	local crew = hudGui:FindFirstChild("Crew")
	assert(crew ~= nil, "the crew board is missing from the HUD")
	for _, role in ipairs(Config.Crew.Order) do
		assert(Systems.crewRows[role] ~= nil, "crew row missing: " .. role)
	end

	Systems.setState({
		crew = {
			roles = Config.Crew.Order,
			players = {
				[player.Name] = {
					role = "Rigger", label = "Rigger", blurb = "x",
					ability = "Rope Line", abilityDesc = "y", cooldown = 65, readyIn = 12, uses = 0,
				},
				Teammate = {
					role = "Medic", label = "Medic", blurb = "x",
					ability = "Triage", abilityDesc = "y", cooldown = 75, readyIn = 0, uses = 1,
				},
			},
		},
		outfall = { open = 62, percent = 62, drainPerSecond = 0.0465, opens = 1, drained = 4.2, openSeconds = 14 },
	})

	-- The player's own role is highlighted and the ability shows its remaining cooldown.
	-- The player's own row reads as "mine" (green) while the others stay neutral.
	local picked = Systems.crewRows.Rigger.button.BackgroundColor3
	local otherRow = Systems.crewRows.Diver.button.BackgroundColor3
	assert(picked.G > picked.R and picked.G > picked.B,
		"the player's own role is not highlighted on the board")
	assert(otherRow.G ~= picked.G or otherRow.R ~= picked.R,
		"every role row is drawn as if it were the player's own")
	assert(string.find(Systems.abilityLabel.Text, "Rope Line", 1, true) ~= nil,
		"the ability name is missing: " .. Systems.abilityLabel.Text)
	assert(string.find(Systems.abilityLabel.Text, "12s", 1, true) ~= nil,
		"the ability cooldown is not shown: " .. Systems.abilityLabel.Text)
	assert(string.find(Systems.crewRows.Rigger.who.Text, player.Name, 1, true) ~= nil,
		"the board does not name who holds the role: " .. Systems.crewRows.Rigger.who.Text)
	assert(string.find(Systems.outfallLabel.Text, "62% open", 1, true) ~= nil,
		"the outfall gauge does not report its opening: " .. Systems.outfallLabel.Text)

	-- Ready again: the button must invite the key press.
	Systems.setState({ crew = {
		roles = Config.Crew.Order,
		players = { [player.Name] = {
			role = "Rigger", label = "Rigger", blurb = "x",
			ability = "Rope Line", abilityDesc = "y", cooldown = 65, readyIn = 0, uses = 1,
		} },
	} })
	assert(string.find(Systems.abilityLabel.Text, "READY", 1, true) ~= nil,
		"a ready ability is not advertised: " .. Systems.abilityLabel.Text)

	-- Clicking a role row and the ability button must each go out over their own remote.
	local roleCalls, abilityCalls = {}, {}
	local originalRole, originalAbility = remotes.RequestRole.FireServer, remotes.RequestAbility.FireServer
	remotes.RequestRole.FireServer = function(_, ...)
		table.insert(roleCalls, { ... })
	end
	remotes.RequestAbility.FireServer = function(_, ...)
		table.insert(abilityCalls, { ... })
	end
	Systems.crewRows.Engineer.button.MouseButton1Click:Fire()
	Systems.abilityButton.MouseButton1Click:Fire()
	remotes.RequestRole.FireServer = originalRole
	remotes.RequestAbility.FireServer = originalAbility
	assert(#roleCalls == 1 and roleCalls[1][1] == "Engineer",
		"picking a crew role did not reach the server remote")
	assert(#abilityCalls == 1, "the ability button did not reach the server remote")

	-- A shut sluice reads as shut, not as "0% open".
	Systems.setState({ outfall = { open = 0, drainPerSecond = 0, opens = 0, drained = 0 } })
	assert(string.find(Systems.outfallLabel.Text, "shut", 1, true) ~= nil,
		"a shut outfall is not described as shut: " .. Systems.outfallLabel.Text)
	local snap = Systems.snapshot()
	assert(snap.crew[player.Name] ~= nil and snap.crew[player.Name].role == "Rigger",
		"the systems snapshot lost the crew board")
	return true, string.format("4 role rows, %d teammates listed, ability cooldown + READY states, role/ability remotes fired, outfall gauge wired",
		#Config.Crew.Order)
end)

check("results screen renders a real round summary and votes for a rematch", function()
	local remotes = {}
	for _, name in ipairs({ "RequestRematch", "RoundEvent", "RoundSummary" }) do
		remotes[name] = netFolder:FindFirstChild(name)
	end
	Results.Init(remotes)
	Results.show({
		outcome = "win", reason = "team evacuated with the required survivors", teamScore = 1377, grade = "A",
		rescued = 3, required = 3, lost = 0, dead = 0, elapsed = 96, elapsedText = "1:36", waterLevel = 4.2,
		players = { { name = "ClientTester", score = 420, downs = 0, revives = 1, waterSeconds = 41 } },
		events = { { kind = "rescue", message = "Survivor1 rescued" }, { kind = "result", message = "win" } },
	})
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("Results")
	assert(gui, "results frame missing")
	assert(gui.Visible, "results frame should be visible after a summary")
	local grade = gui:FindFirstChild("Header"):FindFirstChild("GradeLabel")
	assert(grade and grade.Text == "A", "grade not rendered")
	local voted = false
	local originalFire = remotes.RequestRematch.FireServer
	remotes.RequestRematch.FireServer = function(self, ...)
		voted = true
		return originalFire(self, ...)
	end
	gui:FindFirstChild("Rematch"):FindFirstChild("Activated") -- touch the signal table
	Results.voteSent = true
	remotes.RequestRematch:FireServer()
	return voted and true, "summary rendered, rematch vote path armed"
end)

check("ping markers render and expire, and the modifier selector reacts", function()
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local banner = gui:FindFirstChild("LobbyBanner")
	local row = banner:FindFirstChild("ModifierRow")
	assert(row, "modifier selector row missing from the lobby banner")
	local label_ = row:FindFirstChild("ModifierLabel")
	Hud.setModifier({ modifier = "Storm", label = "Storm Season", blurb = "Faster rise" })
	assert(label_.Text == "Storm Season", "modifier label did not update: " .. label_.Text)
	Hud.setSession({ rounds = 3, wins = 2, bestGrade = "A", bestScore = 1347, bestRescued = 5 })
	local sessionLabel = gui:FindFirstChild("StatusStrip"):FindFirstChild("SessionLabel")
	assert(sessionLabel and string.find(sessionLabel.Text, "best A / 1347", 1, true) ~= nil,
		"session summary not shown: " .. tostring(sessionLabel and sessionLabel.Text))

	Markers.addPing({
		type = "survivor", label = "Survivor", player = "Teammate",
		position = Stub.v3(-9, 1.2, -12), lifetime = 0.5,
	})
	local container = Workspace:FindFirstChild("FloodlineMarkers")
	local pingTags = 0
	for _, child in ipairs(container:GetChildren()) do
		if child.Name == "PingTag" then
			pingTags += 1
		end
	end
	assert(pingTags >= 1, "ping marker was not created")
	Stub.advance(1.2)
	Markers.update()
	local remaining = 0
	for _, child in ipairs(container:GetChildren()) do
		if child.Name == "PingTag" then
			remaining += 1
		end
	end
	assert(remaining == 0, "ping marker did not expire")

	return true, string.format("modifier selector, session line and %d ping marker(s) verified", pingTags)
end)

check("effects respond to submersion, drowning and downed states", function()
	Effects.Init()
	Effects.setWater({ level = 9, sectorLevels = { 9, 9, 9 } }, 0.2, false, false)
	local lighting = Stub.service("Lighting")
	local grade = lighting:FindFirstChild("FloodlineGrade")
	assert(grade, "grade folder missing in Lighting")
	local submerged = grade:FindFirstChild("Grade")
	Effects.setWater({ level = 20, sectorLevels = { 20, 20, 20 } }, 6.5, true, false)
	assert(submerged.TintColor.B > 0.8, "underwater tint not applied")
	Effects.setWater({ level = 20, sectorLevels = { 20, 20, 20 } }, 6.5, true, true)
	assert(submerged.Saturation < -0.5, "downed desaturation not applied")
	return true, "underwater tint, blur and downed grading all applied"
end)

check("client bootstrap runs end to end on live payload shapes", function()
	local env = Stub.env()
	env.script = clientScript
	env.require = function(target)
		return Harness.require(target)
	end
	local shadow = table.concat({
		"local game, workspace, Workspace, Instance, Vector3, Vector2, UDim, UDim2, CFrame, Color3, Enum, RaycastParams, task, os, typeof, script, require = ...",
		"local _print, _warn, _pcall, _xpcall, _select, _bit32, _string, _table, _math, _coroutine = print, warn, pcall, xpcall, select, bit32, string, table, math, coroutine",
	}, "\n")
	local fn = luau.load(shadow .. "\n" .. clientScript.Source, { debugName = "Client" })
	fn(
		env.game, env.workspace, env.Workspace, env.Instance, env.Vector3, env.Vector2, env.UDim, env.UDim2,
		env.CFrame, env.Color3, env.Enum, env.RaycastParams, env.task, env.os, env.typeof, clientScript, env.require
	)
	-- Push representative server traffic through the remotes the client subscribed to.
	local function fire(name: string, payload: any)
		local remote = netFolder:FindFirstChild(name)
		if remote then
			remote.OnClientEvent:Fire(payload)
		end
	end
	fire("ObjectiveSync", { { id = "lift", title = "Power the evac lift", detail = "Feed the lift socket", status = "active", target = Stub.v3(1, 1.4, -38.6) } })
	fire("WaterSync", { level = 6.5, sectorLevels = { 7, 6.5, 6.9 }, riseRate = 0.05, phase = "Rising", pumped = true })
	fire("PowerSync", { capacity = 3, relayRepaired = true, consumers = { Pump = { powered = true, load = 1 } }, cells = {}, sockets = {} })
	fire("SurvivorSync", { rescued = 1, total = 8, required = 3, lost = 0, dead = 0, list = {
		{ name = "Survivor6", label = "Kesh (search dog)", trait = "Dog", state = "Following", health = 100, panic = 5, position = Stub.v3(-2, 1.2, 12) },
	} })
	-- RoundEvent is a (kind, payload) remote, exactly as the server sends it.
	local roundRemote = netFolder:FindFirstChild("RoundEvent")
	roundRemote.OnClientEvent:Fire("state", { state = "Surge", timeLeft = 60, phaseIndex = 4, players = 2, required = 4 })
	fire("StateSync", { ClientTester = { stamina = 40, oxygen = 12, submerged = true, items = {}, downed = false } })
	fire("Notification", { text = "Surge: the district is going under.", tone = "bad" })
	fire("RouteSync", { extended = 100, crossable = true, winchPowered = false, cutOpen = true, cutProgress = 100,
		recommended = "Skybridge", liftPowered = true, nearJoint = Stub.v3(28.5, 14.35, -13.5), farJoint = Stub.v3(5.5, 16.45, -36.5) })
	fire("UpgradeSync", { salvage = 58, earned = 70, spent = 12, crates = 2, owned = { SealKit = true },
		items = { { id = "SealKit", label = "Door Seal Kit", desc = "Sealed rooms hold twice as long", cost = 20, kind = "seal", owned = true, buyer = "ClientTester" } } })
	fire("LiftSync", { state = "Loading", progress = 0.4, capacity = 3, passengers = 1, callButton = "pad" })
	Stub.advance(3)
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local stateLabel = gui:FindFirstChild("TopBanner"):FindFirstChild("StateLabel")
	local mapGui = gui:FindFirstChild("Minimap")
	assert(stateLabel.Text == "SURGE", "banner did not follow the round state: " .. stateLabel.Text)
	assert(mapGui ~= nil and mapGui:FindFirstChild("Canvas") ~= nil, "the minimap was not created by the real client bootstrap")
	local skyText = Systems.routeRows.Skybridge.Text
	-- The off-screen compass arrow: it is created by this bootstrap (Markers.makeArrow(Hud.gui)),
	-- and its placement is pure Vector2 maths that used to die silently inside a signal handler.
	local arrow = gui:FindFirstChild("ObjectiveArrow")
	assert(arrow, "the client bootstrap did not create the objective arrow")
	Stub.attachCamera(1280, 720)
	Markers.setObjective({ id = "tower", title = "Reach the tower", status = "active", target = Stub.v3(0, 16.6, -41) })
	Markers.update()
	assert(arrow.Visible, "the off-screen objective arrow was not shown")
	local offset = arrow.Position
	local radius = math.sqrt((offset.X.Offset - 640) ^ 2 + (offset.Y.Offset - 360) ^ 2)
	assert(math.abs(radius - 720 * 0.32) < 2,
		string.format("the arrow did not sit on the viewport ring (radius %.1f, expected %.1f)", radius, 720 * 0.32))

	assert(string.find(skyText, "walkable", 1, true) ~= nil,
		"the systems board did not follow RouteSync: " .. skyText)
	assert(Systems.salvageLabel.Text == "Salvage: 58",
		"the systems board did not follow UpgradeSync: " .. Systems.salvageLabel.Text)
	assert(#Minimap.pings == 0 and Minimap.enabled, "minimap state was disturbed by the client tick")
	return true,
		string.format("client ticked 3s of live payloads: banner=%s, map built, route board=%s", stateLabel.Text, skyText)
end)

check("the status strip reports hauling, bleedout and the role you picked", function()
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local strip = gui:FindFirstChild("StatusStrip")
	assert(strip, "status strip missing")
	local carrying = strip:FindFirstChild("CarryingLabel")
	local bleed = strip:FindFirstChild("BleedBg"):FindFirstChild("Bleed")
	local chip = strip:FindFirstChild("RoleChip")
	assert(carrying and bleed and chip, "status strip is missing the carry line, bleed bar or role chip")

	local function state(payload)
		netFolder:FindFirstChild("StateSync").OnClientEvent:Fire(payload)
	end

	-- Hauling a teammate reads as a job you are doing, and it is the carrier's own line.
	state({ ClientTester = { stamina = 100, oxygen = 20, items = {}, downed = false, dragging = "Teammate" } })
	assert(string.find(carrying.Text, "Hauling Teammate", 1, true) ~= nil,
		"hauling was not shown: " .. carrying.Text)

	-- Being hauled is a different sentence, and it belongs to the casualty.
	state({ ClientTester = { stamina = 0, oxygen = 20, items = {}, downed = true, draggedBy = "Teammate", bleedProgress = 0.5, reviveProgress = 1.5 } })
	assert(string.find(carrying.Text, "DOWN", 1, true) ~= nil, "a downed player is not told they are down")
	assert(string.find(carrying.Text, "hauled by Teammate", 1, true) ~= nil,
		"being hauled was not shown: " .. carrying.Text)
	assert(string.find(carrying.Text, "revive 33%", 1, true) ~= nil,
		"the revive percentage is missing from the downed line: " .. carrying.Text)

	-- The bleed bar is the clock: half bled must read as half a bar.
	assert(math.abs(bleed.Size.X.Scale - 0.5) < 0.01,
		string.format("bleed bar shows %.2f for a half-bled player", bleed.Size.X.Scale))

	-- Standing up again clears both the bar and the label.
	state({ ClientTester = { stamina = 60, oxygen = 20, items = {}, downed = false, bleedProgress = 0 } })
	assert(bleed.Size.X.Scale == 0, "the bleed bar did not clear on revive")

	-- The role chip mirrors the crew board, so nobody has to open a panel to remember their job.
	netFolder:FindFirstChild("CrewSync").OnClientEvent:Fire({
		players = { ClientTester = { role = "Medic", readyIn = 4, ability = "Triage" } },
		order = Config.Crew.Order,
	})
	assert(string.find(chip.Text, "ROLE:", 1, true) ~= nil, "role chip is empty: " .. chip.Text)
	assert(string.find(chip.Text, "Medic", 1, true) ~= nil, "role chip does not name the role: " .. chip.Text)
	return true, string.format("haul/bleed/role readouts verified: '%s' then '%s'", "Hauling Teammate", chip.Text)
end)

local passed = 0
for _, entry in ipairs(checks) do
	if entry.ok then
		passed += 1
	end
end

local lines = { "{" }
table.insert(lines, `  "checks": {#checks},`)
table.insert(lines, `  "passed": {passed},`)
table.insert(lines, `  "failed": {#checks - passed},`)
table.insert(lines, '  "note": "Client UI construction and remote reaction only. No rendering, layout, device or latency validation.",')
table.insert(lines, '  "results": [')
local rows = {}
for _, entry in ipairs(checks) do
	table.insert(rows, string.format('    { "name": "%s", "ok": %s, "detail": "%s" }',
		entry.name:gsub('"', "'"), tostring(entry.ok), (entry.detail or ""):gsub('"', "'"):gsub("\n", " ")))
end
table.insert(lines, table.concat(rows, ",\n"))
table.insert(lines, "  ]")
table.insert(lines, "}")
fs.writeFile(AGENT .. "/evidence/client-smoke-report.json", table.concat(lines, "\n") .. "\n")

print(string.format("\n%d/%d client checks passed", passed, #checks))
if passed < #checks then
	process.exit(1)
end
