--!strict
-- RescueService: the survivors. Traits, escort following, panic, injury, drowning, carrying,
-- revive, safe-zone rescue and lift handover. NPC rigs are anchor-driven for deterministic motion.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- PathfindingService is engine-only; the headless harness runs without it and falls back to
-- the steering code below.
local okPathfinding, PathfindingService = pcall(function()
	return game:GetService("PathfindingService")
end)
local hasPathfinding = okPathfinding and PathfindingService ~= nil and type(PathfindingService.CreatePath) == "function"

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Rescue = {}
Rescue.Name = "Rescue"

export type SurvivorState = "Idle" | "Following" | "Assisting" | "Downed" | "Carried" | "Lost" | "Rescued" | "Dead"

export type Survivor = {
	name: string,
	trait: string,
	model: Model,
	root: BasePart,
	parts: { [string]: BasePart },
	offsets: { [string]: CFrame },
	state: SurvivorState,
	homePosition: Vector3,
	position: Vector3,
	yaw: number,
	leader: Player?,
	health: number,
	panic: number,
	walkPhase: number,
	speed: number,
	stuckSeconds: number,
	lastDistance: number,
	safeSeconds: number,
	downedAt: number?,
	carriedBy: Player?,
	extractionRoute: string,
	role: string?,
	roleNote: string?,
	refusedAt: number?,
	routeQueue: { Vector3 }?,
	routeGoal: Vector3?,
	boarding: boolean,
	rescuedAt: number?,
	notes: { string },
}

Rescue.survivors = {} :: { [string]: Survivor }
-- Spawn points survive round resets: a rescued NPC is hidden, never destroyed, so the next
-- round always deploys the full crew.
Rescue.spawnPoints = {} :: { [string]: Vector3 }
Rescue.order = {} :: { Survivor }
Rescue.rescuedCount = 0
Rescue.lostCount = 0
Rescue.deadCount = 0
Rescue.recoveredCount = 0
Rescue.dirty = true
Rescue.lastSnapshots = {} :: { [string]: any }

local ctx
local SAFE_RADIUS = 7.5
local PAD_RADIUS = 6.5

local TRAITS = {
	Survivor1 = "Worker",
	Survivor2 = "Injured",
	Survivor3 = "Elderly",
	Survivor4 = "Child",
	Survivor5 = "Deaf",
	Survivor6 = "Dog",
	Survivor7 = "Injured",
	Survivor8 = "Worker",
	Survivor9 = "Medic",
	Survivor10 = "Engineer",
	Survivor11 = "Injured",
	Survivor12 = "Worker",
}

local NAMES = {
	Survivor1 = "Mara (duty engineer)",
	Survivor2 = "Tobin (crushed leg)",
	Survivor3 = "Idris (caretaker)",
	Survivor4 = "Pia (child)",
	Survivor5 = "Rue (no hearing)",
	Survivor6 = "Kesh (search dog)",
	Survivor7 = "Juno (firefighter)",
	Survivor8 = "Alik (pump hand)",
	Survivor9 = "Sana (paramedic)",
	Survivor10 = "Dov (plant engineer)",
	Survivor11 = "Bram (pipefitter)",
	Survivor12 = "Nika (dockhand)",
}

local RX = 0.42
local PATH_RECOMPUTE_SECONDS = 2.5

function Rescue.get(name: string): Survivor?
	return Rescue.survivors[name]
end

function Rescue.setDirty()
	Rescue.dirty = true
end

function Rescue.alive(): { Survivor }
	return Util.filter(Rescue.order, function(s)
		return s.state ~= "Rescued" and s.state ~= "Dead"
	end)
end

function Rescue.countRescued(): number
	return Rescue.rescuedCount
end

function Rescue.requiredRescued(): number
	local total = ctx.config.Survivors.Total
	local fraction = ctx.scaling().RequiredSurvivorFraction
	return math.max(1, math.ceil(total * fraction))
end

function Rescue.speedFor(trait: string): number
	local def = ctx.config.Survivors.Traits[trait]
	local factor = def and def.Speed or 1
	local base = ctx.config.Survivors.FollowSpeed.Base
	return base * factor
end

-- Is a survivor with this role currently following this player?
function Rescue.followingRole(player: Player, role: string)
	for _, survivor in ipairs(Rescue.order) do
		if survivor.leader == player and survivor.state == "Following" and survivor.role == role then
			return survivor
		end
	end
	return nil
end

-- The engineer turns cranks and clears debris faster while they are with you.
function Rescue.engineerNear(player: Player, radius: number?): string?
	local engineer = Rescue.followingRole(player, "Engineer")
	if not engineer then
		return nil
	end
	if radius then
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and ((root :: BasePart).Position - engineer.position).Magnitude > radius then
			return nil
		end
	end
	return NAMES[engineer.name] or engineer.name
