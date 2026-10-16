--!strict
-- FLOODLINE: Last District — server bootstrap.
-- Owns the shared context, remote wiring, service lifecycle and every client request entry point.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
local Util = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Util"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Modules = script.Parent:WaitForChild("Modules")

local WorldService = require(Modules:WaitForChild("WorldService"))
local PowerService = require(Modules:WaitForChild("PowerService"))
local FloodService = require(Modules:WaitForChild("FloodService"))
local RescueService = require(Modules:WaitForChild("RescueService"))
local LiftService = require(Modules:WaitForChild("LiftService"))
local HazardService = require(Modules:WaitForChild("HazardService"))
local InteractService = require(Modules:WaitForChild("InteractService"))
local PlayerService = require(Modules:WaitForChild("PlayerService"))
local ObjectiveService = require(Modules:WaitForChild("ObjectiveService"))
local ScoringService = require(Modules:WaitForChild("ScoringService"))
local TelemetryService = require(Modules:WaitForChild("Telemetry"))
local RoundService = require(Modules:WaitForChild("RoundService"))
local DoorService = require(Modules:WaitForChild("DoorService"))
local RouteService = require(Modules:WaitForChild("RouteService"))
local UpgradeService = require(Modules:WaitForChild("UpgradeService"))
local CommsService = require(Modules:WaitForChild("CommsService"))
local SessionService = require(Modules:WaitForChild("SessionService"))

local remotes = Net.serverInit()

local worldFolder = Workspace:WaitForChild("World", 30) :: Model?
if not worldFolder then
	error("[FLOODLINE] Workspace.World not found. Rebuild the place with tools/build_game.luau.")
end

local carriedFolder = Instance.new("Folder")
carriedFolder.Name = "CarriedCells"
carriedFolder.Parent = Workspace

local ctx: any = {
	config = Config,
	util = Util,
	net = Net,
	remotes = remotes,
	worldFolder = worldFolder,
	carriedFolder = carriedFolder,
	booted = false,
	power = PowerService,
	flood = FloodService,
	rescue = RescueService,
	lift = LiftService,
	hazard = HazardService,
	interact = InteractService,
	playerService = PlayerService,
	objective = ObjectiveService,
	scoring = ScoringService,
	telemetry = TelemetryService,
	round = RoundService,
	doors = DoorService,
	route = RouteService,
	upgrade = UpgradeService,
	comms = CommsService,
	session = SessionService,
	world = WorldService,
}

-- ===================== shared helpers =====================

function ctx.log(message: string)
	print(message)
end

function ctx.playerCount(): number
	return #Players:GetPlayers()
end

function ctx.currentModifier(): string
	return SessionService.modifier
end

function ctx.scaling()
	return Config.scaling(ctx.playerCount(), SessionService.modifier)
end

function ctx.requestModifier(player: Player, modifierName: string)
	if RoundService.state ~= "Lobby" and RoundService.state ~= "Intermission" then
		ctx.notifyPlayer(player, "Difficulty is locked once a round starts.", "warn")
		return
	end
	if not SessionService.setModifier(modifierName) then
		ctx.notifyPlayer(player, "Unknown difficulty preset.", "warn")
		return
	end
	ctx.notify(`{player.Name} set the difficulty to {SessionService.modifier}.`, "info")
	ctx.objective.markDirty()
end

function ctx.roundActive(): boolean
	return RoundService.active()
end

function ctx.waterLevel(): number
	return FloodService.level
end

function ctx.playerWalkSpeed(player: Player): number
	return PlayerService.walkSpeed(player)
end

-- Geometry is authored inside landmark models, so a plain FindFirstChild is not enough.
-- This lookup searches descendants once and caches the hit.
local worldCache: { [string]: Instance } = {}

function ctx.findWorld(name: string): Instance?
	local cached = worldCache[name]
	if cached and cached.Parent then
		return cached
	end
	local found = worldFolder:FindFirstChild(name)
	if not found then
		for _, descendant in ipairs(worldFolder:GetDescendants()) do
			if descendant.Name == name then
				found = descendant
				break
			end
		end
	end
	if found then
		worldCache[name] = found
	end
	return found
end

function ctx.padPart(): BasePart?
	local pad = ctx.findWorld("ExtractionPad")
	return (pad and pad:IsA("BasePart")) and pad or nil
