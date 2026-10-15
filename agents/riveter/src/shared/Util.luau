--!strict
-- Shared helpers: math, geometry, small collection utilities.

local Util = {}

function Util.clamp(v: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, v))
end

function Util.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function Util.round(v: number, places: number?): number
	local m = 10 ^ (places or 0)
	return math.floor(v * m + 0.5) / m
end

function Util.formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local m = math.floor(seconds / 60)
	local s = seconds % 60
	return string.format("%d:%02d", m, s)
end

function Util.formatClock(seconds: number): string
	return string.format("%02d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
end

-- Knuth-ish deterministic shuffle so a round can be reproduced from a seed.
function Util.shuffle<T>(list: { T }, seed: number?): { T }
	local out = table.clone(list)
	local s = seed or os.time()
	for i = #out, 2, -1 do
		s = (s * 1103515245 + 12345) % 2147483648
		local j = (s % i) + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

function Util.count<T>(list: { T }, predicate: (T) -> boolean): number
	local n = 0
	for _, item in ipairs(list) do
		if predicate(item) then
			n += 1
		end
	end
	return n
end

function Util.filter<T>(list: { T }, predicate: (T) -> boolean): { T }
	local out = {}
	for _, item in ipairs(list) do
		if predicate(item) then
			table.insert(out, item)
		end
	end
	return out
end

function Util.map<T, U>(list: { T }, fn: (T) -> U): { U }
	local out = {}
	for i, item in ipairs(list) do
		out[i] = fn(item)
	end
	return out
end

function Util.find<T>(list: { T }, predicate: (T) -> boolean): T?
	for _, item in ipairs(list) do
		if predicate(item) then
			return item
		end
	end
	return nil
end

function Util.sortedKeys<K, V>(map: { [K]: V }): { K }
	local keys = {}
	for k in pairs(map) do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

function Util.partPosition(instance: Instance): Vector3?
	if instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

function Util.modelBounds(model: Model): (Vector3, Vector3)
	local cf, size = model:GetBoundingBox()
	local min = cf.Position - size * 0.5
	local max = cf.Position + size * 0.5
	return min, max
end

function Util.pointInBounds(point: Vector3, min: Vector3, max: Vector3, pad: number?): boolean
	local p = pad or 0
	return point.X >= min.X - p and point.X <= max.X + p
		and point.Y >= min.Y - p and point.Y <= max.Y + p
		and point.Z >= min.Z - p and point.Z <= max.Z + p
end

function Util.horizontalDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function Util.distance(a: Vector3, b: Vector3): number
	return (a - b).Magnitude
end

-- Round a vector to a readable string, used in logs/evidence.
function Util.v3str(v: Vector3): string
	return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z)
end

function Util.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value :: any) do
		out[k] = Util.deepCopy(v)
	end
	return (out :: any) :: T
end

function Util.merge(...: { [any]: any }): { [any]: any }
	local out = {}
	for _, tbl in ipairs({ ... }) do
		for k, v in pairs(tbl) do
			out[k] = v
		end
	end
	return out
end

-- Safe sound helper: silently no-ops if the internal asset is unavailable.
function Util.playSound(parent: Instance, soundId: string, volume: number?, pitch: number?)
	local ok, err = pcall(function()
		local sound = Instance.new("Sound")
		sound.SoundId = soundId
		sound.Volume = volume or 0.6
		sound.PlaybackSpeed = pitch or 1
		sound.RollOffMaxDistance = 90
		sound.Parent = parent
		sound:Play()
		task.delay(6, function()
			sound:Destroy()
		end)
	end)
	if not ok then
		warn("[FLOODLINE] sound skipped: " .. tostring(err))
	end
end

return Util
