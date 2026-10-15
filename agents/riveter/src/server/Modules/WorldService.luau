--!strict
-- WorldService: one-time discovery of baked geometry plus the runtime water volumes.
-- Every other service reads the world through this registry instead of scanning Workspace.

local Workspace = game:GetService("Workspace")

local World = {}
World.Name = "World"

export type Zone = {
	name: string,
	model: Instance,
	min: Vector3,
	max: Vector3,
	center: Vector3,
	size: Vector3,
	sector: number,
	interior: boolean,
	floorY: number,
	roofY: number,
}

World.world = nil :: Model?
World.zones = {} :: { [string]: Zone }
World.sectorByPart = {}
World.sockets = {} :: { [string]: BasePart }
World.cells = {} :: { [string]: BasePart }
World.survivorModels = {} :: { [string]: Model }
World.props = {} :: { [string]: Instance }
World.water = {} :: { BasePart }
World.sealedZones = {} :: { [string]: boolean }
World.lift = nil :: Model?
World.spawnLocation = nil :: SpawnLocation?

local SECTORS = {
	{ name = "South", zMin = 22, zMax = 95 },
	{ name = "Mid", zMin = -32, zMax = 22 },
	{ name = "North", zMin = -95, zMax = -32 },
}

local LANDMARKS = {
	{ name = "Terminal", interior = true, sector = 2 },
	{ name = "PumpHouse", interior = true, sector = 2 },
	{ name = "ApartmentBlock", interior = true, sector = 2 },
	{ name = "Workshop", interior = true, sector = 1 },
	{ name = "Clinic", interior = true, sector = 1 },
	{ name = "RelayTower", interior = false, sector = 2 },
}

local function boundsOf(inst: Instance): (Vector3, Vector3, Vector3, Vector3)
	if inst:IsA("Model") then
		local cf, size = inst:GetBoundingBox()
		return cf.Position - size * 0.5, cf.Position + size * 0.5, cf.Position, size
	elseif inst:IsA("BasePart") then
		local size = inst.Size
		return inst.Position - size * 0.5, inst.Position + size * 0.5, inst.Position, size
	end
	return Vector3.new(0, 0, 0), Vector3.new(0, 0, 0), Vector3.new(0, 0, 0), Vector3.new(0, 0, 0)
end

function World.sectorAt(position: Vector3): number
	for index, sector in ipairs(SECTORS) do
		if position.Z >= sector.zMin and position.Z < sector.zMax then
			return index
		end
	end
	if position.Z < -32 then
		return 3
	end
	return 1
end

function World.liftTravelPosition(): Vector3
	return World.lift and World.lift:GetPivot().Position or Vector3.new(0, 0, 0)
end

function World.survivorSpawnPosition(model: Model): Vector3
	local attr = model:GetAttribute("SpawnPos")
	if typeof(attr) == "Vector3" then
		return attr
	end
	local min, max = boundsOf(model)
	return (min + max) * 0.5
end

-- Which zone contains a world point (interiors win over open ground).
function World.zoneAt(position: Vector3): Zone?
	local best: Zone? = nil
	local bestVolume = math.huge
	for _, zone in pairs(World.zones) do
		local pad = zone.interior and 0 or 1.5
		local inside = position.X >= zone.min.X - pad and position.X <= zone.max.X + pad
			and position.Z >= zone.min.Z - pad and position.Z <= zone.max.Z + pad
			and position.Y >= zone.min.Y - 3 and position.Y <= zone.max.Y + 3
		if inside then
			local volume = zone.size.X * zone.size.Y * zone.size.Z
			if zone.interior then
				volume *= 0.25 -- prefer interiors when overlapping
			end
			if volume < bestVolume then
				bestVolume = volume
				best = zone
			end
		end
	end
	return best
end

-- Water depth at a point, in studs. Interior foundations sit above street level,
-- so enclosed rooms flood a little later than the open district.
function World.depthAt(position: Vector3, level: number, sectorLevels: { number }?): number
	local sector = World.sectorAt(position)
	local localLevel = level
	if sectorLevels and sectorLevels[sector] then
		localLevel = sectorLevels[sector]
	end
	local zone = World.zoneAt(position)
	local foundation = 0
	if zone and zone.interior then
		foundation = 0.9
		if World.sealedZones[zone.name] then
			-- Sealed rooms hold the water back: the floor floods much later.
			foundation += 2.6
		end
	end
	local waterY = localLevel - foundation
	return math.max(0, waterY - position.Y)
end

function World.setSealed(zoneName: string, sealed: boolean)
	World.sealedZones[zoneName] = sealed
end

