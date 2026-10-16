--!strict
-- DoorService: hinged doors that players can open and close.
-- Closing a door seals its interior: the zone inside then floods noticeably later, which turns
-- door discipline into a real defensive decision instead of decoration.

local RunService = game:GetService("RunService")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Doors = {}
Doors.Name = "Doors"

export type Door = {
	part: BasePart,
	zone: string,
	closed: boolean,
	angle: number,
	target: number,
	hinge: CFrame,
	label: string,
}

Doors.list = {} :: { Door }
Doors.byPart = {} :: { [BasePart]: Door }
Doors.closedZones = {} :: { [string]: boolean }

local ctx
local STEP = math.rad(1)

-- Re-apply every sealed zone after the Seal Kit upgrade lands.
function Doors.refreshSeals()
	local strength = ctx.upgrade and ctx.upgrade.sealMultiplier() or 1
	for zoneName, closed in pairs(Doors.closedZones) do
		ctx.world.setSealed(zoneName, closed, strength)
	end
end

function Doors.isZoneSealed(zoneName: string): boolean
	return Doors.closedZones[zoneName] == true
end

function Doors.sealedZoneCount(): number
	local n = 0
	for _, closed in pairs(Doors.closedZones) do
		if closed then
			n += 1
		end
	end
	return n
end

local function apply(door: Door)
	local progress = math.abs(door.angle) / math.max(0.001, math.rad(ctx.config.Doors.OpenAngle))
	door.part.CFrame = door.hinge * CFrame.Angles(0, math.rad(door.angle), 0)
	door.part.CanCollide = door.angle < math.rad(35)
	-- A door mid-swing blocks less; a closed door is solid and slightly glossy (sealed).
	door.part.Transparency = 0.05
	local zoneName = door.zone
	local anyClosed = false
	for _, other in ipairs(Doors.list) do
		if other.zone == zoneName and other.closed then
			anyClosed = true
			break
		end
	end
	Doors.closedZones[zoneName] = anyClosed
	local strength = ctx.upgrade and ctx.upgrade.sealMultiplier() or 1
	ctx.world.setSealed(door.zone, anyClosed, strength)
end

function Doors.set(door: Door, closed: boolean, instant: boolean?)
	door.closed = closed
	door.target = closed and 0 or -ctx.config.Doors.OpenAngle
	if instant then
		door.angle = door.target
		apply(door)
	end
end

function Doors.toggle(player: Player, part: BasePart): (boolean, string?)
	local door = Doors.byPart[part]
	if not door then
		return false, "That door will not move."
	end
	Doors.set(door, not door.closed)
	local stateText = door.closed and "closed (the room will hold water back)" or "open (water can flow through)"
	ctx.notifyPlayer(player, `{door.label} {stateText}.`, "info")
	Util.playSound(part, ctx.config.Fx.PingSounds.Switch, 0.4, door.closed and 0.85 or 1.15)
	ctx.telemetry.note("door", `{door.label} {door.closed and "closed" or "opened"} by {player.Name}`)
	ctx.objective.markDirty()
	return true, nil
end

function Doors.reset()
	for _, door in ipairs(Doors.list) do
		Doors.set(door, false, true)
	end
	-- Terminal and Clinic doors start closed: the crew re-opened the command post, nothing else.
	for _, door in ipairs(Doors.list) do
		if door.zone == "Clinic" then
			Doors.set(door, true, true)
		end
	end
end

function Doors.update(dt: number)
	local speed = (ctx.config.Doors.OpenAngle / ctx.config.Doors.SwingSeconds) * dt
	for _, door in ipairs(Doors.list) do
		if math.abs(door.angle - door.target) < speed then
			if door.angle ~= door.target then
				door.angle = door.target
				apply(door)
			end
		else
			door.angle += (door.target > door.angle) and speed or -speed
			apply(door)
		end
	end
end

local function discover()
	Doors.list = {}
	Doors.byPart = {}
	local world = ctx.worldFolder
	for _, descendant in ipairs(world:GetDescendants()) do
		if descendant:IsA("BasePart") and string.sub(descendant.Name, 1, 5) == "Door_" then
			local zoneName = string.sub(descendant.Name, 6)
			-- The hinge sits on the door's short edge: X-facing doors hinge on -X, Z-facing on -Z.
			local size = descendant.Size
			local hingeOffset = (size.Z > size.X) and Vector3.new(0, 0, size.Z * 0.5) or Vector3.new(size.X * 0.5, 0, 0)
			local hingePosition = descendant.Position - hingeOffset
			local door: Door = {
				part = descendant,
				zone = zoneName,
				closed = false,
				angle = -ctx.config.Doors.OpenAngle,
				target = -ctx.config.Doors.OpenAngle,
				hinge = CFrame.new(hingePosition) * (descendant.CFrame - descendant.Position),
				label = `{zoneName} door`,
			}
			table.insert(Doors.list, door)
			Doors.byPart[descendant] = door
			local prompt = descendant:FindFirstChildOfClass("ProximityPrompt")
			if not prompt then
				prompt = Instance.new("ProximityPrompt")
				prompt.Parent = descendant
			end
			prompt.ActionText = "Toggle Door"
			prompt.ObjectText = door.label
			prompt.HoldDuration = 0.2
			prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, 12)
			prompt.Triggered:Connect(function(player: Player)
				if ctx.roundActive() then
					Doors.toggle(player, descendant)
				end
			end)
		end
	end
	ctx.log(`[Doors] {#Doors.list} hinged doors wired`)
end

function Doors.Init(context)
	ctx = context
	discover()
end

function Doors.Start(context)
	ctx = context
	Doors.reset()
	RunService.Heartbeat:Connect(function(dt)
		if ctx.booted then
			Doors.update(math.min(dt, 0.2))
		end
	end)
end

return Doors
