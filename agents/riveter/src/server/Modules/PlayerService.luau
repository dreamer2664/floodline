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
local ctx

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
		return ctx.config.Player.CarryWalkSpeed
	end
	if entry.sprinting and entry.stamina > 5 then
		return ctx.config.Player.SprintSpeed
	end
	return ctx.config.Player.WalkSpeed
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

function PlayerService.downed(player: Player, cause: string)
	local entry = state(player)
	if entry.downed then
		return
	end
	entry.downed = true
	entry.downedAt = os.clock()
	entry.reviveProgress = 0
	entry.deaths += 1
	PlayerService.downedCount += 1
	ctx.notify(`{player.Name} is down — {cause}.`, "bad")
	ctx.sendPlayerEvent(player, "downed", { cause = cause })
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
	entry.reviveProgress = 0
	entry.stamina = ctx.config.Player.StaminaMax
	entry.spectating = false
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = math.max(35, humanoid.MaxHealth * 0.5)
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
	local speed = 1
	if PlayerService.hasItem(player, "Medkit") then
		speed = 1.9
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
		entry.reviveProgress = 0
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
end

return PlayerService
