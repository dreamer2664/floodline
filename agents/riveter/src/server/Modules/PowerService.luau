--!strict
-- PowerService: the triage puzzle. Physical cells, four consumers, two sockets worth of capacity,
-- a recharge dock, brownouts when the grid is overloaded, and short-outs when sockets flood.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Net = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Net"))
local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Power = {}
Power.Name = "Power"

export type Cell = {
	id: string,
	part: BasePart,
	charge: number,
	holder: Player?,
	socket: string?,
	destroyed: boolean,
}

Power.cells = {} :: { [string]: Cell }
Power.sockets = {} :: { [string]: { part: BasePart, consumer: string, cellId: string?, tripped: boolean, trippedReason: string? } }
Power.consumers = {} :: { [string]: { powered: boolean, load: number, label: string, reason: string? } }
Power.capacity = 0
Power.relayRepaired = false
Power.dirty = true

local ctx

local function consumerDef(name: string)
	return ctx.config.Power.Consumers[name]
end

function Power.cellByHolder(player: Player): Cell?
	for _, cell in pairs(Power.cells) do
		if cell.holder == player then
			return cell
		end
	end
	return nil
end

function Power.cellAt(socketKey: string): Cell?
	local socket = Power.sockets[socketKey]
	if socket and socket.cellId then
		return Power.cells[socket.cellId]
	end
	return nil
end

function Power.markDirty()
	Power.dirty = true
end

function Power.grantCharge(amount: number): number
	-- Distributed top-up used by rare "salvage" interactions.
	local granted = 0
	for _, cell in pairs(Power.cells) do
		if not cell.destroyed and cell.charge < ctx.config.Power.CellChargeMax then
			cell.charge = math.min(ctx.config.Power.CellChargeMax, cell.charge + amount)
			granted += amount
		end
	end
	Power.markDirty()
	return granted
end

function Power.repairRelay(player: Player?): boolean
	if Power.relayRepaired then
		return false
	end
	Power.relayRepaired = true
	Power.capacity = ctx.config.Power.BaseCapacity + ctx.config.Power.RelayCapacityBonus
		+ (ctx.upgrade and ctx.upgrade.capacityBonus() or 0)
	ctx.notify("Relay tower online. Grid capacity increased.", "good")
	ctx.log("[Power] relay repaired by " .. (player and player.Name or "system"))
	Power.markDirty()
	return true
end

-- Attach a cell to a socket. Returns false plus a reason when refused.
function Power.insert(player: Player, socketKey: string): (boolean, string?)
	local socket = Power.sockets[socketKey]
	if not socket then
		return false, "That socket does not exist."
	end
	if socket.cellId then
		return false, "Socket already occupied."
	end
	local cell = Power.cellByHolder(player)
	if not cell then
		return false, "You are not carrying a cell."
	end
	if cell.charge <= 0 then
		return false, "That cell is flat. Recharge it at the terminal dock."
	end
	if socket.tripped and socket.trippedReason == "flood" then
		return false, "Socket is submerged and shorting."
	end
	cell.holder = nil
	cell.socket = socketKey
	cell.part.Parent = socket.part
	cell.part.CFrame = socket.part.CFrame * CFrame.new(0, 1.35, 0)
	cell.part.Anchored = true
	cell.part.CanCollide = true
	socket.cellId = cell.id
	ctx.log(`[Power] {player.Name} inserted {cell.id} into {socketKey}`)
	Power.recompute()
	Util.playSound(socket.part, ctx.config.Fx.PingSounds.Switch, 0.5, 1.15)
	return true, nil
end

function Power.eject(player: Player, socketKey: string): (boolean, string?)
	local socket = Power.sockets[socketKey]
	if not socket or not socket.cellId then
		return false, "Socket is empty."
	end
	local cell = Power.cells[socket.cellId]
	if not cell then
		return false, "Cell data missing."
	end
	if Power.cellByHolder(player) then
		return false, "You are already carrying a cell."
	end
	socket.cellId = nil
	cell.socket = nil
	cell.holder = player
	cell.part.Anchored = false
	cell.part.CanCollide = false
	cell.part.Parent = ctx.carriedFolder
	ctx.log(`[Power] {player.Name} pulled {cell.id} from {socketKey}`)
	Power.recompute()
	return true, nil
end

