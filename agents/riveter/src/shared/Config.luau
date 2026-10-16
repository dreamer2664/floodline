--!strict
-- FLOODLINE: Last District — shared tunables.
-- Single source of truth for both server simulation and client presentation.

local Config = {}

Config.Game = {
	Name = "FLOODLINE: Last District",
	Version = "r07",
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
	-- Minutes matter: the boat/helicopter cannot appear the second you call. The crew keeps pulling
	-- people out while it approaches, which is what gives the flood time to actually threaten anyone.
	EvacApproachSeconds = 55,
	EvacApproachSecondsStorm = 40, -- a surge compresses the window
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
	CellCount = 4,
	CellChargeMax = 100,
	CellDrainPerSecond = 0.14, -- per powered consumer slot
	CellRechargePerSecond = 2.6, -- while docked at the charger
	ShortOutDepth = 0.85, -- socket submerged -> trips
	BreakerResetSeconds = 3.2, -- hand work needed to close a tripped breaker (3 holds)
	BrownoutPriority = { "Pump", "Lift", "Winch", "Bridge", "Relay" }, -- highest first in list
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
		Winch = {
			Label = "Skybridge Winch",
			Load = 1,
			Desc = "Motors the roof skybridge out over the canal cut.",
		},
	},
}

-- Second extraction route: the roof skybridge, a hand-crankable span that does not need the
-- grid at all (slow), plus the flooded maintenance tunnel cut under the mid district.
Config.Route = {
	Skybridge = {
		Name = "Skybridge",
		ExtendSeconds = 22, -- seconds of cranking to walk the span fully out
		RetractSeconds = 26,
		MotorSeconds = 5.5, -- when the winch consumer is powered
		CrankHoldSpeedup = 1.6, -- crank pedestals turn faster with an engineer alongside
		CrankPromptHold = 1.6,
		CrankCooldown = 0.35,
		DeckParts = { "BridgeDeck_A", "BridgeDeck_B", "BridgeDeck_C", "BridgeDeck_D" },
		RailParts = { "BridgeRail_A", "BridgeRail_B", "BridgeRail_C", "BridgeRail_D" },
		NearJoint = Vector3.new(28.5, 14.35, -13.5),
		FarJoint = Vector3.new(5.5, 16.45, -36.5),
		CrankNear = "BridgeCrank_Near",
		CrankFar = "BridgeCrank_Far",
		WalkRadius = 3.2,
	},
	Tunnel = {
		Name = "Maintenance Tunnel",
		Barricade = "TunnelBarricade",
		ClearSeconds = 7.5,
		ShortcutBonus = 45,
		FloodOffset = 1.4, -- the cut sits below street level: it floods first
	},
}

-- Crew roles. Every player picks one role in the lobby; each role is always-on passives plus a
-- single long-cooldown ability, so a four-player crew covers four jobs at once and a solo player
-- still gets exactly one of them.
Config.Crew = {
	Order = { "Diver", "Engineer", "Medic", "Rigger" },
	Default = "Diver",
	BarTop = 120, -- studs of screen distance at which the role chip fades out
	Diver = {
		Label = "Diver",
		Blurb = "Lungs and fins: more air, faster in the water, and hauls bodies out quicker.",
		OxygenMultiplier = 1.5,
		SwimMultiplier = 1.25,
		CarryBonus = 1.5,
		Ability = {
			Id = "SecondWind",
			Label = "Second Wind",
			Cooldown = 80,
			Duration = 20,
			Desc = "Refill the whole crew's air and shrug off water drag for 20 seconds.",
		},
	},
	Engineer = {
		Label = "Engineer",
		Blurb = "Plant knowledge: holds resolve faster and flooded breakers can be reset by hand.",
		HoldMultiplier = 1.35,
		BreakerMultiplier = 1.5,
		Ability = {
			Id = "SocketJumper",
			Label = "Socket Jumper",
			Cooldown = 70,
			Desc = "Reset every tripped socket in the district from wherever you are standing.",
		},
	},
	Medic = {
		Label = "Medic",
		Blurb = "Steady hands: revives land faster, and a downed teammate near you bleeds out slower.",
		ReviveMultiplier = 1.45,
		BleedoutMultiplier = 1.4,
		AuraRadius = 60,
		Ability = {
			Id = "Triage",
			Label = "Triage",
			Cooldown = 75,
			Radius = 34,
			Desc = "Patch up every teammate and survivor near you and stop their bleeding.",
		},
	},
	Rigger = {
		Label = "Rigger",
		Blurb = "Ropes and winches: cranks turn faster and the whole crew moves quicker with you.",
		CrankMultiplier = 1.45,
		CarryBonus = 1.0,
		Ability = {
			Id = "RopeLine",
			Label = "Rope Line",
			Cooldown = 65,
			Duration = 25,
			Radius = 60,
			SpeedMultiplier = 1.18,
			Desc = "Rig a line: nearby survivors and teammates move 18% faster for 25 seconds.",
		},
	},
}

