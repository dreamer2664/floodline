--!nocheck
-- harness.luau — boots the shipped FLOODLINE place inside the stub runtime.
--
-- The geometry, the module sources and the bootstrap script are read from
-- agents/riveter/releases/FLOODLINE.rbxlx, so this exercises the artifact that ships.

local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Stub = require("./roblox_stub")

local Harness = {}
Harness.log = {}

local function note(message: string)
	table.insert(Harness.log, message)
end

-- ============================================================
-- mirror the exported place into stub instances
-- ============================================================
local SERVICE_TARGETS = {
	Workspace = "Workspace",
	ReplicatedStorage = "ReplicatedStorage",
	ServerStorage = "ServerStorage",
	ServerScriptService = "ServerScriptService",
	StarterPlayer = "StarterPlayer",
}

-- @lune/roblox does not implement Model:GetPivot, so measure the bounding box ourselves.
local function sourcePivot(model)
	local min, max
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local half = descendant.Size * 0.5
			local lo = descendant.Position - half
			local hi = descendant.Position + half
			if not min then
				min, max = lo, hi
			else
				min = Stub.v3(math.min(min.X, lo.X), math.min(min.Y, lo.Y), math.min(min.Z, lo.Z))
				max = Stub.v3(math.max(max.X, hi.X), math.max(max.Y, hi.Y), math.max(max.Z, hi.Z))
			end
		end
	end
	if not min then
		return Stub.v3(0, 0, 0)
	end
	return (min + max) * 0.5
end

local function copyInstance(source, parent)
	local target = Stub.Instance.new(source.ClassName)
	target.Name = source.Name
	if source:IsA("BasePart") then
		target.Size = Stub.v3(source.Size.X, source.Size.Y, source.Size.Z)
		target.Position = Stub.v3(source.Position.X, source.Position.Y, source.Position.Z)
		target.CFrame = Stub.cframe(target.Position)
		target.Anchored = source.Anchored
		target.CanCollide = source.CanCollide
		target.CanQuery = source.CanQuery
		target.CanTouch = source.CanTouch
		target.Transparency = source.Transparency
		target.Color = Stub.color3(source.Color.R, source.Color.G, source.Color.B)
		target.Material = source.Material.Name
	elseif source:IsA("ProximityPrompt") then
		target.ActionText = source.ActionText
		target.ObjectText = source.ObjectText
		target.HoldDuration = source.HoldDuration
		target.MaxActivationDistance = source.MaxActivationDistance
	elseif source:IsA("Humanoid") then
		target.MaxHealth = source.MaxHealth
		target.Health = source.Health
		target.WalkSpeed = source.WalkSpeed
	elseif source:IsA("Script") or source:IsA("ModuleScript") or source:IsA("LocalScript") then
		target.Source = source.Source
	elseif source:IsA("StringValue") or source:IsA("IntValue") then
		target.Value = source.Value
	end
	target.Parent = parent
	for _, child in ipairs(source:GetChildren()) do
		copyInstance(child, target)
	end
	if source:IsA("Model") then
		local pivot = sourcePivot(source)
		target.CFrame = Stub.cframe(Stub.v3(pivot.X, pivot.Y, pivot.Z))
	end
	return target
end

function Harness.mountPlace(path: string)
	local place = roblox.deserializePlace(fs.readFile(path))
	local mounted = {}
	-- Always provide every service the game touches, even when the place omits an empty one.
	for className, targetName in pairs(SERVICE_TARGETS) do
		local target = Stub.service(targetName)
		target.ClassName = className
		target.Name = className
		mounted[targetName] = target
	end
	for _, service in ipairs(place:GetChildren()) do
		local targetName = SERVICE_TARGETS[service.ClassName]
		if targetName then
			local target = mounted[targetName]
			for _, child in ipairs(service:GetChildren()) do
				if not target:FindFirstChild(child.Name) then
					copyInstance(child, target)
				end
			end
		end
	end
	Harness.place = place
	Harness.mounted = mounted
	note(`mounted services: {table.concat((function()
		local names = {}
		for name in pairs(mounted) do
			table.insert(names, name)
		end
		table.sort(names)
		return names
	end)(), ", ")}`)
	return mounted
