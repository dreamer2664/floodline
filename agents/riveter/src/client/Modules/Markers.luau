--!strict
-- Markers: world-space UI. Objective diamonds, survivor nameplates with health/panic,
-- the safe-zone ring countdown and an off-screen objective arrow.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local C = Config.Ui.Colors
local Markers = {}
Markers.Name = "Markers"

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local container = nil :: Folder?
local tags = {} :: { [string]: BillboardGui }
local objectiveTag: BillboardGui? = nil
local arrow: TextLabel? = nil

Markers.pings = {}

local function ensureContainer()
	if container and container.Parent then
		return container
	end
	local folder = Instance.new("Folder")
	folder.Name = "FloodlineMarkers"
	folder.Parent = Workspace
	container = folder
	return folder
end

local function makeTag(adornee: Instance, text: string, size: number, color: Color3): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Tag"
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(190, 34)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.1, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 180
	gui.LightInfluence = 0
	gui.Parent = ensureContainer()

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = C.Panel
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local bar = Instance.new("Frame")
	bar.Name = "Health"
	bar.Size = UDim2.new(1, 0, 0, 3)
	bar.Position = UDim2.new(0, 0, 1, -3)
	bar.BackgroundColor3 = C.Good
	bar.BorderSizePixel = 0
	bar.Parent = frame

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "Label"
	textLabel.Text = text
	textLabel.Font = Config.Ui.Font
	textLabel.TextSize = size
	textLabel.TextColor3 = color
	textLabel.BackgroundTransparency = 1
	textLabel.TextWrapped = true
	textLabel.Size = UDim2.new(1, -8, 1, -4)
	textLabel.Position = UDim2.fromOffset(4, 0)
	textLabel.Parent = frame
	return gui
end

function Markers.syncSurvivors(snapshot: any)
	local folder = ensureContainer()
	local seen = {}
	for _, entry in ipairs(snapshot.list or {}) do
		if entry.state == "Rescued" or entry.state == "Dead" then
			continue
		end
		seen[entry.name] = true
		local tag = tags[entry.name]
		if not tag then
			local anchor = folder:FindFirstChild(entry.name)
			if not anchor then
				anchor = Instance.new("Part")
				anchor.Name = entry.name
				anchor.Size = Vector3.new(2, 2, 2)
				anchor.Anchored = true
				anchor.CanCollide = false
				anchor.CanQuery = false
				anchor.CanTouch = false
				anchor.Transparency = 1
				anchor.Parent = folder
			end
			tag = makeTag(anchor, entry.label, 12, C.Text)
			tags[entry.name] = tag
		end
		local anchor = tag.Adornee :: BasePart
		anchor.Position = entry.position + Vector3.new(0, 1.4, 0)
		local label = (tag:FindFirstChild("Frame") :: Frame):FindFirstChild("Label") :: TextLabel
		local health = (tag:FindFirstChild("Frame") :: Frame):FindFirstChild("Health") :: Frame
		local stateColor = (entry.state == "Downed" and C.Bad)
			or (entry.state == "Lost" and C.Warn)
			or (entry.state == "Following" and C.Accent)
			or (entry.state == "Carried" and C.Water)
			or C.Text
		label.Text = `{entry.label} — {entry.state}`
		label.TextColor3 = stateColor
		health.Size = UDim2.new(math.clamp(entry.health / 100, 0, 1), 0, 0, 3)
		health.BackgroundColor3 = entry.health < 35 and C.Bad or (entry.health < 70 and C.Warn or C.Good)
		tag.Enabled = true
	end
	for name, tag in pairs(tags) do
		if not seen[name] then
			tag:Destroy()
			tags[name] = nil
		end
	end
end

-- Co-op pings: short-lived world markers with the caller's name and type label.
function Markers.addPing(payload: any)
	local folder = ensureContainer()
	local key = `Ping_{payload.player}_{math.floor(os.clock() * 1000)}`
	local anchor = Instance.new("Part")
	anchor.Name = key
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Position = payload.position
	anchor.Parent = folder

	local color = C.Accent
	local palette = { danger = C.Bad, objective = C.Accent, survivor = C.Good, loot = C.Water }
	color = palette[payload.type] or C.Accent

	local gui = Instance.new("BillboardGui")
	gui.Name = "PingTag"
	gui.Adornee = anchor
	gui.Size = UDim2.fromOffset(150, 44)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 400
	gui.LightInfluence = 0
	gui.Parent = folder
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Parent = gui
	local marker = Instance.new("Frame")
	marker.Size = UDim2.fromOffset(12, 12)
	marker.Position = UDim2.new(0.5, -6, 0, 0)
	marker.Rotation = 45
	marker.BackgroundColor3 = color
	marker.BorderSizePixel = 0
	marker.Parent = frame
	local text = Instance.new("TextLabel")
	text.Font = Config.Ui.FontBold
	text.TextSize = 13
	text.TextColor3 = color
	text.BackgroundTransparency = 1
	text.TextStrokeTransparency = 0.5
	text.Size = UDim2.new(1, 0, 0, 18)
	text.Position = UDim2.new(0, 0, 0, 14)
	text.Text = `{payload.label} · {payload.player}`
	text.Parent = frame
	local distance = Instance.new("TextLabel")
	distance.Name = "Distance"
	distance.Font = Config.Ui.Font
	distance.TextSize = 11
	distance.TextColor3 = C.TextDim
	distance.BackgroundTransparency = 1
	distance.Size = UDim2.new(1, 0, 0, 16)
	distance.Position = UDim2.new(0, 0, 0, 30)
	distance.Parent = frame

	-- The server sends a lifetime; the expiry instant is computed on this client's clock.
	local lifetime = payload.lifetime or Config.Pings.Lifetime
	local expiresAt = os.clock() + lifetime
	table.insert(Markers.pings, { anchor = anchor, gui = gui, expiresAt = expiresAt })
	return gui
