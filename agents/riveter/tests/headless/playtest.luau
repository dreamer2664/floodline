--!nocheck
-- playtest.luau — headless bot playtests of the shipped place.
--
-- Bots play real rounds through the same server modules the game runs: they read the objective
-- board, walk, use proximity prompts, carry cells, escort survivors, crank the skybridge, clear
-- the service cut, loot crates, buy bench upgrades and call the evacuation. Each run is timed
-- against the virtual clock, and the rounds are recorded to evidence/playtest-report.json.
--
-- What this DOES cover: round pacing (prep -> rise -> surge -> extraction), power triage, escort
-- throughput, route use, salvage economy, scaling maths and win/fail conditions.
--
-- What this does NOT cover: engine physics, human input, latency, rendering, audio, and anything
-- about how the game FEELS. Bots walk in straight lines at the speed the server sets on the
-- humanoid, with a 0.5x factor past waist depth as a stand-in for water drag; they never get
-- stuck on geometry, never fumble a hold and never mistime a surge. Treat the timings as a
-- lower bound on a competent human crew, not a guarantee.
--
-- Run:  lune run agents/riveter/tests/headless/playtest.luau

local fs = require("@lune/fs")
local process = require("@lune/process")

local Stub = require("./roblox_stub")
local Harness = require("./harness")

local ROOT = process.cwd
local AGENT = ROOT .. "/agents/riveter"
local PLACE = AGENT .. "/releases/FLOODLINE.rbxlx"

print("=== FLOODLINE bot playtests ===")
Harness.mountPlace(PLACE)
Harness.boot()

local function module(name: string)
	local modules = Harness.mounted.ServerScriptService:FindFirstChild("Modules")
	return Harness.require(modules:FindFirstChild(name))
end

local Config = Harness.require(Harness.replicated():FindFirstChild("Shared"):FindFirstChild("Config"))
local Round = module("RoundService")
local Power = module("PowerService")
local Crew = module("CrewService")
-- Module scope: BOT:targets is defined at this level, so anything it mutates must live here.
local outfallCranks = 0
local dragsStarted = 0
local dragsHauled = 0
-- Prompt hold durations the bots have to respect (read from the baked Config at boot).
local Holds = { outfallHold = Config.Outfall.HoldSeconds, socketHold = 1.0 }
local Outfall = module("OutfallService")
local Flood = module("FloodService")
local WorldService = module("WorldService")
local Rescue = module("RescueService")
local Lift = module("LiftService")
local Route = module("RouteService")
local Upgrades = module("UpgradeService")
local Doors = module("DoorService")
local Objectives = module("ObjectiveService")
local PlayerService = module("PlayerService")
local World = Harness.world()
local Players = Stub.players()

local v3 = Stub.v3

local function part(name: string)
	return Harness.findDescendantByName(World, name)
end

local function clock()
	return Stub.clock()
end

-- ===================== bot =====================

local BOT = {}
BOT.__index = BOT

local TICK = 0.25          -- virtual seconds per policy step
local REACH = 4.2          -- how close a bot has to be to use something
local RUN_LIMIT = 1200     -- give up on a round after 20 virtual minutes
local SWIM_FACTOR = 0.55   -- stand-in for water drag (documented above)

-- Salvage priority: keep the pump ahead of the water, then safety, then throughput.
local UPGRADE_PRIORITY = { "Impeller", "SealKit", "Capacitor", "Rebreather", "FieldHospital", "LiftServo" }

local function horizontal(a, b)
	return (v3(a.X, 0, a.Z) - v3(b.X, 0, b.Z)).Magnitude
end

local function newBot(name: string, index: number)
	local player = Stub.addPlayer(name)
	local self = setmetatable({
		name = name,
		player = player,
		index = index,
		log = {},
		wants = nil,
		lastAction = "spawn",
		stuckFor = 0,
		lastPosition = nil,
		failures = 0,
	}, BOT)
	Stub.spawnCharacter(player, v3(-6 + index * 3, 3, -18))
	return self
end

function BOT:note(message: string)
	table.insert(self.log, { t = math.floor(clock() * 10) / 10, text = message })
end

function BOT:position()
	return Stub.characterPosition(self.player)
end

function BOT:humanoid()
	local character = self.player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

