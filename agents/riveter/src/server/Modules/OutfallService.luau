--!strict
-- OutfallService: the district sluice.
--
-- A hand-cranked gate on the canal that pulls water out of every sector while it is open. It costs
-- a body rather than a power cell on purpose: on a four-player crew somebody has to volunteer to
-- stand in the water and crank while the others escort, which is exactly the kind of decision a
-- co-op round should force. It closes itself slowly, so the crew has to keep coming back to it.
--
-- The gate is baked geometry (OutfallGate) that slides straight down as the sluice opens, so the
-- state of the district is readable from across the map without opening a menu.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Outfall = {}
Outfall.Name = "Outfall"

Outfall.open = 0 -- 0 = shut, 1 = wide open
Outfall.work = 0
Outfall.lastCrankAt = 0
Outfall.cranking = {} :: { [Player]: number }
Outfall.opens = 0
Outfall.awardedForOpen = false
Outfall.drained = 0 -- studs of water pulled out of the district this round (all sectors summed)
Outfall.dirty = true
-- Run clock for crank pacing. Wall time is wrong here twice over: the hold is already enforced by
-- the prompt, and a server that is paused or fast-forwarded (headless runs, Studio step-through)
-- would otherwise either spam cranks or refuse every one of them.
Outfall.now = 0
Outfall.gate = nil :: BasePart?
Outfall.closedCFrame = nil :: CFrame?
Outfall.log = {} :: { string }

local ctx

local function config(): any
	return ctx.config.Outfall
end

local function note(message: string)
	table.insert(Outfall.log, message)
	if #Outfall.log > 16 then
		table.remove(Outfall.log, 1)
	end
end

-- Studs of water per second the sluice is currently pulling out of the district.
function Outfall.drainRate(): number
	if not ctx.roundActive() then
		return 0
	end
	return config().DrainPerSecond * Outfall.open
end

function Outfall.isOpen(): boolean
	return Outfall.open > 0.05
end

local function applyGate()
	local gate = Outfall.gate
	local closed = Outfall.closedCFrame
	if not (gate and closed) then
		return
	end
	-- Straight down: the plate sinks into the culvert as the sluice opens.
	gate.CFrame = closed + Vector3.new(0, -config().DropDepth * Outfall.open, 0)
	gate.CanCollide = true
end

function Outfall.setOpen(progress: number)
	local cfg = config()
	Outfall.open = math.clamp(progress, 0, 1)
	Outfall.work = Outfall.open * cfg.OpenSeconds
	applyGate()
	Outfall.dirty = true
end

-- One completed crank hold. The engineer's role passive and an engineer survivor both help.
function Outfall.crank(player: Player, seconds: number?): (boolean, string?)
	local cfg = config()
	if not ctx.roundActive() then
		return false, "The sluice is only worth working during a round."
	end
	if Outfall.open >= 0.999 then
		return false, "The outfall is already wide open."
	end
	if Outfall.lastCrankAt > 0 and Outfall.now - Outfall.lastCrankAt < cfg.CrankCooldown then
		return false, "The wheel is still turning. Keep cranking."
	end
	Outfall.lastCrankAt = Outfall.now
	local work = seconds or cfg.HoldSeconds
	local crew = ctx.crew
	if crew then
		work *= crew.crankMultiplier(player) * crew.holdMultiplier(player)
	end
	local engineer = ctx.rescue.engineerNear(player, 26)
	if engineer then
		work *= cfg.EngineerMultiplier
		ctx.notifyPlayer(player, `{engineer} braces the wheel — it turns faster.`, "good")
	end
	Outfall.cranking[player] = (Outfall.cranking[player] or 0) + work
	local before = Outfall.open
	Outfall.setOpen((Outfall.work + work) / cfg.OpenSeconds)
	-- Pay out once per genuine opening: cranking a sluice that is already wide open (or holding it
	-- at the top) must not farm score. The flag clears only when the sluice swings properly shut.
	if Outfall.open >= 0.999 and not Outfall.awardedForOpen then
		Outfall.awardedForOpen = true
		Outfall.opens += 1
		ctx.addScore(player, cfg.ScorePerOpen, "opened the outfall")
		ctx.notify("Outfall wide open — the district is draining.", "good")
		note(`outfall opened by {player.Name}`)
	end
	return true, nil
end

function Outfall.update(dt: number)
	Outfall.now += dt
	if Outfall.open <= 0 then
		return
	end
	Outfall.dirty = true
	-- It creeps shut: without somebody on the wheel the sluice closes in about 20 seconds.
	local closed = math.min(Outfall.open, config().ClosePerSecond * dt)
	Outfall.setOpen(Outfall.open - closed)
	if Outfall.open < config().ReopenThreshold then
		Outfall.awardedForOpen = false
	end
	if Outfall.open <= 0 then
		ctx.notify("The outfall has swung shut.", "warn")
		note("sluice closed on its own")
	end
end

function Outfall.snapshot()
	return {
		open = Util.round(Outfall.open * 100, 0),
		percent = Util.round(Outfall.open * 100, 0),
		openSeconds = config().OpenSeconds,
		drainPerSecond = Util.round(Outfall.drainRate(), 4),
		opens = Outfall.opens,
		drained = Util.round(Outfall.drained, 2),
		position = Outfall.gate and Outfall.gate.Position or nil,
	}
end

function Outfall.pushSnapshot()
	Outfall.dirty = false
	ctx.remotes.OutfallSync:FireAllClients(Outfall.snapshot())
end

function Outfall.reset()
	Outfall.opens = 0
	Outfall.awardedForOpen = false
	Outfall.drained = 0
	Outfall.cranking = {}
	Outfall.lastCrankAt = 0
	Outfall.now = 0
	Outfall.log = {}
	Outfall.setOpen(0)
	note("round reset: sluice shut")
	Outfall.dirty = true
end

function Outfall.Init(context)
	ctx = context
	local gate = ctx.findWorld(config().Gate)
	if gate and gate:IsA("BasePart") then
		Outfall.gate = gate
		Outfall.closedCFrame = gate.CFrame
	else
		ctx.log("[Outfall] no gate part found; the sluice will run without visible geometry")
	end
	local wheel = ctx.findWorld(config().Wheel)
	if wheel and wheel:IsA("BasePart") then
		local prompt = wheel:FindFirstChildOfClass("ProximityPrompt")
		if not prompt then
			prompt = Instance.new("ProximityPrompt")
			prompt.Parent = wheel
		end
		prompt.ActionText = "Crank Sluice"
		prompt.ObjectText = "District Outfall"
		prompt.HoldDuration = config().HoldSeconds
		prompt.MaxActivationDistance = 12
		prompt.Triggered:Connect(function(player: Player)
			if not ctx.roundActive() then
				return
			end
			local ok, reason = Outfall.crank(player)
			if not ok and reason then
				ctx.notifyPlayer(player, reason, "warn")
			else
				local percent = math.floor(Outfall.open * 100)
				ctx.notifyPlayer(player, `Outfall {percent}% open.`, percent >= 100 and "good" or "info")
			end
		end)
	end
	ctx.log(`[Outfall] wheel={wheel ~= nil} gate={gate ~= nil}`)
end

function Outfall.Start(context)
	ctx = context
	Outfall.reset()
	RunService.Heartbeat:Connect(function(dt)
		if ctx.booted and ctx.roundActive() then
			Outfall.update(math.min(dt, 0.2))
		end
		if Outfall.dirty and ctx.booted then
			Outfall.pushSnapshot()
		end
	end)
end

return Outfall
