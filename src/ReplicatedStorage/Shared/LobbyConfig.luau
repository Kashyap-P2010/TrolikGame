--[[
	LobbyConfig — Shared constants for the lobby system.
	Used by both server and client scripts.
	
	Difficulty unlock requirements reference player attributes:
	  - "EasyExamPassed"  → unlocks Medium
	  - "MediumExamPassed" → unlocks Hard
	These attributes should be set by the exam system when it's built.
]]

local LobbyConfig = {}

-- Teleport destination
LobbyConfig.TARGET_PLACE_ID = 74833272427125

-- Timing
LobbyConfig.COUNTDOWN_SECONDS = 15
LobbyConfig.TELEPORT_RETRY_ATTEMPTS = 3
LobbyConfig.TELEPORT_RETRY_DELAY = 2

-- Capacity
LobbyConfig.MAX_LOBBY_PLAYERS = 12
LobbyConfig.PAD_COUNT = 4

-- Difficulties (ordered: cycling wraps around this list)
LobbyConfig.DIFFICULTIES = {
	{
		name = "Easy",
		color = Color3.fromRGB(0, 255, 0),
		unlockRequirement = nil, -- Always unlocked
		promptText = "",
	},
	{
		name = "Medium",
		color = Color3.fromRGB(255, 255, 0),
		unlockRequirement = "EasyExamPassed",
		promptText = "Score 70% on the Easy Exam to unlock this",
	},
	{
		name = "Hard",
		color = Color3.fromRGB(255, 0, 0),
		unlockRequirement = "MediumExamPassed",
		promptText = "Score 70% on the Medium Exam to unlock this",
	},
}

-- Pad states (used as string enum)
LobbyConfig.PadState = {
	WAITING     = "Waiting",
	CREATING    = "Creating",
	ACTIVE      = "Active",
	TELEPORTING = "Teleporting",
}

-- UI colors
LobbyConfig.CREATE_BUTTON_LOCKED_COLOR   = Color3.fromRGB(27, 42, 53)
LobbyConfig.CREATE_BUTTON_UNLOCKED_COLOR = Color3.fromRGB(0, 255, 0)

return LobbyConfig
