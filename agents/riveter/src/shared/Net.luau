--!strict
-- Remote plumbing for both realms. The server owns the instances; the client waits for them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}

Net.FOLDER_NAME = "FloodlineNet"

-- Remote inventory: name -> class
Net.Remotes = {
	-- server -> client
	StateSync = "RemoteEvent",
	RoundEvent = "RemoteEvent",
	ObjectiveSync = "RemoteEvent",
	SurvivorSync = "RemoteEvent",
	PowerSync = "RemoteEvent",
	WaterSync = "RemoteEvent",
	Notification = "RemoteEvent",
	LiftSync = "RemoteEvent",
	PlayerEvent = "RemoteEvent",
	RoundSummary = "RemoteEvent",
	PingSync = "RemoteEvent",
	ModifierSync = "RemoteEvent",
	SessionSync = "RemoteEvent",
	RouteSync = "RemoteEvent",
	UpgradeSync = "RemoteEvent",
	CrewSync = "RemoteEvent",
	OutfallSync = "RemoteEvent",
	-- client -> server
	RequestStart = "RemoteEvent",
	RequestRematch = "RemoteEvent",
	RequestInteract = "RemoteEvent",
	RequestSprint = "RemoteEvent",
	RequestDrop = "RemoteEvent",
	RequestLiftCall = "RemoteEvent",
	RequestRevive = "RemoteEvent",
	ReportPosition = "RemoteEvent",
	RequestPing = "RemoteEvent",
	RequestModifier = "RemoteEvent",
	RequestUpgrade = "RemoteEvent",
	RequestRole = "RemoteEvent",
	RequestAbility = "RemoteEvent",
	GetSnapshot = "RemoteFunction",
}

function Net.ensureFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(Net.FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Net.FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	return folder :: Folder
end

function Net.serverInit(): { [string]: Instance }
	local folder = Net.ensureFolder()
	local out = {}
	for name, class in pairs(Net.Remotes) do
		local existing = folder:FindFirstChild(name)
		if not existing then
			existing = Instance.new(class)
			existing.Name = name
			existing.Parent = folder
		end
		out[name] = existing
	end
	return out
end

-- Client-side: wait (bounded) for the server to publish the folder.
function Net.clientInit(timeout: number?): { [string]: Instance }
	local folder = ReplicatedStorage:WaitForChild(Net.FOLDER_NAME, timeout or 20)
	local out = {}
	if not folder then
		warn("[FLOODLINE] net folder unavailable")
		return out
	end
	for name in pairs(Net.Remotes) do
		local inst = folder:WaitForChild(name, 10)
		if inst then
			out[name] = inst
		end
	end
	return out
end

function Net.fire(bag: { [string]: Instance }, name: string, ...)
	local remote = bag[name]
	if remote and remote:IsA("RemoteEvent") then
		remote:FireAllClients(...)
	elseif remote and remote:IsA("RemoteFunction") then
		-- FireAllClients does not exist on RemoteFunction; ignored by design.
	else
		if RunService:IsServer() then
			warn(`[FLOODLINE] missing remote {name}`)
		end
	end
end

function Net.fireClient(bag: { [string]: Instance }, player: Player, name: string, ...)
	local remote = bag[name]
	if remote and remote:IsA("RemoteEvent") then
		remote:FireClient(player, ...)
	end
end

function Net.fireServer(bag: { [string]: Instance }, name: string, ...)
	local remote = bag[name]
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer(...)
	end
end

return Net
