--!strict
-- FLOODLINE: Last District — shared tunables.
-- Single source of truth for both server simulation and client presentation.

local Config = {}

Config.Game = {
	Name = "FLOODLINE: Last District",
	Version = "r03",
	MaxPlayers = 4,
	MinPlayersToStart = 1,
	LobbyAutoStartSeconds = 10,
	RematchVoteSeconds = 25,
	IntermissionSeconds = 8,
}

Config.Round = {
	States = { "Lobby", "Prep", "Rising", "Surge", "Extraction", "Results", "Intermission" },
	PrepSeconds = 90,
	PhaseSeconds = 150,
	PhaseCount = 4,
	SurgeSeconds = 75,
	ExtractionSeconds = 120,
	ResultsSeconds = 30,
}

-- Water simulation. Level is expressed in studs of water depth above y=0.
Config.Water = {
	StartLevel = 0.0,
	SectorCount = 3,
	SectorOffsets = { 2.6, 0.0, 1.1 }, -- canal-front sector floods first
	SectorSizes = {
		{ 180, 100 }, -- x span, z span per sector (world splits along Z)
	},
	RisePerSecond = {
		Prep = 0.010,
		Rising = 0.055,
		Surge = 0.150,
		Extraction = 0.020,
	},
	Wave = { Amplitude = 0.22, Period = 6.5 },
	PumpDraw = 0.72, -- fraction of rise removed while a pump is powered
	PumpDrainPerSecond = 0.030, -- active pumping can pull water back down
	SwimDepth = 3.2,
	OxygenSeconds = 22,
	OxygenRecoverPerSecond = 6,
	DrownDamagePerSecond = 7.5,
	ShockDepth = 1.2,
	SurvivorPanicDepth = 0.9,
	MaxLevel = 34,
}

-- Power grid. Cells are physical parts; sockets are consumers.
Config.Power = {
	BaseCapacity = 2,
	RelayCapacityBonus = 1,
	CellCount = 3,
	CellChargeMax = 100,
	CellDrainPerSecond = 0.14, -- per powered consumer slot
	CellRechargePerSecond = 2.6, -- while docked at the charger
	ShortOutDepth = 0.85, -- socket submerged -> trips
	BrownoutPriority = { "Pump", "Lift", "Bridge", "Relay" }, -- highest first in list
	Consumers = {
		Pump = {
			Label = "Flood Pump",
			Load = 1,
			Desc = "Holds back the water in the low district.",
		},
		Lift = {
			Label = "Evac Lift",
			Load = 1,
			Desc = "Powers the passenger lift to the relay tower.",
		},
		Bridge = {
			Label = "Bridge Gate",
			Load = 1,
			Desc = "Opens the north span into the tower side.",
		},
		Relay = {
			Label = "Relay Tower",
			Load = 1,
			Desc = "Widens grid capacity and restores district comms.",
		},
	},
}

Config.Lift = {
	Capacity = 3, -- passengers (survivors) per trip
	PlayerCapacity = 4,
	TravelSeconds = 6.5,
	DwellSeconds = 2.0,
	BaseHeight = 1.0,
	TopHeight = 15.6,
	BasePosition = Vector3.new(0, 1, -32),
	TopPosition = Vector3.new(0, 15.6, -40),
	CallRadius = 16,
	BoardRadius = 7.5,
	AutoBoardSurvivors = true,
}

Config.Survivors = {
	Total = 8,
	FollowSpeed = { Base = 11.5, Injured = 8.5, Child = 12.5, Elderly = 7.5 },
	StrayDistance = 46,
	RegroupDistance = 26,
	PanicGrowthPerSecond = 4.5,
	PanicCalmPerSecond = 7.0,
	PanicThreshold = 100,
	LostAfterPanicSeconds = 12,
	ReviveSeconds = 6.5,
	DownedBleedoutSeconds = 55,
	Traits = {
		Worker = { Label = "Worker", Speed = 1.0, Bonus = 10, Note = "Knows the district: opens the workshop valve faster." },
		Injured = { Label = "Injured", Speed = 0.74, Bonus = 30, Note = "Slow. Keep them out of the water." },
		Child = { Label = "Child", Speed = 1.09, Bonus = 25, Note = "Fast but panics quickly in water." },
		Elderly = { Label = "Elderly", Speed = 0.65, Bonus = 35, Note = "Very slow. Needs a protected route." },
		Deaf = { Label = "Deaf", Speed = 1.0, Bonus = 20, Note = "Cannot hear calls: get close to lead them." },
		Dog = { Label = "Search Dog", Speed = 1.15, Bonus = 15, Note = "Follows automatically once calm." },
	},
}

