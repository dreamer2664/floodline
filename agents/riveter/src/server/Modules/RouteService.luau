--!strict
-- RouteService: the second extraction route.
--
-- The skybridge is a roof span between the apartment block and the relay platform. It is baked
-- in its extended position (so Studio shows real geometry), retracted at round start, and can be
-- walked back out two ways: the powered winch (one grid consumer, fast) or hand cranks at either
-- end (slow, no power at all). It is also the walking route survivors use when they are on the
-- wrong side of the district for the lift.
--
-- The service cut is the other half of the route system: a covered passage between the pump
-- house and the terminal that stays blocked until the conduit collapse is cleared.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Route = {}
Route.Name = "Route"

Route.skybridge = {
	extended = 0, -- 0 = tucked on the apartment roof, 1 = fully walked out
	target = 0,
	work = 0, -- crank seconds accumulated towards full extension
	cranking = {} :: { [Player]: number },
	lastCrankAt = 0,
	crossings = 0,
	viaPower = false,
}
Route.cut = {
	blocked = true,
	clearProgress = 0,
	clearedBy = nil :: Player?,
	clearedAt = nil :: number?,
}

Route.dirty = true
Route.deckParts = {} :: { { part: BasePart, extended: CFrame, tucked: CFrame } }
Route.railParts = {} :: { { part: BasePart, extended: CFrame, tucked: CFrame } }
Route.nearJoint = Vector3.new(0, 0, 0)
Route.farJoint = Vector3.new(0, 0, 0)
Route.cutZone = "ServiceCut"
Route.barricade = nil :: BasePart?
Route.log = {} :: { string }

local ctx
local MODEL_NAME = "Skybridge"

local function dot(a: Vector3, b: Vector3): number
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end

local function note(message: string)
	table.insert(Route.log, message)
	if #Route.log > 24 then
		table.remove(Route.log, 1)
	end
end

-- ===================== geometry discovery =====================

-- Deck segments are computed from the same two joints the build tool uses, so the authored
-- geometry and the runtime motion can never drift apart.
local function computeSegmentCFrames(nearJoint: Vector3, farJoint: Vector3, segments: number)
	local delta = farJoint - nearJoint
	local dir = delta.Unit
	local length = delta.Magnitude / segments
	local yaw = math.atan2(dir.X, dir.Z)
	local pitch = math.asin(math.clamp(dir.Y, -1, 1))
	local list = {}
	for index = 1, segments do
		local from = nearJoint + dir * ((index - 1) * length)
		local to = nearJoint + dir * (index * length)
		local extended = CFrame.new((from + to) * 0.5) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(-pitch, 0, 0)
		-- Retracted: the span folds back over the apartment roof, behind the near joint.
		local tuckedCenter = nearJoint + dir * (-(1.2 + (index - 1) * 2.6)) + Vector3.new(0, -0.35, 0)
		local tucked = CFrame.new(tuckedCenter) * CFrame.Angles(0, yaw, 0)
		table.insert(list, { extended = extended, tucked = tucked })
	end
	return list
end

local function adoptSpanMembers(): number
	local model = ctx.findWorld(MODEL_NAME)
	local cfg = ctx.config.Route.Skybridge
	Route.nearJoint = cfg.NearJoint
	Route.farJoint = cfg.FarJoint
	if not model then
		return 0
	end
	local segments = #cfg.DeckParts
	local frames = computeSegmentCFrames(cfg.NearJoint, cfg.FarJoint, segments)
	local adopted = 0
	Route.deckParts = {}
	Route.railParts = {}
	for index, name in ipairs(cfg.DeckParts) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			table.insert(Route.deckParts, { part = part, extended = frames[index].extended, tucked = frames[index].tucked })
			adopted += 1
		end
	end
	-- Rails, chords and braces ride with their deck segment. They are named
	-- BridgeRail_<letter><side>, so the letter at index 12 identifies the segment.
	local railed = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end
		local name = descendant.Name
		if string.sub(name, 1, 10) ~= "BridgeRail" and string.sub(name, 1, 11) ~= "BridgeChord" and string.sub(name, 1, 11) ~= "BridgeBrace" then
			continue
		end
		local letter = string.sub(name, 12, 12)
		for index, deckName in ipairs(cfg.DeckParts) do
			if string.sub(deckName, -1) == letter and frames[index] and not railed[descendant] then
				railed[descendant] = true
				local localOffset = frames[index].extended:ToObjectSpace(descendant.CFrame)
				table.insert(Route.railParts, {
					part = descendant,
					extended = descendant.CFrame,
					tucked = frames[index].tucked * localOffset,
				})
				adopted += 1
				break
			end
		end
	end
	return adopted
