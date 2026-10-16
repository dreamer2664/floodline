--!strict
-- LiftService: the passenger evacuation lift. Vertical travel between the safe zone and the
-- relay-tower extraction pad, capacity limits, power dependency, stall-on-brownout and the
-- "load survivors" interaction. Riders are welded via Seats so they move with the cabin.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Lift = {}
Lift.Name = "Lift"

Lift.state = "Idle" -- Idle | Boarding | Moving | Dwell | Returning | Stalled
Lift.progress = 0
Lift.passengers = {} :: { any }
Lift.playerRiders = {} :: { [Player]: boolean }
Lift.called = false
Lift.direction = 1
Lift.timer = 0
Lift.dirty = true
Lift.stalls = 0

local ctx
local platform: BasePart? = nil
local model: Model? = nil
local wired: { [Instance]: boolean } = {}

local function config()
	return ctx.config.Lift
end

-- Effective travel time / cabin capacity after the Lift Servo upgrade.
local function travelSeconds(): number
	local servo = ctx.upgrade and ctx.upgrade.liftServo() or { speed = 1, capacity = 0 }
	return config().TravelSeconds / servo.speed
end

local function capacity(): number
	local servo = ctx.upgrade and ctx.upgrade.liftServo() or { speed = 1, capacity = 0 }
	return config().Capacity + servo.capacity
end

-- Called when an upgrade changes the servo mid-round so the snapshot and prompts agree.
function Lift.refresh()
	Lift.setDirty()
end

function Lift.baseCFrame(): CFrame
	local cfg = config()
	return CFrame.new(cfg.BasePosition)
end

function Lift.topCFrame(): CFrame
	local cfg = config()
	return CFrame.new(cfg.TopPosition)
end

function Lift.passengerCount(): number
	return #Lift.passengers
end

function Lift.isAtBase(): boolean
	return Lift.progress <= 0.01
end

function Lift.isAtTop(): boolean
	return Lift.progress >= 0.99
end

function Lift.setDirty()
	Lift.dirty = true
end

local function applyProgress(progress: number)
	if not model then
		return
	end
	local eased = progress * progress * (3 - 2 * progress)
	local base = Lift.baseCFrame()
	local top = Lift.topCFrame()
	local cframe = base:Lerp(top, eased)
	model:PivotTo(cframe)
end

function Lift.call(player: Player?): (boolean, string?)
	if not model then
		return false, "Lift unavailable."
	end
	if not ctx.power.isPowered("Lift") then
		return false, "The lift has no power. Feed the lift socket."
	end
	if Lift.state == "Moving" or Lift.state == "Returning" then
		return false, "Lift is already moving."
	end
	Lift.called = true
	if Lift.isAtBase() then
		Lift.state = "Boarding"
		Lift.timer = config().DwellSeconds
		if player then
			ctx.notifyPlayer(player, "Lift opening at the safe zone.", "good")
		end
	else
		Lift.state = "Returning"
		Lift.direction = -1
		if player then
			ctx.notifyPlayer(player, "Lift returning to the safe zone.", "good")
		end
	end
	Lift.setDirty()
	return true, nil
end

-- Load nearby survivors into the cabin.
function Lift.load(player: Player?): (boolean, string?)
	if not ctx.power.isPowered("Lift") then
		return false, "The lift has no power."
	end
	if not Lift.isAtBase() or (Lift.state ~= "Idle" and Lift.state ~= "Boarding") then
		return false, "The lift must be resting at the safe zone to load."
	end
	local room = capacity()
	local boarded = 0
	local candidates = ctx.rescue.alive()
	for _, survivor in ipairs(candidates) do
		if #Lift.passengers >= room or boarded >= room then
			break
		end
		if survivor.boarding or survivor.state == "Following" and survivor.leader ~= player then
			continue
		end
		local distance = (survivor.position - Lift.baseCFrame().Position).Magnitude
		if distance <= config().CallRadius then
			Lift.boardSurvivor(survivor)
			boarded += 1
		end
	end
	if boarded == 0 then
		return false, "Nobody able to board within reach."
	end
	Lift.state = "Boarding"
	Lift.timer = math.max(Lift.timer, 1.2)
	Lift.setDirty()
	return true, nil
