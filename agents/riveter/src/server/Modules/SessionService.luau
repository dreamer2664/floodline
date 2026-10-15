--!strict
-- SessionService: server-lifetime progress and the lobby difficulty selection.
-- Nothing is persisted to disk: this is the running session's record, which is what a
-- drop-in co-op round needs (best grade, personal bests, per-round history).

local Players = game:GetService("Players")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Session = {}
Session.Name = "Session"

Session.modifier = "Standard"
Session.history = {} :: { any }
Session.bestScore = 0
Session.bestGrade = "-"
Session.bestRescued = 0
Session.rounds = 0
Session.wins = 0
Session.personalBest = {} :: { [string]: number }

local ctx
local GRADE_ORDER = { "D", "C", "B", "A", "S" }

local function gradeRank(grade: string): number
	for index, value in ipairs(GRADE_ORDER) do
		if value == grade then
			return index
		end
	end
	return 0
end

function Session.setModifier(name: string): boolean
	local found = false
	for _, key in ipairs(ctx.config.Modifiers.Order) do
		if key == name then
			found = true
			break
		end
	end
	if not found then
		return false
	end
	Session.modifier = name
	Session.pushModifier()
	return true
end

function Session.cycleModifier(direction: number): string
	local order = ctx.config.Modifiers.Order
	local index = 1
	for position, key in ipairs(order) do
		if key == Session.modifier then
			index = position
			break
		end
	end
	local nextIndex = ((index - 1 + direction) % #order) + 1
	Session.modifier = order[nextIndex]
	Session.pushModifier()
	return Session.modifier
end

function Session.pushModifier()
	local payload = Session.snapshot()
	ctx.remotes.ModifierSync:FireAllClients(payload)
	ctx.telemetry.note("modifier", `difficulty set to {Session.modifier}`)
end

-- Called by RoundService when a round resolves.
function Session.recordRound(summary: any)
	Session.rounds += 1
	if summary.outcome == "win" then
		Session.wins += 1
	end
	if (summary.teamScore or 0) > Session.bestScore then
		Session.bestScore = summary.teamScore
	end
	if gradeRank(summary.grade or "-") > gradeRank(Session.bestGrade) then
		Session.bestGrade = summary.grade or "-"
	end
	if (summary.rescued or 0) > Session.bestRescued then
		Session.bestRescued = summary.rescued
	end
	for _, entry in ipairs(summary.players or {}) do
		local previous = Session.personalBest[entry.name] or 0
		if (entry.score or 0) > previous then
			Session.personalBest[entry.name] = entry.score
		end
	end
	table.insert(Session.history, {
		index = Session.rounds,
		outcome = summary.outcome,
		reason = summary.reason,
		grade = summary.grade,
		teamScore = summary.teamScore,
		rescued = summary.rescued,
		required = summary.required,
		modifier = Session.modifier,
		elapsed = summary.elapsedText,
	})
	if #Session.history > 12 then
		table.remove(Session.history, 1)
	end
	local payload = Session.summary()
	ctx.remotes.SessionSync:FireAllClients(payload)
	return payload
end

function Session.snapshot()
	local mod = ctx.config.modifier(Session.modifier)
	return {
		modifier = Session.modifier,
		label = mod.Label,
		blurb = mod.Blurb,
		order = ctx.config.Modifiers.Order,
		riseMultiplier = mod.RiseMultiplier,
		scoreMultiplier = mod.ScoreMultiplier,
	}
end

function Session.summary()
	local personal = {}
	for name, score in pairs(Session.personalBest) do
		personal[name] = score
	end
	return {
		modifier = Session.modifier,
		rounds = Session.rounds,
		wins = Session.wins,
		bestScore = Session.bestScore,
		bestGrade = Session.bestGrade,
		bestRescued = Session.bestRescued,
		personalBest = personal,
		history = Session.history,
	}
end

function Session.reset()
	Session.modifier = "Standard"
	Session.history = {}
	Session.bestScore = 0
	Session.bestGrade = "-"
	Session.bestRescued = 0
	Session.rounds = 0
	Session.wins = 0
	Session.personalBest = {}
end

function Session.Init(context)
	ctx = context
end

function Session.Start(context)
	ctx = context
	ctx.log(`[Session] difficulty default {Session.modifier}`)
end

return Session
