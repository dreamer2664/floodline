--!strict
-- PlayerService: characters, stamina/sprint, carry slows, inventory, downed+revive, respawn
-- penalties, per-player stats and leaderstats. Solo players get a gentler bleedout and an
-- automatic self-recovery so a single-player round is never a dead end.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local PlayerService = {}
PlayerService.Name = "Player"

export type PlayerState = {
	sprinting: boolean,
	stamina: number,
	carrying: boolean,
	items: { [string]: number },
	downed: boolean,
	downedAt: number?,
	bleedProgress: number,
	bleedouts: number,
	reviveProgress: number,
	revives: number,
	damageTaken: number,
	waterSeconds: number,
	rescuedBy: number,
	score: number,
	deaths: number,
	walkSpeedBase: number,
	lastPosition: Vector3,
	spectating: boolean,
}

PlayerService.states = {} :: { [Player]: PlayerState }
PlayerService.downedCount = 0
-- Whoever is being hauled by whom. Dragging is what turns "someone is down in the flood" from a
-- countdown into a job two people can actually finish.
PlayerService.drags = {} :: { [Player]: Player }
local ctx

-- Drag tuning. These live at the top of the file because walkSpeed (defined below) reads
-- DRAG_SPEED, and a local declared further down is simply not in scope there.
local DRAG_RANGE = 9          -- studs: you have to be standing over them to get a grip
local DRAG_SPEED = 0.55       -- hauling a body across a flooded street is slow work
local DRAG_OFFSET = 2.2       -- how far behind the carrier the casualty rides
-- Multiplier on the bleedout TIME, not the rate: heads up and out of the water buys 50% longer,
-- so a crew that commits to the haul gets a real window. (The first cut multiplied 0.6 and made
-- dragging bleed a player out 40% faster, which is exactly backwards.)
local DRAG_BLEED_STRETCH = 1.5

local function state(player: Player): PlayerState
	local entry = PlayerService.states[player]
	if not entry then
		entry = {
			sprinting = false,
			stamina = ctx.config.Player.StaminaMax,
			carrying = false,
			items = {},
			downed = false,
			downedAt = nil,
			dragging = nil,
			draggedBy = nil,
			bleedProgress = 0,
			bleedouts = 0,
			reviveProgress = 0,
			revives = 0,
			damageTaken = 0,
			waterSeconds = 0,
			rescuedBy = 0,
			score = 0,
			deaths = 0,
			walkSpeedBase = ctx.config.Player.WalkSpeed,
			lastPosition = Vector3.new(0, 0, 0),
			spectating = false,
		}
		PlayerService.states[player] = entry
	end
	return entry
end

PlayerService.state = state

function PlayerService.getState(player: Player): PlayerState?
	return PlayerService.states[player]
end

function PlayerService.walkSpeed(player: Player): number
	local entry = state(player)
	if entry.carrying then
		-- Rigger/Diver hauling passives: carrying is slow on purpose, but a role built around it
		-- should feel like it.
		local bonus = ctx.crew and ctx.crew.carryBonus(player) or 0
		local speed = ctx.config.Player.CarryWalkSpeed + bonus
		if ctx.crew then
			speed *= ctx.crew.speedMultiplierAt(entry.lastPosition)
		end
		return speed
	end
	if PlayerService.drags[player] then
		-- Hauling a body: slower than a cell, and the Rigger's carry passive applies to a person too.
		local haul = ctx.config.Player.CarryWalkSpeed * DRAG_SPEED
		local bonus = ctx.crew and ctx.crew.carryBonus(player) or 0
		local speed = math.max(5, haul + bonus)
		if ctx.crew then
			speed *= ctx.crew.speedMultiplierAt(entry.lastPosition)
		end
		return speed
	end
	if entry.sprinting and entry.stamina > 5 then
		return ctx.config.Player.SprintSpeed
	end
	local speed = ctx.config.Player.WalkSpeed
	if ctx.crew then
		speed *= ctx.crew.speedMultiplierAt(entry.lastPosition)
	end
	return speed
end

function PlayerService.addItem(player: Player, itemType: string)
	local entry = state(player)
	entry.items[itemType] = (entry.items[itemType] or 0) + 1
	ctx.notifyPlayer(player, `Picked up: {itemType}`, "good")
	ctx.power.markDirty()
end