end

function Lift.boardSurvivor(survivor): boolean
	if #Lift.passengers >= capacity() then
		return false
	end
	if survivor.state == "Rescued" or survivor.state == "Dead" then
		return false
	end
	survivor.boarding = true
	survivor.state = "Assisting"
	table.insert(Lift.passengers, survivor)
	ctx.log(`[Lift] {survivor.name} boarded ({#Lift.passengers}/{capacity()})`)
	Lift.setDirty()
	return true
end

function Lift.unloadSurvivors()
	local pad = ctx.padPart()
	local base = Lift.topCFrame()
	for _, survivor in ipairs(Lift.passengers) do
		survivor.boarding = false
		survivor.state = "Idle"
		survivor.homePosition = pad and pad.Position or (base.Position + Vector3.new(0, 0, -4))
		survivor.safeSeconds = 0
	end
	ctx.log(`[Lift] unloaded {#Lift.passengers} survivors at the pad`)
	Lift.passengers = {}
	Lift.setDirty()
end

-- Passengers ride with the cabin: reuse the rescue rig writer with the lift delta.
function Lift.moveSurvivors(delta: CFrame)
	for index, survivor in ipairs(Lift.passengers) do
		-- Simple slot layout inside the cabin so they do not stand inside each other.
		local slot = Vector3.new(((index - 1) % 2) * 2.4 - 1.2, 1.55, (math.floor((index - 1) / 2)) * 2.4 - 1.2)
		local cabin = Lift.baseCFrame():Lerp(Lift.topCFrame(), Lift.progress * Lift.progress * (3 - 2 * Lift.progress))
		ctx.rescue.setRigPosition(survivor, cabin * slot)
	end
end

