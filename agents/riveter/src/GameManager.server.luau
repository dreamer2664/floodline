-- FLOODLINE server (authoritative)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Remotes = Instance.new("Folder")
Remotes.Name = "Remotes"
Remotes.Parent = ReplicatedStorage
local function makeRemote(name, class)
	local r = Instance.new(class)
	r.Name = name
	r.Parent = Remotes
	return r
end
local EvtState = makeRemote("RoundState", "RemoteEvent")
local EvtHUD = makeRemote("HUDMessage", "RemoteEvent")
local EvtPower = makeRemote("PowerUpdate", "RemoteEvent")
local EvtRequestStart = makeRemote("RequestStart", "RemoteEvent")
local EvtCallLiftUI = makeRemote("CallLiftUI", "RemoteEvent")

local ROUND = {
	state = "Lobby",
	startTime = 0,
	stage = 0,
	waterY = -2,
	targetWaterY = -2,
	power = { Pump = false, Bridge = false, Lift = false },
	carrying = {},
	following = {},
	rescued = 0,
	extracted = {},
	totalSurvivors = 0,
	liftCalled = false,
	liftY = 1,
}

local function getWater()
	local w = Workspace:FindFirstChild("FloodWater", true)
	if not w then
		w = Instance.new("Part")
		w.Name = "FloodWater"
		w.Anchored = true
		w.CanCollide = false
		w.Transparency = 0.45
		w.Color = Color3.fromRGB(20, 80, 120)
		w.Material = Enum.Material.Glass
		w.Size = Vector3.new(200, 1, 200)
		w.Position = Vector3.new(0, -2, 0)
		w.Parent = Workspace
	end
	return w
end

local function getSafeZone()
	return Workspace:FindFirstChild("SafeZone", true)
end

local function survivorsFolder()
	local f = Workspace:FindFirstChild("Survivors", true)
	if not f then f = Instance.new("Folder"); f.Name = "Survivors"; f.Parent = Workspace end
	return f
end

local function cellsFolder()
	local f = Workspace:FindFirstChild("Cells", true)
	if not f then f = Instance.new("Folder"); f.Name = "Cells"; f.Parent = Workspace end
	return f
end

local function countSurvivors()
	local n = 0
	for _, s in ipairs(survivorsFolder():GetChildren()) do
		if s:IsA("Model") then n = n + 1 end
	end
	return n
end

local function resetSurvivors()
	for _, s in ipairs(survivorsFolder():GetChildren()) do
		if s:IsA("Model") then
			local hrp = s:FindFirstChild("HumanoidRootPart")
			local sp = s:GetAttribute("SpawnPos")
			if hrp and sp then
				s:PivotTo(CFrame.new(sp))
			end
			local hum = s:FindFirstChildOfClass("Humanoid")
			if hum then hum.Health = hum.MaxHealth end
		end
	end
end

local function resetCells()
	for _, c in ipairs(cellsFolder():GetChildren()) do
		c.Transparency = 0
		c.CanCollide = true
		local pr = c:FindFirstChildOfClass("ProximityPrompt")
		if pr then pr.Enabled = true end
	end
end

local function resetLift()
	local lift = Workspace:FindFirstChild("EvacLift", true)
	if lift then
		lift:PivotTo(CFrame.new(0, 1, -30))
	end
	ROUND.liftCalled = false
	ROUND.liftY = 1
end

local function broadcastPower()
	EvtPower:FireAllClients(ROUND.power)
end

local function startRound()
	ROUND.state = "Running"
	ROUND.startTime = tick()
	ROUND.stage = 0
	ROUND.waterY = -2
	ROUND.targetWaterY = -2
	ROUND.power = { Pump = false, Bridge = false, Lift = false }
	ROUND.carrying = {}
	ROUND.following = {}
	ROUND.rescued = 0
	ROUND.extracted = {}
	ROUND.liftCalled = false
	ROUND.totalSurvivors = countSurvivors()
	resetSurvivors()
	resetCells()
	resetLift()
	getWater().Position = Vector3.new(0, -2, 0)
	EvtState:FireAllClients("Running")
	EvtHUD:FireAllClients("Round started. Find cells, power what matters.")
	broadcastPower()
end