function PlayerService.consumeItem(player: Player, itemType: string): boolean
	local entry = state(player)
	if (entry.items[itemType] or 0) <= 0 then
		return false
	end
	entry.items[itemType] -= 1
	return true
end

function PlayerService.hasItem(player: Player, itemType: string): boolean
	local entry = state(player)
	return (entry.items[itemType] or 0) > 0
end

function PlayerService.canPickUp(player: Player, itemType: string): boolean
	local entry = state(player)
	if entry.downed then
		return false
	end
	local total = 0
	for _, count in pairs(entry.items) do
		total += count
	end
	return total < 4
end

function PlayerService.setCarrying(player: Player, carrying: boolean)
	state(player).carrying = carrying
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = PlayerService.walkSpeed(player)
	end
end

function PlayerService.addScore(player: Player, amount: number, reason: string?)
	local entry = state(player)
	entry.score += amount
	local stats = player:FindFirstChild("leaderstats")
	if stats then
		local score = stats:FindFirstChild("Score")
		if score and score:IsA("IntValue") then
			score.Value = entry.score
		end
	end
	if reason then
		ctx.log(`[Score] {player.Name} +{amount} ({reason})`)
	end
end

local function dragPromptOn(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	return (root :: any):FindFirstChild("DragTeammate")
end

-- The prompt lives on the casualty, so a rescuer only ever sees "Drag" on somebody who is down.
local function attachDragPrompt(casualty: Player)
	local character = casualty.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	if (root :: any):FindFirstChild("DragTeammate") then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DragTeammate"
	prompt.ActionText = "Drag to safety"
	prompt.ObjectText = casualty.Name
	prompt.HoldDuration = 0.35
	prompt.MaxActivationDistance = DRAG_RANGE
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	prompt.Triggered:Connect(function(dragger: Player)
		local ok, reason = PlayerService.startDrag(dragger, casualty)
		if not ok and reason then
			ctx.notifyPlayer(dragger, reason, "warn")
		end
	end)
end

local function detachDragPrompt(casualty: Player)
	local prompt = dragPromptOn(casualty)
	if prompt then
		prompt:Destroy()
	end
end

function PlayerService.downed(player: Player, cause: string)
	local entry = state(player)
	if entry.downed then
		return
	end
	entry.downed = true
	entry.downedAt = os.clock()
	entry.bleedProgress = 0
	entry.reviveProgress = 0
	entry.deaths += 1
	PlayerService.downedCount += 1
	ctx.notify(`{player.Name} is down — {cause}.`, "bad")
	ctx.sendPlayerEvent(player, "downed", { cause = cause })
	attachDragPrompt(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.BreakJointsOnDeath = false
	end
	if ctx.playerCount() == 1 then
		-- Solo: give a self-recovery window instead of a hard wipe.
		local seconds = ctx.scaling().RespawnPenaltySeconds
		task.delay(seconds, function()
			if PlayerService.states[player] and state(player).downed then
				ctx.notify("Solo recovery: you drag yourself back to the safe zone.", "warn")
				PlayerService.revivePlayer(player, nil)
			end
		end)
	end
end

function PlayerService.revivePlayer(player: Player, byWhom: Player?)
	local entry = state(player)
	if not entry.downed then
		return false
	end
	entry.downed = false
	entry.downedAt = nil
	entry.bleedProgress = 0
	entry.reviveProgress = 0
	entry.stamina = ctx.config.Player.StaminaMax
	entry.spectating = false
	entry.dragging = nil
	entry.draggedBy = nil
	detachDragPrompt(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local field = ctx.upgrade and ctx.upgrade.has("FieldHospital")
		humanoid.Health = field and humanoid.MaxHealth or math.max(35, humanoid.MaxHealth * 0.5)
		humanoid.WalkSpeed = PlayerService.walkSpeed(player)
		humanoid.UseJumpPower = true
		humanoid.JumpPower = 50
	end
	local spawn = ctx.world.spawnLocation
	if character and spawn then
		character:PivotTo(CFrame.new(spawn.Position + Vector3.new(0, 4, 0)))
	end
	if byWhom then
		entry.revives += 1
		PlayerService.addScore(byWhom, 40, "teammate revive")
		ctx.notifyPlayer(byWhom, `You revived {player.Name}.`, "good")
	end
	ctx.notify(`{player.Name} is back up.`, "good")
	ctx.sendPlayerEvent(player, "revived", {})
	return true
end

-- A downed player who was never reached. They are hauled back to the safe zone and come back
-- with a penalty: the run continues, but the crew felt it.
function PlayerService.bleedOut(player: Player)
	local entry = state(player)
	if not entry.downed then
		return
	end
	entry.bleedouts += 1
	entry.bleedProgress = 0
	entry.downed = false
	entry.downedAt = nil
	entry.dragging = nil
	entry.draggedBy = nil
	detachDragPrompt(player)
	entry.reviveProgress = 0
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local spawn = ctx.world.spawnLocation or ctx.padPart and ctx.padPart()
	if humanoid then
		humanoid.Health = math.max(1, ctx.config.Player.BleedoutRespawnHealth)
		humanoid.WalkSpeed = PlayerService.walkSpeed(player)
		humanoid.UseJumpPower = true
		humanoid.JumpPower = 50
	end
	if character and spawn then
		character:PivotTo(CFrame.new((spawn :: BasePart).Position + Vector3.new(0, 4, 0)))
	end
	ctx.notify(`{player.Name} bled out and was dragged back to the safe zone.`, "bad")
	ctx.sendPlayerEvent(player, "bledout", {})
	ctx.telemetry.note("player", `{player.Name} bled out`)
	return true
end

function PlayerService.progressRevive(player: Player, target: Player, dt: number): boolean
	local targetState = state(target)
	if not targetState.downed then
		return false
	end
	local character = target.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local rescuerRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not (root and rescuerRoot) then
		return false
	end
	if ((root :: BasePart).Position - (rescuerRoot :: BasePart).Position).Magnitude > 9 then
		return false
	end
	local speed = ctx.upgrade and ctx.upgrade.reviveSpeed() or 1
	if ctx.crew then
		speed *= ctx.crew.reviveMultiplier(player)
	end
	if PlayerService.hasItem(player, "Medkit") then
		speed *= 1.9
	end
	targetState.reviveProgress += dt * speed
	if targetState.reviveProgress >= 4.5 then
		if PlayerService.hasItem(player, "Medkit") then
			PlayerService.consumeItem(player, "Medkit")
		end
		PlayerService.revivePlayer(target, player)
		return true
	end
	return false
end

function PlayerService.setupCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	if not humanoid then
		return
	end
	humanoid.MaxHealth = ctx.config.Player.MaxHealth
	humanoid.Health = ctx.config.Player.MaxHealth
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 50
	humanoid.WalkSpeed = PlayerService.walkSpeed(player)
	local entry = state(player)
	entry.downed = false
	entry.downedAt = nil
	entry.stamina = ctx.config.Player.StaminaMax
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		entry.lastPosition = (root :: BasePart).Position
	end
	humanoid.Died:Connect(function()
		if ctx.roundActive() then
			PlayerService.downed(player, "injuries")
		end
	end)
	humanoid.HealthChanged:Connect(function(health)
		if health < ctx.config.Player.MaxHealth then
			-- Damage bookkeeping for round stats.
		end
	end)
end

function PlayerService.onCharacterAdded(player: Player, character: Model)
	PlayerService.setupCharacter(player, character)
	ctx.sendPlayerEvent(player, "spawned", {})
end

-- ===================== dragging a downed teammate =====================

function PlayerService.carriedBy(player: Player): Player?
	return state(player).draggedBy
end

function PlayerService.dragging(player: Player): Player?
	return PlayerService.drags[player]
end

function PlayerService.startDrag(dragger: Player, casualty: Player): (boolean, string?)
	if dragger == casualty then
		return false, "You cannot drag yourself."
	end
	local draggerEntry = state(dragger)
	local casualtyEntry = state(casualty)
	if draggerEntry.downed then
		return false, "You are down."
	end
	if not casualtyEntry.downed then
		return false, `{casualty.Name} is on their feet.`
	end
	if draggerEntry.dragging then
		return false, `You are already dragging {draggerEntry.dragging.Name}.`
	end
	if casualtyEntry.draggedBy then
		return false, `{casualtyEntry.draggedBy.Name} already has {casualty.Name}.`
	end
	if draggerEntry.carrying then
		return false, "Set the cell down first - you need both hands."
	end
	local draggerCharacter = dragger.Character
	local casualtyCharacter = casualty.Character
	local draggerRoot = draggerCharacter and draggerCharacter:FindFirstChild("HumanoidRootPart")
	local casualtyRoot = casualtyCharacter and casualtyCharacter:FindFirstChild("HumanoidRootPart")
	if not (draggerRoot and casualtyRoot) then
		return false, "Nobody to grab."
	end
	local draggerPart = draggerRoot :: BasePart
	local casualtyPart = casualtyRoot :: BasePart
	local distance = (draggerPart.Position - casualtyPart.Position).Magnitude
	if distance > DRAG_RANGE then
		return false, "Get closer to them."
	end
	draggerEntry.dragging = casualty
	casualtyEntry.draggedBy = dragger
	PlayerService.drags[dragger] = casualty
	ctx.notify(`{dragger.Name} is hauling {casualty.Name} to safety.`, "info")
	ctx.sendPlayerEvent(dragger, "drag", { target = casualty.Name, started = true })
	return true, nil
end

function PlayerService.stopDrag(dragger: Player, reason: string?): boolean
	local casualty = PlayerService.drags[dragger]
	if not casualty then
		return false
	end
	PlayerService.drags[dragger] = nil
	state(dragger).dragging = nil
	state(casualty).draggedBy = nil
	-- Put the casualty down where the carrier stands rather than leaving them behind in mid-air.
	local draggerRoot = dragger.Character and dragger.Character:FindFirstChild("HumanoidRootPart")
	local casualtyRoot = casualty.Character and casualty.Character:FindFirstChild("HumanoidRootPart")
	if draggerRoot and casualtyRoot then
		local draggerPart = draggerRoot :: BasePart
		local casualtyPart = casualtyRoot :: BasePart
		local behind = draggerPart.CFrame * CFrame.new(0, 0, DRAG_OFFSET)
		casualtyPart.CFrame = CFrame.new(behind.Position)
		state(casualty).lastPosition = behind.Position
	end
	if reason then
		ctx.notifyPlayer(dragger, reason, "info")
	end
	return true
end

function PlayerService.update(dt: number)
	for _, player in ipairs(Players:GetPlayers()) do
		local entry = state(player)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")

		if entry.downed then
			if humanoid and humanoid.Health > 0 and root then
				humanoid.WalkSpeed = 0
				humanoid.JumpPower = 0
				-- Self-recovery countdown for solo players is handled at down time.
			end
			-- Ride along with whoever has hold of you.
			local hauler = entry.draggedBy
			local haulerRoot = hauler and hauler.Character and hauler.Character:FindFirstChild("HumanoidRootPart")
			if hauler and haulerRoot and root then
				local haulerPart = haulerRoot :: BasePart
				local rootPart = root :: BasePart
				local trail = haulerPart.CFrame * CFrame.new(0, 0, DRAG_OFFSET)
				rootPart.CFrame = CFrame.new(trail.Position)
				rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
				entry.lastPosition = trail.Position
			end
			-- Bleeding out. A medic standing over you stretches the clock; being hauled keeps your
			-- head above the water line, which is worth something but does not stop the bleeding.
			local bleedout = ctx.config.Player.DownedBleedoutSeconds
			if ctx.crew then
				bleedout *= ctx.crew.bleedoutMultiplier(entry.lastPosition)
			end
			if entry.draggedBy then
				bleedout *= DRAG_BLEED_STRETCH
			end
			entry.bleedProgress = (entry.bleedProgress or 0) + dt / bleedout
			if entry.bleedProgress >= 1 then
				PlayerService.bleedOut(player)
			end
			continue
		end

		if not (humanoid and root) then
			continue
		end

		-- Sprint stamina
		local moving = (root :: BasePart).AssemblyLinearVelocity.Magnitude > 1.5
		if entry.sprinting and moving and entry.stamina > 0 then
			entry.stamina = math.max(0, entry.stamina - ctx.config.Player.StaminaDrain * dt)
		else
			entry.stamina = math.min(ctx.config.Player.StaminaMax, entry.stamina + ctx.config.Player.StaminaRegen * dt)
		end

		-- Fall damage
		local velocity = (root :: BasePart).AssemblyLinearVelocity.Y
		if velocity < -55 then
			local damage = (-velocity - 55) * 0.55
			entry.damageTaken += damage
			humanoid:TakeDamage(damage)
		end

		-- Water exposure bookkeeping
		if ctx.flood.depthAt((root :: BasePart).Position) > 0.3 then
			entry.waterSeconds += dt
		end

		entry.lastPosition = (root :: BasePart).Position
		-- A carrier walks their casualty; the grip is lost if they are ever wrenched apart (a lift
		-- ride, a teleport, a dropped connection).
		local casualty = PlayerService.drags[player]
		if casualty then
			if not state(casualty).downed then
				PlayerService.stopDrag(player)
			else
				local casualtyRoot = casualty.Character and casualty.Character:FindFirstChild("HumanoidRootPart")
				if casualtyRoot then
					local gap = ((root :: BasePart).Position - (casualtyRoot :: BasePart).Position).Magnitude
					if gap > DRAG_RANGE + 4 then
						PlayerService.stopDrag(player, `{casualty.Name} slipped out of your grip.`)
					end
				end
			end
		end
		humanoid.WalkSpeed = PlayerService.walkSpeed(player)
	end
end

function PlayerService.pushSync()
	local payload = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local entry = state(player)
		payload[player.Name] = {
			stamina = Util.round(entry.stamina, 0),
			sprinting = entry.sprinting,
			carrying = entry.carrying,
			items = entry.items,
			downed = entry.downed,
			dragging = entry.dragging and entry.dragging.Name or nil,
			draggedBy = entry.draggedBy and entry.draggedBy.Name or nil,
			bleedProgress = Util.round(entry.bleedProgress or 0, 2),
			bleedouts = entry.bleedouts or 0,
			reviveProgress = Util.round(entry.reviveProgress, 2),
			score = entry.score,
			waterSeconds = Util.round(entry.waterSeconds, 0),
			oxygen = Util.round(ctx.flood.oxygenFor(player).value, 0),
			submerged = ctx.flood.oxygenFor(player).submerged,
		}
	end
	ctx.remotes.StateSync:FireAllClients(payload)
end

function PlayerService.reset()
	for _, player in ipairs(Players:GetPlayers()) do
		local entry = state(player)
		entry.downed = false
		entry.downedAt = nil
		entry.bleedProgress = 0
		entry.bleedouts = 0
		entry.reviveProgress = 0
		entry.dragging = nil
		entry.draggedBy = nil
		detachDragPrompt(player)
		entry.score = 0
		entry.deaths = 0
		entry.waterSeconds = 0
		entry.damageTaken = 0
		entry.items = {}
		entry.carrying = false
		entry.spectating = false
		entry.stamina = ctx.config.Player.StaminaMax
		local stats = player:FindFirstChild("leaderstats")
		if stats then
			local rescued = stats:FindFirstChild("Rescued")
			if rescued and rescued:IsA("IntValue") then
				rescued.Value = 0
			end
			local score = stats:FindFirstChild("Score")
			if score and score:IsA("IntValue") then
				score.Value = 0
			end
		end
		if player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = humanoid.MaxHealth
			end
		end
	end
end

function PlayerService.Init(context)
	ctx = context
end

function PlayerService.Start(context)
	ctx = context
	Players.PlayerAdded:Connect(function(player)
		local stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		stats.Parent = player
		local rescued = Instance.new("IntValue")
		rescued.Name = "Rescued"
		rescued.Parent = stats
		local score = Instance.new("IntValue")
		score.Name = "Score"
		score.Parent = stats
		player.CharacterAdded:Connect(function(character)
			PlayerService.onCharacterAdded(player, character)
		end)
		if player.Character then
			PlayerService.onCharacterAdded(player, player.Character)
		end
		PlayerService.states[player] = nil
		state(player)
		if ctx.round.state == "Lobby" then
			ctx.notifyPlayer(player, "Welcome to the Last District. The round starts shortly.", "good")
		else
			ctx.notifyPlayer(player, `Round in progress: {ctx.round.state}.`, "warn")
		end
		ctx.objective.markDirty()
	end)
	Players.PlayerRemoving:Connect(function(player)
		PlayerService.states[player] = nil
		ctx.rescue.release(player)
		ctx.rescue.dropCarried(player)
		ctx.round.onPlayerLeft(player)
		if ctx.playerCount() == 0 then
			ctx.round.resetToLobby()
		end
	end)
	-- Per-frame bookkeeping: sprint stamina, fall damage, water exposure and the downed bleedout
	-- clock. This used to be defined but never connected, so none of it ticked.
	RunService.Heartbeat:Connect(function(dt)
		if ctx.booted then
			PlayerService.update(math.min(dt, 0.25))
		end
	end)
end

return PlayerService
