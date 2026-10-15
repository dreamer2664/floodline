--!nocheck
-- roblox_stub.luau — a minimal, faithful-enough Roblox runtime for headless testing.
--
-- It implements exactly the API surface the FLOODLINE server uses: an Instance tree with the
-- class relationships the game relies on, Vector3/CFrame/Color3 math, the DataModel services,
-- and a VIRTUAL CLOCK so a full 9-minute round can be simulated in a fraction of a second.
--
-- This is a test double, not an engine. It cannot validate rendering, physics contacts or
-- networking latency; those stay NOT RUN and are reported as such.

local Stub = {}

-- ============================================================
-- virtual clock
-- ============================================================
local clock = 0
local scheduled: { { at: number, fn: () -> () } } = {}
local clockHooks: { (number) -> () } = {}
local services = {}
local RunService

function Stub.clock()
	return clock
end

local advancing = false

function Stub.advance(seconds: number, step: number?)
	if advancing then
		-- Nested advance (task.wait inside a handler): only move the clock; the outer loop
		-- keeps draining the scheduled queue.
		clock += seconds
		return
	end
	advancing = true
	local stepSize = step or 1 / 30
	local remaining = seconds
	while remaining > 0 do
		local dt = math.min(stepSize, remaining)
		remaining -= dt
		clock += dt
		-- delayed tasks first, so delayed logic sees the advanced clock
		local ready = {}
		for index, entry in ipairs(scheduled) do
			if entry.at <= clock then
				table.insert(ready, index)
			end
		end
		for index = #ready, 1, -1 do
			local entry = table.remove(scheduled, ready[index])
			if entry and entry.fn then
				local ok, err = pcall(entry.fn)
				if not ok then
					warn("[stub] scheduled task error: " .. tostring(err))
				end
			end
		end
		RunService.Heartbeat:Fire(dt)
		RunService.RenderStepped:Fire(dt)
		for _, hook in ipairs(clockHooks) do
			local ok, err = pcall(hook, dt)
			if not ok then
				warn("[stub] hook error: " .. tostring(err))
			end
		end
	end
	advancing = false
end

function Stub.onStep(fn: (number) -> ())
	table.insert(clockHooks, fn)
end

-- ============================================================
-- datatypes
-- ============================================================
local Vector3 = {}
Vector3.__index = Vector3

local function v3(x: number, y: number, z: number)
	return setmetatable({ X = x, Y = y, Z = z }, Vector3)
end

Vector3.__add = function(a, b)
	return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__sub = function(a, b)
	return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__mul = function(a, b)
	if type(b) == "number" then
		return v3(a.X * b, a.Y * b, a.Z * b)
	elseif type(a) == "number" then
		return v3(b.X * a, b.Y * a, b.Z * a)
	end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3.__div = function(a, b)
	return v3(a.X / b, a.Y / b, a.Z / b)
end
Vector3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.__tostring = function(a)
	return string.format("(%g, %g, %g)", a.X, a.Y, a.Z)
end
Vector3.__index = function(self, key)
	if key == "Magnitude" then
		return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
	elseif key == "Unit" then
		local m = math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2)
		if m == 0 then
			return v3(0, 0, 0)
		end
		return v3(self.X / m, self.Y / m, self.Z / m)
	end
	return rawget(Vector3, key)
end

local CFrame = {}
local cf

local CFrameMT = {}

function CFrameMT.__index(tbl, key)
	if key == "X" then
		return tbl.Position.X
	elseif key == "Y" then
		return tbl.Position.Y
	elseif key == "Z" then
		return tbl.Position.Z
	elseif key == "LookVector" then
		return tbl._look
	end
	return rawget(CFrame, key)
end

function CFrameMT.__mul(a, b)
	if getmetatable(b) == Vector3 then
		return a.Position + b
	end
	local look = b.LookVector or v3(0, 0, -1)
	local offset = a._look or v3(0, 0, -1)
	return cf(
		a.Position + (b.Position or v3(0, 0, 0)),
		v3(offset.X * (1 + look.X * 0), offset.Y, offset.Z)
	)
end

function CFrameMT.__add(a, b)
	return cf(a.Position + b)
