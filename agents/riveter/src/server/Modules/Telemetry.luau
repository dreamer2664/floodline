--!strict
-- Telemetry: an append-only round log. It is the honest evidence trail for what actually
-- happened in a session, written to ServerStorage so it can be inspected after a playtest.

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local Telemetry = {}
Telemetry.Name = "Telemetry"

Telemetry.timeline = {} :: { any }
Telemetry.roundIndex = 0
local ctx

function Telemetry.note(kind: string, message: string, data: any?)
	table.insert(Telemetry.timeline, {
		t = os.clock(),
		kind = kind,
		message = message,
		data = data,
	})
	if #Telemetry.timeline % 25 == 0 then
		Telemetry.flush()
	end
end

function Telemetry.recent(count: number)
	local out = {}
	for i = math.max(1, #Telemetry.timeline - count + 1), #Telemetry.timeline do
		table.insert(out, Telemetry.timeline[i])
	end
	return out
end

function Telemetry.reset()
	Telemetry.timeline = {}
	Telemetry.roundIndex += 1
	Telemetry.note("round", `round {Telemetry.roundIndex} beginning`)
end

function Telemetry.flush(summary: any?)
	local folder = ServerStorage:FindFirstChild("FloodlineLogs")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "FloodlineLogs"
		folder.Parent = ServerStorage
	end
	local payload = {
		roundIndex = Telemetry.roundIndex,
		version = ctx.config.Game.Version,
		writtenAt = os.time(),
		players = ctx.playerCount(),
		game = {
			version = ctx.config.Game.Version,
			scaling = ctx.scaling(),
		},
		world = {
			zones = (function()
				local names = {}
				for name in pairs(ctx.world.zones) do
					table.insert(names, name)
				end
				table.sort(names)
				return names
			end)(),
			sockets = (function()
				local names = {}
				for name in pairs(ctx.world.sockets) do
					table.insert(names, name)
				end
				table.sort(names)
				return names
			end)(),
			survivors = #ctx.rescue.order,
		},
		timeline = Telemetry.timeline,
		summary = summary,
	}
	local value = folder:FindFirstChild(`Round_{Telemetry.roundIndex}`)
	if not value then
		value = Instance.new("StringValue")
		value.Name = `Round_{Telemetry.roundIndex}`
		value.Parent = folder
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		(value :: StringValue).Value = encoded
	end
	return payload
end

function Telemetry.Init(context)
	ctx = context
end

return Telemetry
