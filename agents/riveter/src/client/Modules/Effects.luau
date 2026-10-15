--!strict
-- Effects: camera-side feedback only — underwater tint/blur, drowning vignette, water line
-- colour grading, downed desaturation and storm flashes. Nothing here changes gameplay state.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local Effects = {}
Effects.Name = "Effects"

local player = Players.LocalPlayer
local submerged = false
local downed = false
local effectFolder = nil
local colorCorrection: ColorCorrectionEffect
local blur: BlurEffect
local vignette: Frame
local vignetteStroke: UIStroke

function Effects.build()
	effectFolder = Lighting:FindFirstChild("FloodlineGrade")
	if not effectFolder then
		effectFolder = Instance.new("Folder")
		effectFolder.Name = "FloodlineGrade"
		effectFolder.Parent = Lighting
	end
	local cc = effectFolder:FindFirstChild("Grade")
	if not cc then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "Grade"
		cc.Parent = effectFolder
	end
	colorCorrection = cc :: ColorCorrectionEffect
	local bl = effectFolder:FindFirstChild("DepthBlur")
	if not bl then
		bl = Instance.new("BlurEffect")
		bl.Name = "DepthBlur"
		bl.Size = 0
		bl.Parent = effectFolder
	end
	blur = bl :: BlurEffect

	Lighting.Brightness = 1.6
	Lighting.OutdoorAmbient = Color3.fromRGB(58, 66, 78)
	Lighting.Ambient = Color3.fromRGB(46, 52, 62)
	Lighting.ClockTime = 17.4
	Lighting.FogColor = Color3.fromRGB(78, 92, 104)
	Lighting.FogStart = 90
	Lighting.FogEnd = 420
	Lighting.ShadowSoftness = 0.35
	Lighting.EnvironmentDiffuseScale = 0.35

	local playerGui = player:WaitForChild("PlayerGui")
	local hud = playerGui:FindFirstChild("FloodlineHud")
	if hud then
		local frame = Instance.new("Frame")
		frame.Name = "Vignette"
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundTransparency = 1
		frame.ZIndex = 5
		frame.Parent = hud
		vignette = frame
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 0
		stroke.Color = Color3.fromRGB(120, 20, 20)
		stroke.Transparency = 0.2
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = frame
		vignetteStroke = stroke
	end
end

function Effects.setWater(snapshot: any, myDepth: number, isSubmerged: boolean, isDowned: boolean)
	submerged = isSubmerged
	downed = isDowned
	local submergeAmount = math.clamp(myDepth / 6, 0, 1)
	if isSubmerged then
		colorCorrection.TintColor = Color3.fromRGB(140, 190, 220)
		colorCorrection.Saturation = -0.25
		colorCorrection.Brightness = -0.12
		blur.Size = 10
	else
		colorCorrection.TintColor = Color3.fromRGB(255, 250, 242)
		colorCorrection.Saturation = -0.05 - submergeAmount * 0.1
		colorCorrection.Brightness = 0.02
		blur.Size = submergeAmount * 2.5
	end
	if downed then
		colorCorrection.Saturation = -0.75
		colorCorrection.Brightness = -0.25
		blur.Size = 14
	end
	if vignetteStroke then
		local healthFactor = 1
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			healthFactor = math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1)
		end
		local intensity = (1 - healthFactor) * 0.9
		if downed then
			intensity = 1
		end
		vignetteStroke.Thickness = intensity * 26
		vignetteStroke.Transparency = 0.55 - intensity * 0.35
	end
	-- Rising water tint on the sky/fog so the pressure reads even indoors.
	local level = snapshot.level or 0
	local ratio = math.clamp(level / Config.Water.MaxLevel, 0, 1)
	Lighting.FogColor = Color3.fromRGB(78, 92, 104):Lerp(Color3.fromRGB(58, 84, 104), ratio)
	Lighting.FogEnd = 420 - ratio * 210
end

function Effects.Init()
	Effects.build()
end

return Effects
