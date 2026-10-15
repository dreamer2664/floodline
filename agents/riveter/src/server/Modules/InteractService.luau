--!strict
-- InteractService: wires every bespoke interaction prompt (valves, fuses, medkits, radios,
-- chargers, gates) to gameplay logic so the baked geometry is fully playable.

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Interact = {}
Interact.Name = "Interact"

local ctx
local wired = {} :: { [Instance]: boolean }

Interact.actions = {} :: { [string]: (player: Player, part: BasePart) -> (boolean, string?) }

local function ensurePrompt(part: BasePart, actionText: string, objectText: string, hold: number?): ProximityPrompt
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Parent = part
	end
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = hold or 0.25
	prompt.MaxActivationDistance = prompt.MaxActivationDistance or 12
	return prompt
end

local function wire(part: BasePart, actionName: string, actionText: string, objectText: string, hold: number?, oneShot: boolean?)
	if wired[part] then
		return
	end
	wired[part] = true
	local prompt = ensurePrompt(part, actionText, objectText, hold)
	prompt.Triggered:Connect(function(player: Player)
		if not ctx.roundActive() then
			return
		end
		local handler = Interact.actions[actionName]
		if handler then
			local ok, reason = handler(player, part)
			if not ok and reason then
				ctx.notifyPlayer(player, reason, "warn")
				Util.playSound(part, ctx.config.Fx.PingSounds.Error, 0.35, 0.8)
			elseif ok then
				Util.playSound(part, ctx.config.Fx.PingSounds.Prompt, 0.4, 1.1)
			end
		end
	end)
	if oneShot then
		prompt:SetAttribute("OneShot", true)
	end
end

-- ===================== action implementations =====================

local function valveAction(player: Player, part: BasePart): (boolean, string?)
	if ctx.hazard.isLeakFixed() then
		return false, "The gas line is already capped."
	end
	local needs = 1
	if ctx.hasItem(player, "Wrench") then
		needs = 1
	end
	local progress = part:GetAttribute("TurnProgress") or 0
	progress = progress + 1
	part:SetAttribute("TurnProgress", progress)
	ctx.notifyPlayer(player, `Valve turning… ({progress}/3)`, "warn")
	if progress >= 3 then
		ctx.hazard.fixLeak(player)
		part:SetAttribute("TurnProgress", 0)
	end
	return true, nil
end

local function relayAction(player: Player, part: BasePart): (boolean, string?)
	if ctx.power.relayRepaired then
		return false, "The relay is already online."
	end
	if not ctx.hasItem(player, "Fuse") then
		return false, "You need a replacement fuse (workshop parts crate)."
	end
	ctx.consumeItem(player, "Fuse")
	ctx.power.repairRelay(player)
	part:SetAttribute("Fitted", true)
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(90, 210, 140)
	return true, nil
end

local function chargerAction(player: Player, part: BasePart): (boolean, string?)
	local cell = ctx.power.cellByHolder(player)
	if cell then
		return ctx.power.dockCell(player, "Charger")
	end
	local socket = ctx.power.sockets["Charger"]
	if socket and socket.cellId then
		return ctx.power.eject(player, "Charger")
	end
	return false, "Bring a power cell here to recharge it."
end

local function gateAction(player: Player, part: BasePart): (boolean, string?)
	if ctx.power.isPowered("Bridge") then
		return false, "The gate is already open."
	end
	return false, "The gate motor needs power. Feed the bridge socket."
end

local ITEM_NAMES = {
	RelayFuse = "Fuse",
	Medkit1 = "Medkit",
	Medkit2 = "Medkit",
	Medkit3 = "Medkit",
	Radio = "Radio",
	Wrench = "Wrench",
}

local function itemAction(player: Player, part: BasePart): (boolean, string?)
	local itemType = ITEM_NAMES[part.Name]
	if type(itemType) ~= "string" then
		return false, "Nothing here."
	end
	if part:GetAttribute("Taken") then
		return false, "Already taken."
	end
	if not ctx.playerService.canPickUp(player, itemType) then
		return false, "Your hands are full."
	end
	ctx.playerService.addItem(player, itemType)
	part:SetAttribute("Taken", true)
	part.Transparency = 1
	part.CanCollide = false
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = false
	end
	return true, nil
end

local function radioAction(player: Player, part: BasePart): (boolean, string?)
	if not ctx.hasItem(player, "Radio") then
		return false, "The relay radio is still up on the tower. Fetch it."
	end
	if ctx.round.radioCalled then
		return false, "Evacuation already requested."
	end
	ctx.round.callEvacuation(player)
	return true, nil
end

local function ladderAction(player: Player, part: BasePart): (boolean, string?)
	return false, "Truss ladders are climbed directly — walk into them."
end

Interact.actions = {
	Valve = valveAction,
	RelaySlot = relayAction,
	Charger = chargerAction,
	Gate = gateAction,
	Item = itemAction,
	Radio = radioAction,
	Ladder = ladderAction,
}

-- ===================== discovery =====================

local function discover()
	local world = ctx.worldFolder
	local named = {
		Valve = { "Turn Valve", "Gas Valve", 0.5 },
		RelaySlot = { "Fit Fuse", "Relay Control Box", 1.1 },
		Charger = { "Dock Cell", "Cell Charger", 0.3 },
		Radio = { "Call Evacuation", "Relay Radio", 0.6 },
	}

	for _, descendant in ipairs(world:GetDescendants()) do
		if not descendant:IsA("BasePart") then
			continue
		end
		local spec = named[descendant.Name]
		if spec then
			local actionName = descendant.Name
			if actionName == "Radio" then
				-- The radio is both an item pickup and the evacuation console once carried.
				wire(descendant, "Item", "Take Radio", "Relay Radio", 0.4)
			else
				wire(descendant, actionName, spec[1], spec[2], spec[3])
			end
		elseif ITEM_NAMES[descendant.Name] then
			wire(descendant, "Item", `Take {ITEM_NAMES[descendant.Name]}`, descendant.Name, 0.35)
		elseif descendant.Name == "LiftCallTop" then
			local prompt = ensurePrompt(descendant, "Call Lift", "Evac Lift (Pad)")
			prompt.Triggered:Connect(function(player: Player)
				ctx.lift.call(player)
			end)
		elseif descendant.Name == "EvacConsole" then
			wire(descendant, "Radio", "Call Evacuation", "Evacuation Console", 0.6)
		end
	end
end

function Interact.Init(context)
	ctx = context
end

function Interact.Start(context)
	ctx = context
	discover()
	local n = 0
	for _ in pairs(wired) do
		n += 1
	end
	ctx.log(`[Interact] wired {n} interaction prompts`)
end

return Interact
