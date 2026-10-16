--!strict
-- CrewService: player roles (the crew classes).
--
-- Every player holds exactly one role. A role is a set of always-on passives plus one ability
-- with a long cooldown, so the interesting decision is who takes which job rather than when to
-- press a button. Passives are read by the other services through the accessors below; nothing
-- else in the codebase reads Config.Crew directly, so the numbers stay in one place and every
-- change here is visible to the headless harness.
--
-- Server-authoritative: roles are assigned on the server, abilities are spent on the server, and
-- the snapshot the client renders is built here.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Crew = {}
Crew.Name = "Crew"

Crew.roles = {} :: { [Player]: string }
Crew.abilities = {} :: { [Player]: { readyAt: number, used: number } }
Crew.buffs = {} :: { [Player]: { [string]: number } } -- buff kind -> expiry timestamp
Crew.dirty = true
Crew.lastUse = {} :: { [Player]: string }

local ctx

-- The player state lives in PlayerService; this service only reads it (downed checks, ability
-- gating) and never writes it.
local function state_(player: Player): any
	return ctx.playerService and ctx.playerService.getState(player) or nil
end

local function def(roleName: string?): any
	local config = ctx.config.Crew
	if not roleName then
		return config[config.Default]
	end
	return config[roleName] or config[config.Default]
end

Crew.def = def

function Crew.roleOf(player: Player): string
	local role = Crew.roles[player]
	if role and ctx.config.Crew[role] then
		return role
	end
	return ctx.config.Crew.Default
end

-- ===================== assignment =====================

function Crew.set(player: Player, roleName: string): (boolean, string?)
	local config = ctx.config.Crew
	if not config[roleName] or type(config[roleName]) ~= "table" then
		return false, "Unknown crew role."
	end
	if ctx.round and ctx.round.active() and ctx.round.state ~= "Results" and ctx.round.state ~= "Intermission" then
		return false, "Roles are locked once a round starts."
	end
	local previous = Crew.roles[player]
	Crew.roles[player] = roleName
	Crew.abilities[player] = Crew.abilities[player] or { readyAt = 0, used = 0 }
	Crew.dirty = true
	if previous ~= roleName then
		local label = config[roleName].Label
		ctx.notifyPlayer(player, `You are the {label} this round.`, "good")
		ctx.telemetry.note("crew", `{player.Name} -> {roleName}`)
	end
	return true
end

function Crew.ensure(player: Player): string
	local role = Crew.roles[player]
	if not role then
		role = ctx.config.Crew.Default
		Crew.roles[player] = role
		Crew.abilities[player] = { readyAt = 0, used = 0 }
		Crew.dirty = true
	end
	return role
end

-- ===================== passives =====================

local function number(role: string, field: string, fallback: number): number
	local entry = def(role)
	local value = entry and entry[field]
	if type(value) == "number" then
		return value
	end
	return fallback
end

function Crew.oxygenMultiplier(player: Player): number
	return number(Crew.roleOf(player), "OxygenMultiplier", 1)
end

function Crew.swimMultiplier(player: Player): number
	local base = number(Crew.roleOf(player), "SwimMultiplier", 1)
	if Crew.buffActive(player, "SecondWind") then
		base *= 1.35
	end
	return base
end

function Crew.carryBonus(player: Player): number
	return number(Crew.roleOf(player), "CarryBonus", 0)
end

function Crew.holdMultiplier(player: Player): number
	return number(Crew.roleOf(player), "HoldMultiplier", 1)
end

function Crew.breakerMultiplier(player: Player): number
	return number(Crew.roleOf(player), "BreakerMultiplier", 1)
end

function Crew.reviveMultiplier(player: Player): number
	return number(Crew.roleOf(player), "ReviveMultiplier", 1)
end

function Crew.crankMultiplier(player: Player): number
	local base = number(Crew.roleOf(player), "CrankMultiplier", 1)
	if Crew.buffActive(player, "RopeLine") then
		base *= 1.15
	end
	return base
end

-- Bleedout is slowed by the *closest* medic, not by the downed player's own role: a downed medic
-- cannot save themselves, and the rule reads better as "the medic standing over you".
function Crew.bleedoutMultiplier(position: Vector3?): number
	local best = 1
	local config = ctx.config.Crew
	for _, other in ipairs(Players:GetPlayers()) do
		local entry = state_(other)
		if entry and entry.downed then
			continue
		end
		if Crew.roleOf(other) ~= "Medic" then
			continue
		end
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			continue
		end
		local radius = config.Medic.AuraRadius
		if position and ((root :: BasePart).Position - position).Magnitude > radius then
			continue
		end
		best = math.max(best, number("Medic", "BleedoutMultiplier", 1))
	end
	return best
