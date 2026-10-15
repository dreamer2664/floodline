local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local EvtState = Remotes:WaitForChild("RoundState")
local EvtHUD = Remotes:WaitForChild("HUDMessage")
local EvtPower = Remotes:WaitForChild("PowerUpdate")
local EvtRequestStart = Remotes:WaitForChild("RequestStart")
local EvtCallLiftUI = Remotes:WaitForChild("CallLiftUI")

local screen = Instance.new("ScreenGui")
screen.Name = "FloodHUD"
screen.ResetOnSpawn = false
screen.Parent = playerGui

local function label(name, pos, size, text)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Position = pos
	l.Size = size
	l.BackgroundTransparency = 0.35
	l.BackgroundColor3 = Color3.fromRGB(10, 20, 35)
	l.TextColor3 = Color3.fromRGB(230, 240, 255)
	l.TextScaled = true
	l.Font = Enum.Font.GothamBold
	l.Text = text
	l.Parent = screen
	return l
end

local title = label("Title", UDim2.new(0.02,0,0.02,0), UDim2.new(0.4,0,0.06,0), "FLOODLINE: Last District")
local timer = label("Timer", UDim2.new(0.78,0,0.02,0), UDim2.new(0.2,0,0.06,0), "Time: --")
local obj = label("Objective", UDim2.new(0.02,0,0.09,0), UDim2.new(0.6,0,0.06,0), "Objective: survive and extract")
local power = label("Power", UDim2.new(0.02,0,0.16,0), UDim2.new(0.6,0,0.06,0), "Power: none")
local msg = label("Message", UDim2.new(0.02,0,0.86,0), UDim2.new(0.96,0,0.1,0), "Welcome. Press Start when ready.")

local startBtn = Instance.new("TextButton")
startBtn.Name = "StartButton"
startBtn.Position = UDim2.new(0.35,0,0.7,0)
startBtn.Size = UDim2.new(0.3,0,0.08,0)
startBtn.BackgroundColor3 = Color3.fromRGB(220, 140, 40)
startBtn.TextColor3 = Color3.fromRGB(20,20,20)
startBtn.TextScaled = true
startBtn.Font = Enum.Font.GothamBold
startBtn.Text = "START ROUND"
startBtn.Parent = screen

local liftBtn = Instance.new("TextButton")
liftBtn.Name = "LiftButton"
liftBtn.Position = UDim2.new(0.7,0,0.7,0)
liftBtn.Size = UDim2.new(0.25,0,0.08,0)
liftBtn.BackgroundColor3 = Color3.fromRGB(60, 160, 220)
liftBtn.TextColor3 = Color3.fromRGB(20,20,20)
liftBtn.TextScaled = true
liftBtn.Font = Enum.Font.GothamBold
liftBtn.Text = "CALL LIFT"
liftBtn.Parent = screen

startBtn.MouseButton1Click:Connect(function()
	EvtRequestStart:FireServer()
	startBtn.Visible = false
end)
liftBtn.MouseButton1Click:Connect(function()
	EvtCallLiftUI:FireServer()
end)

EvtState.OnClientEvent:Connect(function(state)
	msg.Text = "State: " .. tostring(state)
	if state == "Lobby" then
		startBtn.Visible = true
	end
end)
EvtHUD.OnClientEvent:Connect(function(m)
	msg.Text = tostring(m)
end)
EvtPower.OnClientEvent:Connect(function(p)
	local parts = {}
	for k, v in pairs(p) do
		table.insert(parts, k .. "=" .. (v and "ON" or "off"))
	end
	power.Text = "Power: " .. table.concat(parts, ", ")
end)

-- timer update
task.spawn(function()
	local t0 = tick()
	while true do
		timer.Text = "Time: " .. os.date("!%M:%S", math.floor(tick() - t0))
		task.wait(1)
	end
end)
