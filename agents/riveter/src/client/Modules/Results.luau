--!strict
-- Results: end-of-round scoreboard with per-player breakdown, grade stamp, the events log
-- of what actually happened, and the rematch vote button.

local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local Util = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Util"))

local C = Config.Ui.Colors
local Results = {}
Results.Name = "Results"

local player = Players.LocalPlayer
local panel: Frame? = nil
local remotes: any = nil
Results.lastSummary = nil
Results.voteSent = false

local function new(className: string, props: { [string]: any }, children: { Instance }?): Instance
	local instance = Instance.new(className)
	for key, value in pairs(props) do
		(instance :: any)[key] = value
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = instance
		end
	end
	return instance
end

local function corner(radius: number): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, radius) }) :: UICorner
end

local function text(str: string, size: number, color: Color3, font: Enum.Font?, align: Enum.TextXAlignment?): TextLabel
	return new("TextLabel", {
		Text = str,
		Font = font or Config.Ui.Font,
		TextSize = size,
		TextColor3 = color,
		BackgroundTransparency = 1,
		TextXAlignment = align or Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, size + 6),
		RichText = true,
	}) :: TextLabel
end

local function build()
	local playerGui = player:WaitForChild("PlayerGui")
	local frame = new("Frame", {
		Name = "Results",
		Size = UDim2.fromOffset(560, 430),
		Position = UDim2.new(0.5, -280, 0.5, -215),
		BackgroundColor3 = C.Bg,
		BackgroundTransparency = 0.04,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 20,
	}, { corner(14) }) :: Frame
	frame.Parent = playerGui

	local header = new("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 70),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
	}, { corner(14) }) :: Frame
	header.Parent = frame
	local title = text("ROUND COMPLETE", 20, C.Accent, Config.Ui.FontBold)
	title.Name = "Headline"
	title.Position = UDim2.fromOffset(20, 10)
	title.Size = UDim2.fromOffset(340, 26)
	title.Parent = header
	Results.reasonLabel = text("", 13, C.TextDim)
	Results.reasonLabel.Name = "ReasonLabel"
	Results.reasonLabel.Position = UDim2.fromOffset(20, 36)
	Results.reasonLabel.Size = UDim2.fromOffset(340, 20)
	Results.reasonLabel.Parent = header
	Results.gradeLabel = text("D", 46, C.Accent, Config.Ui.FontBold, Enum.TextXAlignment.Right)
	Results.gradeLabel.Name = "GradeLabel"
	Results.gradeLabel.Position = UDim2.new(1, -150, 0, 8)
	Results.gradeLabel.Size = UDim2.fromOffset(130, 52)
	Results.gradeLabel.Parent = header
	Results.scoreLabel = text("", 13, C.TextDim, Config.Ui.Font, Enum.TextXAlignment.Right)
	Results.scoreLabel.Name = "ScoreLabel"
	Results.scoreLabel.Position = UDim2.new(1, -180, 0, 46)
	Results.scoreLabel.Size = UDim2.fromOffset(160, 18)
	Results.scoreLabel.Parent = header

	local stats = new("Frame", {
		Name = "Stats",
		Size = UDim2.new(1, -40, 0, 108),
		Position = UDim2.fromOffset(20, 82),
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
	}, { corner(10) }) :: Frame
	stats.Parent = frame
	local rows = {
		{ key = "rescued", label = "Survivors extracted" },
		{ key = "required", label = "Quota" },
		{ key = "lost", label = "Survivors lost" },
		{ key = "elapsedText", label = "Round time" },
		{ key = "waterLevel", label = "Peak water level" },
	}
	Results.statLabels = {}
	for index, row in ipairs(rows) do
		local name = text(row.label, 12, C.TextDim)
		name.Position = UDim2.fromOffset(16, 8 + (index - 1) * 20)
		name.Size = UDim2.fromOffset(220, 18)
		name.Parent = stats
		local value = text("", 12, C.Text, Config.Ui.FontBold, Enum.TextXAlignment.Right)
		value.Position = UDim2.new(1, -216, 0, 8 + (index - 1) * 20)
		value.Size = UDim2.fromOffset(200, 18)
		value.Parent = stats
		Results.statLabels[row.key] = value
	end

	local tableHead = text("PLAYER BREAKDOWN", 12, C.Accent, Config.Ui.FontBold)
	tableHead.Name = "BreakdownHead"
	tableHead.Position = UDim2.fromOffset(20, 198)
	tableHead.Size = UDim2.fromOffset(300, 18)
	tableHead.Parent = frame
	Results.playerList = new("Frame", {
		Size = UDim2.new(1, -40, 0, 92),
		Position = UDim2.fromOffset(20, 220),
		BackgroundTransparency = 1,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }),
	}) :: Frame
	Results.playerList.Parent = frame

	Results.eventLabel = text("", 10, C.TextDim)
	Results.eventLabel.Name = "EventLabel"
	Results.eventLabel.Position = UDim2.fromOffset(20, 318)
	Results.eventLabel.Size = UDim2.new(1, -40, 0, 60)
	Results.eventLabel.TextWrapped = true
	Results.eventLabel.TextYAlignment = Enum.TextYAlignment.Top
	Results.eventLabel.Parent = frame

	Results.rematchButton = new("TextButton", {
		Name = "Rematch",
		Text = "RUN IT AGAIN",
		Font = Config.Ui.FontBold,
		TextSize = 14,
		TextColor3 = Color3.fromRGB(20, 16, 8),
		BackgroundColor3 = C.Accent,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(200, 34),
		Position = UDim2.new(0.5, -214, 1, -44),
	}, { corner(8) }) :: TextButton
	Results.rematchButton.Parent = frame
	Results.voteLabel = text("", 12, C.TextDim, Config.Ui.Font, Enum.TextXAlignment.Left)
	Results.voteLabel.Name = "VoteLabel"
	Results.voteLabel.Text = "vote: 0"
	Results.voteLabel.Position = UDim2.new(0.5, 6, 1, -36)
	Results.voteLabel.Size = UDim2.fromOffset(180, 20)
	Results.voteLabel.Parent = frame

	panel = frame
	return frame