end

-- ============================================================
-- module loading
-- ============================================================
local loaded: { [any]: any } = {}
local loadReport: { { path: string, ok: boolean, error: string? } } = {}

local function instantiate(moduleScript)
	local cached = loaded[moduleScript]
	if cached ~= nil then
		return cached
	end
	local env = Stub.env()
	env.script = moduleScript
	env.require = function(target)
		if type(target) == "table" and target.ClassName then
			return instantiate(target)
		end
		error("unexpected require target: " .. tostring(target))
	end
	local shadow = table.concat({
		"local game, workspace, Workspace, Instance, Vector3, Vector2, UDim, UDim2, CFrame, Color3, Enum, RaycastParams, task, os, typeof, script, require = ...",
		"local _print, _warn, _pcall, _xpcall, _select, _bit32, _string, _table, _math, _coroutine = print, warn, pcall, xpcall, select, bit32, string, table, math, coroutine",
	}, "\n")
	local source = shadow .. "\n" .. moduleScript.Source
	local ok, fnOrErr = pcall(function()
		return luau.load(source, { debugName = moduleScript:GetFullName() })
	end)
	if not ok then
		table.insert(loadReport, { path = moduleScript:GetFullName(), ok = false, error = tostring(fnOrErr) })
		error("compile failure in " .. moduleScript:GetFullName() .. ": " .. tostring(fnOrErr))
	end
	local result = fnOrErr(
		env.game, env.workspace, env.Workspace, env.Instance, env.Vector3, env.Vector2, env.UDim, env.UDim2,
		env.CFrame, env.Color3, env.Enum, env.RaycastParams, env.task, env.os, env.typeof, moduleScript, env.require
	)
	loaded[moduleScript] = result
	table.insert(loadReport, { path = moduleScript:GetFullName(), ok = true })
	return result
end

function Harness.require(instance)
	return instantiate(instance)
end

function Harness.loadReport()
	return loadReport
end

-- ============================================================
-- boot the shipped bootstrap script
-- ============================================================
function Harness.boot()
	local services = Harness.mounted
	local sss = services.ServerScriptService
	assert(sss, "ServerScriptService was not mounted")
	local bootstrap = sss:FindFirstChild("Bootstrap")
	assert(bootstrap, "Bootstrap script missing from the exported place")
	local env = Stub.env()
	env.script = bootstrap
	env.require = function(target)
		return instantiate(target)
	end
	local shadow = table.concat({
		"local game, workspace, Workspace, Instance, Vector3, Vector2, UDim, UDim2, CFrame, Color3, Enum, RaycastParams, task, os, typeof, script, require = ...",
		"local _print, _warn, _pcall, _xpcall, _select, _bit32, _string, _table, _math, _coroutine = print, warn, pcall, xpcall, select, bit32, string, table, math, coroutine",
	}, "\n")
	local source = shadow .. "\n" .. bootstrap.Source
	local fn = luau.load(source, { debugName = "Bootstrap" })
	fn(
		env.game, env.workspace, env.Workspace, env.Instance, env.Vector3, env.Vector2, env.UDim, env.UDim2,
		env.CFrame, env.Color3, env.Enum, env.RaycastParams, env.task, env.os, env.typeof, bootstrap, env.require
	)
	Harness.booted = true
	note("bootstrap executed")
end

-- ============================================================
-- convenience accessors used by the scenarios
-- ============================================================
function Harness.world()
	return Harness.mounted.Workspace:FindFirstChild("World")
end

function Harness.replicated()
	return Harness.mounted.ReplicatedStorage
end

function Harness.servers(): any
	local services = require("./roblox_stub")
	return services
end

function Harness.findDescendantByName(root, name)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant.Name == name then
			return descendant
		end
	end
	return nil
end

function Harness.promptOn(part)
	return part and part:FindFirstChildOfClass("ProximityPrompt") or nil
end

function Harness.trigger(part, player)
	local prompt = Harness.promptOn(part)
	if not prompt then
		return false
	end
	prompt.Triggered:Fire(player)
	return true
end

return Harness
