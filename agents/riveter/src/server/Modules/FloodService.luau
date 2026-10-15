--!strict
-- FloodService: owns the water. Rising levels per district sector, storm surges, pump mitigation,
-- swim/buoyancy physics for characters, oxygen and drowning.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Flood = {}
Flood.Name = "Flood"

Flood.level = 0
Flood.sectorLevels = { 0, 0, 0 }
Flood.riseRate = 0
Flood.phase = "Lobby"
Flood.paused = true
Flood.nextSurgeAt = 0
Flood.surgeTarget = nil :: number?
Flood.oxygen = {} :: { [Player]: { value: number, submerged: boolean } }
Flood.lastNotifyAt = 0

local ctx

function Flood.depthAt(position: Vector3): number
	return ctx.world.depthAt(position, Flood.level, Flood.sectorLevels)
end

function Flood.sectorDepth(sector: number, y: number): number
	local level = Flood.sectorLevels[sector] or Flood.level
	return math.max(0, level - y)
end

function Flood.isSubmerged(position: Vector3, threshold: number?): boolean
	return Flood.depthAt(position) > (threshold or 0.8)
end

function Flood.setPhase(phase: string)
	Flood.phase = phase
	local base = ctx.config.Water.RisePerSecond[phase] or 0
	local scale = ctx.scaling().RiseMultiplier
	Flood.riseRate = base * scale
	Flood.paused = (phase == "Lobby" or phase == "Results" or phase == "Intermission")
	Flood.nextSurgeAt = os.clock() + 22
	ctx.log(`[Flood] phase={phase} rise={Util.round(Flood.riseRate, 4)}/s`)
end

function Flood.reset()
	Flood.level = ctx.config.Water.StartLevel
	Flood.sectorLevels = {}
	for index = 1, ctx.config.Water.SectorCount do
		Flood.sectorLevels[index] = Flood.level + (ctx.config.Water.SectorOffsets[index] or 0)
	end
	Flood.oxygen = {}
	Flood.applyVolumes()
end

function Flood.surge(amount: number, sector: number?)
	if sector then
		Flood.sectorLevels[sector] = math.min(ctx.config.Water.MaxLevel, (Flood.sectorLevels[sector] or Flood.level) + amount)
	else
		for index = 1, ctx.config.Water.SectorCount do
			Flood.sectorLevels[index] = math.min(ctx.config.Water.MaxLevel, Flood.sectorLevels[index] + amount)
		end
	end
	Flood.level = math.min(ctx.config.Water.MaxLevel, Flood.level + (amount * 0.6))
	Flood.applyVolumes()
end

function Flood.applyVolumes()
	local wave = math.sin(os.clock() * (math.pi * 2 / ctx.config.Water.Wave.Period)) * ctx.config.Water.Wave.Amplitude
	for index = 1, ctx.config.Water.SectorCount do
		local level = (Flood.sectorLevels[index] or Flood.level) + wave * (index == 1 and 1.0 or 0.6)
		ctx.world.setWaterLevel(index, level)
	end
	ctx.world.setSurfaceMarker(Flood.level + wave)
end

-- Pump mitigation: a powered pump suppresses the rise and slowly drains the low sector.
local function pumpMitigation(dt: number)
	if not ctx.power.isPowered("Pump") then
		return 1, 0
	end
	local drain = 0
	if Flood.level > 1.5 then
		drain = ctx.config.Water.PumpDrainPerSecond * dt
	end
	return (1 - ctx.config.Water.PumpDraw), drain
end

function Flood.update(dt: number)
	if Flood.paused then
		Flood.applyVolumes()
		return
	end
	local suppression, drain = pumpMitigation(dt)
	local rise = Flood.riseRate * suppression * dt
	for index = 1, ctx.config.Water.SectorCount do
		local next = (Flood.sectorLevels[index] or 0) + rise - drain - drain * 0.5
		Flood.sectorLevels[index] = math.clamp(next, 0, ctx.config.Water.MaxLevel)
	end
	Flood.level = math.clamp(Flood.level + rise - drain, 0, ctx.config.Water.MaxLevel)

	if os.clock() >= Flood.nextSurgeAt and (Flood.phase == "Rising" or Flood.phase == "Surge") then
		Flood.nextSurgeAt = os.clock() + (Flood.phase == "Surge" and 16 or 26)
		local sector = math.random(1, ctx.config.Water.SectorCount)
		local amount = Flood.phase == "Surge" and 0.85 or 0.4
		Flood.surge(amount, sector)
		local label = ({ "the canal front", "the mid streets", "the north flats" })[sector]
		ctx.notify(`Storm surge: water jumps in {label}.`, "warn")
	end

	Flood.applyVolumes()
	Flood.updateCharacters(dt)
