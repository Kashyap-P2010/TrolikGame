--[[
	CollisionManager — Per-player collision filtering for lobby pad barriers.
	
	Uses PhysicsService collision groups so that specific players can pass
	through a pad's invisbox while everyone else is blocked.
	
	Groups registered per pad N (1..PAD_COUNT):
	  PadBlock_N — assigned to the invisbox part
	  PadAllow_N — assigned to characters that may pass through
	
	Collision rules:
	  PadBlock_N  ↔  PadAllow_N  → NON-COLLIDABLE (lobby members pass freely)
	  PadBlock_N  ↔  Default     → COLLIDABLE      (outsiders are blocked)
	
	invisbox CanCollide acts as the master on/off switch:
	  Waiting     → false  (barrier physically off, groups irrelevant)
	  Creating    → true   (only owner in PadAllow_N passes)
	  Active      → false  (open for joiners)
	  Active+Full → true   (all 12 assigned; outsiders blocked)
	  Teleporting → true   (no new entries)
]]

local PhysicsService = game:GetService("PhysicsService")
local Players        = game:GetService("Players")
local LobbyConfig    = require(
	game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("LobbyConfig")
)

local CollisionManager = {}

local BLOCK_PREFIX = "PadBlock_"
local ALLOW_PREFIX = "PadAllow_"

local playerAssignments: { [Player]: string } = {}
local playerConnections: { [Player]: { RBXScriptConnection } } = {}

---------------------------------------------------------------------------
-- Cache invisbox references (set during init so WaitForChild only runs once)
---------------------------------------------------------------------------
local invisBoxCache: { [number]: BasePart } = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function setCharacterGroup(character: Model, groupName: string)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end
end

local function getInvisBox(padIndex: number): BasePart?
	return invisBoxCache[padIndex]
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

--- Register collision groups and cache invisbox references.
--- Must be called once from the server at startup.
function CollisionManager.init()
	local lobbyPads = workspace:WaitForChild("LobbyPads", 10)
	assert(lobbyPads, "[CollisionManager] workspace.LobbyPads not found!")

	for i = 1, LobbyConfig.PAD_COUNT do
		local blockGroup = BLOCK_PREFIX .. i
		local allowGroup = ALLOW_PREFIX .. i

		pcall(function() PhysicsService:RegisterCollisionGroup(blockGroup) end)
		pcall(function() PhysicsService:RegisterCollisionGroup(allowGroup) end)

		PhysicsService:CollisionGroupSetCollidable(blockGroup, allowGroup, false)
		PhysicsService:CollisionGroupSetCollidable(blockGroup, "Default",  true)

		-- Cache the invisbox
		local pad = lobbyPads:WaitForChild("Pad" .. i, 10)
		if pad then
			local box = pad:FindFirstChild("invisbox") or pad:FindFirstChild("InvisBox")
			if box and box:IsA("BasePart") then
				invisBoxCache[i] = box
				print("[CollisionManager] Cached invisbox for Pad" .. i)
			else
				warn("[CollisionManager] invisbox not found in Pad" .. i
					.. " — barrier will not work for this pad")
			end
		else
			warn("[CollisionManager] Pad" .. i .. " not found!")
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		CollisionManager.resetPlayerCollision(player)
		cleanupPlayerConnections(player)
	end)
end

--- Activate the invisbox barrier (assign block group, enable CanCollide).
function CollisionManager.activateBarrier(padIndex: number)
	local box = getInvisBox(padIndex)
	if not box then return end
	box.CollisionGroup = BLOCK_PREFIX .. padIndex
	box.CanCollide     = true
end

--- Deactivate the invisbox barrier (disable CanCollide, reset group).
function CollisionManager.deactivateBarrier(padIndex: number)
	local box = getInvisBox(padIndex)
	if not box then return end
	box.CanCollide     = false
	box.CollisionGroup = "Default"
end

--- Assign a player's character to the pad's allow group so they pass through.
--- Handles late-loading accessories and future respawns while assigned.
function CollisionManager.allowPlayerOnPad(padIndex: number, player: Player)
	local groupName = ALLOW_PREFIX .. padIndex

	CollisionManager.resetPlayerCollision(player)
	cleanupPlayerConnections(player)

	playerAssignments[player] = groupName
	playerConnections[player] = {}

	if player.Character then
		setCharacterGroup(player.Character, groupName)

		local descConn = player.Character.DescendantAdded:Connect(function(desc)
			if desc:IsA("BasePart") and playerAssignments[player] == groupName then
				desc.CollisionGroup = groupName
			end
		end)
		table.insert(playerConnections[player], descConn)
	end

	local charConn = player.CharacterAdded:Connect(function(newChar)
		if playerAssignments[player] ~= groupName then return end
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

--- Reset a player's character to the Default collision group.
function CollisionManager.resetPlayerCollision(player: Player)
	playerAssignments[player] = nil
	if player.Character then
		setCharacterGroup(player.Character, "Default")
	end
end

--- Reset collision for all players on a specific pad.
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