Config.Scoring = {
	PerSurvivor = 100,
	TeamSurvivorBonus = 60,
	TimeParPerPhase = 140,
	TimeBonusPerSecond = 1.2,
	PowerEfficiencyBonus = 80,
	GradeThresholds = { S = 1400, A = 1100, B = 800, C = 500 },
}

-- Difficulty scales with the number of active players.
Config.Scaling = {
	[1] = {
		RequiredSurvivorFraction = 0.35,
		PhaseSeconds = 175,
		PrepSeconds = 100,
		SurgeSeconds = 95,
		HazardRate = 0.6,
		RiseMultiplier = 0.82,
		OxygenSeconds = 26,
		RespawnPenaltySeconds = 12,
	},
	[2] = {
		RequiredSurvivorFraction = 0.45,
		PhaseSeconds = 160,
		PrepSeconds = 95,
		SurgeSeconds = 85,
		HazardRate = 0.8,
		RiseMultiplier = 0.92,
		OxygenSeconds = 24,
		RespawnPenaltySeconds = 18,
	},
	[3] = {
		RequiredSurvivorFraction = 0.55,
		PhaseSeconds = 150,
		PrepSeconds = 90,
		SurgeSeconds = 80,
		HazardRate = 1.0,
		RiseMultiplier = 1.0,
		OxygenSeconds = 22,
		RespawnPenaltySeconds = 24,
	},
	[4] = {
		RequiredSurvivorFraction = 0.6,
		PhaseSeconds = 145,
		PrepSeconds = 85,
		SurgeSeconds = 75,
		HazardRate = 1.15,
		RiseMultiplier = 1.06,
		OxygenSeconds = 20,
		RespawnPenaltySeconds = 26,
	},
}

Config.Player = {
	WalkSpeed = 16,
	SprintSpeed = 23,
	CrouchSpeed = 8,
	StaminaMax = 100,
	StaminaDrain = 14,
	StaminaRegen = 9,
	CarryWalkSpeed = 12.5, -- while holding a power cell
	MaxHealth = 100,
	WaterDragMultiplier = 0.55,
	ShockDamage = 18,
	FallDamageThreshold = 26,
}

Config.Fx = {
	PingSounds = {
		Prompt = "rbxasset://sounds/electronicpingshort.wav",
		Switch = "rbxasset://sounds/switch.wav",
		Splash = "rbxasset://sounds/impact_water.mp3",
		Error = "rbxasset://sounds/switch3.wav",
	},
	WaterColor = Color3.fromRGB(38, 92, 128),
	WaterTransparency = 0.42,
	SurfaceWaterColor = Color3.fromRGB(52, 116, 156),
}

Config.Ui = {
	Colors = {
		Bg = Color3.fromRGB(12, 16, 22),
		Panel = Color3.fromRGB(20, 26, 34),
		PanelLight = Color3.fromRGB(32, 40, 52),
		Accent = Color3.fromRGB(230, 156, 62),
		AccentDim = Color3.fromRGB(140, 96, 42),
		Good = Color3.fromRGB(88, 200, 130),
		Warn = Color3.fromRGB(232, 190, 74),
		Bad = Color3.fromRGB(224, 84, 76),
		Text = Color3.fromRGB(232, 238, 244),
		TextDim = Color3.fromRGB(150, 164, 178),
		Water = Color3.fromRGB(86, 168, 214),
	},
	Font = Enum.Font.Gotham,
	FontBold = Enum.Font.GothamBold,
}

function Config.scaling(playerCount: number)
	local n = math.clamp(playerCount, 1, 4)
	return Config.Scaling[n] or Config.Scaling[4]
end

return Config