end

function ctx.notify(message: string, tone: string?)
	RoundService.notifyAll(message, tone)
end

function ctx.notifyPlayer(player: Player, message: string, tone: string?)
	remotes.Notification:FireClient(player, { text = message, tone = tone or "info", personal = true })
end

function ctx.sendPlayerEvent(player: Player, kind: string, data: any?)
	remotes.PlayerEvent:FireClient(player, kind, data)
end

function ctx.addScore(player: Player, amount: number, reason: string?)
	PlayerService.addScore(player, amount, reason)
end

function ctx.hasItem(player: Player, itemType: string): boolean
	return PlayerService.hasItem(player, itemType)
end

function ctx.consumeItem(player: Player, itemType: string): boolean
	return PlayerService.consumeItem(player, itemType)
end

-- Round-level hooks called by the simulation services.
function ctx.onConsumerPowered(name: string)
	RoundService.onConsumerPowered(name)
end

function ctx.onConsumerLost(name: string)
	RoundService.onConsumerLost(name)
end

function ctx.onCellDestroyed(cellId: string)
	RoundService.onCellDestroyed(cellId)
end

function ctx.onRouteOpened(name: string)
	RoundService.onRouteOpened(name)
	ObjectiveService.markDirty()
end

function ctx.onSurvivorRescued(survivor, how: string, bonus: number)
	RoundService.onSurvivorRescued(survivor, how, bonus)
end

-- ===================== lifecycle =====================

local services = {
	{ name = "World", service = WorldService },
	{ name = "Upgrade", service = UpgradeService },
	{ name = "Power", service = PowerService },
	{ name = "Flood", service = FloodService },
	{ name = "Rescue", service = RescueService },
	{ name = "Lift", service = LiftService },
	{ name = "Route", service = RouteService },
	{ name = "Hazard", service = HazardService },
	{ name = "Interact", service = InteractService },
	{ name = "Player", service = PlayerService },
	{ name = "Objective", service = ObjectiveService },
	{ name = "Scoring", service = ScoringService },
	{ name = "Telemetry", service = TelemetryService },
	{ name = "Door", service = DoorService },
	{ name = "Comms", service = CommsService },
	{ name = "Session", service = SessionService },
	{ name = "Round", service = RoundService },
}

for _, entry in ipairs(services) do
	if entry.service.Init then
		entry.service.Init(ctx)
	end
end

for _, entry in ipairs(services) do
	if entry.service.Start then
		entry.service.Start(ctx)
	end
end

ctx.booted = true
ctx.log(`[FLOODLINE] boot complete — version {Config.Game.Version}, max players {Config.Game.MaxPlayers}`)
ctx.telemetry.note("boot", `server boot version {Config.Game.Version}`)

-- ===================== remotes =====================

remotes.RequestStart.OnServerEvent:Connect(function(player: Player)
	RoundService.requestStart(player)
end)

remotes.RequestRematch.OnServerEvent:Connect(function(player: Player)
	RoundService.requestRematch(player)
end)

remotes.RequestSprint.OnServerEvent:Connect(function(player: Player, sprinting: boolean)
	local state = PlayerService.getState(player)
	if state then
		state.sprinting = sprinting == true
	end
end)

remotes.RequestDrop.OnServerEvent:Connect(function(player: Player)
	local cell = PowerService.cellByHolder(player)
	if cell then
		PowerService.drop(player)
		PlayerService.setCarrying(player, false)
		ctx.notifyPlayer(player, "Cell set down.", "info")
		return
	end
	if not RescueService.dropCarried(player) then
		ctx.notifyPlayer(player, "Nothing to drop.", "warn")
	end
end)

remotes.RequestLiftCall.OnServerEvent:Connect(function(player: Player)
	if not RoundService.active() then
		ctx.notifyPlayer(player, "Round has not started.", "warn")
		return
	end
	local ok, reason = LiftService.call(player)
	if not ok then
		ctx.notifyPlayer(player, reason or "Lift unavailable.", "warn")
	end
end)

remotes.RequestRevive.OnServerEvent:Connect(function(player: Player, targetName: string)
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Name == targetName or (other == player) then
			PlayerService.revivePlayer(other, player)
			return
		end
	end
end)