local function endRound(result)
	ROUND.state = "Results"
	EvtState:FireAllClients(result)
	local msg = result
	EvtHUD:FireAllClients(msg .. " | Rescued: " .. ROUND.rescued .. "/" .. ROUND.totalSurvivors)
	task.delay(12, function()
		ROUND.state = "Lobby"
		EvtState:FireAllClients("Lobby")
		EvtHUD:FireAllClients("Rematch in lobby. Press Start.")
	end)
end

-- Interaction handling
local function handlePrompt(prompt, player)
	local parent = prompt.Parent
	if not parent then return end
	local name = parent.Name
	if name:sub(1, 4) == "Cell" then
		if not ROUND.carrying[player] then
			ROUND.carrying[player] = name
			parent.Transparency = 1
			parent.CanCollide = false
			prompt.Enabled = false
			EvtHUD:FireClient(player, "Carrying power cell. Insert into a socket.")
		end
	elseif name:sub(1, 7) == "Socket_" then
		local consumer = name:sub(8)
		if ROUND.carrying[player] then
			ROUND.power[consumer] = true
			ROUND.carrying[player] = nil
			broadcastPower()
			EvtHUD:FireAllClients(consumer .. " powered")
		else
			if ROUND.power[consumer] then
				ROUND.power[consumer] = false
				ROUND.carrying[player] = consumer .. "_cell"
				broadcastPower()
				EvtHUD:FireClient(player, "Removed cell from " .. consumer)
			else
				EvtHUD:FireClient(player, "No cell to insert")
			end
		end
	elseif name:sub(1, 8) == "Survivor" then
		ROUND.following[parent] = player
		EvtHUD:FireClient(player, "Leading " .. name)
	elseif name == "LiftCall" then
		if ROUND.power.Lift then
			ROUND.liftCalled = true
			EvtHUD:FireAllClients("Evacuation lift called")
		else
			EvtHUD:FireClient(player, "Lift has no power")
		end
	elseif name == "StartButton" then
		if ROUND.state == "Lobby" then startRound() end
	end
end

local function hookPrompts(root)
	for _, p in ipairs(root:GetDescendants()) do
		if p:IsA("ProximityPrompt") then
			p.Triggered:Connect(function(player) handlePrompt(p, player) end)
		end
	end
	root.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") then
			d.Triggered:Connect(function(player) handlePrompt(d, player) end)
		end
	end)
end
hookPrompts(Workspace)

EvtRequestStart.OnServerEvent:Connect(function(player)
	if ROUND.state == "Lobby" then startRound() end
end)
EvtCallLiftUI.OnServerEvent:Connect(function(player)
	local liftCall = Workspace:FindFirstChild("LiftCall", true)
	-- find any part named LiftCall
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d.Name == "LiftCall" then
			if ROUND.power.Lift then ROUND.liftCalled = true; EvtHUD:FireAllClients("Lift called") else EvtHUD:FireClient(player, "Lift unpowered") end
			break
		end
	end
end)

-- Player join handling
Players.PlayerAdded:Connect(function(pl)
	pl.CharacterAdded:Connect(function(char)
		task.wait(0.5)
		if ROUND.state == "Lobby" then
			EvtState:FireClient(pl, "Lobby")
		else
			EvtState:FireClient(pl, ROUND.state)
		end
	end)
end)

-- Auto start
task.spawn(function()
	task.wait(8)
	if ROUND.state == "Lobby" and #Players:GetPlayers() >= 1 then
		startRound()
	end
end)

