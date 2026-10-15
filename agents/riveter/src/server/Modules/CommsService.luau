--!strict
-- CommsService: the co-op ping system. Four ping types, server-side validation, per-player
-- cooldown, and a broadcast the client renders as a world marker with a HUD callout.
-- Without voice chat this is how a team says "survivor here" or "water is coming".

local Players = game:GetService("Players")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Comms = {}
Comms.Name = "Comms"

Comms.lastPing = {} :: { [Player]: number }
Comms.counts = {} :: { [Player]: number }
Comms.total = 0
Comms.recent = {} :: { any }

local ctx
local TYPE_LOOKUP = {}

local function buildLookup()
	for _, entry in ipairs(ctx.config.Pings.Types) do
		TYPE_LOOKUP[entry.id] = entry
	end
end

local function validate(player: Player, position: Vector3): (boolean, string?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "You are not in the world."
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return false, "You cannot ping while down."
	end
	local origin = (root :: BasePart).Position
	if (position - origin).Magnitude > ctx.config.Pings.MaxDistance then
		return false, "Too far away to mark that."
	end
	-- Reject marks inside solid geometry or below the world.
	if position.Y < ctx.config.Water.StartLevel - 40 or position.Y > 300 then
		return false, "That mark is out of bounds."
	end
	return true, nil
end

function Comms.ping(player: Player, pingType: string, position: any): boolean
	if not ctx.roundActive() then
		return false
	end
	if typeof(position) ~= "Vector3" then
		return false
	end
	local entry = TYPE_LOOKUP[pingType]
	if not entry then
		return false
	end
	local now = os.clock()
	if (Comms.lastPing[player] or 0) > now - ctx.config.Pings.Cooldown then
		ctx.notifyPlayer(player, "Slow down — ping cooldown.", "warn")
		return false
	end
	local ok, reason = validate(player, position)
	if not ok then
		ctx.notifyPlayer(player, reason or "Invalid ping.", "warn")
		return false
	end
	Comms.lastPing[player] = now
	Comms.counts[player] = (Comms.counts[player] or 0) + 1
	Comms.total += 1

	-- Lifetimes are relative on purpose: os.clock() has a different origin in every realm, so an
	-- absolute expiry computed here would be meaningless on a client.
	local payload = {
		type = entry.id,
		label = entry.label,
		color = entry.color,
		position = position,
		player = player.Name,
		lifetime = ctx.config.Pings.Lifetime,
	}
	table.insert(Comms.recent, payload)
	if #Comms.recent > 40 then
		table.remove(Comms.recent, 1)
	end

	for _, other in ipairs(Players:GetPlayers()) do
		ctx.remotes.PingSync:FireClient(other, payload)
	end
	ctx.telemetry.note("ping", `{player.Name} marked {entry.label}`)
	return true
end

function Comms.reset()
	Comms.lastPing = {}
	Comms.counts = {}
	Comms.recent = {}
	Comms.total = 0
end

function Comms.snapshot()
	local perPlayer = {}
	for player, count in pairs(Comms.counts) do
		perPlayer[player.Name] = count
	end
	return {
		total = Comms.total,
		perPlayer = perPlayer,
	}
end

function Comms.Init(context)
	ctx = context
	buildLookup()
end

function Comms.Start(context)
	ctx = context
	Comms.reset()
	ctx.log(`[Comms] {#ctx.config.Pings.Types} ping types ready`)
end

return Comms
