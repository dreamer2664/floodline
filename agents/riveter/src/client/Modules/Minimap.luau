--!strict
-- Minimap: a live top-down plan of the district drawn from the baked geometry itself.
--
-- Nothing is baked into the client: the static layer is measured from Workspace.World models
-- (so the map follows the place file), and the live layer is fed by the same snapshots the HUD
-- already receives (players, survivors, cells, sockets, routes, pings). Everything is Frames —
-- no images, no external assets.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local Minimap = {}
Minimap.Name = "Minimap"

local C = Config.Ui.Colors
local SIZE = 176 -- pixels across; the world is 200 x 200 studs
local WORLD = 200
local SCALE = SIZE / WORLD

Minimap.enabled = true
Minimap.gui = nil :: Frame?
Minimap.canvas = nil :: Frame?
Minimap.dots = {} :: { [string]: Frame }
Minimap.static = {} :: { [string]: Frame }
Minimap.pings = {} :: { { frame: Frame, until_: number } }
Minimap.state = {
	players = {},
	survivors = {},
	cells = {},
	sockets = {},
	route = nil,
	objectives = {},
	water = { level = 0 },
	power = { consumers = {}, capacity = 2 },
}
local player = Players.LocalPlayer

-- ===================== layout helpers =====================

local function px(position: Vector3): Vector2
	return Vector2.new(SIZE * 0.5 + position.X * SCALE, SIZE * 0.5 + position.Z * SCALE)
end

local function new(className: string, props: { [string]: any }, children: { Instance }?): Instance
	local instance = Instance.new(className)
	for key, value in pairs(props) do
		(instance :: any)[key] = value
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = instance
		end
	end
	return instance
end

local function rect(name: string, cx: number, cy: number, w: number, h: number, color: Color3, transparency: number, rotation: number?): Frame
	return new("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(cx, cy),
		Size = UDim2.fromOffset(math.max(2, w), math.max(2, h)),
		BackgroundColor3 = color,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		Rotation = rotation or 0,
		ZIndex = 2,
	}) :: Frame
end

-- ===================== static layer =====================

-- Measure a model's footprint straight from its parts so the plan always matches the place.
local function footprint(model: Instance): (Vector3?, Vector3?)
	local min: Vector3? = nil
	local max: Vector3? = nil
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local size = descendant.Size
			local position = descendant.Position
			local lo = position - size * 0.5
			local hi = position + size * 0.5
			if not min or not max then
				min, max = lo, hi
			else
				min = Vector3.new(math.min(min.X, lo.X), math.min(min.Y, lo.Y), math.min(min.Z, lo.Z))
				max = Vector3.new(math.max(max.X, hi.X), math.max(max.Y, hi.Y), math.max(max.Z, hi.Z))
			end
		end
	end
	if not min or not max then
		return nil
	end
	return min, max
end

local LANDMARK_COLORS: { [string]: { color: Color3, transparency: number } } = {
	Terminal = { color = Color3.fromRGB(84, 96, 112), transparency = 0.25 },
	PumpHouse = { color = Color3.fromRGB(96, 84, 72), transparency = 0.25 },
	ApartmentBlock = { color = Color3.fromRGB(92, 92, 108), transparency = 0.25 },
	Workshop = { color = Color3.fromRGB(104, 92, 70), transparency = 0.3 },
	Clinic = { color = Color3.fromRGB(88, 116, 104), transparency = 0.25 },
	RelayTower = { color = Color3.fromRGB(120, 124, 136), transparency = 0.35 },
	ParkingGarage = { color = Color3.fromRGB(80, 84, 96), transparency = 0.3 },
	FerryTerminal = { color = Color3.fromRGB(84, 108, 120), transparency = 0.25 },
	ServiceCut = { color = Color3.fromRGB(140, 120, 84), transparency = 0.3 },
	EvacComplex = { color = Color3.fromRGB(90, 190, 140), transparency = 0.35 },
	Docks = { color = Color3.fromRGB(70, 92, 108), transparency = 0.4 },
	BridgeGate = { color = Color3.fromRGB(150, 68, 62), transparency = 0.35 },
}

