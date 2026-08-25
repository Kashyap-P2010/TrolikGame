--[[
	CollisionManager — Per-player collision filtering for lobby pad barriers.
	
	Uses PhysicsService collision groups so that specific players can pass
	through a pad's InvisBox while everyone else is blocked.
	
	Groups registered (per pad N = 1..4):
	  PadBlock_N  — assigned to InvisBox parts
	  PadAllow_N  — assigned to characters that may pass through
	
	Collision rules:
	  PadBlock_N  vs  PadAllow_N  →  NON-COLLIDABLE  (allowed players pass)
	  PadBlock_N  vs  Default     →  COLLIDABLE       (everyone else blocked)
	  PadBlock_N  vs  PadAllow_M  →  COLLIDABLE       (other-pad players blocked)
	
	The InvisBox CanCollide property is toggled as the top-level on/off switch:
	  Waiting     → CanCollide = false  (anyone walks through freely)
	  Creating    → CanCollide = true   (only owner passes)
	  Active      → CanCollide = false  (open for joiners, until full)
	  Active+Full → CanCollide = true   (all 12 assigned to allow group)
	  Teleporting → CanCollide = true   (no new entries)
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local LobbyConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("LobbyConfig"))

local CollisionManager = {}

local BLOCK_PREFIX = "PadBlock_"
local ALLOW_PREFIX = "PadAllow_"

-- Track per-player collision group assignment: player → groupName
local playerAssignments: { [Player]: string } = {}

-- Per-player cleanup connections
local playerConnections: { [Player]: { RBXScriptConnection } } = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function setCharacterGroup(character: Model, groupName: string)
	if not character then return end
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end
end

local function getInvisBox(padIndex: number): BasePart?
	local pad = workspace:WaitForChild("LobbyPads", 10)
	if not pad then return nil end

	local padPart = pad:WaitForChild("Pad" .. padIndex, 10)
	if not padPart then return nil end

	-- Handle both casings and wait if not immediately available
	local invisBox = padPart:FindFirstChild("invisbox") or padPart:FindFirstChild("InvisBox")
	if not invisBox then
		invisBox = padPart:WaitForChild("invisbox", 5)
	end
	
	if not invisBox then
		warn("[CollisionManager] invisbox not found inside Pad" .. padIndex)
	end
	
	return invisBox
end

local function cleanupPlayerConnections(player: Player)
	local conns = playerConnections[player]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		playerConnections[player] = nil
	end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Register all collision groups. Call once at server start.
function CollisionManager.init()
	for i = 1, LobbyConfig.PAD_COUNT do
		local blockGroup = BLOCK_PREFIX .. i
		local allowGroup = ALLOW_PREFIX .. i

		-- pcall in case groups already registered (e.g. script hot-reload)
		pcall(function() PhysicsService:RegisterCollisionGroup(blockGroup) end)
		pcall(function() PhysicsService:RegisterCollisionGroup(allowGroup) end)

		-- Allow group passes through its own block group
		PhysicsService:CollisionGroupSetCollidable(blockGroup, allowGroup, false)
		-- Block group collides with Default (default behaviour, but be explicit)
		PhysicsService:CollisionGroupSetCollidable(blockGroup, "Default", true)
	end

	-- Cleanup when players leave
	Players.PlayerRemoving:Connect(function(player)
		CollisionManager.resetPlayerCollision(player)
		cleanupPlayerConnections(player)
	end)
end

--- Enable the InvisBox barrier and assign it to the pad's block group.
function CollisionManager.activateBarrier(padIndex: number)
	local invisBox = getInvisBox(padIndex)
	if not invisBox then
		warn("[CollisionManager] InvisBox not found for Pad" .. padIndex)
		return
	end

	invisBox.CollisionGroup = BLOCK_PREFIX .. padIndex
	invisBox.CanCollide = true
end

--- Disable the InvisBox barrier (anyone can walk through).
function CollisionManager.deactivateBarrier(padIndex: number)
	local invisBox = getInvisBox(padIndex)
	if not invisBox then return end

	invisBox.CanCollide = false
	invisBox.CollisionGroup = "Default"
end

--- Assign a player's character to the allow group so they pass through the barrier.
--- Handles late-loading accessories and respawns while assigned.
function CollisionManager.allowPlayerOnPad(padIndex: number, player: Player)
	local groupName = ALLOW_PREFIX .. padIndex

	-- Clean any previous assignment first
	CollisionManager.resetPlayerCollision(player)
	cleanupPlayerConnections(player)

	playerAssignments[player] = groupName
	playerConnections[player] = {}

	-- Apply to current character
	if player.Character then
		setCharacterGroup(player.Character, groupName)

		-- Watch for late-loading descendants (accessories)
		local descConn = player.Character.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") and playerAssignments[player] == groupName then
				desc.CollisionGroup = groupName
			end
		end)
		table.insert(playerConnections[player], descConn)
	end

	-- If the player respawns while still assigned, re-apply
	local charConn = player.CharacterAdded:Connect(function(newChar)
		if playerAssignments[player] ~= groupName then return end
		-- Brief wait for character model to populate
		task.wait(0.1)
		if playerAssignments[player] ~= groupName then return end

		setCharacterGroup(newChar, groupName)

		local descConn = newChar.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") and playerAssignments[player] == groupName then
				desc.CollisionGroup = groupName
			end
		end)
		table.insert(playerConnections[player], descConn)
	end)
	table.insert(playerConnections[player], charConn)
end

--- Reset a single player's character back to the Default collision group.
function CollisionManager.resetPlayerCollision(player: Player)
	playerAssignments[player] = nil

	if player.Character then
		setCharacterGroup(player.Character, "Default")
	end
end

--- Reset collision for all given players on a specific pad,
--- but only if they are actually assigned to that pad's allow group.
function CollisionManager.resetPadCollisions(padIndex: number, players: { Player })
	local expectedGroup = ALLOW_PREFIX .. padIndex
	for _, player in players do
		if playerAssignments[player] == expectedGroup then
			CollisionManager.resetPlayerCollision(player)
			cleanupPlayerConnections(player)
		end
	end
end

return CollisionManager