end

local function characterOxygen(player: Player): { value: number, submerged: boolean }
	local entry = Flood.oxygen[player]
	if not entry then
		entry = { value = ctx.config.Water.OxygenSeconds, submerged = false }
		Flood.oxygen[player] = entry
	end
	return entry
end

function Flood.updateCharacters(dt: number)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not (root and humanoid and humanoid.Health > 0) then
			Flood.oxygen[player] = nil
			continue
		end
		local rootPart = root :: BasePart
		local depth = Flood.depthAt(rootPart.Position)
		local headDepth = Flood.depthAt(rootPart.Position + Vector3.new(0, 1.5, 0))
		local entry = characterOxygen(player)

		if depth > 0 then
			-- Buoyancy keeps the body at the surface; sprint drag makes water a real cost.
			local target = math.max(0.4, depth - 1.1)
			local lift = math.clamp(target * 34, 0, 42)
			rootPart.AssemblyLinearVelocity = Vector3.new(
				rootPart.AssemblyLinearVelocity.X,
				math.clamp(rootPart.AssemblyLinearVelocity.Y * 0.85 + lift * dt * 6, -30, 24),
				rootPart.AssemblyLinearVelocity.Z
			)
			local baseSpeed = ctx.playerWalkSpeed(player)
			local speed = baseSpeed * math.clamp(1 - depth * 0.16, 0.35, 1) * ctx.config.Player.WaterDragMultiplier + 4
			humanoid.WalkSpeed = math.max(4, speed)
			humanoid.JumpPower = if depth > 3 then 0 else humanoid.JumpPower
			humanoid.UseJumpPower = true
			if depth > 0.35 and os.clock() - (Flood.lastNotifyAt or 0) > 1.5 then
				Flood.lastNotifyAt = os.clock()
				Util.playSound(rootPart, ctx.config.Fx.PingSounds.Splash, 0.35, 1.1)
			end
		else
			humanoid.WalkSpeed = ctx.playerWalkSpeed(player)
		end

		if headDepth > 0.15 then
			entry.submerged = true
			entry.value -= dt
			if entry.value <= 0 then
				entry.value = 0
				humanoid:TakeDamage(ctx.config.Water.DrownDamagePerSecond * dt)
			end
			if math.floor(entry.value) == math.floor(entry.value + dt) and entry.value < 5.5 and entry.value > 4.4 then
				ctx.notifyPlayer(player, "You are under water. Get your head up.", "bad")
			end
		else
			entry.submerged = false
			entry.value = math.min(ctx.config.Water.OxygenSeconds, entry.value + ctx.config.Water.OxygenRecoverPerSecond * dt)
		end
	end
end

function Flood.oxygenFor(player: Player): { value: number, submerged: boolean }
	return characterOxygen(player)
end

function Flood.snapshot()
	local sectorLevels = {}
	for index = 1, ctx.config.Water.SectorCount do
		sectorLevels[index] = Util.round(Flood.sectorLevels[index] or 0, 2)
	end
	return {
		level = Util.round(Flood.level, 2),
		sectorLevels = sectorLevels,
		riseRate = Util.round(Flood.riseRate, 4),
		phase = Flood.phase,
		pumped = ctx.power.isPowered("Pump"),
	}
end

function Flood.Init(context)
	ctx = context
	Flood.reset()
end

function Flood.Start(context)
	ctx = context
	RunService.Heartbeat:Connect(function(dt)
		if ctx.roundActive() or Flood.phase == "Lobby" then
			Flood.update(math.min(dt, 0.2))
		end
	end)
end

return Flood
