--!strict
-- ObjectiveService: turns live world state into an ordered, per-round objective list that the
-- HUD renders with world markers. Also drives the "what do I do now" guidance for new players.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Objective = {}
Objective.Name = "Objective"

export type Entry = {
	id: string,
	title: string,
	detail: string,
	status: string, -- pending | active | done
	target: Vector3?,
	priority: number,
}

Objective.list = {} :: { Entry }
Objective.dirty = true
Objective.lastPush = 0
local ctx

local function findNearestCellPosition(player: Player?): Vector3?
	local best: Vector3? = nil
	local bestDistance = math.huge
	local origin = nil
	if player and player.Character then
		local root = player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			origin = (root :: BasePart).Position
		end
	end
	for _, cell in pairs(ctx.power.cells) do
		if cell.destroyed then
			continue
		end
		if cell.holder or cell.socket then
			continue
		end
		local distance = origin and (cell.part.Position - origin).Magnitude or 0
		if distance < bestDistance then
			bestDistance = distance
			best = cell.part.Position
		end
	end
	return best
end

local function nearestSurvivorPosition(player: Player?): (Vector3?, string?)
	local best: Vector3? = nil
	local label: string? = nil
	local bestDistance = math.huge
	local origin = nil
	if player and player.Character then
		local root = player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			origin = (root :: BasePart).Position
		end
	end
	for _, survivor in ipairs(ctx.rescue.alive()) do
		local distance = origin and (survivor.position - origin).Magnitude or 0
		if survivor.state == "Downed" then
			distance -= 25 -- downed survivors are urgent
		end
		if distance < bestDistance then
			bestDistance = distance
			best = survivor.position
			label = survivor.name
		end
	end
	return best, label
end

function Objective.rebuild(player: Player?)
	local list: { Entry } = {}
	local power = ctx.power

	local cellsAvailable = 0
	for _, cell in pairs(power.cells) do
		if not cell.destroyed and not cell.holder and not cell.socket then
			cellsAvailable += 1
		end
	end

	list[#list + 1] = {
		id = "cells",
		title = "Recover power cells",
		detail = cellsAvailable > 0 and `{cellsAvailable} cell(s) still in the district. Dock one at the terminal or a socket.`
			or "All cells are deployed. Watch their charge.",
		status = (power.consumers.Pump.powered or power.consumers.Lift.powered) and "done" or "active",
		target = findNearestCellPosition(player),
		priority = 1,
	}

	local pumpPowered = power.consumers.Pump.powered
	list[#list + 1] = {
		id = "pump",
		title = "Hold back the water",
		detail = pumpPowered
			and `Pump running. Rise is at {Util.round(ctx.flood.riseRate * 0.28, 3)} studs/s.`
			or "Feed the pump socket in the terminal to slow the flood.",
		status = pumpPowered and "done" or "active",
		target = ctx.world.sockets.Pump and ctx.world.sockets.Pump.Position,
		priority = 2,
	}

	list[#list + 1] = {
		id = "relay",
		title = "Repair the relay tower",
		detail = power.relayRepaired and "Relay online: grid capacity increased."
			or "Find the fuse in the workshop, fit it in the tower control box.",
		status = power.relayRepaired and "done" or "active",
		target = ctx.worldFolder:FindFirstChild("RelaySlot") and (ctx.worldFolder:FindFirstChild("RelaySlot") :: BasePart).Position,
		priority = 3,
	}

	list[#list + 1] = {
		id = "lift",
		title = "Power the evac lift",
		detail = power.consumers.Lift.powered and "Lift powered — load survivors and ride to the pad."
			or "Feed the lift socket so the lift can carry passengers.",
		status = power.consumers.Lift.powered and "done" or "active",
		target = ctx.world.sockets.Lift and ctx.world.sockets.Lift.Position,
		priority = 4,
	}

	local rescued = ctx.rescue.rescuedCount
	local required = ctx.rescue.requiredRescued()
	local survivorPosition, survivorName = nearestSurvivorPosition(player)
	list[#list + 1] = {
		id = "rescue",
		title = `Escort survivors to safety ({rescued}/{required} required)`,
		detail = survivorName and `Nearest: {survivorName}` or "No survivors left in the district.",
		status = rescued >= required and "done" or "active",
		target = survivorPosition,
		priority = rescued >= required and 6 or 1,
	}

	local pad = ctx.padPart()
	list[#list + 1] = {
		id = "extract",
		title = ctx.round.radioCalled and "Extraction authorised — reach the pad" or "Call the evacuation on the relay radio",
		detail = ctx.round.radioCalled and "Lift is the only way to the pad."
			or "Fetch the radio from the tower control box and call it in.",
		status = ctx.round.extracted and "done" or (ctx.round.radioCalled and "active" or "pending"),
		target = pad and pad.Position,
		priority = 5,
	}

	table.sort(list, function(a, b)
		if a.status ~= b.status then
			return a.status == "active"
		end
		return a.priority < b.priority
	end)

	Objective.list = list
	Objective.dirty = true
end

function Objective.push(player: Player?)
	local payload = {}
	for _, entry in ipairs(Objective.list) do
		payload[#payload + 1] = {
			id = entry.id,
			title = entry.title,
			detail = entry.detail,
			status = entry.status,
			target = entry.target,
			priority = entry.priority,
		}
	end
	if player then
		ctx.remotes.ObjectiveSync:FireClient(player, payload)
	else
		ctx.remotes.ObjectiveSync:FireAllClients(payload)
	end
	Objective.dirty = false
	Objective.lastPush = os.clock()
end

function Objective.markDirty()
	Objective.dirty = true
end

function Objective.snapshot()
	local out = {}
	for _, entry in ipairs(Objective.list) do
		out[#out + 1] = { id = entry.id, title = entry.title, status = entry.status }
	end
	return out
end

function Objective.Init(context)
	ctx = context
end

function Objective.Start(context)
	ctx = context
	Objective.rebuild()
	RunService.Heartbeat:Connect(function()
		if Objective.dirty and ctx.roundActive() then
			Objective.push()
		end
	end)
	Players.PlayerAdded:Connect(function(player)
		task.wait(2)
		Objective.rebuild(player)
		Objective.push(player)
	end)
end

return Objective