end

function Markers.updatePings()
	local remaining = {}
	for _, entry in ipairs(Markers.pings) do
		if os.clock() >= entry.expiresAt or not entry.anchor.Parent then
			entry.gui:Destroy()
			entry.anchor:Destroy()
		else
			table.insert(remaining, entry)
		end
	end
	Markers.pings = remaining
end

function Markers.setObjective(entry: any)
	local folder = ensureContainer()
	if not entry or not entry.target then
		if objectiveTag then
			objectiveTag.Enabled = false
		end
		return
	end
	local anchor = folder:FindFirstChild("ObjectiveAnchorPart")
	if not anchor then
		anchor = Instance.new("Part")
		anchor.Name = "ObjectiveAnchorPart"
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.Transparency = 1
		anchor.Parent = folder
	end
	(anchor :: BasePart).Position = entry.target
	if not objectiveTag then
		local gui = Instance.new("BillboardGui")
		gui.Name = "Objective"
		gui.Adornee = anchor
		gui.Size = UDim2.fromOffset(210, 46)
		gui.AlwaysOnTop = true
		gui.MaxDistance = 400
		gui.LightInfluence = 0
		gui.Parent = folder
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundTransparency = 1
		frame.Parent = gui
		local diamond = Instance.new("Frame")
		diamond.Name = "Diamond"
		diamond.Size = UDim2.fromOffset(14, 14)
		diamond.Position = UDim2.new(0.5, -7, 0, -4)
		diamond.BackgroundColor3 = C.Accent
		diamond.BorderSizePixel = 0
		diamond.Rotation = 45
		diamond.Parent = frame
		local text = Instance.new("TextLabel")
		text.Name = "Label"
		text.Font = Config.Ui.FontBold
		text.TextSize = 14
		text.TextColor3 = C.Accent
		text.BackgroundTransparency = 1
		text.Size = UDim2.new(1, 0, 0, 20)
		text.Position = UDim2.new(0, 0, 0, 14)
		text.TextStrokeTransparency = 0.6
		text.Parent = frame
		local distance = Instance.new("TextLabel")
		distance.Name = "Distance"
		distance.Font = Config.Ui.Font
		distance.TextSize = 11
		distance.TextColor3 = C.TextDim
		distance.BackgroundTransparency = 1
		distance.Size = UDim2.new(1, 0, 0, 16)
		distance.Position = UDim2.new(0, 0, 0, 32)
		distance.Parent = frame
		objectiveTag = gui
	end
	local frame = (objectiveTag :: BillboardGui):FindFirstChild("Frame") :: Frame
	local text = frame:FindFirstChild("Label") :: TextLabel
	text.Text = entry.title
	frame:FindFirstChild("Diamond").BackgroundColor3 = entry.status == "done" and C.Good or C.Accent
	objectiveTag.Enabled = true
end

-- Compass arrow that points at the current objective while it is off-screen.
function Markers.makeArrow(parent: Instance): TextLabel
	local arrow = Instance.new("TextLabel")
	arrow.Name = "ObjectiveArrow"
	arrow.Text = "▲"
	arrow.Font = Config.Ui.FontBold
	arrow.TextSize = 22
	arrow.TextColor3 = C.Accent
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.fromOffset(28, 28)
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Visible = false
	arrow.Parent = parent
	Markers.arrow = arrow
	return arrow
end

function Markers.update()
	Markers.updatePings()
	local current = Workspace.CurrentCamera
	if current and current ~= camera then
		camera = current
	end
	if not camera or not Markers.arrow then
		return
	end
	local anchor = container and container:FindFirstChild("ObjectiveAnchorPart")
	if not (anchor and anchor:IsA("BasePart")) then
		Markers.arrow.Visible = false
		return
	end
	local viewport = camera.ViewportSize
	local screen, onScreen = camera:WorldToViewportPoint(anchor.Position)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local distance = root and ((root :: BasePart).Position - anchor.Position).Magnitude or 0
	local frame = (objectiveTag :: BillboardGui):FindFirstChild("Frame")
	if frame then
		local distLabel = frame:FindFirstChild("Distance")
		if distLabel and distLabel:IsA("TextLabel") then
			distLabel.Text = `{math.floor(distance)}m`
		end
	end
	if onScreen and screen.Z > 0 then
		Markers.arrow.Visible = false
	else
		Markers.arrow.Visible = true
		local centre = Vector2.new(viewport.X / 2, viewport.Y / 2)
		local direction = Vector2.new(screen.X - centre.X, screen.Y - centre.Y)
		local angle = math.atan2(direction.Y, direction.X)
		local radius = math.min(viewport.X, viewport.Y) * 0.32
		local position = centre + Vector2.new(math.cos(angle), math.sin(angle)) * radius
		Markers.arrow.Position = UDim2.fromOffset(position.X, position.Y)
		Markers.arrow.Rotation = math.deg(angle) + 90
	end
end

function Markers.Init()
	ensureContainer()
end

return Markers
