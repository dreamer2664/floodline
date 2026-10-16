--!strict
-- Systems: the routes + salvage board.
--
-- Left column, under the objectives: the state of both extraction routes (lift / skybridge /
-- service cut) and the salvage bench shop. Purchases go straight out over the RequestUpgrade
-- remote; the server owns the money and the effects.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Systems = {}
Systems.Name = "Systems"

local C = Config.Ui.Colors
local player = Players.LocalPlayer

Systems.gui = nil :: Frame?
Systems.rows = {} :: { [string]: { button: TextButton, label: TextLabel, cost: TextLabel } }
Systems.routeRows = {} :: { [string]: TextLabel }
Systems.salvageLabel = nil :: TextLabel
Systems.hintLabel = nil :: TextLabel
Systems.visible = true
Systems.state = { route = nil, upgrades = nil, lift = nil }
Systems.lastRouteText = ""

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

local function row(name: string, y: number, parent: Frame): Frame
	local frame = new("Frame", {
		Name = name,
		Size = UDim2.new(1, -24, 0, 22),
		Position = UDim2.fromOffset(12, y),
		BackgroundTransparency = 1,
	}) :: Frame
	frame.Parent = parent
	return frame
end

local function routeRow(name: string, y: number, parent: Frame): TextLabel
	local frame = row(name, y, parent)
	local dot = new("Frame", {
		Name = "Dot",
		Size = UDim2.fromOffset(8, 8),
		Position = UDim2.fromOffset(0, 7),
		BackgroundColor3 = C.TextDim,
		BorderSizePixel = 0,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) }) :: Frame
	dot.Parent = frame
	local text = label("", 12, C.TextDim)
	text.Name = "Text"
	text.Position = UDim2.fromOffset(14, 0)
	text.Size = UDim2.new(1, -14, 1, 0)
	text.Parent = frame
	Systems.routeRows[name] = text
	return text
end

