--!strict
-- HazardService: live cables that short out in water, gas leak with a valve fix, telegraphed
-- debris strikes that can down survivors, and structural collapse during the surge.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Hazard = {}
Hazard.Name = "Hazard"

Hazard.leakFixed = false
Hazard.events = {} :: { any }
Hazard.nextEventAt = 0
Hazard.cables = {} :: { BasePart }
Hazard.debrisFolder = nil :: Folder?
Hazard.lastCableZap = {} :: { [Player]: number }
Hazard.collapsed = false
Hazard.log = {} :: { string }

local ctx

function Hazard.isLeakFixed(): boolean
	return Hazard.leakFixed
end

function Hazard.fixLeak(player: Player?)
	Hazard.leakFixed = true
	table.insert(Hazard.log, `leak fixed by {player and player.Name or "system"} at {Util.round(os.clock(), 1)}`)
	ctx.notify("Gas leak capped. The workshop is breathable again.", "good")
	if player then
		ctx.addScore(player, 45, "gas leak")
	end
end

function Hazard.reset()
	Hazard.leakFixed = false
	Hazard.events = {}
	Hazard.nextEventAt = os.clock() + 30
	Hazard.collapsed = false
	Hazard.lastCableZap = {}
	Hazard.log = {}
	Hazard.cables = {}
	local world = ctx.worldFolder
	-- Cable segments are tagged in the baked world.
	for _, descendant in ipairs(world:GetDescendants()) do
		if descendant:IsA("BasePart") and string.sub(descendant.Name, 1, 9) == "LiveCable" then
			table.insert(Hazard.cables, descendant)
		end
	end
	if Hazard.debrisFolder then
		Hazard.debrisFolder:ClearAllChildren()
	else
		local folder = Instance.new("Folder")
		folder.Name = "Debris"
		folder.Parent = world
		Hazard.debrisFolder = folder
	end
	ctx.log(`[Hazard] {#Hazard.cables} live cable runs armed`)
end

-- ===================== live cables =====================

local function updateCables(dt: number)
	local now = os.clock()
	for _, cable in ipairs(Hazard.cables) do
		local depth = ctx.flood.depthAt(cable.Position)
		local live = depth < ctx.config.Water.ShockDepth
		if live then
			cable.Color = Color3.fromRGB(255, 120, 60)
			cable.Transparency = 0.05
		else
			cable.Color = Color3.fromRGB(70, 70, 80)
			cable.Transparency = 0.45
		end
		if not live then
			continue
		end
		for _, player in ipairs(Players:GetPlayers()) do
			if (Hazard.lastCableZap[player] or 0) > now - 0.8 then
				continue
			end
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not (root and humanoid and humanoid.Health > 0) then
				continue
			end
			if ((root :: BasePart).Position - cable.Position).Magnitude <= 6.5 then
				Hazard.lastCableZap[player] = now
				humanoid:TakeDamage(ctx.config.Player.ShockDamage)
				ctx.notifyPlayer(player, "Live cable! Get clear.", "bad")
				Util.playSound(cable, ctx.config.Fx.PingSounds.Error, 0.4, 1.4)
			end
		end
	end
end

-- ===================== gas leak =====================

local function updateGas(dt: number)
	if Hazard.leakFixed then
		return
	end
	local workshop = ctx.world.zones.Workshop
	if not workshop then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not (root and humanoid and humanoid.Health > 0) then
			continue
		end
		if Util.pointInBounds((root :: BasePart).Position, workshop.min, workshop.max, 2) then
			humanoid:TakeDamage(3.5 * dt)
		end
	end
	-- Unprotected survivors in the workshop get sick too.
	for _, survivor in ipairs(ctx.rescue.alive()) do
		if Util.pointInBounds(survivor.position, workshop.min, workshop.max, 2) then
			survivor.health -= 2.2 * dt
			if survivor.health <= 0 and survivor.state ~= "Downed" then
				ctx.rescue.onHazardDown(survivor.name, "gas")
			end
		end
	end
end

-- ===================== debris strikes =====================

local function telegraph(position: Vector3, seconds: number, label: string)
	local marker = Instance.new("Part")
	marker.Name = "ImpactWarning"
	marker.Shape = Enum.PartType.Cylinder
	marker.Size = Vector3.new(0.4, 12, 12)
	marker.CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, 0, math.rad(90))
	marker.Anchored = true
	marker.CanCollide = false
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.fromRGB(230, 90, 70)
	marker.Transparency = 0.5
	marker.Parent = Hazard.debrisFolder
	ctx.notify(`{label} — clear the marked area!`, "bad")
	for i = 0, 8 do
		task.delay(i * (seconds / 8), function()
			if marker.Parent then
				marker.Transparency = 0.4 + 0.5 * math.abs(math.sin(i))
			end
		end)
	end
	return marker