end

-- ===================== buffs =====================

function Crew.buffActive(player: Player, kind: string): boolean
	local entry = Crew.buffs[player]
	local until_ = entry and entry[kind]
	if not until_ then
		return false
	end
	if os.clock() >= until_ then
		entry[kind] = nil
		Crew.dirty = true
		return false
	end
	return true
end

function Crew.buff(player: Player, kind: string, duration: number)
	Crew.buffs[player] = Crew.buffs[player] or {}
	Crew.buffs[player][kind] = os.clock() + duration
	Crew.dirty = true
end

-- Rope Line: a moving speed aura around any rigger who has just spent the ability.
function Crew.speedMultiplierAt(position: Vector3): number
	local config = ctx.config.Crew
	local bonus = 1
	for _, other in ipairs(Players:GetPlayers()) do
		if not Crew.buffActive(other, "RopeLine") or Crew.roleOf(other) ~= "Rigger" then
			continue
		end
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			continue
		end
		if ((root :: BasePart).Position - position).Magnitude <= config.Rigger.Ability.Radius then
			bonus = math.max(bonus, config.Rigger.Ability.SpeedMultiplier)
		end
	end
	return bonus
end

-- ===================== abilities =====================

local function abilityOf(player: Player): any
	return def(Crew.roleOf(player)).Ability
end

function Crew.cooldownLeft(player: Player): number
	local entry = Crew.abilities[player] or { readyAt = 0, used = 0 }
	return math.max(0, math.ceil(entry.readyAt - os.clock()))
end

function Crew.abilityReady(player: Player): boolean
	return Crew.cooldownLeft(player) <= 0
end

-- The four abilities, in one place. Each returns (ok, message).
local ABILITIES: { [string]: (Player) -> (boolean, string?) } = {}

ABILITIES.SecondWind = function(player: Player): (boolean, string?)
	local config = ctx.config.Crew.Diver.Ability
	local refilled = 0
	for _, other in ipairs(Players:GetPlayers()) do
		ctx.flood.refillOxygen(other)
		refilled += 1
	end
	Crew.buff(player, "SecondWind", config.Duration)
	ctx.notify(`{player.Name} takes a second wind — the crew's air is refilled.`, "good")
	ctx.addScore(player, 40, "second wind")
	return true, `air refilled for {refilled} diver(s)`
end

ABILITIES.SocketJumper = function(player: Player): (boolean, string?)
	local cleared = ctx.power.clearTrips(nil)
	ctx.addScore(player, 25 * cleared, "socket jumper")
	if cleared == 0 then
		ctx.notifyPlayer(player, "No breakers were tripped — the grid is clean.", "info")
	else
		ctx.notify(`{player.Name} jumped the breakers: {cleared} socket(s) reset.`, "good")
	end
	return true, `{cleared} breaker(s) reset`
end

ABILITIES.Triage = function(player: Player): (boolean, string?)
	local config = ctx.config.Crew.Medic.Ability
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local origin = root and (root :: BasePart).Position or nil
	local healed, calmed = 0, 0
	for _, other in ipairs(Players:GetPlayers()) do
		local otherCharacter = other.Character
		local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
		local humanoid = otherCharacter and otherCharacter:FindFirstChildOfClass("Humanoid")
		if not (otherRoot and humanoid) then
			continue
		end
		if origin and (((otherRoot :: BasePart).Position - origin).Magnitude > config.Radius) then
			continue
		end
		if humanoid.Health > 0 then
			humanoid.Health = math.min(ctx.config.Player.MaxHealth, math.max(humanoid.Health, ctx.config.Player.MaxHealth))
			healed += 1
		end
	end
	-- Survivors in the same radius stop panicking and get first aid.
	for _, survivor in ipairs(ctx.rescue.order) do
		if survivor.state == "Rescued" or survivor.state == "Dead" or survivor.state == "Lost" then
			continue
		end
		if origin and ((survivor.position - origin).Magnitude > config.Radius) then
			continue
		end
		survivor.panic = 0
		survivor.health = math.min(100, survivor.health + 25)
		calmed += 1
	end
	ctx.notify(`{player.Name} runs triage: {healed} teammate(s), {calmed} survivor(s).`, "good")
	ctx.addScore(player, 30 + 10 * calmed, "triage")
	return true, `{healed} healed, {calmed} calmed`