end

-- ===================== state =====================

-- How far a world point sits along the span (0 at the apartment joint, 1 at the tower joint).
function Route.spanParameter(position: Vector3): number
	local delta = Route.farJoint - Route.nearJoint
	local length = delta.Magnitude
	if length < 0.001 then
		return 0
	end
	return math.clamp(dot(position - Route.nearJoint, delta) / (length * length), 0, 1)
end

function Route.extension(): number
	return Route.skybridge.extended
end

function Route.isCrossable(): boolean
	return Route.skybridge.extended >= 0.92
end

-- True when the two points are on opposite halves of the span (a crossing is needed).
function Route.crossingNeeded(from: Vector3, to: Vector3): boolean
	local a = Route.spanParameter(from)
	local b = Route.spanParameter(to)
	if a < 0.5 and b > 0.5 then
		return true
	end
	if a > 0.5 and b < 0.5 then
		return true
	end
	return false
end

-- Intermediate waypoints for NPC escort across the roof span (nil when a straight line is fine).
function Route.waypointsFor(from: Vector3, to: Vector3): { Vector3 }?
	if not Route.isCrossable() then
		return nil
	end
	local delta = Route.farJoint - Route.nearJoint
	local dir = delta.Unit
	-- Only worth routing over the bridge when both ends are near its line, otherwise the walk
	-- down to street level is shorter anyway.
	local function nearSpan(position: Vector3): boolean
		local t = Route.spanParameter(position)
		local projected = Route.nearJoint + delta * t
		return (position - projected).Magnitude <= 18
	end
	if not (nearSpan(from) and nearSpan(to)) then
		return nil
	end
	if not Route.crossingNeeded(from, to) then
		return nil
	end
	local entry = Route.nearJoint + dir * 1.5
	local middle = Route.nearJoint + dir * (delta.Magnitude * 0.5)
	local exit = Route.farJoint - dir * 1.5
	local function lift(position: Vector3): Vector3
		return Vector3.new(position.X, position.Y + 2.5, position.Z)
	end
	return { lift(entry), lift(middle), lift(exit) }
end

-- ===================== controls =====================

local function applyExtension(progress: number)
	local eased = progress
	for index, entry in ipairs(Route.deckParts) do
		-- Segments walk out in order, so the span visibly builds itself across the gap.
		local spanStart = (index - 1) / #Route.deckParts
		local local_progress = math.clamp((eased - spanStart * 0.55) / 0.55, 0, 1)
		local cf = entry.tucked:Lerp(entry.extended, local_progress)
		entry.part.CFrame = cf
		entry.part.CanCollide = local_progress > 0.75
		entry.part.Transparency = 0
	end
	for _, entry in ipairs(Route.railParts) do
		local cf = entry.tucked:Lerp(entry.extended, eased)
		entry.part.CFrame = cf
		entry.part.CanCollide = eased > 0.85
	end
end

function Route.setExtension(progress: number)
	Route.skybridge.extended = math.clamp(progress, 0, 1)
	Route.skybridge.work = Route.skybridge.extended * ctx.config.Route.Skybridge.ExtendSeconds
	applyExtension(Route.skybridge.extended)
	Route.dirty = true
end

function Route.retract(instant: boolean?)
	if instant then
		Route.setExtension(0)
	else
		Route.skybridge.target = 0
	end
	Route.skybridge.viaPower = false
end