end

function CFrameMT.__sub(a, b)
	return cf(a.Position - b.Position)
end

function CFrameMT.__tostring(self)
	return tostring(self.Position)
end

cf = function(...)
	local args = { ... }
	local position = v3(0, 0, 0)
	local look = v3(0, 0, -1)
	local right = v3(1, 0, 0)
	local up = v3(0, 1, 0)
	if #args == 1 and type(args[1]) == "table" then
		position = args[1]
	elseif #args == 3 then
		position = v3(args[1], args[2], args[3])
	elseif #args == 4 and type(args[1]) == "table" then
		position = args[1]
		local lookup = args[2]
		local m = math.sqrt(lookup.X ^ 2 + lookup.Y ^ 2 + lookup.Z ^ 2)
		if m > 0 then
			look = v3(lookup.X / m, lookup.Y / m, lookup.Z / m)
		end
	end
	local self = setmetatable({
		Position = position,
		LookVector = look,
		RightVector = right,
		UpVector = up,
	}, CFrameMT)
	self._look = look
	return self
end

function CFrame.new(a, b, c)
	if type(a) == "table" and type(b) == "table" and type(c) == "table" then
		-- CFrame.new(pos, lookAt)
		local look = b - a
		return cf(a, look)
	end
	if type(a) == "table" and b == nil then
		return cf(a)
	end
	return cf(a or 0, b or 0, c or 0)
end

function CFrame.Angles(x, y, z)
	local self = cf(0, 0, 0)
	self._angles = { x, y, z }
	self.LookVector = v3(math.sin(y or 0), 0, -math.cos(y or 0))
	return self
end

function CFrame.fromEulerAnglesXYZ(x, y, z)
	return CFrame.Angles(x, y, z)
end

CFrame.__mul = function(a, b)
	if getmetatable(b) == Vector3 then
		return a.Position + b
	end
	local look = b.LookVector or v3(0, 0, -1)
	local rotated = v3(
		look.X * (a.LookVector.X ~= 0 and math.abs(a.LookVector.X) or 1),
		look.Y,
		look.Z * (a.LookVector.Z ~= 0 and math.abs(a.LookVector.Z) or 1)
	)
	return cf(a.Position + (b.Position or v3(0, 0, 0)), rotated)
end

CFrame.__add = function(a, b)
	return cf(a.Position + b)
end

CFrame.__sub = function(a, b)
	return cf(a.Position - b.Position)
end

function CFrame.Lerp(a, b, t)
	return cf(a.Position + (b.Position - a.Position) * t, b.LookVector or a.LookVector)
end

function CFrame.ToObjectSpace(self, other)
	local position = other.Position and (other.Position - self.Position) or (other - self.Position)
	return cf(position)
end

function CFrame.Inverse(self)
	return cf(v3(-self.Position.X, -self.Position.Y, -self.Position.Z))
end

local Color3 = {}
Color3.__index = Color3
function Color3.new(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3)
end
function Color3.fromRGB(r, g, b)
	return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3.Lerp(a, b, t)
	return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end
Color3.__mul = function(a, b)
	if type(b) == "number" then
		return Color3.new(a.R * b, a.G * b, a.B * b)
	end
	return a
end

local UDim = {}
UDim.__index = UDim
function UDim.new(scale, offset)
	return setmetatable({ Scale = scale or 0, Offset = offset or 0 }, UDim)
end

local UDim2 = {}
UDim2.__index = UDim2
function UDim2.new(xScale, xOffset, yScale, yOffset)
	return setmetatable({
		X = UDim.new(xScale or 0, xOffset or 0),
		Y = UDim.new(yScale or 0, yOffset or 0),
	}, UDim2)
end
function UDim2.fromScale(x, y)
	return UDim2.new(x, 0, y, 0)
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x, 0, y)
end

local Vector2 = {}
Vector2.__index = Vector2
function Vector2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0 }, Vector2)
end

local Enum = setmetatable({}, {
	__index = function(_, group)
		return setmetatable({}, {
			__index = function(_, item)
				return { Name = item, EnumType = group }
			end,
		})
	end,
})

