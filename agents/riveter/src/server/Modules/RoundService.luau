--!strict
-- RoundService: the director. Owns the state machine, timers, scaling per player count,
-- win/fail evaluation, evacuation authorisation, results and rematch voting.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Round = {}
Round.Name = "Round"

Round.state = "Lobby"
Round.phaseIndex = 0
Round.phaseEndsAt = 0
Round.stateEndsAt = 0
Round.roundStartedAt = 0
Round.radioCalled = false
Round.extracted = false
Round.extractedPlayers = {} :: { [Player]: boolean }
Round.holdNotified = {} :: { [Player]: number }
Round.evacuationAt = 0
Round.evacuationApproachSeconds = 0
Round.rematchVotes = {} :: { [Player]: boolean }
Round.lastOutcome = nil :: any
Round.lobbyCountdown = nil :: number?
Round.paused = false
Round.stateLabel = "Waiting"
Round.poweredOnce = {} :: { [string]: boolean }

local ctx
local PHASES = { "Prep", "Phase 1", "Phase 2", "Phase 3", "Phase 4" }

function Round.roundElapsed(): number
	if Round.roundStartedAt == 0 then
		return 0
	end
	return os.clock() - Round.roundStartedAt
end

function Round.playerCount(): number
	return #Players:GetPlayers()
end

local function setState(state: string, duration: number?)
	Round.state = state
	Round.stateEndsAt = duration and (os.clock() + duration) or math.huge
	Round.stateLabel = state
	ctx.telemetry.note("state", `state -> {state}`)
	ctx.log(`[Round] state={state} duration={duration}`)
	ctx.remotes.RoundEvent:FireAllClients("state", {
		state = state,
		duration = duration,
		phaseIndex = Round.phaseIndex,
		scaling = ctx.scaling(),
	})
	ctx.objective.markDirty()
end

function Round.notifyAll(message: string, tone: string?)
	ctx.remotes.Notification:FireAllClients({ text = message, tone = tone or "info", t = os.clock() })
end

function Round.resetToLobby()
	Round.phaseIndex = 0
	-- The previous round's summary has been shown and voted on; a stale one must never leak into
	-- the next round's results screen or telemetry.
	Round.lastOutcome = nil
	Round.radioCalled = false
	Round.extracted = false
	Round.extractedPlayers = {}
	Round.holdNotified = {}
	Round.evacuationAt = 0
	Round.evacuationApproachSeconds = 0
	Round.rematchVotes = {}
	Round.roundStartedAt = 0
	Round.poweredOnce = {}
	ctx.flood.reset()
	ctx.flood.setPhase("Lobby")
	ctx.power.reset()
	ctx.rescue.reset()
	ctx.lift.reset()
	ctx.hazard.reset()
	ctx.playerService.reset()
	ctx.scoring.reset()
	ctx.telemetry.reset()
	ctx.route.reset()
	ctx.upgrade.reset()
	ctx.interact.reset()
	ctx.doors.reset()
	ctx.outfall.reset()
	ctx.crew.reset()
	setState("Lobby", nil)
	Round.lobbyCountdown = nil
	ctx.notify("Lobby open. Step onto the terminal pad to start when ready.", "info")
end

local function beginPrep()
	Round.roundStartedAt = os.clock()
	Round.phaseIndex = 0
	Round.radioCalled = false
	Round.extracted = false
	Round.extractedPlayers = {}
	Round.holdNotified = {}
	Round.evacuationAt = 0
	Round.evacuationApproachSeconds = 0
	Round.rematchVotes = {}
	ctx.flood.reset()
	ctx.flood.setPhase("Prep")
	ctx.power.reset()
	ctx.rescue.reset()
	ctx.lift.reset()
	ctx.hazard.reset()
	ctx.scoring.reset()
	ctx.playerService.reset()
	ctx.route.reset()
	ctx.interact.reset()
	ctx.doors.reset()
	ctx.upgrade.reset()
	ctx.outfall.reset()
	ctx.crew.reset()
	local prep = ctx.scaling().PrepSeconds
	Round.phaseEndsAt = os.clock() + prep
	setState("Prep", prep)
	Round.notifyAll(`Evacuation window opens in {Util.formatClock(prep)}. Power the district, find the survivors.`, "warn")
	ctx.telemetry.note("round", "prep began")
end

local function beginRising()
	Round.phaseIndex = 1
	Round.phaseEndsAt = os.clock() + ctx.scaling().PhaseSeconds
	ctx.flood.setPhase("Rising")
	setState("Rising", ctx.scaling().PhaseSeconds)
	Round.notifyAll("The storm drain has failed. Water is coming up.", "bad")
	ctx.telemetry.note("round", "rising began")