function Lift.playerOnLift(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart then
		return true
	end
	local position = (root :: BasePart).Position
	return (position - (Lift.baseCFrame().Position + Vector3.new(0, Lift.progress * 14.2, 0))).Magnitude <= 8
end

function Lift.update(dt: number)
	if not model then
		return
	end
	local cfg = config()
	local powered = ctx.power.isPowered("Lift")

	if Lift.state == "Moving" or Lift.state == "Returning" then
		if not powered then
			Lift.stalls += 1
			Lift.state = "Stalled"
			ctx.notify("The lift stalled — power was cut mid-travel.", "bad")
			Lift.setDirty()
		end
	end

	if Lift.state == "Stalled" then
		if powered then
			ctx.notify("Lift power restored. Resuming.", "good")
			Lift.state = Lift.direction > 0 and "Moving" or "Returning"
			Lift.setDirty()
		else
			return
		end
	end

	if Lift.state == "Boarding" then
		Lift.timer -= dt
		if not powered then
			-- Keep waiting, but never leave the base.
			return
		end
		if Lift.timer <= 0 and #Lift.passengers > 0 then
			Lift.state = "Moving"
			Lift.direction = 1
			ctx.notify(`Lift ascending with {#Lift.passengers} survivors.`, "good")
			Util.playSound(platform or model, ctx.config.Fx.PingSounds.Switch, 0.5, 0.9)
			Lift.setDirty()
		elseif Lift.timer <= 0 then
			Lift.state = "Idle"
			Lift.setDirty()
		end
		return
	end

	if Lift.state == "Moving" then
		local before = Lift.baseCFrame():Lerp(Lift.topCFrame(), Lift.progress * Lift.progress * (3 - 2 * Lift.progress))
		Lift.progress = math.min(1, Lift.progress + dt / travelSeconds())
		local eased = Lift.progress * Lift.progress * (3 - 2 * Lift.progress)
		local after = Lift.baseCFrame():Lerp(Lift.topCFrame(), eased)
		applyProgress(Lift.progress)
		Lift.moveSurvivors(after * before:Inverse())
		if Lift.progress >= 1 then
			Lift.state = "Dwell"
			Lift.timer = cfg.DwellSeconds
			Lift.unloadSurvivors()
			Util.playSound(platform or model, ctx.config.Fx.PingSounds.Prompt, 0.5, 0.8)
			Lift.setDirty()
		end
		return
	end

	if Lift.state == "Dwell" then
		Lift.timer -= dt
		if Lift.timer <= 0 then
			Lift.state = "Returning"
			Lift.direction = -1
			Lift.setDirty()
		end
		return
	end

	if Lift.state == "Returning" then
		Lift.progress = math.max(0, Lift.progress - dt / travelSeconds())
		applyProgress(Lift.progress)
		if Lift.progress <= 0 then
			Lift.state = "Idle"
			Lift.direction = 0
			Lift.called = false
			Lift.setDirty()
		end
		return
	end
end

function Lift.snapshot()
	return {
		state = Lift.state,
		progress = Util.round(Lift.progress * 100, 0),
		passengers = #Lift.passengers,
		capacity = capacity(),
		powered = ctx.power.isPowered("Lift"),
		atBase = Lift.isAtBase(),
	}
end

function Lift.pushSnapshot()
	Lift.dirty = false
	ctx.remotes.LiftSync:FireAllClients(Lift.snapshot())
end

function Lift.reset()
	Lift.state = "Idle"
	Lift.progress = 0
	Lift.passengers = {}
	Lift.called = false
	Lift.direction = 0
	Lift.timer = 0
	Lift.stalls = 0
	model = ctx.world.lift
	if model then
		local platformPart = model:FindFirstChild("Platform")
		platform = platformPart and platformPart:IsA("BasePart") and platformPart or nil
		applyProgress(0)
	end
	Lift.setDirty()
end

function Lift.Init(context)
	ctx = context
	model = ctx.world.lift
	local platformPart = model and model:FindFirstChild("Platform")
	platform = (platformPart and platformPart:IsA("BasePart")) and platformPart or nil
	-- Call buttons live in different landmark models (ground floor and pad) and the pad is
	-- nested inside the evac complex, so resolve them through the cached world lookup.
	for _, partName in ipairs({ "LiftCall", "LiftCallTop", "ExtractionPad" }) do
		local part = ctx.findWorld(partName)
		if part and part:IsA("BasePart") then
			local prompt = part:FindFirstChildOfClass("ProximityPrompt")
			if not prompt then
				prompt = Instance.new("ProximityPrompt")
				prompt.Parent = part
			end
			prompt.ActionText = "Call Lift"
			prompt.ObjectText = partName == "ExtractionPad" and "Extraction Pad" or "Evac Lift"
			prompt.HoldDuration = 0.3
			prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, 12)
			if not wired[part] then
				wired[part] = true
				prompt.Triggered:Connect(function(player: Player)
					Lift.call(player)
				end)
			end
		end
	end
	if platform then
		local prompt = platform:FindFirstChildOfClass("ProximityPrompt")
		if not prompt then
			prompt = Instance.new("ProximityPrompt")
			prompt.Parent = platform
		end
		prompt.ActionText = "Load Survivors"
		prompt.ObjectText = "Evac Lift"
		prompt.HoldDuration = 0.35
		prompt.MaxActivationDistance = 12
		prompt.Triggered:Connect(function(player: Player)
			Lift.load(player)
		end)
	end
end

function Lift.Start(context)
	ctx = context
	Lift.reset()
	RunService.Heartbeat:Connect(function(dt)
		if ctx.roundActive() then
			Lift.update(math.min(dt, 0.2))
		end
		if Lift.dirty then
			Lift.pushSnapshot()
		end
	end)
end

return Lift