function Power.drop(player: Player, position: Vector3?): boolean
	local cell = Power.cellByHolder(player)
	if not cell then
		return false
	end
	local dropPos = position or (player.Character and player.Character:GetPivot().Position or Vector3.new(0, 0, 0))
	cell.holder = nil
	cell.part.Anchored = true
	cell.part.CanCollide = true
	cell.part.Parent = ctx.worldFolder
	cell.part.CFrame = CFrame.new(dropPos + Vector3.new(0, 1.2, 0))
	Power.markDirty()
	return true
end

function Power.pickup(player: Player, cellId: string): (boolean, string?)
	local cell = Power.cells[cellId]
	if not cell or cell.destroyed then
		return false, "No cell there."
	end
	if cell.holder or cell.socket then
		return false, "Cell already in use."
	end
	if Power.cellByHolder(player) then
		return false, "You can only carry one cell."
	end
	cell.holder = player
	cell.part.Anchored = false
	cell.part.CanCollide = false
	cell.part.Parent = ctx.carriedFolder
	ctx.log(`[Power] {player.Name} picked up {cell.id}`)
	Power.markDirty()
	return true, nil
end

function Power.dockCell(player: Player, dockKey: string): (boolean, string?)
	local dock = Power.sockets[dockKey]
	if not dock then
		return false, "No dock."
	end
	local cell = Power.cellByHolder(player)
	if not cell then
		return false, "Nothing to dock."
	end
	if dock.cellId then
		return false, "Dock is occupied."
	end
	cell.holder = nil
	cell.docked = true
	cell.dockKey = dockKey
	cell.part.Anchored = true
	cell.part.CanCollide = true
	cell.part.Parent = dock.part
	cell.part.CFrame = dock.part.CFrame * CFrame.new(0, 1.2, 0)
	dock.cellId = cell.id
	Power.markDirty()
	return true, nil
end

-- Grid solver: capacity vs load, with brownout priority and per-socket faults.
function Power.recompute()
	if not ctx then
		return
	end
	Power.capacity = ctx.config.Power.BaseCapacity
		+ (Power.relayRepaired and ctx.config.Power.RelayCapacityBonus or 0)
		+ (ctx.upgrade and ctx.upgrade.capacityBonus() or 0)

	-- Trips first: flooded sockets and dead cells.
	for key, socket in pairs(Power.sockets) do
		local def = consumerDef(socket.consumer)
		if not def then
			continue
		end
		if socket.cellId then
			local cell = Power.cells[socket.cellId]
			if not cell or cell.destroyed then
				socket.cellId = nil
			end
		end
	end

	local wanted = {}
	for key, socket in pairs(Power.sockets) do
		local def = consumerDef(socket.consumer)
		if def and socket.cellId and not socket.tripped then
			wanted[socket.consumer] = { key = key, load = def.Load, label = def.Label }
		end
	end

	local order = ctx.config.Power.BrownoutPriority
	local load = 0
	local powered = {}
	for _, name in ipairs(order) do
		if wanted[name] then
			local entry = wanted[name]
			if load + entry.load <= Power.capacity then
				load += entry.load
				powered[name] = true
			end
		end
	end

	local changed = {}
	for name, def in pairs(ctx.config.Power.Consumers) do
		local now = powered[name] == true
		local previous = Power.consumers[name]
		if not previous or previous.powered ~= now then
			changed[name] = { was = previous and previous.powered or false, now = now }
		end
		Power.consumers[name] = {
			powered = now,
			load = def.Load,
			label = def.Label,
			reason = (not now and wanted[name]) and "brownout" or (not now and "unpowered" or nil),
		}
	end

	Power.dirty = true
	Power.lastChange = os.clock()

	for name, delta in pairs(changed) do
		if delta.now then
			ctx.notify(`{ctx.config.Power.Consumers[name].Label} online.`, "good")
			ctx.onConsumerPowered(name)
		elseif delta.was then
			ctx.notify(`{ctx.config.Power.Consumers[name].Label} lost power.`, "bad")
			ctx.onConsumerLost(name)
		end
	end
end

-- Engineer rescue effect: the whole cell rack comes back to full charge.
function Power.rechargeAll(player: Player?): number
	local recharged = 0
	for _, cell in pairs(Power.cells) do
		if not cell.destroyed and cell.charge < ctx.config.Power.CellChargeMax then
			cell.charge = ctx.config.Power.CellChargeMax
			recharged += 1
		end
	end
	Power.markDirty()
	if recharged > 0 then
		ctx.notify(`Engineer on board: {recharged} cell(s) recharged to full.`, "good")
	end
	return recharged