end

local function advancePhase()
	Round.phaseIndex += 1
	ctx.upgrade.onPhaseBegan(Round.phaseIndex)
	if Round.phaseIndex > ctx.config.Round.PhaseCount then
		beginSurge()
		return
	end
	Round.phaseEndsAt = os.clock() + ctx.scaling().PhaseSeconds
	Round.notifyAll(`Flood phase {Round.phaseIndex} of {ctx.config.Round.PhaseCount}.`, "warn")
	ctx.telemetry.note("flood", `phase {Round.phaseIndex} began`, { level = Util.round(ctx.flood.level, 2) })
end

local function beginSurge()
	Round.phaseEndsAt = os.clock() + ctx.scaling().SurgeSeconds
	ctx.flood.setPhase("Surge")
	setState("Surge", ctx.scaling().SurgeSeconds)
	Round.notifyAll("Surge: the district is going under. Extract whoever is left.", "bad")
	ctx.telemetry.note("flood", "surge began", { level = Util.round(ctx.flood.level, 2) })
end

-- Every road into the extraction phase goes through here, so the vehicle always has an arrival
-- time. (A surge that forces the evacuation used to leave the pad permanently inert: the round
-- could then only end when the window timed out.)
local function beginExtraction(reason: string)
	ctx.flood.setPhase("Extraction")
	setState("Extraction", ctx.config.Round.ExtractionSeconds)
	local approach = (Round.state == "Surge") and ctx.config.Round.EvacApproachSecondsStorm
		or ctx.config.Round.EvacApproachSeconds
	if Round.evacuationAt == 0 then
		Round.evacuationAt = os.clock() + approach
		Round.evacuationApproachSeconds = approach
	end
	Round.notifyAll(`Extraction authorised: {reason}. The evac vehicle is {approach}s out.`, "good")
	ctx.telemetry.note("round", `extraction authorised ({reason}), evac ETA {approach}s`)
end

local function finish(outcome: string, reason: string)
	if Round.state == "Results" or Round.state == "Intermission" then
		return
	end
	local summary = ctx.scoring.buildSummary(outcome, reason)
	Round.lastOutcome = summary
	ctx.telemetry.note("result", `{outcome}: {reason}`, {
		score = summary.teamScore,
		grade = summary.grade,
		rescued = summary.rescued,
		required = summary.required,
	})
	ctx.telemetry.flush(summary)
	ctx.session.recordRound(summary)
	summary.modifier = ctx.session.snapshot()
	summary.session = ctx.session.summary()
	ctx.remotes.RoundSummary:FireAllClients(summary)
	if outcome == "win" then
		Round.notifyAll(`District cleared. Grade {summary.grade} — {summary.teamScore} points.`, "good")
	elseif outcome == "partial" then
		Round.notifyAll(`Partial evacuation. Grade {summary.grade} — {summary.teamScore} points.`, "warn")
	else
		Round.notifyAll(`Round failed: {reason}.`, "bad")
	end
	setState("Results", ctx.config.Round.ResultsSeconds)
	Round.phaseEndsAt = math.huge
end

function Round.callEvacuation(player: Player)
	if Round.radioCalled then
		return
	end
	Round.radioCalled = true
	ctx.addScore(player, 60, "evacuation call")
	ctx.telemetry.note("radio", `evacuation called by {player.Name}`)
	beginExtraction(`called by {player.Name}`)
	ctx.objective.markDirty()
end

-- Seconds until the vehicle is on the pad, or 0 once it is (used by the HUD and the objective).
function Round.evacEta(): number
	if not Round.radioCalled then
		return -1
	end
	if Round.evacuationAt == 0 then
		return 0
	end
	return math.max(0, math.ceil(Round.evacuationAt - os.clock()))
end

function Round.evacArrived(): boolean
	return Round.radioCalled and Round.evacuationAt ~= 0 and os.clock() >= Round.evacuationAt
end