end

function Results.show(summary: any)
	Results.lastSummary = summary
	Results.voteSent = false
	if not panel then
		build()
	end
	local frame = panel :: Frame
	frame.Visible = true
	local outcome = summary.outcome or "fail"
	local tone = (outcome == "win" and C.Good) or (outcome == "partial" and C.Warn) or C.Bad
	local headline = outcome == "win" and "DISTRICT CLEARED" or (outcome == "partial" and "PARTIAL EVACUATION" or "ROUND FAILED")
	Results.reasonLabel.Text = `{headline} — {summary.reason or ""}`
	Results.reasonLabel.TextColor3 = tone
	Results.gradeLabel.Text = summary.grade or "D"
	Results.gradeLabel.TextColor3 = tone
	Results.scoreLabel.Text = `{summary.teamScore or 0} team points`
	Results.statLabels.rescued.Text = `{summary.rescued or 0}`
	Results.statLabels.required.Text = `{summary.required or 0}`
	Results.statLabels.lost.Text = `{summary.lost or 0} lost, {summary.dead or 0} dead`
	Results.statLabels.elapsedText.Text = summary.elapsedText or "0:00"
	Results.statLabels.waterLevel.Text = string.format("%.1f m", summary.waterLevel or 0)

	Results.playerList:ClearAllChildren()
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 3)
	layout.Parent = Results.playerList
	for _, entry in ipairs(summary.players or {}) do
		local row = new("Frame", {
			Size = UDim2.new(1, 0, 0, 18),
			BackgroundColor3 = C.Panel,
			BackgroundTransparency = 0.55,
			BorderSizePixel = 0,
		}, { corner(4) }) :: Frame
		row.Parent = Results.playerList
		local name = text(entry.name, 12, C.Text)
		name.Position = UDim2.fromOffset(8, 0)
		name.Size = UDim2.fromOffset(160, 18)
		name.Parent = row
		local detail = text(`downs {entry.downs or 0} · revives {entry.revives or 0} · water {entry.waterSeconds or 0}s`, 11, C.TextDim)
		detail.Position = UDim2.fromOffset(172, 0)
		detail.Size = UDim2.fromOffset(230, 18)
		detail.Parent = row
		local score = text(tostring(entry.score or 0), 12, C.Accent, Config.Ui.FontBold, Enum.TextXAlignment.Right)
		score.Position = UDim2.new(1, -80, 0, 0)
		score.Size = UDim2.fromOffset(70, 18)
		score.Parent = row
	end

	local events = summary.events or {}
	local recent = {}
	for i = math.max(1, #events - 5), #events do
		local event = events[i]
		if event then
			table.insert(recent, `[{(event.kind or "?")}] {event.message or ""}`)
		end
	end
	Results.eventLabel.Text = "RECENT LOG\n" .. table.concat(recent, "\n")
end

function Results.hide()
	if panel then
		(panel :: Frame).Visible = false
	end
end

function Results.setVotes(text: string)
	if Results.voteLabel then
		Results.voteLabel.Text = text
	end
end

function Results.Init(remoteBag: any)
	remotes = remoteBag
	build()
	Results.rematchButton.MouseButton1Click:Connect(function()
		if not Results.voteSent then
			Results.voteSent = true
			Results.rematchButton.Text = "VOTED"
			Results.rematchButton.BackgroundColor3 = C.PanelLight
			Results.rematchButton.TextColor3 = C.TextDim
			remotes.RequestRematch:FireServer()
		end
	end)
	remotes.RoundEvent.OnClientEvent:Connect(function(kind: string, payload: any)
		if kind == "state" and (payload.state == "Results") then
			-- summary arrives via RoundSummary
		elseif kind == "state" and (payload.state == "Lobby" or payload.state == "Prep") then
			Results.hide()
			Results.rematchButton.Text = "RUN IT AGAIN"
			Results.rematchButton.BackgroundColor3 = C.Accent
			Results.rematchButton.TextColor3 = Color3.fromRGB(20, 16, 8)
		end
	end)
	remotes.RoundSummary.OnClientEvent:Connect(function(summary: any)
		Results.show(summary)
	end)
end

return Results