function Minimap.buildWorld()
	local world = Workspace:FindFirstChild("World")
	if not world then
		return
	end
	if Minimap.canvas then
		Minimap.canvas:ClearAllChildren()
		Minimap.static = {}
		local bg = rect("MapBg", SIZE * 0.5, SIZE * 0.5, SIZE, SIZE, Color3.fromRGB(16, 20, 26), 0.05)
		bg.ZIndex = 1
		bg.Parent = Minimap.canvas
		local water = rect("MapWater", SIZE * 0.5, SIZE * 0.5, SIZE, SIZE, Config.Fx.WaterColor, 0.75)
		water.ZIndex = 2
		water.Parent = Minimap.canvas
		Minimap.static.Water = water
	end
	local target = Minimap.canvas
	if not target then
		return
	end
	-- district frame: ground, roads, canal, sea wall, pier
	local function namedRect(name: string, color: Color3, transparency: number, zIndex: number)
		local part = Util.find(world:GetDescendants(), function(instance)
			return instance.Name == name and instance:IsA("BasePart")
		end)
		if not part then
			return
		end
		local size = (part :: BasePart).Size
		local point = px((part :: BasePart).Position)
		local frame = rect(name .. "Rect", point.X, point.Y, size.X * SCALE, size.Z * SCALE, color, transparency)
		frame.ZIndex = zIndex
		frame.Parent = target
		Minimap.static[name] = frame
	end
	namedRect("StreetNS", Color3.fromRGB(58, 62, 72), 0.35, 2)
	namedRect("StreetEW", Color3.fromRGB(58, 62, 72), 0.35, 2)
	namedRect("CanalBed", Color3.fromRGB(26, 66, 96), 0.25, 3)
	namedRect("SeaWall", Color3.fromRGB(40, 46, 56), 0.2, 3)
	namedRect("PierDeck", Color3.fromRGB(112, 96, 74), 0.3, 3)
	for name, spec in pairs(LANDMARK_COLORS) do
		local model = world:FindFirstChild(name)
		if not model then
			continue
		end
		local min, max = footprint(model)
		if not min or not max then
			continue
		end
		local center = (min + max) * 0.5
		local size = max - min
		local point = px(center)
		local frame = rect(name .. "Plan", point.X, point.Y, size.X * SCALE, size.Z * SCALE, spec.color, spec.transparency)
		frame.ZIndex = 4
		frame.Parent = target
		Minimap.static[name] = frame
	end
	-- the two routes are drawn as connectors so their state reads at a glance
	local sky = world:FindFirstChild("Skybridge")
	if sky then
		local delta = Config.Route.Skybridge.FarJoint - Config.Route.Skybridge.NearJoint
		local center = (Config.Route.Skybridge.NearJoint + Config.Route.Skybridge.FarJoint) * 0.5
		local length = delta.Magnitude
		local yaw = math.deg(math.atan2(delta.X, delta.Z))
		local point = px(center)
		local frame = rect("SkybridgeLine", point.X, point.Y, 3, length * SCALE, C.Accent, 0.15, -yaw)
		frame.ZIndex = 5
		frame.Parent = target
		Minimap.static.Skybridge = frame
	end
end

-- ===================== dots =====================

local function dot(key: string, color: Color3, size: number, zIndex: number): Frame
	local existing = Minimap.dots[key]
	if existing then
		return existing
	end
	local frame = rect("Dot_" .. key, 0, 0, size, size, color, 0, 0)
	frame.Visible = false
	frame.ZIndex = zIndex
	frame.Parent = Minimap.canvas
	Minimap.dots[key] = frame
	return frame
end