-- Main loop
task.spawn(function()
	while true do
		if ROUND.state == "Running" or ROUND.state == "Extraction" then
			local elapsed = tick() - ROUND.startTime
			local stages = { {0, -2}, {90, 0.5}, {180, 2.5}, {270, 4.5}, {360, 6.5} }
			local newStage = 0
			for i, s in ipairs(stages) do
				if elapsed >= s[1] then newStage = i - 1 end
			end
			if newStage ~= ROUND.stage then
				ROUND.stage = newStage
				ROUND.targetWaterY = stages[newStage + 1][2]
				EvtHUD:FireAllClients("Flood rising! Stage " .. newStage)
			end
			local water = getWater()
			ROUND.waterY = ROUND.waterY + (ROUND.targetWaterY - ROUND.waterY) * 0.08
			water.Position = Vector3.new(0, ROUND.waterY, 0)

			-- damage
			for _, pl in ipairs(Players:GetPlayers()) do
				local char = pl.Character
				if char then
					local hrp = char:FindFirstChild("HumanoidRootPart")
					local hum = char:FindFirstChildOfClass("Humanoid")
					if hrp and hum and hrp.Position.Y < ROUND.waterY - 0.3 then
						hum:TakeDamage(1.5)
					end
				end
			end

			-- pump effect: if Pump powered, lower target water slightly
			if ROUND.power.Pump then
				ROUND.targetWaterY = ROUND.targetWaterY - 0.6
			end

			-- bridge: if Bridge powered, make bridge part walkable (already walkable) maybe change color
			local bridge = Workspace:FindFirstChild("BridgeGate", true)
			if bridge then
				bridge.Color = ROUND.power.Bridge and Color3.fromRGB(80, 200, 120) or Color3.fromRGB(120, 60, 60)
				bridge.CanCollide = true
			end

			-- survivor follow + rescue
			for surv, pl in pairs(ROUND.following) do
				if surv.Parent and pl.Character then
					local hum = surv:FindFirstChildOfClass("Humanoid")
					if hum then
						local pos = pl.Character:GetPivot().Position
						hum:MoveTo(Vector3.new(pos.X, surv:GetPivot().Position.Y, pos.Z))
					end
				end
			end
			local safe = getSafeZone()
			if safe then
				for _, surv in ipairs(survivorsFolder():GetChildren()) do
					if surv:IsA("Model") then
						local hrp = surv:FindFirstChild("HumanoidRootPart")
						if hrp and (hrp.Position - safe.Position).Magnitude < 12 then
							if not surv:GetAttribute("Rescued") then
								surv:SetAttribute("Rescued", true)
								ROUND.rescued = ROUND.rescued + 1
								ROUND.following[surv] = nil
								surv.Transparency = 1
								for _, d in ipairs(surv:GetDescendants()) do if d:IsA("BasePart") then d.Transparency = 1 end end
								EvtHUD:FireAllClients("Survivor rescued! (" .. ROUND.rescued .. "/" .. ROUND.totalSurvivors .. ")")
							end
						end
					end
				end
			end

			-- lift movement
			local lift = Workspace:FindFirstChild("EvacLift", true)
			if lift and ROUND.liftCalled and ROUND.power.Lift then
				local cur = lift:GetPivot().Position
				local targetY = 14
				if cur.Y < targetY then
					lift:PivotTo(CFrame.new(cur.X, cur.Y + 0.25, cur.Z))
				else
					ROUND.state = "Extraction"
				end
			end

			-- extraction: players near lift at top
			if ROUND.state == "Extraction" then
				if lift then
					local lpos = lift:GetPivot().Position
					for _, pl in ipairs(Players:GetPlayers()) do
						if not ROUND.extracted[pl] then
							local char = pl.Character
							if char then
								local hrp = char:FindFirstChild("HumanoidRootPart")
								if hrp and (hrp.Position - lpos).Magnitude < 12 and lpos.Y > 12 then
									ROUND.extracted[pl] = true
									EvtHUD:FireClient(pl, "Extracted!")
								end
							end
						end
					end
				end
				-- end if all players extracted or timeout
				local allExt = true
				for _, pl in ipairs(Players:GetPlayers()) do
					if not ROUND.extracted[pl] then allExt = false end
				end
				if allExt and #Players:GetPlayers() > 0 then
					local result = "Win"
					if ROUND.rescued < math.max(1, math.floor(ROUND.totalSurvivors / 2)) then result = "Partial" end
					endRound(result .. ": Extracted " .. ROUND.rescued .. " survivors")
				end
			end

			if elapsed > 600 and (ROUND.state == "Running" or ROUND.state == "Extraction") then
				endRound("Fail: Time ran out")
			end
		end
		task.wait(0.1)
	end
end)

-- Death handling
Players.PlayerAdded:Connect(function(pl)
	pl.CharacterAdded:Connect(function(char)
		local hum = char:WaitForChild("Humanoid")
		hum.Died:Connect(function()
			if ROUND.state ~= "Results" then
				EvtHUD:FireClient(pl, "You died. Respawning...")
			end
		end)
	end)
end)

-- Lighting setup
local Lighting = game:GetService("Lighting")
Lighting.FogEnd = 220
Lighting.FogStart = 80
Lighting.Brightness = 1.1
Lighting.Ambient = Color3.fromRGB(40,50,70)
Lighting.OutdoorAmbient = Color3.fromRGB(60,70,90)