end

function Power.isPowered(name: string): boolean
	local entry = Power.consumers[name]
	return entry ~= nil and entry.powered
end

function Power.snapshot()
	local cells = {}
	for id, cell in pairs(Power.cells) do
		cells[id] = {
			id = id,
			charge = Util.round(cell.charge, 1),
			holder = cell.holder and cell.holder.Name or nil,
			socket = cell.socket,
			docked = cell.docked or false,
			destroyed = cell.destroyed,
			position = cell.part.Position,
		}
	end
	local sockets = {}
	for key, socket in pairs(Power.sockets) do
		sockets[key] = {
			consumer = socket.consumer,
			cellId = socket.cellId,
			tripped = socket.tripped,
			trippedReason = socket.trippedReason,
			position = socket.part.Position,
			isDock = socket.isDock or false,
		}
	end
	local consumers = {}
	for name, entry in pairs(Power.consumers) do
		consumers[name] = {
			powered = entry.powered,
			label = entry.label,
			reason = entry.reason,
			load = entry.load,
		}
	end
	return {
		cells = cells,
		sockets = sockets,
		consumers = consumers,
		capacity = Power.capacity,
		relayRepaired = Power.relayRepaired,
	}
end

function Power.tripSocket(socketKey: string, reason: string)
	local socket = Power.sockets[socketKey]
	if not socket or socket.tripped then
		return
	end
	socket.tripped = true
	socket.trippedReason = reason
	local cell = socket.cellId and Power.cells[socket.cellId]
	if cell then
		cell.destroyed = true
		cell.charge = 0
		cell.part.Color = Color3.fromRGB(40, 40, 44)
		cell.part.Material = Enum.Material.Slate
		ctx.notify(`A power cell shorted out in the {socket.consumer} socket.`, "bad")
		ctx.onCellDestroyed(cell.id)
		socket.cellId = nil
	end
	Power.recompute()
end

-- Clear a flood trip so a socket can be used again (engineer effect / salvage kit).
function Power.clearTrips(reason: string?): number
	local cleared = 0
	for _, socket in pairs(Power.sockets) do
		if socket.tripped and (reason == nil or socket.trippedReason == reason) then
			socket.tripped = false
			socket.trippedReason = nil
			cleared += 1
		end
	end
	if cleared > 0 then
		Power.recompute()
	end
	return cleared
end

function Power.update(dt: number)
	if not ctx then
		return
	end
	local level = ctx.waterLevel()
	local maxCharge = ctx.config.Power.CellChargeMax
	for id, cell in pairs(Power.cells) do
		if cell.destroyed then
			continue
		end
		if cell.socket then
			local socket = Power.sockets[cell.socket]
			local def = socket and consumerDef(socket.consumer)
			if def and Power.isPowered(socket.consumer) then
				cell.charge = math.max(0, cell.charge - ctx.config.Power.CellDrainPerSecond * def.Load * dt)
				if cell.charge <= 0 then
					socket.tripped = true
					socket.trippedReason = "flat"
					socket.cellId = nil
					cell.socket = nil
					ctx.notify("A power cell ran flat. Swap it out at the terminal.", "warn")
					Power.recompute()
				end
				Power.dirty = true
			end
			if socket then
				local depth = level - socket.part.Position.Y
				if depth > ctx.config.Power.ShortOutDepth then
					Power.tripSocket(cell.socket, "flood")
				end
			end
		elseif cell.docked then
			if cell.charge < maxCharge then
				cell.charge = math.min(maxCharge, cell.charge + ctx.config.Power.CellRechargePerSecond * dt)
				Power.dirty = true
			end
		end
	end
end

-- Prompt wiring: the baked place has prompts on sockets and cells, but until now nothing
-- server-side listened to them. Without this the cell/socket props were decorative.
local wired: { [Instance]: boolean } = {}

local function ensurePrompt(part: BasePart, action: string, object: string): ProximityPrompt
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Parent = part
	end
	prompt.ActionText = action
	prompt.ObjectText = object
	if prompt.HoldDuration <= 0 then
		prompt.HoldDuration = 0.3
	end
	prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, 12)
	return prompt
end