end

-- Medic field aura: a following medic patches their leader up, slowly.
function Rescue.medicAura(player: Player, dt: number)
	local medic = Rescue.followingRole(player, "Medic")
	if not medic then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local def = ctx.config.Survivors.Roles.Medic
	if humanoid.Health >= def.HealCeiling then
		return
	end
	humanoid.Health = math.min(def.HealCeiling, humanoid.Health + def.HealPerSecond * dt)
end

local function promptFor(model: Model): ProximityPrompt?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root then
		return root:FindFirstChildOfClass("ProximityPrompt")
	end
	return nil
end

function Rescue.build(name: string, model: Model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	-- Return the rig to its authored spot and make it visible again before measuring it.
	local home = Rescue.spawnPoints[name]
	if home then
		model:PivotTo(CFrame.new(home))
	else
		Rescue.spawnPoints[name] = model:GetPivot().Position
	end
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanQuery = true
			descendant.CanTouch = true
			descendant.Transparency = descendant.Name == "HumanoidRootPart" and 1 or 0
		end
	end
	local parts: { [string]: BasePart } = {}
	local offsets: { [string]: CFrame } = {}
	local baseCFrame = model:GetPivot()
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			parts[descendant.Name] = descendant
			offsets[descendant.Name] = baseCFrame:ToObjectSpace(descendant.CFrame)
		end
	end
	local trait = TRAITS[name] or "Worker"
	local position = baseCFrame.Position
	local survivor: Survivor = {
		name = name,
		trait = trait,
		model = model,
		root = root,
		parts = parts,
		offsets = offsets,
		state = "Idle",
		homePosition = position,
		position = position,
		yaw = 0,
		leader = nil,
		health = 100,
		panic = 0,
		walkPhase = 0,
		speed = Rescue.speedFor(trait),
		stuckSeconds = 0,
		lastDistance = math.huge,
		safeSeconds = 0,
		downedAt = nil,
		carriedBy = nil,
		extractionRoute = "safezone",
		role = (ctx.config.Survivors.Traits[trait] or {}).Role,
		roleNote = (ctx.config.Survivors.Traits[trait] or {}).Effect,
		refusedAt = nil,
		routeQueue = nil,
		routeGoal = nil,
		boarding = false,
		rescuedAt = nil,
		notes = {},
	}
	Rescue.survivors[name] = survivor
	table.insert(Rescue.order, survivor)
	table.sort(Rescue.order, function(a, b)
		return a.name < b.name
	end)
	local prompt = promptFor(model)
	if prompt then
		prompt.ActionText = "Lead"
		prompt.ObjectText = NAMES[name] or name
		prompt.HoldDuration = 0.2
		prompt.MaxActivationDistance = 12
		prompt.Triggered:Connect(function(player: Player)
			Rescue.lead(player, name)
		end)
		prompt.PromptShown:Connect(function()
			-- client optimises highlighting; nothing needed server-side
		end)
	end
end

function Rescue.reset()
	Rescue.survivors = {}
	Rescue.order = {}
	Rescue.rescuedCount = 0
	Rescue.lostCount = 0
	Rescue.deadCount = 0
	local world = ctx.worldFolder
	local folder = world:FindFirstChild("Survivors")
	if not folder then
		return
	end
	for _, model in ipairs(folder:GetChildren()) do
		if model:IsA("Model") then
			Rescue.build(model.Name, model)
		end
	end
	Rescue.dirty = true
	local spawnCount = 0
	for _ in pairs(Rescue.spawnPoints) do
		spawnCount += 1
	end
	ctx.log(`[Rescue] {#Rescue.order} survivors deployed ({spawnCount} spawn points known)`)
end

-- ===================== interactions =====================

function Rescue.lead(player: Player, name: string): (boolean, string?)
	local survivor = Rescue.survivors[name]
	if not survivor then
		return false, "No such survivor."
	end
	if survivor.state == "Rescued" or survivor.state == "Dead" then
		return false, "They are already out of the district."
	end
	if survivor.state == "Carried" then
		return false, "Set them down first."
	end
	if survivor.state == "Downed" then
		return false, "They are down. Revive them first."
	end
	if survivor.trait == "Deaf" then
		local leaderRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if leaderRoot and ((leaderRoot :: BasePart).Position - survivor.position).Magnitude > 9 then
			return false, "Rue cannot hear you. Get closer and touch them."
		end
	end
	survivor.leader = player
	if survivor.state ~= "Following" then
		survivor.state = "Following"
		survivor.notes = {}
		ctx.notifyPlayer(player, `Leading {NAMES[name] or name}.`, "good")
	end
	Rescue.dirty = true
	return true, nil
end

function Rescue.release(player: Player, name: string?)
	for _, survivor in ipairs(Rescue.order) do
		if survivor.leader == player and (name == nil or survivor.name == name) then
			survivor.leader = nil
			if survivor.state == "Following" then
				survivor.state = "Idle"
			end
		end
	end
	Rescue.dirty = true
end

function Rescue.revive(player: Player, name: string): (boolean, string?, number?)
	local survivor = Rescue.survivors[name]
	if not survivor or survivor.state ~= "Downed" then
		return false, "Nothing to revive there.", 0
	end
	local needed = ctx.config.Survivors.ReviveSeconds
	if ctx.hasItem(player, "Medkit") then
		needed *= 0.45
	end
	survivor.state = "Idle"
	survivor.health = 55
	survivor.panic = math.min(survivor.panic, 45)
	survivor.downedAt = nil
	survivor.leader = player
	survivor.state = "Following"
	ctx.notifyPlayer(player, `{NAMES[name] or name} is back on their feet.`, "good")
	ctx.addScore(player, 25, "revive")
	Rescue.dirty = true
	return true, nil, needed
end

function Rescue.carry(player: Player, name: string): (boolean, string?)
	local survivor = Rescue.survivors[name]
	if not survivor then
		return false, "No such survivor."
	end
	if survivor.state ~= "Downed" and survivor.state ~= "Following" and survivor.state ~= "Idle" then
		return false, "You cannot carry them right now."
	end
	survivor.state = "Carried"
	survivor.carriedBy = player
	survivor.shelter = nil
	survivor.leader = nil
	Rescue.dirty = true
	ctx.notifyPlayer(player, `Carrying {NAMES[name] or name}. You move slower.`, "warn")
	return true, nil
end

function Rescue.dropCarried(player: Player): boolean
	local carried = Util.find(Rescue.order, function(s)
		return s.carriedBy == player
	end)
	if not carried then
		return false
	end
	carried.state = "Idle"
	carried.carriedBy = nil
	carried.homePosition = carried.position
	Rescue.dirty = true
	return true
end

function Rescue.onHazardDown(name: string, cause: string)
	local survivor = Rescue.survivors[name]
	if not survivor or survivor.state == "Rescued" or survivor.state == "Dead" then
		return
	end
	if survivor.state == "Downed" then
		-- Already down: injuries do not stack into a second "X is down" message, and the bleedout
		-- clock is not restarted, so a survivor lying in water actually dies.
		return
	end
	survivor.health = 0
	survivor.state = "Downed"
	survivor.downedAt = os.clock()
	survivor.leader = nil
	table.insert(survivor.notes, cause)
	ctx.notify(`{NAMES[name] or name} is down ({cause}).`, "bad")
	Rescue.dirty = true
end

-- ===================== motion =====================

local function groundHeight(position: Vector3, ignore: Model): number
	local origin = Vector3.new(position.X, position.Y + 8, position.Z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	params.IgnoreWater = true
	local result = Workspace:Raycast(origin, Vector3.new(0, -40, 0), params)
	if result then
		return result.Position.Y
	end
	return position.Y
end

local function applyRig(survivor: Survivor, position: Vector3, yaw: number, locomoting: boolean, dt: number)
	local model = survivor.model
	local baseCFrame = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	if locomoting then
		survivor.walkPhase += dt * 7.5
	end
	local swing = math.sin(survivor.walkPhase) * (locomoting and 0.5 or 0.06)
	local bob = math.abs(math.cos(survivor.walkPhase)) * (locomoting and 0.12 or 0.02)
	for partName, part in pairs(survivor.parts) do
		local offset = survivor.offsets[partName]
		if not offset then
			continue
		end
		local animated = offset
		if partName == "LegL" then
			animated = offset * CFrame.Angles(swing, 0, 0)
		elseif partName == "LegR" then
			animated = offset * CFrame.Angles(-swing, 0, 0)
		elseif partName == "Head" then
			animated = offset * CFrame.Angles(-bob * 0.5, 0, 0)
		elseif partName == "Torso" then
			animated = offset + Vector3.new(0, bob, 0)
		end
		part.CFrame = baseCFrame * animated
		part.Anchored = true
	end
	survivor.position = position
	survivor.yaw = yaw
	survivor.root.CFrame = baseCFrame * (survivor.offsets["HumanoidRootPart"] or CFrame.new())
end

-- Used by LiftService to keep boarded passengers glued to the moving cabin.
function Rescue.setRigPosition(survivor, position: Vector3)
	if not survivor or survivor.state == "Rescued" or survivor.state == "Dead" then
		return
	end
	applyRig(survivor, position, survivor.yaw or 0, false, 0)
end

-- Ask the engine for a real route; survivors use it when a straight line stops working.
local function computePath(survivor, goal: Vector3): boolean
	if not hasPathfinding then
		return false
	end
	local ok, path = pcall(function()
		local instance = PathfindingService:CreatePath({
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = true,
			AgentMaxSlope = 45,
			WaypointSpacing = 4,
		})
		instance:ComputeAsync(survivor.position, goal)
		return instance
	end)
	if not ok or not path or path.Status ~= Enum.PathStatus.Success then
		return false
	end
	local okWaypoints, waypoints = pcall(function()
		return path:GetWaypoints()
	end)
	if not okWaypoints or type(waypoints) ~= "table" or #waypoints == 0 then
		return false
	end
	local queue = {}
	for _, waypoint in ipairs(waypoints) do
		local position = waypoint.Position or waypoint
		table.insert(queue, Vector3.new(position.X, position.Y, position.Z))
	end
	survivor.path = queue
	survivor.pathIndex = 1
	survivor.pathComputedAt = os.clock()
	return true
end

local function nextPathWaypoint(survivor): Vector3?
	local queue = survivor.path
	if not queue then
		return nil
	end
	while survivor.pathIndex and queue[survivor.pathIndex] do
		local waypoint = queue[survivor.pathIndex]
		if (waypoint - survivor.position).Magnitude < 3.5 then
			survivor.pathIndex += 1
		else
			return waypoint
		end
	end
	survivor.path = nil
	survivor.pathIndex = nil
	return nil
end

-- Steering with a cheap detour: survivors walk straight at their goal, and when a prop blocks
-- them they slide around it for a moment instead of grinding against it forever.
-- Survivors walk straight lines except across the roof span, where RouteService hands out
-- waypoints (near joint, middle, far joint) once the skybridge is out.
local function routeTarget(survivor: Survivor, target: Vector3): Vector3
	if not ctx.route then
		return target
	end
	local queue = survivor.routeQueue
	if queue and #queue > 0 then
		local head = queue[1]
		if (head - survivor.position).Magnitude < 3.4 then
			table.remove(queue, 1)
			if #queue == 0 then
				survivor.routeQueue = nil
				survivor.routeGoal = nil
			end
		else
			return head
		end
	elseif survivor.routeGoal == nil or (survivor.routeGoal - target).Magnitude > 12 then
		local waypoints = ctx.route.waypointsFor(survivor.position, target)
		if waypoints and #waypoints > 0 then
			survivor.routeQueue = waypoints
			survivor.routeGoal = target
			return waypoints[1]
		end
	end
	return target
end

-- Moving to high ground. Survivors walk to the structure under a refuge and then climb it. The
-- engine handles the actual step-up; this keeps them moving and only reports arrival when they are
-- genuinely up there (horizontal AND vertical proximity). The climb rate is deliberately capped at
-- a brisk stair-walk so this can never look like a teleport.
local function moveTowardHeight(survivor: Survivor, target: Vector3, dt: number, speedScale: number): boolean
	local current = survivor.position
	local flat = Vector3.new(target.X, current.Y, target.Z) - current
	local horizontalDistance = flat.Magnitude
	local heightGap = target.Y - current.Y
	if horizontalDistance < 3.5 and heightGap < 3.5 then
		applyRig(survivor, current, survivor.yaw, false, dt)
		return true
	end
	-- Head for the structure; once underneath it, sidle along the footprint looking for the way up.
	local direction
	if horizontalDistance < 1.2 then
		local sweep = os.clock() * 0.9
		direction = Vector3.new(math.cos(sweep), 0, math.sin(sweep))
	else
		direction = flat.Unit
	end
	local speed = ctx.config.Survivors.FollowSpeed.Base * speedScale
	local step = math.min(horizontalDistance, speed * dt)
	local nextXZ = current + Vector3.new(direction.X, 0, direction.Z) * step
	local climb = 0
	if heightGap > 0.5 and horizontalDistance < 16 then
		climb = math.min(heightGap, 4.2 * dt)
	end
	local nextY = current.Y + climb
	if climb <= 0 then
		nextY = groundHeight(nextXZ, survivor.model)
	end
	local nextPosition = Vector3.new(nextXZ.X, nextY, nextXZ.Z)
	local yaw = math.atan2(direction.X, direction.Z)
	applyRig(survivor, nextPosition, yaw, true, dt)
	survivor.position = nextPosition
	survivor.yaw = yaw
	return false
end

local function moveToward(survivor: Survivor, rawTarget: Vector3, dt: number, speedScale: number): boolean
	local target = routeTarget(survivor, rawTarget)
	local current = survivor.position
	local flatTarget = Vector3.new(target.X, current.Y, target.Z)
	local delta = flatTarget - current
	local distance = delta.Magnitude
	if distance < 0.6 then
		applyRig(survivor, current, survivor.yaw, false, dt)
		return true
	end

	local direction = delta.Unit
	-- Prefer an engine path once the survivor starts struggling or the goal moves a long way.
	if survivor.path and survivor.pathGoal and (survivor.pathGoal - flatTarget).Magnitude > 6 then
		survivor.path = nil
	end
	if survivor.path then
		local waypoint = nextPathWaypoint(survivor)
		if waypoint then
			local waypointDelta = Vector3.new(waypoint.X, current.Y, waypoint.Z) - current
			if waypointDelta.Magnitude > 0.4 then
				direction = waypointDelta.Unit
			end
		end
	elseif survivor.stuckSeconds > 1.2 then
		if (not survivor.pathComputedAt) or os.clock() - survivor.pathComputedAt > PATH_RECOMPUTE_SECONDS then
			survivor.pathGoal = flatTarget
			computePath(survivor, flatTarget)
		end
	end
	if survivor.detourUntil and os.clock() < survivor.detourUntil then
		local angle = (survivor.detourSign or 1) * math.rad(72)
		local cos, sin = math.cos(angle), math.sin(angle)
		direction = Vector3.new(
			direction.X * cos - direction.Z * sin,
			0,
			direction.X * sin + direction.Z * cos
		).Unit
	elseif survivor.detourUntil then
		survivor.detourUntil = nil
	end

	-- Rigger's Rope Line: everybody in the aura moves quicker, escorts included.
	local line = ctx.crew and ctx.crew.speedMultiplierAt(survivor.position) or 1
	local speed = survivor.speed * dt * (speedScale or 1) * line
	local nextPos = current + direction * math.min(speed, distance)
	nextPos = Vector3.new(nextPos.X, groundHeight(Vector3.new(nextPos.X, nextPos.Y, nextPos.Z), survivor.model), nextPos.Z)
	local yaw = math.atan2(direction.X, direction.Z)
	applyRig(survivor, nextPos, yaw, true, dt)

	local progressed = distance < survivor.lastDistance - 0.05
	if progressed then
		survivor.stuckSeconds = 0
	else
		survivor.stuckSeconds += dt
		if survivor.stuckSeconds > 0.9 and not survivor.detourUntil then
			survivor.detourUntil = os.clock() + 1.8
			survivor.detourSign = (survivor.stuckSign or 1)
			survivor.stuckSign = -(survivor.stuckSign or 1)
		end
		if survivor.stuckSeconds > 9 and survivor.state == "Following" then
			-- Last resort: they are jammed somewhere the player cannot easily reach.
			survivor.stuckSeconds = 0
			survivor.notes = survivor.notes or {}
			table.insert(survivor.notes, "freed from a jam")
		end
	end
	survivor.lastDistance = distance
	return false
end

local function nearestPlayer(position: Vector3, maxDistance: number?): (Player?, number)
	local best: Player? = nil
	local bestDistance = maxDistance or math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local distance = ((root :: BasePart).Position - position).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = player
			end
		end
	end
	return best, bestDistance
end

local function isRescuedZone(position: Vector3): (boolean, string?)
	local safe = ctx.world.safeZone
	if safe and (position - safe.Position).Magnitude <= SAFE_RADIUS then
		return true, "SafeZone"
	end
	local pad = ctx.padPart()
	if pad and (position - pad.Position).Magnitude <= PAD_RADIUS then
		return true, "ExtractionPad"
	end
	return false, nil
end

-- Hidden rather than deleted: the rig is restored from Rescue.spawnPoints next round.
function Rescue.retire(survivor: Survivor)
	survivor.boarding = false
	for _, part in pairs(survivor.parts) do
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	survivor.model:PivotTo(CFrame.new(Vector3.new(0, -120, 0)))
end

-- Role payoffs fire once, on delivery, so the reward is legible to the whole team.
local function applyRoleEffect(survivor: Survivor, how: string)
	if survivor.role == "Medic" then
		ctx.upgrade.onMedicRescue(nil)
	elseif survivor.role == "Engineer" then
		ctx.power.clearTrips("flood")
		ctx.power.rechargeAll(nil)
		ctx.notify("Engineer on board: flood trips cleared and the cell rack topped up.", "good")
	end
	ctx.telemetry.note("role", `{survivor.name} ({survivor.role or survivor.trait}) rescued via {how}`)
end

local function deliver(survivor: Survivor, how: string)
	survivor.state = "Rescued"
	survivor.rescuedAt = os.clock()
	survivor.leader = nil
	survivor.carriedBy = nil
	survivor.shelter = nil
	Rescue.retire(survivor)
	Rescue.rescuedCount += 1
	local traitDef = ctx.config.Survivors.Traits[survivor.trait]
	local bonus = traitDef and traitDef.Bonus or 0
	applyRoleEffect(survivor, how)
	ctx.onSurvivorRescued(survivor, how, bonus)
	ctx.notify(`{NAMES[survivor.name] or survivor.name} rescued via {how} ({Rescue.rescuedCount}/{ctx.config.Survivors.Total}).`, "good")
	Rescue.dirty = true
end

-- Terminal and idempotent: a person who has already died cannot die again, and nothing that runs
-- later in the same tick may walk them back out of "Dead" (this loops a death counter otherwise).
local function kill(survivor: Survivor, cause: string)
	if survivor.state == "Dead" then
		return
	end
	survivor.state = "Dead"
	survivor.health = 0
	survivor.panic = 0
	survivor.leader = nil
	survivor.downedAt = nil
	Rescue.retire(survivor)
	Rescue.deadCount += 1
	table.insert(survivor.notes, cause)
	ctx.notify(`{NAMES[survivor.name] or survivor.name} was lost to {cause}.`, "bad")
	Rescue.dirty = true
end

local function updateDanger(survivor: Survivor, dt: number)
	local depth = ctx.flood.depthAt(survivor.position)
	local submerged = depth > ctx.config.Water.SurvivorPanicDepth
	local inWater = depth > 0.25

	if survivor.state == "Carried" then
		-- Carried survivors are kept high and dry by their carrier.
		return
	end

	if survivor.state == "Dead" then
		return
	end

	if inWater then
		-- An unclaimed survivor does not stand in the flood: they head for high ground. This is the
		-- difference between a district that drowns its NPCs on the clock and one the crew can
		-- actually work: people are found on landings, catwalks and mezzanines, not at the bottom.
		if (survivor.state == "Idle" or survivor.state == "Lost") and depth > ctx.config.Survivors.ShelterDepth then
			local refuge = survivor.shelter
			if not refuge or ctx.flood.depthAt(refuge) > 0.6 then
				local target, label = Rescue.bestRefuge(survivor.position)
				if target then
					survivor.shelter = target
					survivor.shelterLabel = label
					if not survivor.shelterNoted then
						survivor.shelterNoted = true
						ctx.notify(`{NAMES[survivor.name] or survivor.name} is heading for the {label or "high ground"}.`, "info")
					end
				end
			end
		end
		-- Neck-deep is its own kind of terror: at 1.4 m the panic climb nearly doubles, which is what
		-- makes the rising water a deadline for the survivors and not just for the crew's feet.
		local panicFill = ctx.flood.depthAt(survivor.position) >= 1.4 and 1.35 or 1.0
		survivor.panic = math.min(140, survivor.panic + ctx.config.Survivors.PanicGrowthPerSecond * (submerged and 1.8 or 0.7) * panicFill * dt)
		survivor.health = math.max(0, survivor.health - (submerged and 8.0 or 2.0) * dt)
		if survivor.health <= 0 and survivor.state ~= "Downed" and survivor.state ~= "Rescued" then
			-- Someone who is already down and still in the water is not told again that they are
			-- in the water: they were told once, when they went down.
			Rescue.onHazardDown(survivor.name, "the water")
		end

	else
		survivor.panic = math.max(0, survivor.panic - ctx.config.Survivors.PanicCalmPerSecond * dt)
	end

	if survivor.state == "Downed" then
		local depth = ctx.flood.depthAt(survivor.position)
		if depth >= ctx.config.Survivors.DownedDrownDepth then
			-- Face down in standing water: this is not a bleedout to be raced, it is a drowning.
			kill(survivor, "the water")
			return
		end
		-- Waist-deep and down: cold, wet and much worse off, but still a rescue the crew can make.
		local bleed = ctx.config.Survivors.DownedBleedoutSeconds
		if depth >= ctx.config.Survivors.DownedWetDepth then
			bleed *= 0.5
		end
		if survivor.downedAt and os.clock() - survivor.downedAt > bleed then
			kill(survivor, "their injuries")
		end
		return
	end

	if survivor.panic >= ctx.config.Survivors.PanicThreshold
		and survivor.state ~= "Lost"
		and survivor.state ~= "Downed"
		and survivor.state ~= "Dead"
		and survivor.state ~= "Rescued" then
		survivor.state = "Lost"
		survivor.leader = nil
		ctx.notify(`{NAMES[survivor.name] or survivor.name} panicked and broke away.`, "bad")
		-- Count people, not panic events: a survivor who breaks away, calms down and breaks away
		-- again is still one loss in the summary.
		if not survivor.wasLost then
			survivor.wasLost = true
			Rescue.lostCount += 1
		end
		Rescue.dirty = true
	end
end

-- Nearest refuge marker that is still above the water (and its label, for the HUD).
function Rescue.bestRefuge(from: Vector3): (Vector3?, string?)
	local best, bestLabel, bestDistance = nil, nil, math.huge
	for _, part in ipairs(Rescue.refuges or {}) do
		local depth = ctx.flood.depthAt(part.Position)
		if depth <= 0.6 then
			local distance = (Vector3.new(part.Position.X, 0, part.Position.Z) - Vector3.new(from.X, 0, from.Z)).Magnitude
			if distance < bestDistance then
				best, bestLabel, bestDistance = part.Position, part:GetAttribute("RefugeLabel"), distance
			end
		end
	end
	return best, bestLabel
end

function Rescue.update(dt: number)
	for _, player in ipairs(Players:GetPlayers()) do
		Rescue.medicAura(player, dt)
	end
	for _, survivor in ipairs(Rescue.order) do
		if survivor.state == "Rescued" or survivor.state == "Dead" then
			continue
		end

		-- Carried survivors ride with their carrier.
		if survivor.state == "Carried" then
			local carrier = survivor.carriedBy
			local character = carrier and carrier.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				local rootPart = root :: BasePart
				local position = rootPart.Position + rootPart.CFrame.LookVector * -0.9 + Vector3.new(0, 0.4, 0)
				applyRig(survivor, position, math.atan2(rootPart.CFrame.LookVector.X, rootPart.CFrame.LookVector.Z), false, dt)
			else
				survivor.state = "Idle"
				survivor.carriedBy = nil
			end
			continue
		end

		-- Lift passengers are driven by LiftService.
		if survivor.boarding then
			updateDanger(survivor, dt)
			continue
		end

		local rescued, how = isRescuedZone(survivor.position)
		if rescued then
			survivor.safeSeconds += dt
			if survivor.safeSeconds >= (how == "ExtractionPad" and 1.0 or 3.0) then
				deliver(survivor, how == "ExtractionPad" and "the lift pad" or "the safe zone")
				continue
			end
			applyRig(survivor, survivor.position, survivor.yaw, false, dt)
			updateDanger(survivor, dt)
			continue
		else
			survivor.safeSeconds = 0
		end

		updateDanger(survivor, dt)
		if survivor.state == "Downed" or survivor.state == "Dead" then
			applyRig(survivor, survivor.position, survivor.yaw, false, dt)
			continue
		end

		if survivor.state == "Following" then
			local leader = survivor.leader
			local character = leader and leader.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then
				survivor.state = "Idle"
				survivor.leader = nil
			else
				local leaderPosition = (root :: BasePart).Position
				-- Children refuse to wade: past knee depth they stop and wait to be carried.
				if survivor.role == "Child" then
					local roleDef = ctx.config.Survivors.Roles.Child
					local ahead = survivor.position + (leaderPosition - survivor.position).Unit * 3
					local depth = math.max(ctx.flood.depthAt(survivor.position), ctx.flood.depthAt(ahead))
					if depth > roleDef.MaxWadeDepth then
						if not survivor.refusedAt or os.clock() - survivor.refusedAt > 6 then
							survivor.refusedAt = os.clock()
							ctx.notifyPlayer(leader, `{NAMES[survivor.name] or survivor.name}: {roleDef.MustCarryNote}`, "warn")
						end
						applyRig(survivor, survivor.position, survivor.yaw, false, dt)
						updateDanger(survivor, dt)
						continue
					end
				end
				local distance = (leaderPosition - survivor.position).Magnitude
				if distance > 110 then
					-- Anti-frustration catch-up: reunite with the leader across the district.
					local behind = leaderPosition - ((root :: BasePart).CFrame.LookVector * 5)
					applyRig(survivor, Vector3.new(behind.X, groundHeight(behind, survivor.model), behind.Z), survivor.yaw, false, dt)
					ctx.notifyPlayer(leader, `{NAMES[survivor.name] or survivor.name} caught up to you.`, "warn")
				else
					local followTarget = leaderPosition - ((root :: BasePart).CFrame.LookVector * 2.6)
					moveToward(survivor, followTarget, dt, distance > 14 and 1.35 or 1)
					if survivor.stuckSeconds > 2.5 then
						survivor.stuckSeconds = 0
						ctx.notifyPlayer(leader, `{NAMES[survivor.name] or survivor.name} is stuck — go back for them.`, "warn")
					end
				end
				if distance > ctx.config.Survivors.StrayDistance then
					survivor.panic = math.min(140, survivor.panic + ctx.config.Survivors.PanicGrowthPerSecond * 2.2 * dt)
				end
			end
		elseif survivor.state == "Lost" then
			-- Wander near where they broke away; a player can re-lead them by prompt.
			local wander = Vector3.new(
				math.sin(os.clock() * 0.7 + survivor.position.X) * 6,
				survivor.homePosition.Y,
				math.cos(os.clock() * 0.5 + survivor.position.Z) * 6
			) + survivor.homePosition
			moveToward(survivor, wander, dt, 0.85)
			if survivor.panic < 25 then
				local player, distance = nearestPlayer(survivor.position, 18)
				if player and distance < 18 then
					survivor.state = "Following"
					survivor.leader = player
					if survivor.wasLost and not survivor.recovered then
						survivor.recovered = true
						Rescue.recoveredCount += 1
						ctx.addScore(player, ctx.config.Scoring.PerSurvivor * 0.25, "regained a panicked survivor")
					end
					ctx.notifyPlayer(player, `{NAMES[survivor.name] or survivor.name} calmed down and joined you.`, "good")
					Rescue.dirty = true
				end
			end
		elseif survivor.shelter then
			-- They have run for high ground: hold there until the crew arrives.
			local refuge = survivor.shelter
			if ctx.flood.depthAt(refuge) > 0.6 then
				-- Their refuge is going under as well: pick a new one next tick.
				survivor.shelter = nil
			else
				local arrived = moveTowardHeight(survivor, refuge, dt, ctx.config.Survivors.ShelterSpeed)
				if arrived then
					applyRig(survivor, survivor.position, survivor.yaw, false, dt)
					-- Dry, off the floor and out of the current: they recover while they wait.
					survivor.health = math.min(100, survivor.health + ctx.config.Survivors.ShelterRecoverPerSecond * dt)
				end
				survivor.panic = math.max(0, survivor.panic - ctx.config.Survivors.PanicCalmPerSecond * 0.45 * dt)
			end
		else
			-- Idle patrol around their spawn.
			local offset = Vector3.new(math.sin(os.clock() * 0.4 + survivor.homePosition.X) * 2.2, 0, math.cos(os.clock() * 0.35 + survivor.position.Z) * 2.2)
			moveToward(survivor, survivor.homePosition + offset, dt, 0.5)
			if survivor.trait == "Dog" then
				local player, distance = nearestPlayer(survivor.position, 14)
				if player and distance < 14 then
					Rescue.lead(player, survivor.name)
				end
			end
		end
	end
	if Rescue.dirty then
		Rescue.pushSnapshot()
	end
end

-- ===================== snapshots =====================

function Rescue.snapshot()
	local list = {}
	for _, survivor in ipairs(Rescue.order) do
		list[#list + 1] = {
			name = survivor.name,
			label = NAMES[survivor.name] or survivor.name,
			trait = survivor.trait,
			state = survivor.state,
			health = Util.round(survivor.health, 0),
			panic = Util.round(math.min(100, survivor.panic), 0),
			position = survivor.position,
			leader = survivor.leader and survivor.leader.Name or nil,
			notes = survivor.notes,
			role = survivor.role,
			roleNote = survivor.roleNote,
			sheltering = survivor.shelter ~= nil,
			shelterLabel = survivor.shelterLabel,
			rescued = survivor.state == "Rescued",
		}
	end
	return {
		list = list,
		rescued = Rescue.rescuedCount,
		lost = Rescue.lostCount,
		dead = Rescue.deadCount,
		recovered = Rescue.recoveredCount,
		required = Rescue.requiredRescued(),
		total = ctx.config.Survivors.Total,
	}
end

function Rescue.pushSnapshot()
	Rescue.dirty = false
	ctx.remotes.SurvivorSync:FireAllClients(Rescue.snapshot())
end

local function discoverRefuges()
	Rescue.refuges = {}
	local folder = ctx.worldFolder:FindFirstChild("Refuges")
	if not folder then
		ctx.log("[Rescue] no refuge markers in the world — survivors will not seek high ground")
		return
	end
	for _, descendant in ipairs(folder:GetChildren()) do
		if descendant:IsA("BasePart") then
			table.insert(Rescue.refuges, descendant)
		end
	end
	ctx.log(`[Rescue] {#Rescue.refuges} refuge markers adopted`)
end

function Rescue.Init(context)
	ctx = context
	discoverRefuges()
end

function Rescue.Start(context)
	ctx = context
	Rescue.reset()
	RunService.Heartbeat:Connect(function(dt)
		if ctx.roundActive() then
			Rescue.update(math.min(dt, 0.2))
		end
	end)
end

return Rescue