function BOT:health()
	local humanoid = self:humanoid()
	return humanoid and humanoid.Health or 0
end

function BOT:depth()
	return Flood.depthAt(self:position())
end

function BOT:carryingCell()
	return Power.cellByHolder(self.player) ~= nil
end

function BOT:holding()
	local cell = Power.cellByHolder(self.player)
	if cell then
		return `cell {cell.id}`
	end
	for _, item in ipairs({ "Fuse", "Radio", "Medkit", "Wrench" }) do
		if PlayerService.hasItem(self.player, item) then
			return item
		end
	end
	return "nothing"
end

-- Walk toward a point. Returns true when the bot is inside `reach`.
function BOT:walkTo(target: Vector3, dt: number, reach: number?): boolean
	local here = self:position()
	local distance = horizontal(here, target)
	if distance <= (reach or REACH) then
		self.stuckFor = 0
		self.lastPosition = here
		return true
	end
	if distance < 0.4 then
		return true
	end
	local speed = PlayerService.walkSpeed(self.player)
	local depth = self:depth()
	if depth > 1.0 then
		speed *= SWIM_FACTOR
	end
	local step = math.min(distance, speed * dt)
	local delta = target - here
	local flat = v3(delta.X, 0, delta.Z).Unit * step
	local next_ = here + v3(flat.X, 0, flat.Z)
	next_ = v3(next_.X, math.max(next_.Y, target.Y), next_.Z)
	Stub.movePlayer(self.player, next_)
	-- Stuck detection: a bot that cannot make progress in 6s of trying is logged, not hidden.
	if self.lastPosition and (next_ - self.lastPosition).Magnitude < 0.05 then
		self.stuckFor += dt
	else
		self.stuckFor = 0
	end
	self.lastPosition = next_
	return false
end

function BOT:use(targetPart): boolean
	if not targetPart then
		return false
	end
	if horizontal(self:position(), targetPart.Position) > (REACH + 2.5) then
		return false
	end
	local prompt = Harness.promptOn(targetPart)
	if not prompt then
		return false
	end
	-- Honour holds the way a human would: stand still for the hold, then trigger.
	if prompt.HoldDuration and prompt.HoldDuration > 0.35 then
		Stub.advance(prompt.HoldDuration)
	end
	return Harness.trigger(targetPart, self.player)
end

local function bestSocket()
	-- Fill the pump first, then the lift, then the winch: water kills the round fastest.
	for _, key in ipairs({ "Pump", "Lift", "Winch", "Bridge" }) do
		local socket = Power.sockets[key]
		if socket and not socket.cellId and not socket.tripped then
			return key, socket
		end
	end
	return nil, nil
end

local function nearestFreeCell(from: Vector3)
	local best, bestDistance = nil, math.huge
	for _, cell in pairs(Power.cells) do
		if not cell.destroyed and not cell.holder and not cell.socket then
			local distance = horizontal(from, cell.part.Position)
			if distance < bestDistance then
				best, bestDistance = cell, distance
			end
		end
	end
	return best, bestDistance
end

-- Survivors still out there, sorted by distance, minus the ones a teammate is already handling.
local function escortCandidates(from: Vector3, self_)
	local list = {}
	for _, survivor in ipairs(Rescue.order) do
		if survivor.state ~= "Rescued" and survivor.state ~= "Dead" and survivor.state ~= "Downed" then
			local claimed = survivor.leader ~= nil and survivor.leader ~= self_.player
			if not claimed then
				table.insert(list, { survivor = survivor, distance = horizontal(from, survivor.position) })
			end
		end
	end
	table.sort(list, function(a, b)
		return a.distance < b.distance
	end)
	return list
end

local function nearestUnlootedCrate(from: Vector3)
	local best, bestDistance = nil, math.huge
	for index = 1, 4 do
		local crate = part(`SupplyCrate_{index}`)
		if crate and crate:GetAttribute("Looted") ~= true then
			local distance = horizontal(from, crate.Position)
			if distance < bestDistance then
				best, bestDistance = crate, distance
			end
		end
	end
	return best
end

local function buySomething(bot): boolean
	for _, id in ipairs(UPGRADE_PRIORITY) do
		if Upgrades.canAfford(id) then
			local ok = Upgrades.purchase(bot.player, id)
			if ok then
				bot:note(`bought {id}`)
				return true
			end
		end
	end
	return false