-- Crank interaction: every completed hold push counts as that many seconds of winch work.
-- An engineer in the party turns the crank noticeably faster.
function Route.crank(player: Player, seconds: number?): (boolean, string?)
	local cfg = ctx.config.Route.Skybridge
	local state = Route.skybridge
	if state.extended >= 0.999 then
		return false, "The span is already fully out."
	end
	local now = os.clock()
	if now - state.lastCrankAt < cfg.CrankCooldown and state.lastCrankAt > 0 then
		return false, "The crank is still settling. Keep turning."
	end
	state.lastCrankAt = now
	local work = seconds or cfg.CrankPromptHold
	-- The rigger's role passive turns the crank faster; the winch is the rigger's job.
	if ctx.crew then
		work *= ctx.crew.crankMultiplier(player)
	end
	local engineer = ctx.rescue.engineerNear(player, 26)
	if engineer then
		work *= ctx.config.Survivors.Roles.Engineer.HoldSpeedup
		ctx.notifyPlayer(player, `${engineer} braces the crank — it turns faster.`, "good")
	end
	state.cranking[player] = (state.cranking[player] or 0) + work
	state.work = math.min(cfg.ExtendSeconds, state.work + work)
	Route.setExtension(state.work / cfg.ExtendSeconds)
	if state.extended >= 0.999 and not state.viaPower then
		ctx.notify("Skybridge extended. The roof route to the relay tower is open.", "good")
		note("skybridge fully extended by hand")
		ctx.onRouteOpened("Skybridge")
	end
	return true, nil
end

function Route.setBarricade(blocked: boolean)
	Route.cut.blocked = blocked
	if Route.barricade then
		Route.barricade.CanCollide = blocked
		Route.barricade.Transparency = blocked and 0 or 1
		Route.barricade.CastShadow = blocked
		local rubble = Route.barricade.Parent and Route.barricade.Parent:FindFirstChild("TunnelBarricadeRubble")
		if rubble and rubble:IsA("BasePart") then
			rubble.Transparency = blocked and 0 or 1
			rubble.CanCollide = false
		end
		local prompt = Route.barricade:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Enabled = blocked
		end
	end
	Route.dirty = true
end

function Route.clearDebris(player: Player): (boolean, string?)
	local cfg = ctx.config.Route.Tunnel
	if not Route.cut.blocked then
		return false, "The passage is already open."
	end
	Route.cut.clearProgress += cfg.ClearSeconds / 3
	if Route.cut.clearProgress < cfg.ClearSeconds then
		ctx.notifyPlayer(player, `Clearing the collapse… ({math.floor((Route.cut.clearProgress / cfg.ClearSeconds) * 100)}%)`, "warn")
		Util.playSound(Route.barricade, ctx.config.Fx.PingSounds.Prompt, 0.4, 0.8)
		return true, nil
	end
	Route.cut.clearedBy = player
	Route.cut.clearedAt = os.clock()
	Route.setBarricade(false)
	ctx.notify("Service cut clear: the pump house now connects straight to the terminal.", "good")
	note(`cut cleared by {player.Name}`)
	ctx.addScore(player, cfg.ShortcutBonus, "opened the service cut")
	ctx.upgrade.award(20, `{player.Name} cleared the service cut`)
	ctx.onRouteOpened("ServiceCut")
	return true, nil
end

-- Called by RoundService/ObjectiveService when a route becomes usable.
function Route.openedRoutes(): { string }
	local list = {}
	if Route.isCrossable() then
		table.insert(list, "Skybridge")
	end
	if not Route.cut.blocked then
		table.insert(list, "ServiceCut")
	end
	return list
end

-- The fastest known way to the pad right now, used by the objectives text.
function Route.recommendedRoute(): string
	if ctx.power.isPowered("Lift") then
		return "Lift"
	end
	if Route.isCrossable() then
		return "Skybridge"
	end
	if not Route.cut.blocked then
		return "ServiceCut"
	end
	return "None"
end