-- The district outfall: a sluice on the canal that drains water while somebody cranks it. It is
-- hand-powered on purpose - it costs a body, not a cell, so holding it is a real decision.
Config.Outfall = {
	Name = "Outfall",
	Wheel = "OutfallWheel",
	Gate = "OutfallGate",
	HoldSeconds = 1.4, -- one crank hold
	-- ~11 holds (about 15 s of standing on the wheel) to open it, and about 22 s to creep shut.
	-- The first pass at 14 s of cranking meant a committed player could never finish the job, so the
	-- sluice was dead content in every bot round; 9 s makes it a real alternative to the pump.
	OpenSeconds = 9,
	ClosePerSecond = 0.045, -- it creeps shut on its own
	DrainPerSecond = 0.09, -- studs of water pulled out of every sector per second at full open
	DropDepth = 3.2, -- how far the gate plate travels when fully open
	EngineerMultiplier = 1.4,
	ScorePerOpen = 30,
	CrankCooldown = 0.3,
	ReopenThreshold = 0.2, -- below this it counts as shut again and re-opening pays out once more
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
	Total = 12,
	FollowSpeed = { Base = 11.5, Injured = 8.5, Child = 12.5, Elderly = 7.5 },
	StrayDistance = 46,
	RegroupDistance = 26,
	ShelterDepth = 0.45, -- an unclaimed survivor heads for high ground once the water reaches this
	ShelterSpeed = 0.95, -- they run for their lives
	ShelterRecoverPerSecond = 6.5, -- rest and first aid while they hold high ground
	PanicGrowthPerSecond = 4.5,
	PanicCalmPerSecond = 7.0,
	PanicThreshold = 100,
	LostAfterPanicSeconds = 12,
	ReviveSeconds = 6.5,
	DownedBleedoutSeconds = 75, -- long enough that a crew can cross the district for someone
	DownedWetDepth = 0.75, -- lying in waist-deep water halves that window
	DownedDrownDepth = 1.7, -- and this is over their face: it is a drowning, not a bleedout
	Traits = {
		Worker = { Label = "Worker", Speed = 1.0, Bonus = 10, Note = "Knows the district: opens the workshop valve faster." },
		Injured = { Label = "Injured", Speed = 0.74, Bonus = 30, Note = "Slow. Keep them out of the water." },
		Child = {
			Label = "Child",
			Speed = 1.09,
			Bonus = 25,
			Note = "Fast but panics quickly in water.",
			Role = "Child",
			Effect = "Will not wade past knee depth: pick her up and carry her.",
		},
		Elderly = { Label = "Elderly", Speed = 0.65, Bonus = 35, Note = "Very slow. Needs a protected route." },
		Deaf = { Label = "Deaf", Speed = 1.0, Bonus = 20, Note = "Cannot hear calls: get close to lead them." },
		Dog = { Label = "Search Dog", Speed = 1.15, Bonus = 15, Note = "Follows automatically once calm." },
		Medic = {
			Label = "Medic",
			Speed = 1.0,
			Bonus = 30,
			Note = "Trails you and patches you up as you go.",
			Role = "Medic",
			Effect = "Following players regenerate health. Rescuing them restocks every medkit.",
		},
		Engineer = {
			Label = "Engineer",
			Speed = 0.92,
			Bonus = 35,
			Note = "Knows the plant: valves, winches and barricades yield faster.",
			Role = "Engineer",
			Effect = "Your holds on valves, cranks and debris are 40% faster. Rescue recharges every cell.",
		},
	},
	Roles = {
		Medic = {
			HealPerSecond = 1.6,
			HealCeiling = 72,
			RescueMedkits = 2,
		},
		Engineer = {
			HoldSpeedup = 1.66, -- effective hold time is divided by this
			RescueRecharge = true,
		},
		Child = {
			MaxWadeDepth = 0.6, -- children refuse to lead through water deeper than this
			MustCarryNote = "Pia will not walk into the water — carry her.",
		},
	},
}