function Round.evaluate(): boolean
	if Round.state == "Lobby" or Round.state == "Results" or Round.state == "Intermission" then
		return false
	end

	-- All survivors gone: nothing left to save.
	local alive = #ctx.rescue.alive()
	if alive == 0 and ctx.rescue.rescuedCount < ctx.rescue.requiredRescued() then
		finish("fail", "every survivor was lost")
		return true
	end

	-- Not enough salvageable survivors left to hit the target.
	if alive + ctx.rescue.rescuedCount < ctx.rescue.requiredRescued() then
		finish("fail", "not enough survivors can still be saved")
		return true
	end

	-- Everyone down in multiplayer ends the round.
	if Round.playerCount() > 1 then
		local downed = 0
		for _, player in ipairs(Players:GetPlayers()) do
			local state = ctx.playerService.getState(player)
			if state and state.downed then
				downed += 1
			end
		end
		if downed == Round.playerCount() then
			finish("fail", "the whole team was down at once")
			return true
		end
	end

	-- Success: required survivors rescued, radio called, everyone extracted (or time out).
	if Round.radioCalled and not Round.evacArrived() then
		return false
	end
	if Round.radioCalled and ctx.rescue.rescuedCount >= ctx.rescue.requiredRescued() then
		local alivePlayers = 0
		local extracted = 0
		for _, player in ipairs(Players:GetPlayers()) do
			local state = ctx.playerService.getState(player)
			if state and not state.downed then
				alivePlayers += 1
				if Round.extractedPlayers[player] then
					extracted += 1
				end
			end
		end
		if alivePlayers == 0 or extracted >= alivePlayers then
			finish("win", "team evacuated with the required survivors")
			return true
		end
	end

	local now = os.clock()
	if Round.state == "Extraction" and now >= Round.stateEndsAt then
		if ctx.rescue.rescuedCount >= ctx.rescue.requiredRescued() then
			finish("win", "extraction window closed with the quota met")
		elseif ctx.rescue.rescuedCount > 0 then
			finish("partial", "some survivors evacuated")
		else
			finish("fail", "the lift left empty")
		end
		return true
	end

	if ctx.flood.level >= ctx.config.Water.MaxLevel - 0.05 then
		if ctx.rescue.rescuedCount >= ctx.rescue.requiredRescued() then
			finish("partial", "the district drowned but the quota was met")
		else
			finish("fail", "the district drowned")
		end
		return true
	end

	if Round.phaseEndsAt ~= math.huge and now >= Round.phaseEndsAt then
		if Round.state == "Prep" then
			beginRising()
		elseif Round.state == "Rising" then
			if Round.phaseIndex >= ctx.config.Round.PhaseCount then
				beginSurge()
			else
				advancePhase()
			end
		elseif Round.state == "Surge" then
			-- Surge ends into a forced extraction push.
			if not Round.radioCalled then
				Round.radioCalled = true
				Round.notifyAll("The relay auto-broadcasts the evacuation call.", "warn")
			end
			beginExtraction("storm surge")
		end
		return false
	end
	return false
end

function Round.onRouteOpened(name: string)
	local labels = { Skybridge = "the roof skybridge", ServiceCut = "the service cut" }
	Round.notifyAll(`New route open: {labels[name] or name}.`, "good")
	ctx.telemetry.note("route", `{name} usable`)
end

function Round.onSurvivorRescued(survivor, how: string, traitBonus: number)
	ctx.scoring.teamBonus += traitBonus
	ctx.upgrade.onSurvivorRescued()
	ctx.telemetry.note("rescue", `{survivor.name} ({survivor.trait}) via {how}`, {
		rescued = ctx.rescue.rescuedCount,
		level = Util.round(ctx.flood.level, 2),
	})
	ctx.objective.markDirty()
	local leader = survivor.leader
	if leader then
		ctx.addScore(leader, ctx.config.Scoring.PerSurvivor + traitBonus, "survivor rescue")
	end
end

function Round.onConsumerPowered(name: string)
	ctx.telemetry.note("power", `{name} powered`)
	Round.poweredOnce = Round.poweredOnce or {}
	if not Round.poweredOnce[name] then
		Round.poweredOnce[name] = true
		ctx.upgrade.onFirstPower(name)
	end
	if name == "Lift" and not Round.radioCalled and ctx.rescue.rescuedCount >= ctx.rescue.requiredRescued() then
		Round.notifyAll("Quota met. Fetch the radio and call the evacuation.", "good")
	end
	ctx.objective.markDirty()
end

function Round.onConsumerLost(name: string)
	ctx.telemetry.note("power", `{name} lost power`)
	if name == "Pump" then
		Round.notifyAll("Pump offline — the water is rising unchecked.", "bad")
	end
	ctx.objective.markDirty()
end

function Round.onCellDestroyed(cellId: string)
	ctx.telemetry.note("power", `{cellId} shorted out`)
end

function Round.onPlayerLeft(player: Player)
	Round.extractedPlayers[player] = nil
	Round.rematchVotes[player] = nil
	if Round.state == "Results" then
		local votes = 0
		for _, voted in pairs(Round.rematchVotes) do
			if voted then
				votes += 1
			end
		end
		if votes > Round.playerCount() / 2 then
			Round.resetToLobby()
		end
	end