-- ============================================================
-- signals
-- ============================================================
local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ handlers = {} }, Signal)
end
function Signal:Connect(fn)
	table.insert(self.handlers, fn)
	return { Disconnect = function() end, Connected = true }
end
function Signal:Wait()
	return nil
end
function Signal:Fire(...)
	for _, fn in ipairs(self.handlers) do
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[stub] signal handler error: " .. tostring(err))
		end
	end
end

-- ============================================================
-- instances
-- ============================================================
local CLASS_PARENTS: { [string]: string } = {
	Instance = "",
	BasePart = "Instance",
	Part = "BasePart",
	TrussPart = "BasePart",
	Seat = "BasePart",
	SpawnLocation = "BasePart",
	Model = "Instance",
	Folder = "Instance",
	Humanoid = "Instance",
	ProximityPrompt = "Instance",
	Script = "Instance",
	LocalScript = "Instance",
	ModuleScript = "Instance",
	StringValue = "Instance",
	IntValue = "Instance",
	NumberValue = "Instance",
	BoolValue = "Instance",
	Sound = "Instance",
	BillboardGui = "Instance",
	ScreenGui = "Instance",
	Frame = "Instance",
	TextLabel = "Instance",
	RemoteEvent = "Instance",
	RemoteFunction = "Instance",
	Attachment = "Instance",
	ForceField = "Instance",
}

local Instance = {}

local function newInstance(className: string)
	local self = {
		ClassName = className,
		Name = className,
		Parent = nil,
		Children = {},
		Attributes = {},
		Value = 0,
		Size = v3(1, 1, 1),
		Position = v3(0, 0, 0),
		CFrame = cf(0, 0, 0),
		Color = Color3.new(1, 1, 1),
		Material = Enum.Material.Plastic,
		Transparency = 0,
		Anchored = true,
		CanCollide = true,
		CanQuery = true,
		CanTouch = true,
		CastShadow = false,
		Shape = Enum.PartType.Block,
		Health = 100,
		MaxHealth = 100,
		WalkSpeed = 16,
		JumpPower = 50,
		UseJumpPower = true,
		BreakJointsOnDeath = true,
		SeatPart = nil,
		AssemblyLinearVelocity = v3(0, 0, 0),
		AssemblyLinearVelocityOverride = nil,
		CameraOffset = v3(0, 0, 0),
		Source = "",
		Enabled = true,
		ActionText = "",
		ObjectText = "",
		HoldDuration = 0,
		MaxActivationDistance = 10,
		IgnoreWater = false,
		FilterType = Enum.RaycastFilterType.Exclude,
		FilterDescendantsInstances = {},
		Triggered = Signal.new(),
		PromptShown = Signal.new(),
		Touched = Signal.new(),
		Died = Signal.new(),
		HealthChanged = Signal.new(),
		ChildAdded = Signal.new(),
		MouseButton1Click = Signal.new(),
		Activated = Signal.new(),
		OnServerEvent = Signal.new(),
		OnClientEvent = Signal.new(),
		_sent = {},
	}

	-- Remote traffic is recorded so scenarios can assert on what the server announced.
	function self:FireAllClients(...)
		table.insert(self._sent, { mode = "all", args = table.pack(...) })
	end
	function self:FireClient(target, ...)
		table.insert(self._sent, { mode = "client", target = target, args = table.pack(...) })
	end
	function self:FireServer(player, ...)
		table.insert(self._sent, { mode = "server", player = player, args = table.pack(...) })
	end
	function self:InvokeServer(...)
		table.insert(self._sent, { mode = "invoke", args = table.pack(...) })
		return nil
	end
	self.Position = self.CFrame.Position
	return self
end

local instanceMethods = {}

function instanceMethods.creator(class: string)
	return function()
		return newInstance(class)
	end
end

Instance.new = function(className: string, parent: Instance?)
	local instance = newInstance(className)
	if parent then
		instance.Parent = parent
	end
	return instance
end