local STATE_COLORS: { [string]: Color3 } = {
	Idle = Color3.fromRGB(120, 190, 240),
	Following = Color3.fromRGB(90, 220, 150),
	Assisting = Color3.fromRGB(90, 220, 150),
	Carried = Color3.fromRGB(160, 230, 190),
	Downed = Color3.fromRGB(240, 180, 60),
	Lost = Color3.fromRGB(230, 120, 90),
	Rescued = Color3.fromRGB(90, 120, 90),
	Dead = Color3.fromRGB(120, 60, 60),
}

local function place(frame: Frame, position: Vector3, visible: boolean)
	if typeof(position) ~= "Vector3" then
		frame.Visible = false
		return
	end
	local point = px(position)
	frame.Position = UDim2.fromOffset(point.X, point.Y)
	frame.Visible = visible
end

function Minimap.setState(patch: any)
	for key, value in pairs(patch) do
		Minimap.state[key] = value
	end
end

function Minimap.addPing(payload: any)
	if not (payload and typeof(payload.position) == "Vector3") then
		return
	end
	local tone = payload.tone or payload.color
	local color = (tone == "bad" and C.Bad) or (tone == "good" and C.Good) or (tone == "Water" and C.Water) or C.Accent
	local frame = rect("Ping", 0, 0, 6, 6, color, 0.1, 45)
	frame.ZIndex = 8
	frame.Parent = Minimap.canvas
	place(frame, payload.position, true)
	table.insert(Minimap.pings, {
		frame = frame,
		until_ = os.clock() + (payload.lifetime or Config.Pings.Lifetime),
	})
end

-- ===================== per frame =====================

function Minimap.update()
	if not Minimap.enabled or not Minimap.canvas then
		return
	end
	local now = os.clock()
	-- pings age out
	for index = #Minimap.pings, 1, -1 do
		local entry = Minimap.pings[index]
		if now >= entry.until_ then
			entry.frame:Destroy()
			table.remove(Minimap.pings, index)
		else
			entry.frame.BackgroundTransparency = 0.1 + 0.5 * math.abs(math.sin(now * 4))
		end
	end
	-- players
	local seen = {}
	for _, other in ipairs(Players:GetPlayers()) do
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local isLocal = other == player
			local frame = dot(`p_{other.Name}`, isLocal and Color3.fromRGB(255, 255, 255) or C.Water, isLocal and 7 or 6, 9)
			place(frame, (root :: BasePart).Position, true)
			frame.BackgroundTransparency = 0
			seen[`p_{other.Name}`] = true
		end
	end
	for key, frame in pairs(Minimap.dots) do
		if string.sub(key, 1, 2) == "p_" and not seen[key] then
			frame.Visible = false
		end
	end
	-- local player heading: a short bar sticking out of the dot
	local localDot = Minimap.dots[`p_{player.Name}`]
	if localDot then
		local camera = Workspace.CurrentCamera
		if camera then
			local look = camera.CFrame.LookVector
			local angle = math.deg(math.atan2(look.X, -look.Z))
			localDot.Rotation = angle
		end
	end
	-- survivors
	local survivors = Minimap.state.survivors or {}
	for index, entry in ipairs(survivors.list or {}) do
		local frame = dot(`s_{index}`, STATE_COLORS[entry.state] or C.TextDim, 5, 7)
		local visible = entry.state ~= "Rescued" and entry.state ~= "Dead" and entry.state ~= "Carried"
		place(frame, entry.position, visible)
	end
	-- power cells and sockets
	local power = Minimap.state.power or {}
	for id, cell in pairs(power.cells or {}) do
		local frame = dot(`c_{id}`, cell.destroyed and C.Bad or C.Warn, 5, 6)
		local visible = not cell.destroyed and not cell.holder
		place(frame, cell.position, visible)
	end
	for key, socket in pairs(power.sockets or {}) do
		local frame = dot(`k_{key}`, socket.tripped and C.Bad or C.Accent, 4, 6)
		place(frame, socket.position, true)
	end
	-- objectives: only the active target, so the map stays readable
	local objectives = Minimap.state.objectives or {}
	local shown = 0
	for _, entry in ipairs(objectives) do
		if entry.status == "active" and typeof(entry.target) == "Vector3" and shown < 2 then
			shown += 1
			local frame = dot(`o_{entry.id}`, C.Good, 6, 8)
			place(frame, entry.target, true)
		end
	end
	for key, frame in pairs(Minimap.dots) do
		if string.sub(key, 1, 2) == "o_" then
			local id = string.sub(key, 3)
			local stillActive = false
			for _, entry in ipairs(objectives) do
				if entry.id == id and entry.status == "active" then
					stillActive = true
					break
				end
			end
			if not stillActive then
				frame.Visible = false
			end
		end
	end
	-- route state: dashed line when retracted, solid when walkable
	local sky = Minimap.static.Skybridge
	local route = Minimap.state.route
	if sky and route then
		sky.BackgroundTransparency = 0.75 - 0.6 * math.clamp((route.extended or 0) / 100, 0, 1)
		sky.BackgroundColor3 = route.crossable and C.Good or C.Accent
	end
	local cut = Minimap.static.ServiceCut
	if cut and route then
		cut.BackgroundColor3 = route.cutOpen and C.Good or Color3.fromRGB(180, 110, 90)
		cut.BackgroundTransparency = route.cutOpen and 0.25 or 0.55
	end
	-- water tint follows the flood level so the plan reads as "how bad is it"
	local waterFrame = Minimap.static.Water
	if waterFrame then
		local level = (Minimap.state.water and Minimap.state.water.level) or 0
		local ratio = math.clamp(level / Config.Water.MaxLevel, 0, 1)
		waterFrame.BackgroundTransparency = 0.9 - ratio * 0.55
		waterFrame.BackgroundColor3 = Config.Fx.WaterColor
	end