end

local function strike(position: Vector3, radius: number, damage: number)
	local origin = position + Vector3.new(0, 60, 0)
	local count = math.random(3, 6)
	for i = 1, count do
		local rock = Instance.new("Part")
		rock.Name = "DebrisRock"
		rock.Size = Vector3.new(math.random(2, 5), math.random(2, 5), math.random(2, 5))
		rock.Position = origin + Vector3.new(math.random(-8, 8), math.random(0, 10), math.random(-8, 8))
		rock.Material = Enum.Material.Concrete
		rock.Color = Color3.fromRGB(72, 70, 66)
		rock.Anchored = false
		rock.CanCollide = true
		rock.Parent = Hazard.debrisFolder
		task.delay(45, function()
			rock:Destroy()
		end)
	end
	task.delay(2.2, function()
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if root and humanoid and humanoid.Health > 0 then
				local distance = ((root :: BasePart).Position - position).Magnitude
				if distance <= radius then
					local falloff = 1 - (distance / radius) * 0.6
					humanoid:TakeDamage(damage * falloff)
					ctx.notifyPlayer(player, "Debris hit! Watch the marked zones.", "bad")
				end
			end
		end
		for _, survivor in ipairs(ctx.rescue.alive()) do
			if (survivor.position - position).Magnitude <= radius then
				ctx.rescue.onHazardDown(survivor.name, "falling debris")
			end
		end
		Util.playSound(Hazard.debrisFolder, ctx.config.Fx.PingSounds.Error, 0.5, 0.7)
	end)
end

local function scheduleEvent()
	-- Config.scaling already folds the difficulty modifier into HazardRate.
	local rate = ctx.scaling().HazardRate
	local phase = ctx.flood.phase
	if phase ~= "Rising" and phase ~= "Surge" then
		return
	end
	local roll = math.random()
	local zoneNames = { "Terminal", "ApartmentBlock", "Workshop", "Clinic", "PumpHouse", "ParkingGarage", "FerryTerminal" }
	local zoneName = zoneNames[math.random(1, #zoneNames)]
	local zone = ctx.world.zones[zoneName]
	if not zone then
		return
	end
	if roll < 0.55 then
		local position = Vector3.new(
			math.random(math.floor(zone.min.X), math.floor(zone.max.X)),
			1,
			math.random(math.floor(zone.min.Z), math.floor(zone.max.Z))
		)
		local warning = telegraph(position, 3.2, `Structural debris incoming near the {zoneName}`)
		task.delay(3.2, function()
			warning:Destroy()
			strike(position, 14, 34)
		end)
		table.insert(Hazard.log, `debris strike near {zoneName}`)
	elseif roll < 0.8 then
		local sector = math.random(1, ctx.config.Water.SectorCount)
		ctx.flood.surge(0.6 * rate, sector)
		table.insert(Hazard.log, `flood pulse sector {sector}`)
	else
		if not Hazard.collapsed and ctx.flood.phase == "Surge" then
			Hazard.collapse()
		end
	end
	Hazard.nextEventAt = os.clock() + math.random(28, 46) / math.max(0.3, rate)
end

function Hazard.collapse()
	Hazard.collapsed = true
	local zone = ctx.world.zones.ApartmentBlock
	if not zone then
		return
	end
	table.insert(Hazard.log, "apartment roof access collapse telegraphed")
	ctx.notify("The apartment roof access gave way — upper floors are compromised.", "bad")
	table.insert(Hazard.log, "apartment collapse")
	local top = zone.max.Y
	for _, part in ipairs(ctx.worldFolder:GetDescendants()) do
		if part:IsA("BasePart") and part.Position.Y > top - 4 then
			part.Color = Color3.fromRGB(90, 70, 60)
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and Util.pointInBounds((root :: BasePart).Position, zone.min, zone.max, 2) then
			humanoid:TakeDamage(22)
		end
	end
end

function Hazard.update(dt: number)
	updateCables(dt)
	updateGas(dt)
	if os.clock() >= Hazard.nextEventAt then
		scheduleEvent()
	end
end

function Hazard.snapshot()
	return {
		leakFixed = Hazard.leakFixed,
		collapsed = Hazard.collapsed,
		cableCount = #Hazard.cables,
	}
end

function Hazard.Init(context)
	ctx = context
end

function Hazard.Start(context)
	ctx = context
	Hazard.reset()
	RunService.Heartbeat:Connect(function(dt)
		if ctx.roundActive() then
			Hazard.update(math.min(dt, 0.2))
		end
	end)
end

return Hazard