function newProxy(self)
	return setmetatable(self, {
		__index = function(tbl, key)
			local method = instanceMethods[key]
			if method then
				return function(this, ...)
					return method(this, ...)
				end
			end
			local raw = rawget(tbl, key)
			if raw ~= nil then
				return raw
			end
			-- child lookup by name
			for _, child in ipairs(tbl.Children or {}) do
				if child.Name == key then
					return child
				end
			end
			return nil
		end,
		__newindex = function(tbl, key, value)
			if key == "Parent" then
				local previous = rawget(tbl, "Parent")
				if previous and previous.Children then
					for index, child in ipairs(previous.Children) do
						if child == tbl then
							table.remove(previous.Children, index)
							break
						end
					end
				end
				rawset(tbl, "Parent", value)
				if value and value.Children then
					table.insert(value.Children, tbl)
				end
				return
			end
			if key == "Position" then
				rawset(tbl, "Position", value)
				if rawget(tbl, "CFrame") then
					rawget(tbl, "CFrame").Position = value
				end
				return
			end
			if key == "CFrame" then
				rawset(tbl, "CFrame", value)
				rawset(tbl, "Position", value.Position)
				return
			end
			rawset(tbl, key, value)
		end,
	})
end

function instanceMethods.IsA(self, class)
	local current = self.ClassName
	while current do
		if current == class then
			return true
		end
		current = CLASS_PARENTS[current]
	end
	return false
end

function instanceMethods.GetChildren(self)
	local copy = {}
	for _, child in ipairs(self.Children) do
		table.insert(copy, child)
	end
	return copy
end

function instanceMethods.GetDescendants(self)
	local out = {}
	local function walk(node)
		for _, child in ipairs(node.Children) do
			table.insert(out, child)
			walk(child)
		end
	end
	walk(self)
	return out
end

function instanceMethods.FindFirstChild(self, name)
	for _, child in ipairs(self.Children) do
		if child.Name == name then
			return child
		end
	end
	return nil
end

function instanceMethods.FindFirstChildOfClass(self, class)
	local best
	for _, child in ipairs(self.Children) do
		if child:IsA(class) then
			-- prefer the most derived match like Roblox does
			if not best or CLASS_PARENTS[child.ClassName] == best.ClassName then
				best = best or child
				if child.ClassName == class then
					return child
				end
			end
		end
	end
	return best
end

function instanceMethods.WaitForChild(self, name)
	for _ = 1, 5 do
		local child = self:FindFirstChild(name)
		if child then
			return child
		end
		Stub.advance(0.1)
	end
	return nil
end

function instanceMethods.Destroy(self)
	Stub.destroy(self)
end

function instanceMethods.ClearAllChildren(self)
	for _, child in ipairs(self:GetChildren()) do
		Stub.destroy(child)
	end
end

function instanceMethods.GetFullName(self)
	local parts = {}
	local node = self
	while node do
		table.insert(parts, 1, node.Name)
		node = rawget(node, "Parent")
	end
	return table.concat(parts, ".")
end

function instanceMethods.GetAttribute(self, key)
	local attributes = self.Attributes or {}
	return attributes[key]
end

function instanceMethods.SetAttribute(self, key, value)
	self.Attributes = self.Attributes or {}
	self.Attributes[key] = value
end

function instanceMethods.GetPivot(self)
	if self:IsA("Model") then
		-- Roblox pivots a model on its bounding box, so mirror that.
		local boundingCFrame = self:GetBoundingBox()
		return cf(boundingCFrame.Position)
	end
	return cf(self.CFrame and self.CFrame.Position or self.Position or v3(0, 0, 0))
end

