--!strict
-- FLOODLINE client bootstrap: receives world state, drives the HUD/markers/effects,
-- handles local input (sprint, drop, call lift, revive, interaction) and proximity hints.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ContextActionService = game:GetService("ContextActionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))
local Net = require(Shared:WaitForChild("Net"))

local ClientModules = script.Parent:WaitForChild("Modules")
local Hud = require(ClientModules:WaitForChild("Hud"))
local Markers = require(ClientModules:WaitForChild("Markers"))
local Effects = require(ClientModules:WaitForChild("Effects"))
local Results = require(ClientModules:WaitForChild("Results"))

local player = Players.LocalPlayer
local remotes = Net.clientInit(25)

local C = Config.Ui.Colors

local state = {
	water = { level = 0, sectorLevels = { 0, 0, 0 }, pumped = false },
	survivors = { list = {}, rescued = 0, total = Config.Survivors.Total, required = 3 },
	power = { consumers = {}, cells = {}, sockets = {}, capacity = 2 },
	round = { state = "Lobby", players = 1, phaseIndex = 0 },
	status = {},
	objectives = {},
	myDepth = 0,
	submerged = false,
	downed = false,
}

local function sectorAt(position: Vector3): number
	if position.Z >= 22 then
		return 1
	elseif position.Z >= -32 then
		return 2
	end
	return 3
end

local function localDepth(): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return 0
	end
	local position = (root :: BasePart).Position
	local sector = sectorAt(position)
	local level = state.water.sectorLevels[sector] or state.water.level
	return math.max(0, level - position.Y)
end

-- ===================== HUD wiring =====================

local function wireRemotes()
	if remotes.ObjectiveSync then
		remotes.ObjectiveSync.OnClientEvent:Connect(function(list: { any })
			state.objectives = list
			Hud.updateObjectives(list)
			local active = nil
			for _, entry in ipairs(list) do
				if entry.status == "active" and not active then
					active = entry
				end
			end
			Markers.setObjective(active)
		end)
	end

	if remotes.WaterSync then
		remotes.WaterSync.OnClientEvent:Connect(function(snapshot: any)
			state.water = snapshot
			Hud.setWater(snapshot)
		end)
	end

	if remotes.PowerSync then
		remotes.PowerSync.OnClientEvent:Connect(function(snapshot: any)
			state.power = snapshot
			Hud.updatePower(snapshot)
		end)
	end

	if remotes.SurvivorSync then
		remotes.SurvivorSync.OnClientEvent:Connect(function(snapshot: any)
			state.survivors = snapshot
			Hud.updateSurvivors(snapshot)
			Markers.syncSurvivors(snapshot)
		end)
	end

	if remotes.RoundEvent then
		remotes.RoundEvent.OnClientEvent:Connect(function(kind: string, payload: any)
			if kind == "state" then
				state.round = payload
				Hud.setState(payload)
			elseif kind == "tick" then
				state.round = payload
				Hud.setTick(payload)
			end
		end)
	end

	if remotes.Notification then
		remotes.Notification.OnClientEvent:Connect(function(payload: any)
			Hud.notify(payload)
			if payload.personal then
				Hud.showCentrePrompt(payload.text, payload.tone)
			end
		end)
	end

	if remotes.LiftSync then
		remotes.LiftSync.OnClientEvent:Connect(function(snapshot: any)
			state.lift = snapshot
			if snapshot.state == "Stalled" then
				Hud.showCentrePrompt("Lift stalled — restore power", "bad")
			end
		end)
	end

	if remotes.StateSync then
		remotes.StateSync.OnClientEvent:Connect(function(payload: any)
			state.status = payload
			Hud.setStatus(payload)
			local me = payload[player.Name]
			if me then
				state.downed = me.downed == true
				state.submerged = me.submerged == true
			end
		end)
	end

	if remotes.PlayerEvent then
		remotes.PlayerEvent.OnClientEvent:Connect(function(kind: string, data: any)
			if kind == "downed" then
				Hud.notify({ text = `You are down ({data and data.cause or "injuries"}). Teammates can revive you.`, tone = "bad", personal = true })
				Hud.showCentrePrompt("DOWN — wait for a revive", "bad")
			elseif kind == "revived" then
				Hud.notify({ text = "Back on your feet.", tone = "good", personal = true })
			end
		end)
	end
end

-- ===================== interactions =====================

local function nearestSurvivor(): (string?, number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil, math.huge
	end
	local position = (root :: BasePart).Position
	local best: string? = nil
	local bestDistance = math.huge
	for _, entry in ipairs(state.survivors.list or {}) do
		if entry.state == "Rescued" or entry.state == "Dead" or entry.state == "Carried" then
			continue
		end
		if typeof(entry.position) ~= "Vector3" then
			continue
		end
		local distance = (entry.position - position).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			best = entry.name
		end
	end
	return best, bestDistance
end

local function handleSurvivorKey()
	local name, distance = nearestSurvivor()
	if not name or distance > 10 then
		Hud.showCentrePrompt("No survivor within reach", "warn")
		return
	end
	local entry = Util.find(state.survivors.list or {}, function(item)
		return item.name == name
	end)
	if entry and entry.state == "Downed" then
		remotes.RequestInteract:FireServer("revive", name)
	elseif entry and entry.state == "Following" then
		remotes.RequestInteract:FireServer("carry", name)
	else
		remotes.RequestInteract:FireServer("lead", name)
	end
end

local function handleCellKey()
	-- Pick up the nearest loose cell, or interact with the nearest socket.
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local position = (root :: BasePart).Position
	local bestCell: string? = nil
	local bestCellDistance = 12
	for id, cell in pairs(state.power.cells or {}) do
		if cell.destroyed or cell.holder or cell.socket then
			continue
		end
		local distance = (cell.position - position).Magnitude
		if distance < bestCellDistance then
			bestCellDistance = distance
			bestCell = id
		end
	end
	if bestCell then
		remotes.RequestInteract:FireServer("pickup", bestCell)
		return
	end
	local bestSocket: string? = nil
	local bestSocketDistance = 14
	for key, socket in pairs(state.power.sockets or {}) do
		local distance = (socket.position - position).Magnitude
		if distance < bestSocketDistance then
			bestSocketDistance = distance
			bestSocket = key
		end
	end
	if bestSocket then
		remotes.RequestInteract:FireServer("socket", bestSocket)
	else
		Hud.showCentrePrompt("Nothing to grab here (cell or socket needed)", "warn")
	end
end

local function bindInput()
	ContextActionService:BindAction("FloodlineSprint", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			remotes.RequestSprint:FireServer(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			remotes.RequestSprint:FireServer(false)
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.LeftShift)

	ContextActionService:BindAction("FloodlineDrop", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			remotes.RequestDrop:FireServer()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.Q)

	ContextActionService:BindAction("FloodlineUse", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			handleCellKey()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.E)

	ContextActionService:BindAction("FloodlineSurvivor", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			handleSurvivorKey()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.F)

	ContextActionService:BindAction("FloodlineLift", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			remotes.RequestLiftCall:FireServer()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.G)

	Hud.startButton.MouseButton1Click:Connect(function()
		remotes.RequestStart:FireServer()
	end)

end

-- ===================== per-frame =====================

local hintCooldown = 0

local function updateHints(dt: number)
	hintCooldown -= dt
	if hintCooldown > 0 then
		return
	end
	hintCooldown = 0.35
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local position = (root :: BasePart).Position
	local lines = {}
	-- Nearby interactables come from the prompt system itself, so only world hazards here.
	local depth = localDepth()
	if depth > 0.4 then
		table.insert(lines, `Water depth {string.format("%.1f", depth)}m`)
	elseif state.water.level > 0 then
		table.insert(lines, `District water {string.format("%.1f", state.water.level)}m`)
	end
	if state.power.consumers and state.power.consumers.Pump and not state.power.consumers.Pump.powered then
		table.insert(lines, "Pump offline")
	end
	if state.round.radioCalled then
		table.insert(lines, "Extraction live")
	end
	local name, distance = nearestSurvivor()
	if name and distance < 14 then
		table.insert(lines, `[F] {name} ({math.floor(distance)}m)`)
	end
	Hud.hintLabel.Text = #lines > 0 and table.concat(lines, "  ·  ") or "E: grab/use cell  ·  F: survivor  ·  G: lift  ·  Q: drop  ·  Shift: sprint"
end

local function updateCamera(dt: number)
	-- Downed players get a slow pull-back so the situation reads from a distance.
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and state.downed then
		humanoid.CameraOffset = humanoid.CameraOffset:Lerp(Vector3.new(0, 2.2, 0), 0.05)
	end
end

wireRemotes()
Hud.Init()
Markers.Init()
Effects.Init(remotes)
Results.Init(remotes)
bindInput()
Markers.makeArrow(Hud.gui)

Hud.updateObjectives({})
Hud.updatePower(state.power)
Hud.updateSurvivors(state.survivors)
Hud.setState(state.round)

RunService.RenderStepped:Connect(function(dt)
	state.myDepth = localDepth()
	Effects.setWater(state.water, state.myDepth, state.submerged, state.downed)
	Markers.update()
	Hud.update()
	updateHints(dt)
	updateCamera(dt)
end)

-- Ask for a fresh snapshot when the client joins mid-round.
task.spawn(function()
	local ok, snapshot = pcall(function()
		return remotes.GetSnapshot:InvokeServer()
	end)
	if ok and snapshot then
		Hud.setState(snapshot.round)
		Hud.setTick(snapshot.round)
		Hud.setWater(snapshot.water)
		Hud.updatePower(snapshot.power)
		Hud.updateSurvivors(snapshot.survivors)
		Hud.updateObjectives(snapshot.objectives or {})
		state.water = snapshot.water
		state.power = snapshot.power
		state.survivors = snapshot.survivors
	end
end)

print(`[FLOODLINE] client ready — version {Config.Game.Version}`)