function World.createWaterVolumes(): { BasePart }
	local world = World.world
	if not world then
		return {}
	end
	local parts: { BasePart } = {}
	for index, sector in ipairs(SECTORS) do
		local part = Instance.new("Part")
		part.Name = `Water_{sector.name}`
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.fromRGB(38, 92, 128)
		part.Transparency = 0.45
		part.Size = Vector3.new(184, 2, sector.zMax - sector.zMin)
		part.Position = Vector3.new(0, -6, (sector.zMin + sector.zMax) * 0.5)
		part:SetAttribute("Sector", index)
		part:SetAttribute("IsWater", true)
		part.Parent = world
		parts[index] = part
	end

	-- A single bright surface strip sells the waterline without a real shader.
	local surface = Instance.new("Part")
	surface.Name = "WaterSurfaceMarker"
	surface.Anchored = true
	surface.CanCollide = false
	surface.CanQuery = false
	surface.CanTouch = false
	surface.Material = Enum.Material.Neon
	surface.Color = Color3.fromRGB(70, 150, 190)
	surface.Transparency = 0.72
	surface.Size = Vector3.new(184, 0.22, 176)
	surface.Position = Vector3.new(0, -5, -2)
	surface.Parent = world
	table.insert(parts, surface)

	World.water = parts
	return parts
end

function World.setWaterLevel(index: number, level: number)
	local part = World.water[index]
	if not part then
		return
	end
	local top = level
	local thickness = math.max(2, top + 8)
	part.Size = Vector3.new(part.Size.X, thickness, part.Size.Z)
	part.Position = Vector3.new(part.Position.X, top - thickness * 0.5, part.Position.Z)
end

function World.setSurfaceMarker(level: number)
	local marker = World.water[#SECTORS + 1]
	if marker then
		marker.Position = Vector3.new(0, level, -2)
	end
end

local function countKeys(t): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

function World.Init(ctx)
	local world = Workspace:WaitForChild("World", 30) :: Model?
	if not world then
		warn("[FLOODLINE] Workspace.World missing; world registry is empty")
		return
	end
	World.world = world

	for _, def in ipairs(LANDMARKS) do
		local model = world:FindFirstChild(def.name)
		if model then
			local min, max, center, size = boundsOf(model)
			local zone: Zone = {
				name = def.name,
				model = model,
				min = min,
				max = max,
				center = center,
				size = size,
				sector = def.sector,
				interior = def.interior,
				floorY = min.Y,
				roofY = max.Y,
			}
			World.zones[def.name] = zone
			World.props[def.name] = model
		end
	end

	-- Open-ground pseudo zones used by hazards and lift routing.
	local safe = world:FindFirstChild("SafeZone")
	if safe and safe:IsA("BasePart") then
		World.safeZone = safe
	end
	local gate = world:FindFirstChild("BridgeGate")
	if gate then
		World.props.BridgeGate = gate
	end
	local lift = world:FindFirstChild("EvacLift")
	if lift and lift:IsA("Model") then
		World.lift = lift
	end
	local spawn = world:FindFirstChild("SpawnLocation")
	if spawn and spawn:IsA("SpawnLocation") then
		World.spawnLocation = spawn
	end

	local socketFolder = world:FindFirstChild("Sockets")
	if not socketFolder then
		-- Sockets live inside the terminal; collect them by name prefix.
		for _, part in ipairs(world:GetDescendants()) do
			if part:IsA("BasePart") and string.sub(part.Name, 1, 7) == "Socket_" then
				World.sockets[string.sub(part.Name, 8)] = part
			elseif part:IsA("BasePart") and part.Name == "Charger" then
				World.sockets.Charger = part
			end
		end
	else
		for _, part in ipairs(socketFolder:GetChildren()) do
			if part:IsA("BasePart") then
				local key = string.sub(part.Name, 8)
				World.sockets[key ~= "" and key or part.Name] = part
			end
		end
	end

	local cellsFolder = world:FindFirstChild("Cells")
	if cellsFolder then
		for _, cell in ipairs(cellsFolder:GetChildren()) do
			if cell:IsA("BasePart") then
				World.cells[cell.Name] = cell
			end
		end
	end

	local survivorsFolder = world:FindFirstChild("Survivors")
	if survivorsFolder then
		for _, model in ipairs(survivorsFolder:GetChildren()) do
			if model:IsA("Model") then
				World.survivorModels[model.Name] = model
			end
		end
	end

	World.createWaterVolumes()

	ctx.log(`[World] zones={countKeys(World.zones)} sockets={countKeys(World.sockets)} cells={countKeys(World.cells)} survivors={countKeys(World.survivorModels)}`)
end

return World