remotes.RequestInteract.OnServerEvent:Connect(function(player: Player, action: string, payload: any)
	if action == "lead" and type(payload) == "string" then
		local ok, reason = RescueService.lead(player, payload)
		if not ok then
			ctx.notifyPlayer(player, reason or "Cannot lead them.", "warn")
		end
	elseif action == "revive" and type(payload) == "string" then
		local ok, reason = RescueService.revive(player, payload)
		if not ok then
			ctx.notifyPlayer(player, reason or "Cannot revive.", "warn")
		end
	elseif action == "carry" and type(payload) == "string" then
		local ok, reason = RescueService.carry(player, payload)
		if not ok then
			ctx.notifyPlayer(player, reason or "Cannot carry them.", "warn")
		else
			PlayerService.setCarrying(player, true)
		end
	elseif action == "pickup" and type(payload) == "string" then
		local ok, reason = PowerService.pickup(player, payload)
		if not ok then
			ctx.notifyPlayer(player, reason or "Cannot pick that up.", "warn")
		else
			PlayerService.setCarrying(player, true)
		end
	elseif action == "socket" and type(payload) == "string" then
		local holding = PowerService.cellByHolder(player) ~= nil
		local socket = PowerService.sockets[payload]
		local ok, reason
		if socket and socket.isDock then
			ok, reason = InteractService.actions.Charger(player, socket.part)
		elseif holding then
			ok, reason = PowerService.insert(player, payload)
			if ok then
				PlayerService.setCarrying(player, false)
			end
		else
			ok, reason = PowerService.eject(player, payload)
			if ok then
				PlayerService.setCarrying(player, true)
			end
		end
		if not ok then
			ctx.notifyPlayer(player, reason or "Cannot use that socket.", "warn")
		end
	elseif action == "lift" then
		local ok, reason = LiftService.load(player)
		if not ok then
			ctx.notifyPlayer(player, reason or "Lift cannot load.", "warn")
		end
	end
end)

remotes.RequestPing.OnServerEvent:Connect(function(player: Player, pingType: string, position: Vector3)
	ctx.comms.ping(player, pingType, position)
end)

remotes.RequestModifier.OnServerEvent:Connect(function(player: Player, modifierName: string)
	ctx.requestModifier(player, modifierName)
end)

remotes.RequestUpgrade.OnServerEvent:Connect(function(player: Player, upgradeId: string)
	if type(upgradeId) ~= "string" then
		return
	end
	local ok, reason = UpgradeService.purchase(player, upgradeId)
	if not ok and reason then
		ctx.notifyPlayer(player, reason, "warn")
	end
end)

remotes.ReportPosition.OnServerEvent:Connect(function(player: Player, position: Vector3)
	local state = PlayerService.getState(player)
	if state then
		state.lastPosition = position
	end
end)

remotes.GetSnapshot.OnServerInvoke = function(player: Player)
	ObjectiveService.rebuild(player)
	return {
		round = RoundService.snapshot(),
		water = FloodService.snapshot(),
		power = PowerService.snapshot(),
		survivors = RescueService.snapshot(),
		lift = LiftService.snapshot(),
		route = RouteService.snapshot(),
		upgrades = UpgradeService.snapshot(),
		objectives = ObjectiveService.list,
		scaling = ctx.scaling(),
		modifier = SessionService.snapshot(),
		session = SessionService.summary(),
		version = Config.Game.Version,
	}
end

-- Periodic broadcast of world state to every client (kept cheap: ~6 Hz).
local BROADCAST_INTERVAL = 1 / 6
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	if not ctx.booted then
		return
	end
	accumulator += dt
	if accumulator < BROADCAST_INTERVAL then
		return
	end
	accumulator = 0
	remotes.WaterSync:FireAllClients(FloodService.snapshot())
	remotes.PowerSync:FireAllClients(PowerService.snapshot())
	remotes.RoundEvent:FireAllClients("tick", RoundService.snapshot())
	PlayerService.pushSync()
end)

Players.PlayerAdded:Connect(function(player: Player)
	ctx.telemetry.note("player", `{player.Name} joined`)
	task.delay(3, function()
		if player.Parent then
			ObjectiveService.rebuild(player)
			ObjectiveService.push(player)
			remotes.RoundEvent:FireClient(player, "state", RoundService.snapshot())
		end
	end)
end)

ctx.log("[FLOODLINE] remotes connected")