local function upgradeRow(id: string, def: any, y: number, parent: Frame)
	local frame = row("Upgrade_" .. id, y, parent)
	local button = new("TextButton", {
		Name = "Buy",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.PanelLight,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, { new("UICorner", { CornerRadius = UDim.new(0, 6) }) }) :: TextButton
	button.Parent = frame
	local name = label(def.Label, 12, C.Text, Config.Ui.FontBold)
	name.Name = "Name"
	name.Position = UDim2.fromOffset(8, 0)
	name.Size = UDim2.new(1, -80, 1, 0)
	name.Parent = button
	local cost = label(`{def.Cost}`, 12, C.Accent, Config.Ui.FontBold)
	cost.Name = "Cost"
	cost.Position = UDim2.fromOffset(-58, 0)
	cost.Size = UDim2.fromOffset(50, 22)
	cost.TextXAlignment = Enum.TextXAlignment.Right
	cost.Parent = button
	button.MouseButton1Click:Connect(function()
		local remotes = Systems.remotes
		if remotes and remotes.RequestUpgrade then
			remotes.RequestUpgrade:FireServer(id)
		end
	end)
	Systems.rows[id] = { button = button, label = name, cost = cost }
end

function Systems.build(parentGui: Instance, remotes: { [string]: Instance }): Frame
	Systems.remotes = remotes
	local panel = new("Frame", {
		Name = "Systems",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 14, 1, -658),
		Size = UDim2.fromOffset(272, 236),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, {
		new("UICorner", { CornerRadius = UDim.new(0, 10) }),
		new("UIStroke", { Color = C.PanelLight, Thickness = 1, Transparency = 0.55, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	}) :: Frame
	panel.Parent = parentGui
	local title = label("ROUTES & SALVAGE", 13, C.Accent, Config.Ui.FontBold)
	title.Name = "Title"
	title.Position = UDim2.fromOffset(14, 8)
	title.Size = UDim2.fromOffset(220, 18)
	title.Parent = panel
	local salvage = label("Salvage: 0", 13, C.Good, Config.Ui.FontBold)
	salvage.Name = "Salvage"
	salvage.Position = UDim2.fromOffset(150, 8)
	salvage.Size = UDim2.fromOffset(110, 18)
	salvage.TextXAlignment = Enum.TextXAlignment.Right
	salvage.Parent = panel
	Systems.salvageLabel = salvage
	routeRow("Lift", 30, panel)
	routeRow("Skybridge", 48, panel)
	routeRow("Cut", 66, panel)
	local hint = label("B toggles this board · buys are shared with the team", 11, C.TextDim)
	hint.Name = "Hint"
	hint.Position = UDim2.fromOffset(14, 214)
	hint.Size = UDim2.fromOffset(244, 16)
	hint.Parent = panel
	Systems.hintLabel = hint
	local y = 88
	for _, id in ipairs(Config.Upgrades.Order) do
		upgradeRow(id, Config.Upgrades[id], y, panel)
		y += 24
	end
	Systems.gui = panel
	return panel
end

local function routeColor(ok: boolean, warn: boolean?): Color3
	if ok then
		return C.Good
	elseif warn then
		return C.Accent
	end
	return C.TextDim
end

function Systems.setState(patch: { [string]: any })
	for key, value in pairs(patch) do
		Systems.state[key] = value
	end
	Systems.refresh()
end

function Systems.refresh()
	if not Systems.gui then
		return
	end
	local route = Systems.state.route
	local lift = Systems.state.lift
	if route then
		local liftPowered = route.liftPowered == true
		local liftState = lift and lift.state or "?"
		Systems.routeRows.Lift.Text = `Lift — {liftState}, {liftPowered and "powered" or "no power"}`
		Systems.routeRows.Lift.Parent.Dot.BackgroundColor3 = routeColor(liftPowered)
		local sky = route.extended or 0
		Systems.routeRows.Skybridge.Text = route.crossable and "Skybridge — walkable (roof route)"
			or `Skybridge — {sky}% out{route.winchPowered and " (winch powered)" or " · crank it by hand"}`
		Systems.routeRows.Skybridge.Parent.Dot.BackgroundColor3 = routeColor(route.crossable == true, sky > 0)
		Systems.routeRows.Cut.Text = route.cutOpen and "Service cut — open (pump house ⇄ terminal)"
			or `Service cut — blocked ({route.cutProgress or 0}% cleared)`
		Systems.routeRows.Cut.Parent.Dot.BackgroundColor3 = routeColor(route.cutOpen == true, (route.cutProgress or 0) > 0)
		if route.recommended then
			Systems.hintLabel.Text = `Best route right now: {route.recommended} · B toggles this board`
		end
	end
	local upgrades = Systems.state.upgrades
	if upgrades then
		Systems.salvageLabel.Text = `Salvage: {upgrades.salvage}`
		for id, entry in pairs(Systems.rows) do
			local found = nil
			for _, item in ipairs(upgrades.items or {}) do
				if item.id == id then
					found = item
					break
				end
			end
			if found then
				if found.owned then
					entry.button.BackgroundColor3 = Color3.fromRGB(30, 52, 40)
					entry.label.Text = `{found.label} ✓`
					entry.label.TextColor3 = C.Good
					entry.cost.Text = found.buyer or ""
					entry.cost.TextColor3 = C.TextDim
				else
					local affordable = found.affordable == true
					entry.button.BackgroundColor3 = affordable and C.PanelLight or Color3.fromRGB(26, 30, 38)
					entry.label.Text = found.label
					entry.label.TextColor3 = affordable and C.Text or C.TextDim
					entry.cost.Text = `{found.cost}`
					entry.cost.TextColor3 = affordable and C.Accent or C.TextDim
				end
			end
		end
	end
end

function Systems.toggle(): boolean
	Systems.visible = not Systems.visible
	if Systems.gui then
		Systems.gui.Visible = Systems.visible
	end
	return Systems.visible
end

function Systems.snapshot()
	local text = Systems.salvageLabel and Systems.salvageLabel.Text or ""
	return {
		visible = Systems.visible,
		salvage = text,
		routes = (function()
			local out = {}
			for key, entry in pairs(Systems.routeRows) do
				out[key] = entry.Text
			end
			return out
		end)(),
		rows = (function()
			local count = 0
			for _ in pairs(Systems.rows) do
				count += 1
			end
			return count
		end)(),
	}
end

function Systems.Init(parentGui: Instance, remotes: { [string]: Instance })
	Systems.build(parentGui, remotes)
	Systems.setState({})
	return Systems.gui
end

return Systems
