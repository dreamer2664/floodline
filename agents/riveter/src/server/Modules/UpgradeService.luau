--!strict
-- UpgradeService: the salvage economy and the terminal bench.
--
-- Salvage is earned by playing well (survivors, power milestones, crates, phases) and spent at
-- the bench on round-long upgrades that visibly change the simulation: a stronger pump, more
-- air, grid capacity, stronger door seals, faster revives and a faster lift.
--
-- Nothing here invents new state for the world to drag around: it publishes multipliers that
-- FloodService / PowerService / DoorService / PlayerService / LiftService read every tick.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Upgrade = {}
Upgrade.Name = "Upgrade"

Upgrade.salvage = 0
Upgrade.earned = 0
Upgrade.spent = 0
Upgrade.purchased = {} :: { [string]: { by: string, at: number } }
Upgrade.cratesOpened = 0
Upgrade.lastCratePayout = 0
Upgrade.pendingReviveBonus = 0
Upgrade.dirty = true

local ctx
local wiredCrates: { [Instance]: boolean } = {}

local function definition(id: string)
	return ctx.config.Upgrades[id]
end

-- ===================== economy =====================

function Upgrade.award(amount: number, reason: string?)
	Upgrade.salvage += amount
	Upgrade.earned += amount
	if reason then
		ctx.log(`[Upgrade] +{amount} salvage ({reason})`)
	end
	Upgrade.dirty = true
end

-- ===================== effects read by other services =====================

function Upgrade.has(id: string): boolean
	return Upgrade.purchased[id] ~= nil
end

function Upgrade.floodMultiplier(): number
	local def = definition("Impeller")
	if Upgrade.has("Impeller") and def then
		return 1 + def.Value
	end
	return 1
end

function Upgrade.oxygenBonus(): number
	local def = definition("Rebreather")
	if Upgrade.has("Rebreather") and def then
		return def.Value
	end
	return 0
end

function Upgrade.capacityBonus(): number
	local def = definition("Capacitor")
	if Upgrade.has("Capacitor") and def then
		return def.Value
	end
	return 0
end

function Upgrade.sealMultiplier(): number
	local def = definition("SealKit")
	if Upgrade.has("SealKit") and def then
		return 1 + def.Value
	end
	return 1
end

function Upgrade.reviveSpeed(): number
	local def = definition("FieldHospital")
	if Upgrade.has("FieldHospital") and def then
		return def.Value
	end
	return 1
end

function Upgrade.liftServo(): { speed: number, capacity: number }
	local def = definition("LiftServo")
	if Upgrade.has("LiftServo") and def then
		return { speed = 1 + def.Value, capacity = def.Capacity or 0 }
	end
	return { speed = 1, capacity = 0 }
end

-- ===================== bench =====================

function Upgrade.canAfford(id: string): (boolean, string?)
	local def = definition(id)
	if not def then
		return false, "Unknown upgrade."
	end
	if Upgrade.has(id) then
		return false, `{def.Label} is already fitted this round.`
	end
	if Upgrade.salvage < def.Cost then
		return false, `{def.Label} costs {def.Cost} salvage (you have {math.floor(Upgrade.salvage)}).`
	end
	return true, nil
end

function Upgrade.purchase(player: Player, id: string): (boolean, string?)
	if not ctx.roundActive() then
		return false, "The bench only works during a round."
	end
	local ok, reason = Upgrade.canAfford(id)
	if not ok then
		return false, reason
	end
	local def = definition(id)
	Upgrade.salvage -= def.Cost
	Upgrade.spent += def.Cost
	Upgrade.purchased[id] = { by = player.Name, at = os.clock() }
	ctx.notify(`{player.Name} fitted: {def.Label} — {def.Desc}`, "good")
	ctx.telemetry.note("upgrade", `{id} fitted by {player.Name}`, { cost = def.Cost, salvage = Upgrade.salvage })
	ctx.addScore(player, 15, "upgrade fitted")
	-- Push the change into the systems that were already running.
	if def.Kind == "capacity" then
		ctx.power.recompute()
	elseif def.Kind == "lift" then
		ctx.lift.refresh()
	elseif def.Kind == "seal" then
		ctx.doors.refreshSeals()
	end
	Upgrade.dirty = true
	ctx.objective.markDirty()
	return true, nil
end

function Upgrade.openCrate(player: Player, crate: BasePart): (boolean, string?)
	local attr = crate:GetAttribute("Looted")
	if attr == true then
		return false, "This crate is empty."
	end
	crate:SetAttribute("Looted", true)
	local amount = math.random(12, 20)
	Upgrade.lastCratePayout = amount
	Upgrade.cratesOpened += 1
	Upgrade.award(amount, `crate by {player.Name}`)
	ctx.addScore(player, 10, "salvage crate")
	ctx.notifyPlayer(player, `Salvage crate: +{amount} (pool {math.floor(Upgrade.salvage)}).`, "good")
	Util.playSound(crate, ctx.config.Fx.PingSounds.Prompt, 0.5, 0.9)
	local band = crate.Parent and crate.Parent:FindFirstChild(string.gsub(crate.Name, "SupplyCrate", "SupplyCrateBand"))
	if band and band:IsA("BasePart") then
		band.Color = Color3.fromRGB(90, 96, 106)
	end
	local prompt = crate:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = false
	end
	return true, nil
end

