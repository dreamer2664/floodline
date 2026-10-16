--!strict
-- Hud: the whole player-facing interface, built from primitives (no external images or fonts).
-- Layout: round banner + timer (top), objectives (left), power grid + water gauge (right),
-- survivor roster (bottom left), status strip (bottom centre), notifications (top centre).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local C = Config.Ui.Colors

local Hud = {}
Hud.Name = "Hud"

local player = Players.LocalPlayer

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

local function corner(radius: number): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, radius) }) :: UICorner
end

local function stroke(color: Color3, thickness: number?, transparency: number?): UIStroke
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		Transparency = transparency or 0.4,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}) :: UIStroke
end

local function label(text: string, size: number, color: Color3, font: Enum.Font?): TextLabel
	return new("TextLabel", {
		Text = text,
		Font = font or Config.Ui.Font,
		TextSize = size,
		TextColor3 = color,
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.fromScale(1, 1),
		RichText = true,
	}) :: TextLabel
end

local function panel(name: string, size: UDim2, position: UDim2): Frame
	local frame = new("Frame", {
		Name = name,
		Size = size,
		Position = position,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
	}, { corner(10), stroke(C.PanelLight, 1, 0.55) }) :: Frame
	return frame
end

function Hud.build(): ScreenGui
	local playerGui = player:WaitForChild("PlayerGui")
	-- Building twice must never leave a stale duplicate interface behind.
	local existing = playerGui:FindFirstChild("FloodlineHud")
	if existing then
		existing:Destroy()
	end
	local gui = new("ScreenGui", {
		Name = "FloodlineHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10,
	}) :: ScreenGui
	gui.Parent = playerGui

	-- ============ top banner ============
	local top = panel("TopBanner", UDim2.fromOffset(430, 62), UDim2.new(0.5, -215, 0, 12))
	top.Parent = gui
	local stateLabel = label("LOBBY", 15, C.Accent, Config.Ui.FontBold)
	stateLabel.Name = "StateLabel"
	stateLabel.Position = UDim2.fromOffset(16, 8)
	stateLabel.Size = UDim2.fromOffset(250, 20)
	stateLabel.Parent = top
	Hud.stateLabel = stateLabel
	local timerLabel = label("--:--", 26, C.Text, Config.Ui.FontBold)
	timerLabel.Name = "TimerLabel"
	timerLabel.Position = UDim2.fromOffset(16, 26)
	timerLabel.Size = UDim2.fromOffset(160, 30)
	timerLabel.Parent = top
	Hud.timerLabel = timerLabel
	local phaseLabel = label("", 13, C.TextDim)
	phaseLabel.Name = "PhaseLabel"
	phaseLabel.Position = UDim2.fromOffset(180, 30)
	phaseLabel.Size = UDim2.fromOffset(240, 24)
	phaseLabel.TextXAlignment = Enum.TextXAlignment.Right
	phaseLabel.Parent = top
	Hud.phaseLabel = phaseLabel
	local waterBarBg = new("Frame", {
		Name = "WaterBarBg",
		Size = UDim2.fromOffset(400, 8),
		Position = UDim2.fromOffset(15, 62 - 15),
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	waterBarBg.Parent = top
	local waterBar = new("Frame", {
		Name = "WaterBar",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.Water,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	waterBar.Parent = waterBarBg
	Hud.waterBar = waterBar
	Hud.waterBarBg = waterBarBg

	-- ============ objectives ============
	local objectives = panel("Objectives", UDim2.fromOffset(272, 208), UDim2.fromOffset(14, 92))
	objectives.Parent = gui
	local objTitle = label("OBJECTIVES", 13, C.Accent, Config.Ui.FontBold)
	objTitle.Name = "Title"
	objTitle.Position = UDim2.fromOffset(14, 8)
	objTitle.Size = UDim2.fromOffset(200, 18)
	objTitle.Parent = objectives
	local objList = new("Frame", {
		Name = "List",
		Size = UDim2.new(1, -20, 1, -36),
		Position = UDim2.fromOffset(10, 30),
		BackgroundTransparency = 1,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	}) :: Frame
	objList.Parent = objectives
	Hud.objectiveList = objList
	Hud.rows = {}

	-- ============ power grid ============
	local power = panel("PowerGrid", UDim2.fromOffset(240, 176), UDim2.new(1, -254, 0, 92))
	power.Parent = gui
	local powerTitle = label("POWER GRID", 13, C.Accent, Config.Ui.FontBold)
	powerTitle.Name = "Title"
	powerTitle.Position = UDim2.fromOffset(14, 8)
	powerTitle.Size = UDim2.fromOffset(200, 18)
	powerTitle.Parent = power
	local capacity = label("", 12, C.TextDim)
	capacity.Name = "CapacityLabel"
	capacity.Position = UDim2.fromOffset(14, 26)
	capacity.Size = UDim2.fromOffset(210, 18)
	capacity.Parent = power
	Hud.capacityLabel = capacity
	local powerList = new("Frame", {
		Name = "List",
		Size = UDim2.new(1, -20, 1, -58),
		Position = UDim2.fromOffset(10, 48),
		BackgroundTransparency = 1,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	}) :: Frame
	powerList.Parent = power
	Hud.powerList = powerList
	Hud.powerRows = {}
	local cellInfo = label("", 12, C.TextDim)
	cellInfo.Name = "CellInfoLabel"
	cellInfo.Position = UDim2.new(0, 14, 1, -26)
	cellInfo.Size = UDim2.fromOffset(214, 20)
	cellInfo.Parent = power
	Hud.cellInfo = cellInfo

	-- ============ survivors ============
	local roster = panel("Roster", UDim2.fromOffset(272, 196), UDim2.new(0, 14, 1, -210))
	roster.Parent = gui
	local rosterTitle = label("SURVIVORS", 13, C.Accent, Config.Ui.FontBold)
	rosterTitle.Name = "Title"
	rosterTitle.Position = UDim2.fromOffset(14, 8)
	rosterTitle.Size = UDim2.fromOffset(200, 18)
	rosterTitle.Parent = roster
	local rosterCount = label("", 12, C.TextDim)
	rosterCount.Name = "CountLabel"
	rosterCount.Position = UDim2.fromOffset(150, 8)
	rosterCount.Size = UDim2.fromOffset(110, 18)
	rosterCount.TextXAlignment = Enum.TextXAlignment.Right
	rosterCount.Parent = roster
	Hud.rosterCount = rosterCount
	local rosterList = new("Frame", {
		Name = "List",
		Size = UDim2.new(1, -20, 1, -36),
		Position = UDim2.fromOffset(10, 30),
		BackgroundTransparency = 1,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }),
	}) :: Frame
	rosterList.Parent = roster
	Hud.rosterList = rosterList
	Hud.rosterRows = {}

	-- ============ status strip ============
	local strip = panel("StatusStrip", UDim2.fromOffset(360, 100), UDim2.new(0.5, -180, 1, -112))
	strip.Parent = gui
	local carrying = label("", 13, C.Text)
	carrying.Name = "CarryingLabel"
	carrying.Position = UDim2.fromOffset(14, 8)
	carrying.Size = UDim2.fromOffset(330, 18)
	carrying.Parent = strip
	Hud.carryingLabel = carrying
	local staminaBg = new("Frame", {
		Name = "StaminaBg",
		Size = UDim2.new(1, -28, 0, 8),
		Position = UDim2.fromOffset(14, 32),
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	staminaBg.Parent = strip
	local stamina = new("Frame", {
		Name = "Stamina",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Good,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	stamina.Parent = staminaBg
	Hud.staminaBar = stamina
	local oxygenBg = new("Frame", {
		Name = "OxygenBg",
		Size = UDim2.new(1, -28, 0, 8),
		Position = UDim2.fromOffset(14, 46),
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	oxygenBg.Parent = strip
	local oxygen = new("Frame", {
		Name = "Oxygen",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.Water,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	oxygen.Parent = oxygenBg
	Hud.oxygenBar = oxygen
	-- Bleedout bar: a downed player needs to see the clock they are on, not just the word DOWN.
	local bleedBg = new("Frame", {
		Name = "BleedBg",
		Size = UDim2.new(1, -28, 0, 8),
		Position = UDim2.fromOffset(14, 56),
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	bleedBg.Parent = strip
	local bleed = new("Frame", {
		Name = "Bleed",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.Bad,
		BorderSizePixel = 0,
	}, { corner(4) }) :: Frame
	bleed.Parent = bleedBg
	Hud.bleedBar = bleed
	Hud.bleedBg = bleedBg
	local role = label("", 12, C.Accent)
	role.Name = "RoleChip"
	role.Position = UDim2.new(1, -140, 0, 8)
	role.Size = UDim2.fromOffset(126, 18)
	role.TextXAlignment = Enum.TextXAlignment.Right
	role.Parent = strip
	Hud.roleChip = role
	local hint = label("", 12, C.TextDim)
	hint.Name = "HintLabel"
	hint.Position = UDim2.fromOffset(14, 68)
	hint.Size = UDim2.fromOffset(330, 16)
	hint.Parent = strip
	Hud.hintLabel = hint

	local session = label("", 11, C.TextDim)
	session.Name = "SessionLabel"
	session.Position = UDim2.fromOffset(14, 68)
	session.Size = UDim2.fromOffset(330, 14)
	session.Parent = strip
	Hud.sessionLabel = session

	-- ============ water gauge ============
	local gauge = panel("WaterGauge", UDim2.fromOffset(74, 320), UDim2.new(1, -90, 0.5, -160))
	gauge.Parent = gui
	local gaugeTitle = label("WATER", 12, C.Water, Config.Ui.FontBold)
	gaugeTitle.Name = "Title"
	gaugeTitle.Position = UDim2.fromOffset(0, 6)
	gaugeTitle.Size = UDim2.fromOffset(74, 16)
	gaugeTitle.TextXAlignment = Enum.TextXAlignment.Center
	gaugeTitle.Parent = gauge
	local gaugeBg = new("Frame", {
		Name = "Bg",
		Size = UDim2.new(0, 30, 1, -64),
		Position = UDim2.new(0.5, -15, 0, 26),
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
	}, { corner(6) }) :: Frame
	gaugeBg.Parent = gauge
	local gaugeFill = new("Frame", {
		Name = "Fill",
		Size = UDim2.new(1, 0, 0, 0),
		Position = UDim2.new(0, 0, 1, 0),
		AnchorPoint = Vector2.new(0, 1),
		BackgroundColor3 = C.Water,
		BorderSizePixel = 0,
	}, { corner(6) }) :: Frame
	gaugeFill.Parent = gaugeBg
	Hud.gaugeFill = gaugeFill
	local gaugeValue = label("", 12, C.Text)
	gaugeValue.Name = "ValueLabel"
	gaugeValue.Position = UDim2.new(0, 0, 1, -34)
	gaugeValue.Size = UDim2.fromOffset(74, 16)
	gaugeValue.TextXAlignment = Enum.TextXAlignment.Center
	gaugeValue.Parent = gauge
	Hud.gaugeValue = gaugeValue

	-- ============ notifications ============
	local notes = new("Frame", {
		Name = "Notifications",
		Size = UDim2.fromOffset(460, 220),
		Position = UDim2.new(0.5, -230, 0, 84),
		BackgroundTransparency = 1,
	}, {
		new("UIListLayout", {
			Padding = UDim.new(0, 5),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}) :: Frame
	notes.Parent = gui
	Hud.notifications = notes

	-- ============ centre prompt ============
	local centre = new("TextLabel", {
		Name = "CentrePrompt",
		Size = UDim2.fromOffset(520, 26),
		Position = UDim2.new(0.5, -260, 0.62, 0),
		BackgroundTransparency = 1,
		Font = Config.Ui.FontBold,
		TextSize = 17,
		TextColor3 = C.Text,
		Text = "",
		TextStrokeTransparency = 0.6,
		RichText = true,
	}) :: TextLabel
	centre.Parent = gui
	Hud.centrePrompt = centre

	-- ============ lobby / start ============
	local lobby = panel("LobbyBanner", UDim2.fromOffset(430, 150), UDim2.new(0.5, -215, 0.5, -75))
	lobby.Parent = gui
	local title = label(Config.Game.Name, 20, C.Accent, Config.Ui.FontBold)
	title.Name = "Headline"
	title.Position = UDim2.fromOffset(0, 16)
	title.Size = UDim2.fromOffset(430, 26)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Parent = lobby
	local blurb = new("TextLabel", {
		Name = "Blurb",
		Text = "Hold the pumps. Lead the survivors out. Extract before the district goes under.",
		Font = Config.Ui.Font,
		TextSize = 13,
		TextColor3 = C.TextDim,
		BackgroundTransparency = 1,
		TextWrapped = true,
		Size = UDim2.new(1, -40, 0, 34),
		Position = UDim2.fromOffset(20, 46),
	}) :: TextLabel
	blurb.Parent = lobby
	local startButton = new("TextButton", {
		Name = "Start",
		Text = "START ROUND",
		Font = Config.Ui.FontBold,
		TextSize = 16,
		TextColor3 = Color3.fromRGB(20, 16, 8),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(200, 40),
		Position = UDim2.new(0.5, -100, 1, -56),
		AutoButtonColor = true,
	}, { corner(8) }) :: TextButton
	startButton.Parent = lobby
	Hud.startButton = startButton
	local lobbyHint = label("Solo rounds auto-start. 1-4 players supported.", 12, C.TextDim)
	lobbyHint.Name = "LobbyHint"
	lobbyHint.Position = UDim2.fromOffset(0, 104)
	lobbyHint.Size = UDim2.fromOffset(430, 16)
	lobbyHint.TextXAlignment = Enum.TextXAlignment.Center
	lobbyHint.Parent = lobby

	-- Difficulty selector (lobby only)
	local modifierRow = new("Frame", {
		Name = "ModifierRow",
		Size = UDim2.new(1, -40, 0, 26),
		Position = UDim2.fromOffset(20, 120),
		BackgroundTransparency = 1,
	}) :: Frame
	modifierRow.Parent = lobby
	local lower = new("TextButton", {
		Name = "ModifierPrev",
		Text = "◀",
		Font = Config.Ui.FontBold,
		TextSize = 16,
		TextColor3 = C.Text,
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(30, 26),
		Position = UDim2.fromOffset(60, 0),
	}, { corner(6) }) :: TextButton
	lower.Parent = modifierRow
	local modifierLabel = label("Standard Surge", 13, C.Accent, Config.Ui.FontBold)
	modifierLabel.Name = "ModifierLabel"
	modifierLabel.Position = UDim2.fromOffset(100, 4)
	modifierLabel.Size = UDim2.fromOffset(230, 18)
	modifierLabel.TextXAlignment = Enum.TextXAlignment.Center
	modifierLabel.Parent = modifierRow
	local higher = new("TextButton", {
		Name = "ModifierNext",
		Text = "▶",
		Font = Config.Ui.FontBold,
		TextSize = 16,
		TextColor3 = C.Text,
		BackgroundColor3 = C.PanelLight,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(30, 26),
		Position = UDim2.fromOffset(340, 0),
	}, { corner(6) }) :: TextButton
	higher.Parent = modifierRow
	Hud.modifierLabel = modifierLabel
	Hud.modifierPrev = lower
	Hud.modifierNext = higher
	Hud.lobbyBanner = lobby

	return gui
end

local function statusColor(status: string): Color3
	if status == "done" then
		return C.Good
	elseif status == "active" then
		return C.Accent
	end
	return C.TextDim
end

function Hud.updateObjectives(list: { any })
	for index, entry in ipairs(list) do
		local row = Hud.rows[index]
		if not row then
			row = new("Frame", {
				Name = `Objective{index}`,
				Size = UDim2.new(1, 0, 0, 32),
				BackgroundColor3 = C.PanelLight,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				LayoutOrder = index,
			}, { corner(6) }) :: Frame
			row.Parent = Hud.objectiveList
			row:SetAttribute("Row", index)
			local dot = new("Frame", {
				Name = "Dot",
				Size = UDim2.fromOffset(4, 18),
				Position = UDim2.fromOffset(8, 7),
				BackgroundColor3 = C.Accent,
				BorderSizePixel = 0,
			}, { corner(2) }) :: Frame
			dot.Parent = row
			local title = label("", 12, C.Text, Config.Ui.FontBold)
			title.Name = "Title"
			title.Position = UDim2.fromOffset(18, 2)
			title.Size = UDim2.new(1, -24, 0, 15)
			title.Parent = row
			local detail = new("TextLabel", {
				Name = "Detail",
				Text = "",
				Font = Config.Ui.Font,
				TextSize = 10,
				TextColor3 = C.TextDim,
				BackgroundTransparency = 1,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -24, 0, 13),
				Position = UDim2.fromOffset(18, 16),
			}) :: TextLabel
			detail.Parent = row
			Hud.rows[index] = row
		end
		row.Visible = true
		local title = row:FindFirstChild("Title") :: TextLabel
		local detail = row:FindFirstChild("Detail") :: TextLabel
		local dot = row:FindFirstChild("Dot") :: Frame
		title.Text = entry.title
		title.TextColor3 = statusColor(entry.status)
		detail.Text = entry.detail or ""
		dot.BackgroundColor3 = statusColor(entry.status)
		row.BackgroundTransparency = entry.status == "done" and 0.6 or 0.35
	end
	for index = #list + 1, #(Hud.rows :: any) do
		Hud.rows[index].Visible = false
	end
end

function Hud.updatePower(snapshot: any)
	local consumers = snapshot.consumers or {}
	local names = { "Pump", "Lift", "Bridge", "Relay" }
	for index, name in ipairs(names) do
		local row = Hud.powerRows[index]
		if not row then
			row = new("Frame", {
				Name = name,
				Size = UDim2.new(1, 0, 0, 22),
				BackgroundColor3 = C.PanelLight,
				BackgroundTransparency = 0.4,
				BorderSizePixel = 0,
				LayoutOrder = index,
			}, { corner(5) }) :: Frame
			row.Parent = Hud.powerList
			local dot = new("Frame", {
				Name = "Dot",
				Size = UDim2.fromOffset(10, 10),
				Position = UDim2.fromOffset(8, 6),
				BackgroundColor3 = C.Bad,
				BorderSizePixel = 0,
			}, { corner(5) }) :: Frame
			dot.Parent = row
			local title = label("", 12, C.Text)
			title.Name = "Title"
			title.Position = UDim2.fromOffset(24, 1)
			title.Size = UDim2.new(1, -30, 1, -2)
			title.Parent = row
			Hud.powerRows[index] = row
		end
		local entry = consumers[name] or {}
		local title = row:FindFirstChild("Title") :: TextLabel
		local dot = row:FindFirstChild("Dot") :: Frame
		local tag = entry.powered and "ONLINE" or (entry.reason == "brownout" and "BROWNOUT" or "OFFLINE")
		title.Text = `{name}: <b>{tag}</b>`
		title.TextColor3 = entry.powered and C.Text or C.TextDim
		dot.BackgroundColor3 = entry.powered and C.Good or (entry.reason == "brownout" and C.Warn or C.Bad)
	end
	local capacity = snapshot.capacity or 2
	local load = 0
	for _, entry in pairs(consumers) do
		if entry.powered then
			load += entry.load or 1
		end
	end
	Hud.capacityLabel.Text = `Capacity {load}/{capacity}   Relay: {snapshot.relayRepaired and "online" or "offline"}`
	local cells = snapshot.cells or {}
	local line = {}
	for _, id in ipairs({ "Cell_A", "Cell_B", "Cell_C" }) do
		local cell = cells[id]
		if cell then
			local where = cell.holder and `carried by {cell.holder}` or (cell.socket and cell.socket or (cell.docked and "docked" or "loose"))
			table.insert(line, `{string.sub(id, 6)} {math.floor(cell.charge)}% {cell.destroyed and "(dead)" or where}`)
		end
	end
	Hud.cellInfo.Text = table.concat(line, "\n")
end

function Hud.updateSurvivors(snapshot: any)
	local list = snapshot.list or {}
	local whistle = snapshot.rallyReadyIn or 0
	local whistleText = whistle > 0 and `  ·  whistle {math.ceil(whistle)}s` or "  ·  whistle ready"
	-- Company is the point of the huddle rules, so the roster says it out loud: how many are being
	-- held together right now, and what each survivor is standing next to.
	local steadied = 0
	for _, entry in ipairs(list) do
		if entry.grouped then
			steadied += 1
		end
	end
	local companyText = steadied > 0 and `  ·  {steadied} steadied` or ""
	Hud.rosterCount.Text = `{snapshot.rescued}/{snapshot.total} out  ·  need {snapshot.required}{whistleText}{companyText}`
	for index, entry in ipairs(list) do
		local row = Hud.rosterRows[index]
		if not row then
			row = new("Frame", {
				Name = entry.name,
				Size = UDim2.new(1, 0, 0, 19),
				BackgroundTransparency = 1,
				LayoutOrder = index,
			}) :: Frame
			row.Parent = Hud.rosterList
			local dot = new("Frame", {
				Name = "Dot",
				Size = UDim2.fromOffset(8, 8),
				Position = UDim2.fromOffset(2, 6),
				BackgroundColor3 = C.TextDim,
				BorderSizePixel = 0,
			}, { corner(4) }) :: Frame
			dot.Parent = row
			local name = label("", 11, C.Text)
			name.Name = "Name"
			name.Position = UDim2.fromOffset(16, 0)
			name.Size = UDim2.fromOffset(140, 19)
			name.Parent = row
			local status = label("", 11, C.TextDim)
			status.Name = "Status"
			status.Position = UDim2.fromOffset(156, 0)
			status.Size = UDim2.fromOffset(60, 19)
			status.Parent = row
			local panicBg = new("Frame", {
				Name = "PanicBg",
				Size = UDim2.fromOffset(38, 5),
				Position = UDim2.new(1, -42, 0, 7),
				BackgroundColor3 = C.PanelLight,
				BorderSizePixel = 0,
			}, { corner(2) }) :: Frame
			panicBg.Parent = row
			local panic = new("Frame", {
				Name = "Panic",
				Size = UDim2.fromScale(0, 1),
				BackgroundColor3 = C.Warn,
				BorderSizePixel = 0,
			}, { corner(2) }) :: Frame
			panic.Parent = panicBg
			Hud.rosterRows[index] = row
		end
		local dot = row:FindFirstChild("Dot") :: Frame
		local name = row:FindFirstChild("Name") :: TextLabel
		local status = row:FindFirstChild("Status") :: TextLabel
		local panic = (row:FindFirstChild("PanicBg") :: Frame):FindFirstChild("Panic") :: Frame
		name.Text = `{entry.label} [{entry.trait}]`
		local colors = {
			Idle = C.TextDim,
			Following = C.Accent,
			Assisting = C.Water,
			Downed = C.Bad,
			Carried = C.Water,
			Lost = C.Warn,
			Rescued = C.Good,
			Dead = C.Bad,
		}
		dot.BackgroundColor3 = colors[entry.state] or C.TextDim
		-- "+2" reads as company: rescuers and neighbours holding this survivor steady.
		local company = (entry.grouped and (entry.groupCount or 0) > 0) and ` +{entry.groupCount}` or ""
		status.Text = entry.state .. company
		status.TextColor3 = colors[entry.state] or C.TextDim
		panic.Size = UDim2.fromScale(math.clamp(entry.panic / 100, 0, 1), 1)
		panic.BackgroundColor3 = entry.panic > 70 and C.Bad or C.Warn
	end
	for index = #list + 1, #(Hud.rosterRows :: any) do
		Hud.rosterRows[index].Parent = nil
		Hud.rosterRows[index] = nil
	end
end

function Hud.notify(payload: any)
	local tone = payload.tone or "info"
	local color = (tone == "good" and C.Good) or (tone == "bad" and C.Bad) or (tone == "warn" and C.Warn) or C.Text
	local row = new("Frame", {
		Name = "Note",
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
	}, { corner(7), stroke(color, 1, 0.5) }) :: Frame
	row.Parent = Hud.notifications
	local dot = new("Frame", {
		Size = UDim2.fromOffset(4, 18),
		Position = UDim2.fromOffset(8, 5),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, { corner(2) }) :: Frame
	dot.Parent = row
	local text = new("TextLabel", {
		Text = payload.text or "",
		Font = Config.Ui.Font,
		TextSize = 13,
		TextColor3 = color,
		BackgroundTransparency = 1,
		TextWrapped = true,
		Size = UDim2.new(1, -24, 1, 0),
		Position = UDim2.fromOffset(18, 0),
	}) :: TextLabel
	text.Parent = row
	task.delay(6.5, function()
		for i = 0, 10 do
			row.BackgroundTransparency = 0.1 + i * 0.09
			row.TextTransparency = i * 0.1
			text.TextTransparency = i * 0.1
			for _, child in ipairs(row:GetChildren()) do
				if child:IsA("Frame") then
					child.BackgroundTransparency = i * 0.1
				end
			end
			task.wait(0.03)
		end
		row:Destroy()
	end)
end

function Hud.setState(payload: any)
	local state = payload.state or "Lobby"
	Hud.stateLabel.Text = string.upper(state)
	local tones = {
		Lobby = C.TextDim,
		Prep = C.Good,
		Rising = C.Warn,
		Surge = C.Bad,
		Extraction = C.Water,
		Results = C.Accent,
		Intermission = C.TextDim,
	}
	Hud.stateLabel.TextColor3 = tones[state] or C.Text
	Hud.lobbyBanner.Visible = state == "Lobby"
	if state ~= "Lobby" then
		Hud.lobbyBanner.Visible = false
	end
	if state == "Prep" then
		Hud.hintLabel.Text = "Prepare: dock cells, power the pump, round up survivors."
	elseif state == "Rising" then
		Hud.hintLabel.Text = "Water is rising. Escort survivors to the safe zone."
	elseif state == "Surge" then
		Hud.hintLabel.Text = "SURGE. Get to high ground and load the lift."
	elseif state == "Extraction" then
		Hud.hintLabel.Text = "Extraction authorised — ride the lift to the relay pad."
	elseif state == "Results" then
		Hud.hintLabel.Text = "Round over."
	else
		Hud.hintLabel.Text = "Press START ROUND or wait for the automatic start."
	end
end

function Hud.setTick(payload: any)
	Hud.timerLabel.Text = payload.timeLeft and Util.formatClock(payload.timeLeft) or "READY"
	Hud.phaseLabel.Text = payload.phaseIndex and payload.phaseIndex > 0
			and `Phase {payload.phaseIndex}/{Config.Round.PhaseCount}  ·  {payload.players} player(s)`
		or `{payload.players} player(s)  ·  need {payload.required} rescued`
end

function Hud.setModifier(payload: any)
	if not payload then
		return
	end
	Hud.modifierLabel.Text = payload.label or payload.modifier or "Standard"
	Hud.modifierHint = payload.blurb
end

function Hud.setSession(payload: any)
	if not payload then
		return
	end
	Hud.sessionLabel.Text = string.format(
		"Session: %d round(s), %d won, best %s / %d, best rescue %d",
		payload.rounds or 0, payload.wins or 0, payload.bestGrade or "-",
		payload.bestScore or 0, payload.bestRescued or 0
	)
end

function Hud.setWater(snapshot: any)
	local ratio = math.clamp(snapshot.level / Config.Water.MaxLevel, 0, 1)
	Hud.waterBar.Size = UDim2.fromScale(ratio, 1)
	Hud.waterBar.BackgroundColor3 = ratio > 0.7 and C.Bad or (ratio > 0.4 and C.Warn or C.Water)
	Hud.gaugeFill.Size = UDim2.new(1, 0, ratio, 0)
	Hud.gaugeValue.Text = string.format("%.1fm", snapshot.level)
	Hud.waterBarBg.BackgroundColor3 = snapshot.pumped and Color3.fromRGB(28, 60, 60) or C.PanelLight
end

function Hud.setStatus(payload: any)
	local me = payload[player.Name]
	if not me then
		return
	end
	Hud.staminaBar.Size = UDim2.fromScale(math.clamp(me.stamina / Config.Player.StaminaMax, 0, 1), 1)
	Hud.oxygenBar.Size = UDim2.fromScale(math.clamp(me.oxygen / Config.Water.OxygenSeconds, 0, 1), 1)
	Hud.oxygenBar.BackgroundColor3 = me.oxygen < Config.Water.OxygenSeconds * 0.35 and C.Bad or C.Water
	local items = {}
	for name, count in pairs(me.items or {}) do
		table.insert(items, count > 1 and `{name} x{count}` or name)
	end
	table.sort(items)
	local carryText = me.carrying and "Carrying: power cell" or (#items > 0 and ("Kit: " .. table.concat(items, ", ")) or "Kit: empty")
	if me.dragging then
		carryText = `Hauling {me.dragging} — Q to set them down`
	end
	if me.downed then
		-- A downed player gets one line, and it carries everything they need: that they are down,
		-- who has them, and how far along the revive is.
		local revive = math.floor((me.reviveProgress or 0) / 4.5 * 100)
		carryText = me.draggedBy
			and `DOWN — hauled by {me.draggedBy} · revive {revive}%`
			or `DOWN — revive in progress {revive}%`
	end
	Hud.carryingLabel.Text = carryText
	Hud.carryingLabel.TextColor3 = me.downed and C.Bad or (me.dragging and C.Warn or C.Text)
	-- Bleedout only means anything while you are down; the bar doubles as the revive progress read.
	local bleed = math.clamp(me.bleedProgress or 0, 0, 1)
	Hud.bleedBar.Size = UDim2.fromScale(me.downed and bleed or 0, 1)
	Hud.bleedBar.BackgroundColor3 = bleed > 0.7 and C.Bad or C.Warn
	Hud.bleedBg.BackgroundTransparency = me.downed and 0 or 0.65
	if me.submerged then
		Hud.centrePrompt.Text = "UNDERWATER — surface for air"
		Hud.centrePrompt.TextColor3 = C.Bad
	end
end

function Hud.showCentrePrompt(text: string, tone: string?)
	Hud.centrePrompt.Text = text
	Hud.centrePrompt.TextColor3 = tone == "bad" and C.Bad or C.Text
	Hud.promptUntil = os.clock() + 2.2
end

function Hud.update()
	if Hud.promptUntil and os.clock() > Hud.promptUntil then
		Hud.promptUntil = nil
		Hud.centrePrompt.Text = ""
	end
end

function Hud.Init()
	Hud.gui = Hud.build()
end

return Hud