function Route.update(dt: number)
	local cfg = ctx.config.Route.Skybridge
	local state = Route.skybridge
	-- Powered winch: the grid walks the span out on its own.
	if ctx.power.isPowered("Winch") and state.extended < 1 then
		if not state.viaPower then
			state.viaPower = true
			ctx.notify("Skybridge winch powered — the span is extending.", "good")
			note("winch engaged")
		end
		local rate = 1 / cfg.MotorSeconds
		state.work = math.min(cfg.ExtendSeconds, state.work + rate * cfg.ExtendSeconds * dt)
		Route.setExtension(state.work / cfg.ExtendSeconds)
		if state.extended >= 0.999 then
			ctx.notify("Skybridge locked out. Roof route open.", "good")
			ctx.onRouteOpened("Skybridge")
			state.viaPower = false
		end
	elseif not ctx.power.isPowered("Winch") and state.viaPower then
		state.viaPower = false
		ctx.notify("Winch power cut. The span holds where it is — crank it the rest of the way.", "warn")
	end
end

function Route.snapshot()
	local state = Route.skybridge
	local recommended = Route.recommendedRoute()
	return {
		extended = Util.round(state.extended * 100, 0),
		crossable = Route.isCrossable(),
		winchPowered = ctx.power.isPowered("Winch"),
		cutOpen = not Route.cut.blocked,
		cutProgress = Util.round((Route.cut.clearProgress / ctx.config.Route.Tunnel.ClearSeconds) * 100, 0),
		nearJoint = Route.nearJoint,
		farJoint = Route.farJoint,
		recommended = recommended,
		liftPowered = ctx.power.isPowered("Lift"),
	}
end

function Route.pushSnapshot()
	Route.dirty = false
	ctx.remotes.RouteSync:FireAllClients(Route.snapshot())
end

function Route.reset()
	Route.skybridge.work = 0
	Route.skybridge.cranking = {}
	Route.skybridge.lastCrankAt = 0
	Route.skybridge.viaPower = false
	Route.cut.clearProgress = 0
	Route.cut.clearedBy = nil
	Route.cut.clearedAt = nil
	Route.log = {}
	Route.setExtension(0)
	Route.setBarricade(true)
	note("round reset: span retracted, cut blocked")
	Route.dirty = true
end

function Route.Init(context)
	ctx = context
	local adopted = adoptSpanMembers()
	local barricade = ctx.findWorld(ctx.config.Route.Tunnel.Barricade)
	if barricade and barricade:IsA("BasePart") then
		Route.barricade = barricade
		local prompt = barricade:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.MaxActivationDistance = 14
			prompt.Triggered:Connect(function(player: Player)
				if not ctx.roundActive() then
					return
				end
				Route.clearDebris(player)
			end)
		end
	end
	for _, partName in ipairs({ ctx.config.Route.Skybridge.CrankNear, ctx.config.Route.Skybridge.CrankFar }) do
		local part = ctx.findWorld(partName)
		if part and part:IsA("BasePart") then
			local prompt = part:FindFirstChildOfClass("ProximityPrompt")
			if not prompt then
				prompt = Instance.new("ProximityPrompt")
				prompt.Parent = part
			end
			prompt.ActionText = "Crank Span"
			prompt.ObjectText = partName == ctx.config.Route.Skybridge.CrankNear and "Winch (roof side)" or "Winch (tower side)"
			prompt.HoldDuration = ctx.config.Route.Skybridge.CrankPromptHold
			prompt.MaxActivationDistance = 12
			prompt.Triggered:Connect(function(player: Player)
				if not ctx.roundActive() then
					return
				end
				local ok, reason = Route.crank(player)
				if not ok and reason then
					ctx.notifyPlayer(player, reason, "warn")
				end
			end)
		end
	end
	ctx.log(`[Route] adopted {adopted} skybridge members, barricade={Route.barricade ~= nil}`)
end

function Route.Start(context)
	ctx = context
	Route.reset()
	RunService.Heartbeat:Connect(function(dt)
		if ctx.roundActive() then
			Route.update(math.min(dt, 0.2))
		end
		if Route.dirty then
			Route.pushSnapshot()
		end
	end)
end

return Route