end

function Minimap.toggle(): boolean
	Minimap.enabled = not Minimap.enabled
	if Minimap.gui then
		Minimap.gui.Visible = Minimap.enabled
	end
	return Minimap.enabled
end

function Minimap.build(parentGui: Instance): Frame
	local gui = new("Frame", {
		Name = "Minimap",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.fromOffset(SIZE + 8, SIZE + 8),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, {
		new("UICorner", { CornerRadius = UDim.new(0, 10) }),
		new("UIStroke", { Color = C.PanelLight, Thickness = 1, Transparency = 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	}) :: Frame
	local canvas = new("Frame", {
		Name = "Canvas",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(SIZE, SIZE),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = 3,
	}) :: Frame
	canvas.Parent = gui
	local bg = rect("MapBg", SIZE * 0.5, SIZE * 0.5, SIZE, SIZE, Color3.fromRGB(16, 20, 26), 0.05)
	bg.ZIndex = 1
	bg.Parent = canvas
	local water = rect("MapWater", SIZE * 0.5, SIZE * 0.5, SIZE, SIZE, Config.Fx.WaterColor, 0.9)
	water.ZIndex = 2
	water.Parent = canvas
	Minimap.static.Water = water
	Minimap.gui = gui
	Minimap.canvas = canvas
	gui.Parent = parentGui
	return gui
end

function Minimap.Init(parentGui: Instance)
	Minimap.build(parentGui)
	local ok, err = pcall(Minimap.buildWorld)
	if not ok then
		warn(`[FLOODLINE] minimap world layer failed: {err}`)
	end
	-- Draw early so the plan is on screen even before the first snapshot arrives.
	Minimap.update()
	return Minimap.gui
end

function Minimap.snapshot(): { [string]: any }
	return {
		enabled = Minimap.enabled,
		dots = (function()
			local count = 0
			for _, frame in pairs(Minimap.dots) do
				if frame.Visible then
					count += 1
				end
			end
			return count
		end)(),
		statics = (function()
			local count = 0
			for _ in pairs(Minimap.static) do
				count += 1
			end
			return count
		end)(),
		pings = #Minimap.pings,
	}
end

return Minimap