function instanceMethods.PivotTo(self, cframe)
	local delta = cframe.Position - self:GetPivot().Position
	for _, descendant in ipairs(self:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Position = descendant.Position + delta
			descendant.CFrame = cf(descendant.Position)
		end
	end
	if self:IsA("BasePart") then
		self.Position = self.Position + delta
	end
	self.CFrame = cf((self.CFrame or cf(0, 0, 0)).Position + delta)
end

function instanceMethods.GetBoundingBox(self)
	local min, max
	for _, descendant in ipairs(self:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local half = descendant.Size * 0.5
			local lo = descendant.Position - half
			local hi = descendant.Position + half
			min = min or lo
			max = max or hi
			min = v3(math.min(min.X, lo.X), math.min(min.Y, lo.Y), math.min(min.Z, lo.Z))
			max = v3(math.max(max.X, hi.X), math.max(max.Y, hi.Y), math.max(max.Z, hi.Z))
		end
	end
	if not min then
		local half = self.Size * 0.5
		min = self.Position - half
		max = self.Position + half
	end
	local size = max - min
	return cf((min + max) * 0.5), size
end

function instanceMethods.TakeDamage(self, amount)
	local health = self.Health - amount
	self.Health = math.max(0, health)
	self.HealthChanged:Fire(self.Health)
	if self.Health <= 0 then
		self.Died:Fire()
	end
end

function instanceMethods.ChangeState(self, state)
	self._state = state
end

function instanceMethods.Play(self)
	self._playing = true
end

function instanceMethods.GetPropertyChangedSignal(self, property)
	return Signal.new()
end

function Stub.destroy(instance)
	for _, child in ipairs(instance:GetChildren()) do
		Stub.destroy(child)
	end
	local parent = rawget(instance, "Parent")
	if parent and parent.Children then
		for index, child in ipairs(parent.Children) do
			if child == instance then
				table.remove(parent.Children, index)
				break
			end
		end
	end
	rawset(instance, "Parent", nil)
	rawset(instance, "_destroyed", true)
end

-- Instances constructed through Instance.new must also get the method table, and the
-- exposed Stub.Instance must always dispatch to the current implementation.
local originalNew = Instance.new
Instance.new = function(className, parent)
	return newProxy(originalNew(className, parent))
end

Stub.Instance = {
	new = function(className, parent)
		return Instance.new(className, parent)
	end,
}

-- ============================================================
-- services
-- ============================================================
local function service(name: string)
	local existing = services[name]
	if existing then
		return existing
	end
	local base = Instance.new(name == "Workspace" and "Workspace" or "Instance", nil)
	base.Name = name
	services[name] = base
	return base
end

local Players = service("Players")
Players._players = {}
Players.GetPlayers = function(self)
	return self._players
end
Players.PlayerAdded = Signal.new()
Players.PlayerRemoving = Signal.new()

RunService = service("RunService")
RunService.Heartbeat = Signal.new()
RunService.RenderStepped = Signal.new()
RunService.IsServer = function()
	return true
end

local Workspace = service("Workspace")

-- Axis-aligned slab test so the stub can raycast against the real baked district.
local function rayAABB(origin, direction, center, size)
	local half = size * 0.5
	local tmin, tmax = 0, math.huge
	local axes = { { origin.X, direction.X, center.X, half.X }, { origin.Y, direction.Y, center.Y, half.Y }, { origin.Z, direction.Z, center.Z, half.Z } }
	for _, axis in ipairs(axes) do
		local o, d, c, h = axis[1], axis[2], axis[3], axis[4]
		if math.abs(d) < 1e-8 then
			if o < c - h or o > c + h then
				return nil
			end
		else
			local t1 = (c - h - o) / d
			local t2 = (c + h - o) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin = math.max(tmin, t1)
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	if tmax < 0 then
		return nil
	end
	return tmin > 0 and tmin or tmax
end

Workspace.Raycast = function(self, origin, direction, params)
	local ignore: { [any]: boolean } = {}
	if params then
		for _, instance in ipairs(params.FilterDescendantsInstances or {}) do
			ignore[instance] = true
			for _, descendant in ipairs(instance:GetDescendants()) do
				ignore[descendant] = true
			end
		end
	end
	local best, bestT = nil, math.huge
	for _, descendant in ipairs(self:GetDescendants()) do
		if descendant:IsA("BasePart") and descendant.CanQuery and not ignore[descendant] then
			local t = rayAABB(origin, direction, descendant.Position, descendant.Size)
			if t and t > 0 and t < bestT then
				best, bestT = descendant, t
			end
		end
	end
	if best then
		return {
			Position = origin + direction * bestT,
			Instance = best,
			Distance = bestT * direction.Magnitude,
		}
	end
	return nil
end

local ServerStorage = service("ServerStorage")
local ReplicatedStorage = service("ReplicatedStorage")
local CollectionService = service("CollectionService")
CollectionService.GetTagged = function()
	return {}
end
local HttpService = service("HttpService")
HttpService.JSONEncode = function(_, value)
	-- tiny encoder good enough for the telemetry payload
	local function encode(input)
		local kind = type(input)
		if kind == "number" then
			return tostring(input)
		elseif kind == "string" then
			return '"' .. input:gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
		elseif kind == "boolean" then
			return tostring(input)
		elseif kind == "table" then
			local isArray = #input > 0
			local parts = {}
			if isArray then
				for _, item in ipairs(input) do
					table.insert(parts, encode(item))
				end
				return "[" .. table.concat(parts, ",") .. "]"
			end
			for key, value in pairs(input) do
				table.insert(parts, '"' .. tostring(key) .. '":' .. encode(value))
			end
			return "{" .. table.concat(parts, ",") .. "}"
		end
		return "null"
	end
	return encode(value)
end

local UserInputService = service("UserInputService")
UserInputService.TouchEnabled = false
UserInputService.KeyboardEnabled = true
UserInputService.InputBegan = Signal.new()
UserInputService.InputEnded = Signal.new()

local ContextActionService = service("ContextActionService")
ContextActionService._bindings = {}
ContextActionService.BindAction = function(self, name, handler, createTouchButton, ...)
	self._bindings[name] = { handler = handler, keys = { ... } }
end
ContextActionService.UnbindAction = function(self, name)
	self._bindings[name] = nil
end
ContextActionService.BindActionAtPriority = ContextActionService.BindAction

local Lighting = service("Lighting")

local TweenService = service("TweenService")
TweenService.Create = function()
	return { Play = function() end, Cancel = function() end, Completed = Signal.new() }
end

local Game = service("game")
Game.GetService = function(_, name)
	if name == "Players" then
		return Players
	elseif name == "RunService" then
		return RunService
	elseif name == "Workspace" then
		return Workspace
	elseif name == "ReplicatedStorage" then
		return ReplicatedStorage
	elseif name == "ServerStorage" then
		return ServerStorage
	elseif name == "CollectionService" then
		return CollectionService
	elseif name == "HttpService" then
		return HttpService
	elseif name == "UserInputService" then
		return UserInputService
	elseif name == "ContextActionService" then
		return ContextActionService
	elseif name == "Lighting" then
		return Lighting
	elseif name == "TweenService" then
		return TweenService
	elseif name == "GuiService" then
		return service("GuiService")
	end
	return service(name)
end

function Stub.player(name: string)
	local player = Instance.new("Instance")
	player.Name = name
	player.ClassName = "Player"
	player.Character = nil
	player.UserId = #Players._players + 1
	return player
end

function Stub.addPlayer(name: string)
	local player = Stub.player(name)
	table.insert(Players._players, player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	stats.Parent = player
	local rescued = Instance.new("IntValue")
	rescued.Name = "Rescued"
	rescued.Parent = stats
	local score = Instance.new("IntValue")
	score.Name = "Score"
	score.Parent = stats
	local playerGui = Instance.new("Instance")
	playerGui.Name = "PlayerGui"
	playerGui.Parent = player
	local character = Stub.spawnCharacter(player, v3(0, 3, -12))
	Players.PlayerAdded:Fire(player)
	return player, character
end

function Stub.removePlayer(player)
	for index, entry in ipairs(Players._players) do
		if entry == player then
			table.remove(Players._players, index)
			break
		end
	end
	Players.PlayerRemoving:Fire(player)
end

function Stub.spawnCharacter(player, position)
	local character = Instance.new("Model")
	character.Name = player.Name
	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.Parent = character
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = v3(2, 2, 1)
	root.CanCollide = false
	root.Position = position
	root.Parent = character
	for _, limbName in ipairs({ "Head", "Torso" }) do
		local limb = Instance.new("Part")
		limb.Name = limbName
		limb.Position = position
		limb.Parent = character
	end
	character.Parent = Workspace
	player.Character = character
	player.CharacterAdded = player.CharacterAdded or Signal.new()
	return character
end

function Stub.characterPosition(player): any
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root.Position or v3(0, 0, 0)
end

function Stub.movePlayer(player, position)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		root.Position = position
		for _, limb in ipairs(character:GetChildren()) do
			if limb:IsA("BasePart") then
				limb.Position = position
			end
		end
	end
end

function Stub.attachCamera(viewportX: number?, viewportY: number?)
	local camera = Instance.new("Instance")
	camera.Name = "Camera"
	camera.ClassName = "Camera"
	camera.ViewportSize = Vector2.new(viewportX or 1280, viewportY or 720)
	camera.CFrame = cf(v3(0, 20, 0))
	camera.WorldToViewportPoint = function(_, position)
		-- Purely positional projection: good enough to exercise marker placement code.
		local dx = (position.X - camera.CFrame.Position.X)
		local dy = (position.Y - camera.CFrame.Position.Y)
		local dz = (position.Z - camera.CFrame.Position.Z)
		return v3(
			camera.ViewportSize.X * 0.5 + dx * 8,
			camera.ViewportSize.Y * 0.5 - dy * 8,
			dz == 0 and 1 or dz
		), dz <= 0
	end
	Workspace.CurrentCamera = camera
	return camera
end

function Stub.raycastParams()
	return Instance.new("RaycastParams")
end

function Stub.task()
	local task = {
		delay = function(seconds, fn)
			table.insert(scheduled, { at = clock + seconds, fn = fn })
		end,
		spawn = function(fn, ...)
			local args = table.pack(...)
			table.insert(scheduled, { at = clock, fn = function()
				fn(table.unpack(args, 1, args.n))
			end })
		end,
		wait = function(seconds)
			Stub.advance(seconds or 0.03)
		end,
		defer = function(fn)
			table.insert(scheduled, { at = clock, fn = fn })
		end,
	}
	return task
end

function Stub.env()
	return {
		game = Game,
		workspace = Workspace,
		Workspace = Workspace,
		script = nil,
		Instance = Instance,
		Vector3 = setmetatable({ new = v3, zero = v3(0, 0, 0) }, {}),
		Vector2 = Vector2,
		UDim = UDim,
		UDim2 = UDim2,
		CFrame = CFrame,
		Color3 = Color3,
		Enum = Enum,
		RaycastParams = { new = Stub.raycastParams },
		Faces = { new = function() return {} end },
		Axes = { new = function() return {} end },
		task = Stub.task(),
		os = {
			clock = Stub.clock,
			time = function()
				return math.floor(clock)
			end,
			date = os.date,
		},
		print = print,
		warn = warn,
		pcall = pcall,
		xpcall = xpcall,
		select = select,
		typeof = function(value)
			if type(value) == "table" and getmetatable(value) == Vector3 then
				return "Vector3"
			end
			if type(value) == "table" and getmetatable(value) == CFrame then
				return "CFrame"
			end
			if type(value) == "table" and getmetatable(value) == Color3 then
				return "Color3"
			end
			if type(value) == "table" and value.ClassName then
				return "Instance"
			end
			return type(value)
		end,
		bit32 = bit32,
		string = string,
		table = table,
		math = math,
		coroutine = coroutine,
		_services = services,
	}
end

function Stub.services()
	return services, Players, RunService, Workspace, ReplicatedStorage, ServerStorage
end

-- Conversion helpers so datatypes from @lune/roblox never leak into the stub runtime.
Stub.UDim = UDim
Stub.UDim2 = UDim2
Stub.Vector2 = Vector2

function Stub.v3(x: number, y: number, z: number)
	return v3(x, y, z)
end

function Stub.cframe(position)
	return cf(position)
end

function Stub.cframeFrom(pos, look)
	return cf(pos, look)
end

function Stub.color3(r: number, g: number, b: number)
	return Color3.new(r, g, b)
end

function Stub.service(name: string)
	return service(name)
end

function Stub.workspace()
	return Workspace
end

function Stub.players()
	return Players
end

function Stub.runService()
	return RunService
end

function Stub.replicatedStorage()
	return ReplicatedStorage
end

function Stub.stepCount()
	return #clockHooks
end

return Stub