-- RoundService calls these so the pool tracks the actual run.
function Upgrade.onSurvivorRescued()
	Upgrade.award(ctx.config.Upgrades.PerSurvivor, "survivor")
end

function Upgrade.onFirstPower(consumer: string)
	Upgrade.award(ctx.config.Upgrades.PerFirstPower, `{consumer} online`)
end

function Upgrade.onPhaseBegan(index: number)
	Upgrade.award(ctx.config.Upgrades.PerPhase, `phase {index}`)
end

function Upgrade.onMedicRescue(player: Player?)
	local def = ctx.config.Survivors.Roles.Medic
	local targets = player and { player } or Players:GetPlayers()
	local restocked = 0
	for _, target in ipairs(targets) do
		local state = ctx.playerService.getState(target)
		if state then
			for _ = 1, def.RescueMedkits do
				ctx.playerService.addItem(target, "Medkit")
			end
			restocked += 1
			local character = target.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				humanoid.Health = humanoid.MaxHealth
			end
		end
	end
	if restocked > 0 then
		ctx.notify(`Medic on board: {def.RescueMedkits} medkits restocked and the team patched up.`, "good")
	end
end

-- ===================== prompt wiring =====================

local function wireCrates()
	local folder = ctx.findWorld("Salvage")
	local world = ctx.worldFolder
	local candidates: { BasePart } = {}
	if folder and folder:IsA("Model") then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(candidates, child)
			end
		end
	else
		for _, descendant in ipairs(world:GetDescendants()) do
			if descendant:IsA("BasePart") and string.sub(descendant.Name, 1, 11) == "SupplyCrate" then
				table.insert(candidates, descendant)
			end
		end
	end
	for _, crate in ipairs(candidates) do
		if string.find(crate.Name, "Band", 1, true) then
			continue
		end
		if crate:FindFirstChildOfClass("ProximityPrompt") and not wiredCrates[crate] then
			wiredCrates[crate] = true
			local prompt = crate:FindFirstChildOfClass("ProximityPrompt")
			prompt.ActionText = "Open Crate"
			prompt.ObjectText = "Salvage Crate"
			prompt.HoldDuration = 0.6
			prompt.MaxActivationDistance = 13
			prompt.Triggered:Connect(function(player: Player)
				if not ctx.roundActive() then
					return
				end
				local ok, reason = Upgrade.openCrate(player, crate)
				if not ok and reason then
					ctx.notifyPlayer(player, reason, "warn")
				end
			end)
		end
	end
	local bench = ctx.findWorld("UpgradeBench")
	if bench and bench:IsA("BasePart") then
		local prompt = bench:FindFirstChildOfClass("ProximityPrompt")
		if not prompt then
			prompt = Instance.new("ProximityPrompt")
			prompt.Parent = bench
		end
		if not wiredCrates[bench] then
			wiredCrates[bench] = true
			prompt.ActionText = "Open Bench"
			prompt.ObjectText = "Salvage Bench"
			prompt.HoldDuration = 0.5
			prompt.MaxActivationDistance = 12
			prompt.Triggered:Connect(function(player: Player)
				ctx.remotes.UpgradeSync:FireClient(player, Upgrade.snapshot())
				ctx.sendPlayerEvent(player, "bench", { open = true })
			end)
		end
	end
end

function Upgrade.snapshot()
	local items = {}
	for _, id in ipairs(ctx.config.Upgrades.Order) do
		local def = ctx.config.Upgrades[id]
		local owned = Upgrade.purchased[id]
		table.insert(items, {
			id = id,
			label = def.Label,
			desc = def.Desc,
			cost = def.Cost,
			kind = def.Kind,
			owned = owned ~= nil,
			buyer = owned and owned.by or nil,
			affordable = Upgrade.salvage >= def.Cost and owned == nil,
		})
	end
	return {
		salvage = math.floor(Upgrade.salvage),
		earned = math.floor(Upgrade.earned),
		spent = math.floor(Upgrade.spent),
		items = items,
		crates = Upgrade.cratesOpened,
		owned = (function()
			local count = 0
			for _ in pairs(Upgrade.purchased) do
				count += 1
			end
			return count
		end)(),
	}
end

function Upgrade.pushSnapshot()
	Upgrade.dirty = false
	ctx.remotes.UpgradeSync:FireAllClients(Upgrade.snapshot())
end

function Upgrade.reset()
	Upgrade.salvage = ctx.config.Upgrades.StartSalvage
	Upgrade.earned = ctx.config.Upgrades.StartSalvage
	Upgrade.spent = 0
	Upgrade.purchased = {}
	Upgrade.cratesOpened = 0
Upgrade.lastCratePayout = 0
	for _, descendant in ipairs(ctx.worldFolder:GetDescendants()) do
		if descendant:IsA("BasePart") and string.sub(descendant.Name, 1, 11) == "SupplyCrate" and not string.find(descendant.Name, "Band", 1, true) then
			descendant:SetAttribute("Looted", false)
			local prompt = descendant:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Enabled = true
			end
		end
	end
	Upgrade.dirty = true
end

function Upgrade.Init(context)
	ctx = context
end

function Upgrade.Start(context)
	ctx = context
	Upgrade.reset()
	wireCrates()
	RunService.Heartbeat:Connect(function()
		if Upgrade.dirty and ctx.roundActive() then
			Upgrade.pushSnapshot()
		end
	end)
end

return Upgrade
