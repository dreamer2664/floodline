--!strict
-- ScoringService: translucent bookkeeping only — it collects counters, then grades the round.
-- Nothing here changes world state, which keeps the simulation deterministic and auditable.

local Players = game:GetService("Players")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Scoring = {}
Scoring.Name = "Scoring"

Scoring.entries = {} :: { [string]: any }
Scoring.teamBonus = 0
local ctx

local function entry(name: string)
	Scoring.entries[name] = Scoring.entries[name] or {
		rescues = 0,
		revives = 0,
		power = 0,
		hazards = 0,
		damageInWater = 0,
		score = 0,
	}
	return Scoring.entries[name]
end

function Scoring.add(player: Player, category: string, amount: number)
	local data = entry(player.Name)
	if data[category] == nil then
		data[category] = 0
	end
	data[category] += amount
end

function Scoring.reset()
	Scoring.entries = {}
	Scoring.teamBonus = 0
end

function Scoring.playerScore(player: Player): number
	local state = ctx.playerService.getState(player)
	return state and state.score or 0
end

function Scoring.grade(teamScore: number): string
	local thresholds = ctx.config.Scoring.GradeThresholds
	if teamScore >= thresholds.S then
		return "S"
	elseif teamScore >= thresholds.A then
		return "A"
	elseif teamScore >= thresholds.B then
		return "B"
	elseif teamScore >= thresholds.C then
		return "C"
	end
	return "D"
end

function Scoring.buildSummary(outcome: string, reason: string)
	local players = {}
	local teamScore = Scoring.teamBonus
	for _, player in ipairs(Players:GetPlayers()) do
		local state = ctx.playerService.getState(player)
		local score = state and state.score or 0
		local data = Scoring.entries[player.Name] or {}
		table.insert(players, {
			name = player.Name,
			score = score,
			recoveries = data.power or 0,
			revives = state and state.revives or 0,
			downs = state and state.deaths or 0,
			waterSeconds = state and Util.round(state.waterSeconds, 0) or 0,
			items = state and state.items or {},
		})
		teamScore += score
	end
	teamScore += ctx.rescue.rescuedCount * ctx.config.Scoring.PerSurvivor
	teamScore += ctx.rescue.rescuedCount * ctx.config.Scoring.TeamSurvivorBonus
	local elapsed = ctx.round.roundElapsed()
	local par = ctx.config.Scoring.TimeParPerPhase * ctx.config.Round.PhaseCount
	if elapsed < par then
		teamScore += math.floor((par - elapsed) * ctx.config.Scoring.TimeBonusPerSecond)
	end
	if ctx.power.consumers.Pump.powered and ctx.power.consumers.Lift.powered then
		teamScore += ctx.config.Scoring.PowerEfficiencyBonus
	end
	-- Route mastery is part of the score: an unused second route is a missed opportunity.
	local routesOpened = ctx.route and ctx.route.openedRoutes() or {}
	if #routesOpened > 0 then
		teamScore += #routesOpened * 40
	end
	return {
		outcome = outcome,
		reason = reason,
		teamScore = teamScore,
		grade = Scoring.grade(teamScore),
		rescued = ctx.rescue.rescuedCount,
		required = ctx.rescue.requiredRescued(),
		lost = ctx.rescue.lostCount,
		dead = ctx.rescue.deadCount,
		recovered = ctx.rescue.recoveredCount,
		elapsed = Util.round(elapsed, 0),
		elapsedText = Util.formatTime(elapsed),
		players = players,
		waterLevel = Util.round(ctx.flood.level, 2),
		powerUsed = ctx.power.snapshot(),
		routes = routesOpened,
		upgrades = ctx.upgrade and ctx.upgrade.snapshot() or {},
		cutOpen = ctx.route and not ctx.route.cut.blocked or false,
		events = ctx.telemetry and ctx.telemetry.recent(24) or {},
		hazards = ctx.hazard and ctx.hazard.snapshot() or {},
	}
end

function Scoring.Init(context)
	ctx = context
end

return Scoring