end

function Round.requestStart(player: Player)
	if Round.state ~= "Lobby" then
		ctx.notifyPlayer(player, "Round already underway.", "warn")
		return
	end
	ctx.telemetry.note("lobby", `{player.Name} started the round`)
	beginPrep()
end

function Round.requestRematch(player: Player)
	if Round.state ~= "Results" and Round.state ~= "Intermission" then
		return
	end
	Round.rematchVotes[player] = true
	local votes = 0
	for _, voted in pairs(Round.rematchVotes) do
		if voted then
			votes += 1
		end
	end
	ctx.notify(`{player.Name} voted to run it again ({votes}/{Round.playerCount()}).`, "info")
	if votes >= math.max(1, math.ceil(Round.playerCount() / 2)) then
		Round.resetToLobby()
	end
end

function Round.tickLobby()
	local count = Round.playerCount()
	if count == 0 then
		Round.lobbyCountdown = nil
		return
	end
	if not Round.lobbyCountdown then
		Round.lobbyCountdown = os.clock() + ctx.config.Game.LobbyAutoStartSeconds
		ctx.telemetry.note("lobby", `auto-start armed for {count} player(s)`)
		return
	end
	local remaining = Round.lobbyCountdown - os.clock()
	if remaining <= 0 then
		Round.lobbyCountdown = nil
		beginPrep()
	else
		Round.stateEndsAt = Round.lobbyCountdown
		Round.stateLabel = `Starting in {math.ceil(remaining)}s`
		if math.floor(remaining) ~= Round.lastAnnounce then
			Round.lastAnnounce = math.floor(remaining)
			if math.floor(remaining) <= 5 and math.floor(remaining) > 0 then
				Round.notifyAll(`Round starts in {math.floor(remaining)}…`, "info")
			end
		end
	end
end

function Round.tickExtraction()
	if Round.state ~= "Extraction" then
		return
	end
	local pad = ctx.padPart()
	if not pad then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 and not Round.extractedPlayers[player] then
			local distance = ((root :: BasePart).Position - pad.Position).Magnitude
			if distance <= 9 and not Round.evacArrived() then
				local eta = Round.evacEta()
				if not Round.holdNotified[player] or os.clock() - (Round.holdNotified[player] or 0) > 8 then
					Round.holdNotified[player] = os.clock()
					ctx.notifyPlayer(player, `Hold the pad — the evac vehicle is {eta}s out.`, "warn")
				end
			elseif distance <= 9 then
				Round.extractedPlayers[player] = true
				ctx.addScore(player, 50, "extracted")
				ctx.notifyPlayer(player, "You are on the extraction pad.", "good")
				ctx.telemetry.note("extract", `{player.Name} reached the pad`)
			end
		end
	end
end

function Round.update(dt: number)
	if Round.state == "Lobby" then
		Round.tickLobby()
	elseif Round.state == "Results" then
		if os.clock() >= Round.stateEndsAt then
			Round.rematchVotes = {}
			setState("Intermission", ctx.config.Game.IntermissionSeconds)
		end
	elseif Round.state == "Intermission" then
		if os.clock() >= Round.stateEndsAt then
			Round.resetToLobby()
		end
	else
		if Round.evacArrived() and Round.phaseEndsAt == math.huge then
			Round.phaseEndsAt = os.clock() + 45 -- last call to get on board
		end
		Round.tickExtraction()
		Round.evaluate()
	end
end

function Round.active(): boolean
	return Round.state ~= "Lobby"
end

function Round.snapshot()
	return {
		state = Round.state,
		label = Round.stateLabel,
		phaseIndex = Round.phaseIndex,
		timeLeft = Round.stateEndsAt ~= math.huge and math.max(0, Round.stateEndsAt - os.clock()) or nil,
		elapsed = Round.roundElapsed(),
		radioCalled = Round.radioCalled,
		evacEta = Round.evacEta(),
		evacArrived = Round.evacArrived(),
		extracted = Round.extracted,
		required = ctx.rescue.requiredRescued(),
		rescued = ctx.rescue.rescuedCount,
		players = Round.playerCount(),
		scaling = ctx.scaling(),
		salvage = math.floor(ctx.upgrade.salvage),
		route = ctx.route.snapshot(),
	}
end

function Round.Init(context)
	ctx = context
end

function Round.Start(context)
	ctx = context
	setState("Lobby", nil)
	Round.notifyAll("FLOODLINE: Last District — hold the district and get the survivors out.", "info")
	RunService.Heartbeat:Connect(function(dt)
		if ctx.booted then
			Round.update(math.min(dt, 0.25))
		end
	end)
end

return Round