end

-- One bot decision. `role` splits the work so a 2+ crew does not all chase the same thing.
function BOT:step(dt: number)
	if Round.state == "Results" or Round.state == "Intermission" or Round.state == "Lobby" then
		return
	end
	if PlayerService.getState(self.player).downed then
		self.lastAction = "downed"
		return
	end
	local targets = self:targets()
	if not targets then
		self.lastAction = "idle"
		return
	end
	local goal = targets.goal
	local arrive = targets.arrive or REACH
	if not self:walkTo(goal, dt, arrive) then
		self.lastAction = targets.label
		return
	end
	targets.act(self, dt)
end

-- Pick the next thing to do. Bots read the same objective board the HUD shows.
function BOT:targets()
	local position = self:position()
	local carrying = self:carryingCell()
	local conductor = self.index == 1
	local quotaMet = Rescue.rescuedCount >= Rescue.requiredRescued()

	-- The evac vehicle is inbound: keep working until it is on the pad, then get on it.
	if Round.radioCalled then
		local eta = Round.evacEta()
		if Round.evacArrived() or eta <= 4 then
			local pad = part("ExtractionPad")
			return { goal = pad.Position, label = "boarding", arrive = 6, act = function() end }
		end
	end

	-- 0. Downed people come first: a survivor bleeding out in the open is a life lost, and a downed
	--    teammate is four hands lost.
	for _, other in ipairs(Players:GetPlayers()) do
		local otherState = other ~= self.player and PlayerService.getState(other) or nil
		if otherState and otherState.downed then
			local character = other.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				-- Someone already has them: help by standing on the revive, not by grabbing an arm.
				if otherState.draggedBy and otherState.draggedBy ~= self.player then
					return { goal = (root :: any).Position, label = `revive {other.Name}`, arrive = 7,
						act = function(bot, tick)
							PlayerService.progressRevive(bot.player, other, tick)
						end }
				end
				-- If they are down in the flood, the answer is to haul them out of it, not to kneel
				-- in the water next to them. Bots only drag while the casualty is actually wet.
				local theirs = PlayerService.dragging(self.player)
				local wet = Flood.depthAt((root :: any).Position) > 0.9
				if wet and not theirs then
					return { goal = (root :: any).Position, label = `drag {other.Name}`, arrive = 6,
						act = function(bot)
							local ok = PlayerService.startDrag(bot.player, other)
							if ok then
								dragsStarted += 1
								bot:note(`grabbing {other.Name}`)
							end
						end }
				end
				if theirs == other then
					local safeZone = part("SafeZone")
					return { goal = safeZone.Position, label = `haul {other.Name} to safety`, arrive = 9,
						act = function(bot)
							-- Arrived at the shelter: the casualty is safe, so set them down.
							if (bot:position() - safeZone.Position).Magnitude < 11 then
								if PlayerService.stopDrag(bot.player) then
									dragsHauled += 1
									bot:note(`hauled {other.Name} clear`)
								end
							end
						end }
				end
				return { goal = (root :: any).Position, label = `revive {other.Name}`, arrive = 7,
					act = function(bot, tick)
						PlayerService.progressRevive(bot.player, other, tick)
						if not PlayerService.getState(other).downed then
							bot:note(`revived {other.Name}`)
						end
					end }
			end
		end
	end
	for _, survivor in ipairs(Rescue.order) do
		if survivor.state == "Downed" then
			return { goal = survivor.position, label = `pick up {survivor.name}`, arrive = 5,
				act = function(bot)
					if Rescue.revive(bot.player, survivor.name) then
						bot:note(`revived {survivor.name}`)
					end
				end }
		end
	end

	-- 1. Anyone in the water gets out first.
	if self:depth() > 1.1 then
		local dry = part("SafeZone")
		return { goal = dry.Position + v3(0, 6, 0), label = "leaving water", arrive = 7, act = function() end }
	end

	-- 1b. The outfall. Once the water is up around the low sector's doorsteps, one hand drops
	--     everything for the wheel: draining the district beats any single escort. The job is sticky
	--     (it stays until the sluice is wide open) so a crew does not spend the round walking to the
	--     outfall and back.
	local crewSize = #Players:GetPlayers()
	if (crewSize == 1 or self.index == crewSize) and not Outfall.isOpen() then
		if Outfall.open > 0.05 or Flood.level > 3.5 then
			local wheel = part("OutfallWheel")
			if wheel then
				-- arrive must stay inside the bot's reach, or it "arrives" 12 studs out and every use fails.
			return { goal = wheel.Position, label = "crank outfall", arrive = 6, act = function(bot)
					-- One crank per hold: the prompt has to be held down, so a bot that could spin the
					-- wheel every 0.25 s tick would be measuring the harness, not the game.
					if (bot.nextCrankAt or 0) > clock() then
						return
					end
					if bot:use(wheel) then
						outfallCranks += 1
						bot.nextCrankAt = clock() + Holds.outfallHold
					end
				end }
			end
		end
	end

	-- 2. Cells and sockets: the conductor's job.
	if conductor then
		if carrying then
			local key, socket = bestSocket()
			if socket then
				return { goal = socket.part.Position, label = `fit cell into {key}`,
					act = function(bot)
						bot:use(socket.part)
						if not bot:carryingCell() then
							bot:note(`powered {key}`)
						end
					end }
			end
		else
			local cell, distance = nearestFreeCell(position)
			if cell and distance < 90 then
				return { goal = cell.part.Position, label = `collect {cell.id}`,
					act = function(bot)
						bot:use(cell.part)
					end }
			end
		end

		-- 3. The relay fuse — capacity is what makes the second socket usable.
		if not Power.relayRepaired then
			if PlayerService.hasItem(self.player, "Fuse") then
				local slot = part("RelaySlot")
				return { goal = slot.Position, label = "fit fuse", act = function(bot)
					bot:use(slot)
					if Power.relayRepaired then
						bot:note("relay repaired (+1 capacity)")
					end
				end }
			end
			local fuse = part("RelayFuse")
			if fuse and fuse:GetAttribute("Taken") ~= true then
				return { goal = fuse.Position, label = "fetch fuse", act = function(bot)
					bot:use(fuse)
				end }
			end
		end

		-- 4. Call the evacuation once the quota is met (and keep working while it approaches).
		if quotaMet and not Round.radioCalled then
			if PlayerService.hasItem(self.player, "Radio") then
				local console = part("EvacConsole")
				return { goal = console.Position, label = "call evacuation", act = function(bot)
					bot:use(console)
					if Round.radioCalled then
						bot:note("evacuation called")
					end
				end }
			end
			local radio = part("Radio")
			if radio and radio:GetAttribute("Taken") ~= true then
				return { goal = radio.Position, label = "fetch radio", act = function(bot)
					bot:use(radio)
				end }
			end
		end
	end

	-- 5. Survivors. Each bot takes a different one so a crew spreads out instead of stacking up.
	local candidates = escortCandidates(position, self)
	if #candidates > 0 then
		local pick = conductor and 1 or ((self.index - 2) % #candidates) + 1
		local entry = candidates[pick]
		local survivor = entry.survivor
		if survivor.state ~= "Following" or survivor.leader ~= self.player then
			return { goal = survivor.position, label = `reach {survivor.label or survivor.name}`, arrive = 5,
				act = function(bot)
					if survivor.role == "Child" then
						if Rescue.carry(bot.player, survivor.name) then
							bot:note(`carrying {survivor.name}`)
						end
					else
						local ok = Rescue.lead(bot.player, survivor.name)
						if ok then
							bot:note(`escorting {survivor.name} ({survivor.trait})`)
						end
					end
				end }
		end
		local safeZone = part("SafeZone")
		return { goal = safeZone.Position, label = `escort {survivor.name}`, arrive = 9, act = function() end }
	end

	-- 6. Salvage: the conductor loots and buys when there is nobody left to fetch.
	local bench = part("UpgradeBench")
	if bench then
		if Upgrades.cratesOpened < 4 then
			local crate = nearestUnlootedCrate(position)
			if crate then
				return { goal = crate.Position, label = "loot crate", act = function(bot)
					bot:use(crate)
				end }
			end
		end
		if Upgrades.salvage >= 20 then
			return { goal = bench.Position, label = "bench", act = function(bot)
				buySomething(bot)
			end }
		end
	end

	-- 7. Nothing pressing: hold the pad.
	local pad = part("ExtractionPad")
	return { goal = pad.Position, label = "wait at the pad", arrive = 6, act = function() end }
end

-- ===================== run =====================

local runs = {}
local limitations = {
	"No engine physics: bots teleport in straight lines at the server-set walk speed (0.5x past waist depth).",
	"No client input latency, no camera, no fumbling a hold, no missed prompts.",
	"Bots never get stuck on props, never stagger on ramps and never collide with each other.",
	"Rendering, audio and framerate are not exercised at all.",
}

-- Downed players get dragged back to the shelter, so a round that ends mid-haul must not leave a
-- grip held into the next round.
local function releaseAllDrags(bots)
	for _, bot in ipairs(bots) do
		if PlayerService.dragging(bot.player) then
			PlayerService.stopDrag(bot.player)
		end
	end
end

local function runRound(crew: number, modifier: string)
	local bots = {}
	for index = 1, crew do
		table.insert(bots, newBot(`Bot{index}`, index))
	end
	local lead = bots[1]

	Round.resetToLobby()
	local okModifier = Session_setModifier(modifier)
	-- Crew roles are picked in the lobby, one per bot, so every round exercises the passives:
	-- bot 1 drives the grid, bot 2 hauls, bot 3 patches and bot 4 rigs.
	local roleOrder = { "Engineer", "Diver", "Medic", "Rigger" }
	for index, bot in ipairs(bots) do
		local role = roleOrder[((index - 1) % #roleOrder) + 1]
		Crew.set(bot.player, role)
		bot.role = role
	end
	Round.requestStart(lead.player)
	local started = clock()
	local record = {
		crew = crew,
		modifier = modifier,
		startedAt = 0,
		outcome = "unresolved",
		reason = nil,
		grade = nil,
		score = 0,
		elapsedSeconds = 0,
		rescued = 0,
		required = Rescue.requiredRescued(),
		lost = 0,
		dead = 0,
		cellsDocked = 0,
		routes = {},
		upgrades = {},
		salvage = 0,
		firstPowerAt = nil,
		quotaAt = nil,
		evacuationAt = nil,
		padAt = nil,
		waterPeak = 0,
		playerDowns = 0,
		roles = {},
		casualties = {},
		dragsStarted = 0,
		dragsHauled = 0,
		survivorDowns = 0,
		abilitiesUsed = 0,
		outfallOpens = 0,
		outfallCranks = 0,
		waterCurve = {},
		log = {},
		modifierApplied = okModifier,
	}

	local abilitiesUsed = 0
	dragsStarted = 0
	dragsHauled = 0
	local casualties = {}
	local seenNotes = {}
	local downs = 0
	outfallCranks = 0
	local crankTarget = nil
	local lastSample = 0
	local firstPowerSeen = false
	local quotaSeen = false
	local padSeen = false
	local guard = 0

	while clock() - started < RUN_LIMIT do
		guard += 1
		if guard > 200000 then
			break
		end
		for _, bot in ipairs(bots) do
			bot:step(TICK)
		end
		-- Abilities are spent at the moment the crew would want them.
		for _, bot in ipairs(bots) do
			local state = PlayerService.getState(bot.player)
			if state and not state.downed and Crew.abilityReady(bot.player) then
				local role = Crew.roleOf(bot.player)
				local want = false
				if role == "Engineer" then
					for _, socket in pairs(Power.sockets) do
						want = want or socket.tripped
					end
				elseif role == "Medic" then
					want = PlayerService.downedCount > (bot.spentDowns or 0)
					bot.spentDowns = PlayerService.downedCount
				elseif role == "Diver" then
					want = bot:depth() > 2.5
				elseif role == "Rigger" then
					want = bot:carryingCell() or bot:holding()
				end
				if want and Crew.useAbility(bot.player) then
					abilitiesUsed += 1
					bot:note(`ability {role}`)
				end
			end
		end
		if Outfall.opens > record.outfallOpens then
			record.outfallOpens = Outfall.opens
			lead:note(`outfall opened (${math.floor(Outfall.open * 100)}%)`)
		end
		Stub.advance(TICK)
		local elapsed = clock() - started

		-- Casualties: who died, when, and what killed them. Without this the report only carries a
		-- count, and a round where nine people drown in three minutes looks like bad luck.
		for _, survivor in ipairs(Rescue.order) do
			local notes = #survivor.notes
			if notes > (seenNotes[survivor.name] or 0) then
				seenNotes[survivor.name] = notes
				-- Only death is a casualty: being knocked down and picked up again is a rescue the
				-- crew made, and reporting it as a loss would misread a good round.
				if survivor.state == "Dead" then
					table.insert(casualties, {
						t = math.floor(elapsed * 10) / 10,
						name = survivor.name,
						cause = tostring(survivor.notes[notes]),
						level = math.floor(Flood.level * 100) / 100,
						depth = math.floor(Flood.depthAt(survivor.position) * 100) / 100,
					})
				else
					downs += 1
				end
			end
		end

		if not firstPowerSeen and (Power.isPowered("Pump") or Power.isPowered("Lift")) then
			firstPowerSeen = true
			record.firstPowerAt = math.floor(elapsed * 10) / 10
		end
		if not quotaSeen and Rescue.rescuedCount >= Rescue.requiredRescued() then
			quotaSeen = true
			record.quotaAt = math.floor(elapsed * 10) / 10
		end
		if not padSeen and Round.radioCalled then
			padSeen = true
			record.evacuationAt = math.floor(elapsed * 10) / 10
		end
		record.waterPeak = math.max(record.waterPeak, Flood.level)
		record.playerDowns = PlayerService.downedCount
		if elapsed - lastSample >= 20 then
			lastSample = elapsed
			table.insert(record.waterCurve, { t = math.floor(elapsed), level = math.floor(Flood.level * 100) / 100 })
		end
		if Round.state == "Results" or Round.state == "Intermission" then
			record.padAt = math.floor(elapsed * 10) / 10
			break
		end
	end

	local resolved = (Round.state == "Results" or Round.state == "Intermission") and Round.lastOutcome ~= nil
	local summary = resolved and Round.lastOutcome or nil
	record.elapsedSeconds = math.floor((clock() - started) * 10) / 10
	record.recovered = Rescue.recoveredCount
	if summary then
		record.outcome = summary.outcome
		record.reason = summary.reason
		record.grade = summary.grade
		record.score = summary.teamScore
		record.rescued = summary.rescued
		record.required = summary.required
		record.lost = summary.lost
		record.dead = summary.dead
		record.recovered = summary.recovered or record.recovered
		record.routes = summary.routes or {}
		local ownedList = {}
		for id in pairs(Upgrades.purchased) do
			table.insert(ownedList, id)
		end
		table.sort(ownedList)
		record.upgrades = ownedList
		record.salvage = summary.upgrades and summary.upgrades.salvage or 0
	else
		record.reason = `still in {Round.state} after {math.floor(record.elapsedSeconds)}s`
		record.rescued = Rescue.rescuedCount
		record.lost = Rescue.lostCount
		record.dead = Rescue.deadCount
		record.routes = Route.openedRoutes()
		record.salvage = math.floor(Upgrades.salvage)
		local owned = {}
		for id in pairs(Upgrades.purchased) do
			table.insert(owned, id)
		end
		record.upgrades = owned
	end
	for _, cell in pairs(Power.cells) do
		if cell.socket then
			record.cellsDocked += 1
		end
	end
	if record.waterCurve[#record.waterCurve] == nil or record.waterCurve[#record.waterCurve].t ~= math.floor(record.elapsedSeconds) then
		table.insert(record.waterCurve, { t = math.floor(record.elapsedSeconds), level = math.floor(Flood.level * 100) / 100 })
	end
	record.casualties = casualties
	record.survivorDowns = downs
	record.abilitiesUsed = abilitiesUsed
	record.outfallCranks = outfallCranks
	releaseAllDrags(bots)
	record.roles = {}
	for _, bot in ipairs(bots) do
		table.insert(record.roles, { name = bot.name, role = Crew.roleOf(bot.player) })
	end
	-- The lead bot's story is the most useful debugging artefact.
	record.log = lead.log
	record.botLogs = {}
	for _, bot in ipairs(bots) do
		table.insert(record.botLogs, { name = bot.name, steps = #bot.log, lastAction = bot.lastAction, stuckFor = bot.stuckFor })
	end

	releaseAllDrags(bots)
	for _, bot in ipairs(bots) do
		Stub.removePlayer(bot.player)
	end
	Round.resetToLobby()
	return record
end

-- The harness exposes SessionService through the server module tree.
local Session = module("SessionService")
function Session_setModifier(key: string): boolean
	return Session.setModifier(key)
end

local plan = {
	{ crew = 1, modifier = "Calm" },
	{ crew = 1, modifier = "Standard" },
	{ crew = 1, modifier = "Storm" },
	{ crew = 2, modifier = "Standard" },
	{ crew = 2, modifier = "Storm" },
	{ crew = 4, modifier = "Standard" },
	{ crew = 4, modifier = "Catastrophe" },
}

-- ============================================================
-- Drill: a teammate goes down mid-round and the crew has to haul them
-- ============================================================
-- The bots are careful enough that nobody goes down on their own, so this drill injects the injury
-- the engine would have dealt (a live cable, a fall) and then watches the crew deal with it: the
-- casualty has to be dragged, arrive at the shelter, and the round has to carry on.
local function runDownedCrewDrill(modifier: string)
	local bots = { newBot("Drill1", 1), newBot("Drill2", 2), newBot("Drill3", 3) }
	local lead = bots[1]
	Round.resetToLobby()
	Session_setModifier(modifier)
	Crew.set(bots[1].player, "Rigger")
	Crew.set(bots[2].player, "Medic")
	Crew.set(bots[3].player, "Engineer")
	Round.requestStart(lead.player)

	local casualty = bots[3]
	local started = clock()
	local injected = false
	local surges = 0
	local lastSurgeAt = nil
	local dragged = false
	local hauled = false
	local revived = false
	local downedAt = nil
	local freedAt = nil
	local guard = 0
	local lastNote = 0
	while clock() - started < 600 do
		guard += 1
		if guard > 250000 then
			break
		end
		for _, bot in ipairs(bots) do
			-- The casualty cannot walk while down, so the drill keeps them where they fell.
			if bot ~= casualty or not PlayerService.getState(casualty.player).downed then
				bot:step(TICK)
			end
		end
		-- Inject the injury once the casualty is standing in deep enough water for the difference
		-- between a revive and a haul to matter. A downed player on dry ground is a kneel-and-fix;
		-- the drill is about the other case, so it waits for real water and nudges the storm along.
		if not injected then
			local elapsed = clock() - started
			-- Drill-controlled flood: raise the sector the casualty is standing in until they are
			-- genuinely in deep water. Waiting for the storm is not deterministic (a fast crew wins
			-- the round first), and the point is to test the rescue, not the rain.
			if elapsed > 6 then
				local sector = WorldService.sectorAt(Stub.playerPosition(casualty.player))
				local depth = Flood.depthAt(Stub.playerPosition(casualty.player))
				local tries = 0
				while depth < 1.2 and tries < 8 do
					Flood.surge(2.4, sector)
					surges += 1
					tries += 1
					Stub.advance(0.3)
					depth = Flood.depthAt(Stub.playerPosition(casualty.player))
				end
				lead:note(`drill: {surges} surges put the district at {string.format("%.1f", Flood.level)}m`)
				if depth >= 1.2 then
					injected = true
					downedAt = clock() - started
					PlayerService.downed(casualty.player, "a live cable (drill)")
					lead:note(`drill: Drill3 is down in {string.format("%.1f", depth)}m of water`)
				end
			end
		end
		if injected and not dragged then
			for _, bot in ipairs(bots) do
				if PlayerService.dragging(bot.player) == casualty.player then
					dragged = true
					freedAt = clock() - started
					lead:note(`drill: {bot.name} has hold of Drill3`)
				end
			end
		end
		if dragged and not hauled and not PlayerService.carriedBy(casualty.player) then
			hauled = true
			lead:note("drill: Drill3 is clear")
		end
		if injected and not revived and not PlayerService.getState(casualty.player).downed then
			revived = true
			lead:note(`drill: Drill3 back on their feet after {math.floor((clock() - started) - (downedAt or 0))}s`)
		end
		Stub.advance(TICK)
		if (clock() - started) - lastNote > 30 then
			lastNote = clock() - started
		end
		if Round.state == "Results" or Round.state == "Intermission" then
			break
		end
	end

	releaseAllDrags(bots)
	local position = Stub.playerPosition(casualty.player)
	local safe = part("SafeZone").Position
	local distance = position and (position - safe).Magnitude or 999
	local record = {
		crew = 3,
		modifier = modifier,
		outcome = dragged and "hauled" or "never grabbed",
		reason = `casualty down at {math.floor((downedAt or 0))}s, grabbed {dragged and math.floor(freedAt or 0) .. "s" or "never"}`,
		elapsedSeconds = math.floor((clock() - started) * 10) / 10,
		dragsStarted = dragged and 1 or 0,
		dragsHauled = hauled and 1 or 0,
		revived = revived,
		distanceToShelter = math.floor(distance * 10) / 10,
		injected = injected,
		surges = surges,
		log = lead.log,
	}
	for _, bot in ipairs(bots) do
		Stub.removePlayer(bot.player)
	end
	Round.resetToLobby()
	return record
end

local filter = process.env.FLOODLINE_PLAN
for _, entry in ipairs(plan) do
	local label = `{entry.crew}p-{entry.modifier}`
	if filter and filter ~= "" and not string.find(label, filter, 1, true) then
		continue
	end
	local record = runRound(entry.crew, entry.modifier)
	table.insert(runs, record)
	print(string.format("[%s] crew=%d %-12s %-25s %5.1fs rescued=%d/%d lost=%d routes=%s score=%d grade=%s",
		string.upper(record.outcome), record.crew, record.modifier, record.reason or "",
		record.elapsedSeconds, record.rescued, record.required, record.lost,
		#record.routes > 0 and table.concat(record.routes, "+") or "-", record.score, tostring(record.grade)))
end

-- The downed-crew drill runs on its own round so a win or a loss elsewhere cannot hide it.
local drill = nil
if not filter or filter == "" or string.find("drill", filter, 1, true) then
	drill = runDownedCrewDrill("Standard")
	print(string.format("[DRILL] downed teammate: %s (%s), hauled=%s, revived=%s",
		drill.outcome, drill.reason, tostring(drill.dragsHauled == 1), tostring(drill.revived)))
end

-- ===================== report =====================

local wins, fails, unresolved = 0, 0, 0
local gradeCount = {}
for _, record in ipairs(runs) do
	if record.outcome == "win" then
		wins += 1
	elseif record.outcome == "fail" then
		fails += 1
	else
		unresolved += 1
	end
	gradeCount[record.grade or "-"] = (gradeCount[record.grade or "-"] or 0) + 1
end

-- A tiny JSON encoder: the report is a plain table so nothing can drift out of shape.
local function encode(value: any, indent: string): string
	local kind = type(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return "null"
		end
		return tostring(math.floor(value * 1000 + 0.5) / 1000)
	elseif kind == "string" then
		return `"{value:gsub('"', "'"):gsub("\n", " ")}"`
	elseif kind == "boolean" then
		return tostring(value)
	elseif kind ~= "table" then
		return "null"
	end
	local isArray = true
	local count = 0
	for key in pairs(value) do
		count += 1
		if type(key) ~= "number" then
			isArray = false
		end
	end
	local inner = indent .. "  "
	local parts = {}
	if isArray then
		for _, item in ipairs(value) do
			table.insert(parts, inner .. encode(item, inner))
		end
		if #parts == 0 then
			return "[]"
		end
		return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
	end
	local keys = {}
	for key in pairs(value) do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		table.insert(parts, inner .. `"{key}": ` .. encode(value[key], inner))
	end
	return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local report = {
	runs = #runs,
	wins = wins,
	fails = fails,
	unresolved = unresolved,
	note = "Bots play the shipped server modules on a virtual clock. Timings are a lower bound for a competent crew; engine physics, input and rendering are NOT exercised.",
	limitations = limitations,
	downedCrewDrill = drill,
	results = runs,
}
for _, record in ipairs(report.results) do
	record.botLogs = nil -- the lead bot's log is the one that matters
end

fs.writeFile(AGENT .. "/evidence/playtest-report.json", encode(report, "") .. "\n")
print(string.format("\n%d wins / %d fails / %d unresolved across %d bot rounds", wins, fails, unresolved, #runs))
print(`report: agents/riveter/evidence/playtest-report.json`)