end

ABILITIES.RopeLine = function(player: Player): (boolean, string?)
	local config = ctx.config.Crew.Rigger.Ability
	Crew.buff(player, "RopeLine", config.Duration)
	ctx.notify(`{player.Name} rigs a rope line — the crew moves faster nearby.`, "good")
	ctx.addScore(player, 30, "rope line")
	return true, `line rigged for {config.Duration}s`
end

function Crew.useAbility(player: Player): (boolean, string?)
	if not ctx.roundActive() then
		return false, "The round has not started."
	end
	local entry = state_(player)
	if entry and entry.downed then
		return false, "You are down — wait for a revive."
	end
	local role = Crew.roleOf(player)
	local ability = abilityOf(player)
	if not ability then
		return false, "This role has no ability."
	end
	local left = Crew.cooldownLeft(player)
	if left > 0 then
		return false, `{ability.Label} is still recharging ({left}s).`
	end
	local handler = ABILITIES[ability.Id]
	if not handler then
		return false, "This ability is not wired up."
	end
	local ok, message = handler(player)
	if not ok then
		return false, message
	end
	Crew.abilities[player] = { readyAt = os.clock() + ability.Cooldown, used = ((Crew.abilities[player] or {}).used or 0) + 1 }
	Crew.lastUse[player] = ability.Id
	Crew.dirty = true
	ctx.telemetry.note("crew", `{player.Name} used {ability.Label} ({message or "ok"})`)
	return true, message
end

-- ===================== lifecycle =====================

function Crew.snapshot(): any
	local config = ctx.config.Crew
	local rows = {}
	-- Deterministic order: Players:GetPlayers(), so the client list never reshuffles.
	for _, player in ipairs(Players:GetPlayers()) do
		local role = Crew.ensure(player)
		local ability = def(role).Ability
		local entry = Crew.abilities[player] or { readyAt = 0, used = 0 }
		rows[player.Name] = {
			role = role,
			label = config[role].Label,
			blurb = config[role].Blurb,
			ability = ability.Label,
			abilityDesc = ability.Desc,
			cooldown = ability.Cooldown,
			readyIn = Crew.cooldownLeft(player),
			uses = entry.used,
		}
	end
	return {
		roles = config.Order,
		labels = (function()
			local out = {}
			for _, key in ipairs(config.Order) do
				out[key] = { label = config[key].Label, blurb = config[key].Blurb, ability = config[key].Ability.Label, desc = config[key].Ability.Desc }
			end
			return out
		end)(),
		players = rows,
	}
end

function Crew.pushSnapshot()
	Crew.dirty = false
	ctx.remotes.CrewSync:FireAllClients(Crew.snapshot())
end

function Crew.reset()
	-- Roles survive a round reset: they are a player preference, not round state. Departed players
	-- are dropped so the table cannot grow forever.
	local keep = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local role = Crew.roles[player]
		if role then
			keep[player] = role
		end
	end
	Crew.roles = keep
	Crew.abilities = {}
	Crew.buffs = {}
	for player in pairs(Crew.roles) do
		Crew.abilities[player] = { readyAt = 0, used = 0 }
	end
	Crew.dirty = true
end

function Crew.onPlayerAdded(player: Player)
	Crew.ensure(player)
	Crew.dirty = true
end

function Crew.onPlayerRemoving(player: Player)
	Crew.roles[player] = nil
	Crew.abilities[player] = nil
	Crew.buffs[player] = nil
	Crew.dirty = true
end

function Crew.update(dt: number)
	for player, entry in pairs(Crew.buffs) do
		for kind, until_ in pairs(entry) do
			if os.clock() >= until_ then
				entry[kind] = nil
				Crew.dirty = true
			end
		end
	end
	if Crew.dirty then
		Crew.pushSnapshot()
	end
end

function Crew.Init(context)
	ctx = context
	Players.PlayerAdded:Connect(function(player)
		Crew.onPlayerAdded(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		Crew.onPlayerRemoving(player)
	end)
end

function Crew.Start(context)
	ctx = context
	for _, player in ipairs(Players:GetPlayers()) do
		Crew.ensure(player)
	end
	RunService.Heartbeat:Connect(function(dt)
		if ctx.booted then
			Crew.update(math.min(dt, 0.25))
		end
	end)
end

return Crew
