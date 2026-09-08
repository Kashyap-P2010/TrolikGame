--[[
	CheatSystem/init.server.luau
	
	Bootstrap script for the Cheat System.
	Sets up remotes and initializes the CheatManager module.
]]

local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Shared              = ReplicatedStorage:WaitForChild("Shared")
local CheatRemotes        = require(Shared:WaitForChild("CheatRemotes"))

-- Setup remotes FIRST (before any module tries to get them)
CheatRemotes.setup()

-- Now require and initialize CheatManager
local CheatManager = require(script:WaitForChild("CheatManager"))
CheatManager.init()

print("[CheatSystem] Initialized ✓")
