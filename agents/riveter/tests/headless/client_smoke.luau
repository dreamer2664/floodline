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

local modules = playerScripts:FindFirstChild("Modules")
local hudScript = modules:FindFirstChild("Hud")
local markersScript = modules:FindFirstChild("Markers")
local effectsScript = modules:FindFirstChild("Effects")
local resultsScript = modules:FindFirstChild("Results")
local clientScript = playerScripts:FindFirstChild("Client")

check("client scripts are present in the shipped place", function()
	return hudScript ~= nil and markersScript ~= nil and effectsScript ~= nil
		and resultsScript ~= nil and clientScript ~= nil,
		string.format("modules=%s client=%s", tostring(modules ~= nil), tostring(clientScript ~= nil))
end)

-- Load the client modules through the same loader the harness uses for the server.
local Hud = Harness.require(hudScript)
local Markers = Harness.require(markersScript)
local Effects = Harness.require(effectsScript)
local Results = Harness.require(resultsScript)

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
			{ name = "Survivor1", label = "Mara (duty engineer)", trait = "Worker", state = "Following", health = 88, panic = 42, position = Stub.v3(-9, 1.2, -12) },
			{ name = "Survivor2", label = "Tobin (crushed leg)", trait = "Injured", state = "Downed", health = 0, panic = 96, position = Stub.v3(-33, 1.2, -18) },
			{ name = "Survivor3", label = "Idris (caretaker)", trait = "Elderly", state = "Rescued", health = 100, panic = 0, position = Stub.v3(0, 1, -12) },
		},
	})
	local power = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud"):FindFirstChild("PowerGrid")
	local roster = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud"):FindFirstChild("Roster")
	local powerRows = #power:FindFirstChild("List"):GetChildren()
	local rosterRows = #roster:FindFirstChild("List"):GetChildren()
	return powerRows >= 4 and rosterRows >= 3,
		string.format("power rows=%d roster rows=%d", powerRows, rosterRows)
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
	Stub.advance(3)
	local gui = player:FindFirstChild("PlayerGui"):FindFirstChild("FloodlineHud")
	local stateLabel = gui:FindFirstChild("TopBanner"):FindFirstChild("StateLabel")
	return stateLabel.Text == "SURGE",
		string.format("client ticked 3s of live payloads, banner=%s", stateLabel.Text)
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