-- Salvage economy and the upgrade bench in the terminal.
-- Salvage is the same currency as score: purchases permanently (for the round) reshape the run.
Config.Upgrades = {
	StartSalvage = 20,
	PerSurvivor = 25,
	PerFirstPower = 10,
	PerPhase = 8,
	Order = { "Impeller", "Rebreather", "Capacitor", "SealKit", "FieldHospital", "LiftServo" },
	Impeller = {
		Label = "Pump Impeller",
		Cost = 30,
		Desc = "Pump lifts 35% more water per second.",
		Kind = "flood",
		Value = 0.35,
	},
	Rebreather = {
		Label = "Rebreathers",
		Cost = 25,
		Desc = "Every diver gets +9 seconds of air.",
		Kind = "oxygen",
		Value = 9,
	},
	Capacitor = {
		Label = "Grid Capacitor",
		Cost = 40,
		Desc = "+1 grid capacity: run another consumer at once.",
		Kind = "capacity",
		Value = 1,
	},
	SealKit = {
		Label = "Seal Kits",
		Cost = 20,
		Desc = "Closed doors hold back 60% more water.",
		Kind = "seal",
		Value = 0.6,
	},
	FieldHospital = {
		Label = "Field Hospital",
		Cost = 35,
		Desc = "Revives are twice as fast and start you at full health.",
		Kind = "revive",
		Value = 2.0,
	},
	LiftServo = {
		Label = "Lift Servo",
		Cost = 30,
		Desc = "Winch servo: the lift travels 35% faster and takes one more passenger.",
		Kind = "lift",
		Value = 0.35,
		Capacity = 1,
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
		RequiredSurvivorFraction = 0.50,
		PhaseSeconds = 150,
		PrepSeconds = 90,
		SurgeSeconds = 80,
		HazardRate = 1.0,
		RiseMultiplier = 1.0,
		OxygenSeconds = 22,
		RespawnPenaltySeconds = 24,
	},
	[4] = {
		RequiredSurvivorFraction = 0.55,
		PhaseSeconds = 145,
		PrepSeconds = 85,
		SurgeSeconds = 75,
		HazardRate = 1.15,
		RiseMultiplier = 1.06,
		OxygenSeconds = 20,
		RespawnPenaltySeconds = 26,
	},
}

-- Lobby-selectable difficulty. Multipliers stack on top of the player-count scaling table.
Config.Modifiers = {
	Order = { "Calm", "Standard", "Storm", "Catastrophe" },
	Calm = {
		Label = "Calm Tide",
		Blurb = "Slow water, forgiving hazards. Good for a first run.",
		RiseMultiplier = 0.72,
		HazardMultiplier = 0.5,
		OxygenMultiplier = 1.25,
		QuotaDelta = -0.1,
		PrepBonus = 20,
		ScoreMultiplier = 0.8,
	},
	Standard = {
		Label = "Standard Surge",
		Blurb = "The district as designed.",
		RiseMultiplier = 1.0,
		HazardMultiplier = 1.0,
		OxygenMultiplier = 1.0,
		QuotaDelta = 0,
		PrepBonus = 0,
		ScoreMultiplier = 1.0,
	},
	Storm = {
		Label = "Storm Season",
		Blurb = "Faster rise, more debris, thinner air.",
		RiseMultiplier = 1.22,
		HazardMultiplier = 1.35,
		OxygenMultiplier = 0.85,
		QuotaDelta = 0.1,
		PrepBonus = -10,
		ScoreMultiplier = 1.35,
	},
	Catastrophe = {
		Label = "Catastrophe",
		Blurb = "The dam is already gone. Expect losses.",
		RiseMultiplier = 1.45,
		HazardMultiplier = 1.7,
		OxygenMultiplier = 0.72,
		QuotaDelta = 0.2,
		PrepBonus = -25,
		ScoreMultiplier = 1.8,
	},
}

Config.Pings = {
	Types = {
		{ id = "danger", label = "Danger", color = "Bad" },
		{ id = "objective", label = "Objective", color = "Accent" },
		{ id = "survivor", label = "Survivor", color = "Good" },
		{ id = "loot", label = "Supplies", color = "Water" },
	},
	Lifetime = 9,
	Cooldown = 1.2,
	MaxDistance = 260,
}

Config.Doors = {
	OpenAngle = 95,
	SwingSeconds = 0.55,
	ClosedWaterLag = 2.6, -- extra foundation offset for a sealed interior
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
	DownedBleedoutSeconds = 75, -- a downed player bleeds out and is carried to the safe zone
	BleedoutRespawnHealth = 45,
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

-- Difficulty modifiers layer on top of the per-player-count table.
function Config.modifier(name: string?)
	return Config.Modifiers[name or "Standard"] or Config.Modifiers.Standard
end

function Config.scaling(playerCount: number, modifierName: string?)
	local n = math.clamp(playerCount, 1, 4)
	local base = Config.Scaling[n] or Config.Scaling[4]
	local mod = Config.modifier(modifierName)
	return {
		RequiredSurvivorFraction = math.clamp(base.RequiredSurvivorFraction + mod.QuotaDelta, 0.2, 0.9),
		PhaseSeconds = base.PhaseSeconds,
		PrepSeconds = math.max(35, base.PrepSeconds + mod.PrepBonus),
		SurgeSeconds = base.SurgeSeconds,
		HazardRate = base.HazardRate * mod.HazardMultiplier,
		RiseMultiplier = base.RiseMultiplier * mod.RiseMultiplier,
		OxygenSeconds = Config.Water.OxygenSeconds * mod.OxygenMultiplier,
		RespawnPenaltySeconds = base.RespawnPenaltySeconds,
		Modifier = modifierName or "Standard",
		ModifierLabel = mod.Label,
		ScoreMultiplier = mod.ScoreMultiplier,
	}
end

return Config