local function wireSocket(key: string, socket)
	if wired[socket.part] then
		return
	end
	wired[socket.part] = true
	local def = consumerDef(socket.consumer)
	local label = socket.isDock and "Cell Charger" or (def and def.Label or key)
	local prompt = ensurePrompt(socket.part, socket.isDock and "Dock Cell" or "Use Socket", label)
	prompt.Triggered:Connect(function(player: Player)
		if not ctx.roundActive() then
			return
		end
		local ok, reason
		if socket.isDock then
			ok, reason = Power.dockCell(player, key)
		elseif Power.cellByHolder(player) then
			ok, reason = Power.insert(player, key)
		else
			ok, reason = Power.eject(player, key)
		end
		if ok then
			ctx.playerService.setCarrying(player, Power.cellByHolder(player) ~= nil)
		elseif reason then
			ctx.notifyPlayer(player, reason, "warn")
		end
	end)
end

local function wireCell(id: string, cell)
	local part = cell.part
	if wired[part] then
		return
	end
	wired[part] = true
	local prompt = ensurePrompt(part, "Pick up Cell", cell.label or "Power Cell")
	prompt.Triggered:Connect(function(player: Player)
		if not ctx.roundActive() then
			return
		end
		local ok, reason = Power.pickup(player, id)
		if ok then
			ctx.playerService.setCarrying(player, true)
		elseif reason then
			ctx.notifyPlayer(player, reason, "warn")
		end
	end)
end

function Power.wirePrompts()
	for key, socket in pairs(Power.sockets) do
		wireSocket(key, socket)
	end
	for id, cell in pairs(Power.cells) do
		wireCell(id, cell)
	end
end

function Power.reset()
	Power.cells = {}
	Power.relayRepaired = false
	Power.capacity = ctx.config.Power.BaseCapacity
	for _, socket in pairs(Power.sockets) do
		socket.cellId = nil
		socket.tripped = false
		socket.trippedReason = nil
	end
	local cellsFolder = ctx.worldFolder:FindFirstChild("Cells")
	if not cellsFolder then
		cellsFolder = Instance.new("Folder")
		cellsFolder.Name = "Cells"
		cellsFolder.Parent = ctx.worldFolder
	end

	-- The baked district already ships four cell props; adopt them so the placed geometry is
	-- the single source of truth (and so two sets of cells can never coexist).
	local definitions = {
		{ id = "Cell_A", partName = "Cell1", position = Vector3.new(-34, 1.6, -20), label = "Pump house pit" },
		{ id = "Cell_B", partName = "Cell2", position = Vector3.new(28, 1.6, 31), label = "Clinic store room" },
		{ id = "Cell_C", partName = "Cell3", position = Vector3.new(38, 14.9, -3), label = "Apartment roof cache" },
		{ id = "Cell_D", partName = "Cell4", position = Vector3.new(64, 2.6, 27.5), label = "Ferry strongbox" },
	}
	for _, def in ipairs(definitions) do
		local part = cellsFolder:FindFirstChild(def.partName)
		if part and part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = true
			part.Transparency = 0
			part.Material = Enum.Material.Neon
			part.Color = Color3.fromRGB(255, 200, 60)
		else
			part = Instance.new("Part")
			part.Name = def.partName
			part.Size = Vector3.new(1.5, 1.5, 1.5)
			part.Material = Enum.Material.Neon
			part.Color = Color3.fromRGB(255, 200, 60)
			part.Anchored = true
			part.CanCollide = true
			part.Position = def.position
			part.Parent = cellsFolder
		end
		Power.cells[def.id] = {
			id = def.id,
			part = part,
			charge = ctx.config.Power.CellChargeMax,
			holder = nil,
			socket = nil,
			destroyed = false,
			label = def.label,
		}
		wired[part] = nil
	end
	ctx.log(`[Power] reset with {#definitions} cells (adopted from baked geometry)`)
	Power.wirePrompts()
	Power.recompute()
end

function Power.Init(context)
	ctx = context
	-- Discover sockets: Socket_<Consumer> plus a Charger dock (Consumer attribute "Charger").
	for name, part in pairs(ctx.world.sockets) do
		local isDock = name == "Charger"
		if consumerDef(name) or isDock then
			Power.sockets[name] = {
				part = part,
				consumer = name,
				cellId = nil,
				tripped = false,
				isDock = isDock,
			}
		end
	end
	Power.capacity = ctx.config.Power.BaseCapacity
end

function Power.Start(context)
	ctx = context
	Power.reset()
	RunService.Heartbeat:Connect(function(dt)
		if ctx.roundActive() then
			Power.update(dt)
		end
	end)
end

return Power
