--[[
	LobbySystem — Server-authoritative orchestrator.
	
	Manages the full lifecycle of lobby pads:
	  Waiting  →  Creating  →  Active  →  Teleporting  →  Waiting
	
	Responsibilities:
	  • Pad .Touched connections (occupy + join)
	  • Remote event handlers (Create, Cancel, unlock queries)
	  • Billboard text updates
	  • Countdown timer with teleportation
	  • Player disconnect / death cleanup
	  • InvisBox barrier coordination via CollisionManager
	
	Workspace expectations:
	  workspace.LobbyPads.Pad1 .. Pad4  — BasePart or Model
	    each containing:  invisbox (BasePart), BillboardGui > TextLabel
	  workspace.LobbyPart — SpawnLocation / Part (cancel teleport target)
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

---------------------------------------------------------------------------
-- Module requires
---------------------------------------------------------------------------
local Shared       = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig  = require(Shared:WaitForChild("LobbyConfig"))
local LobbyRemotes = require(Shared:WaitForChild("LobbyRemotes"))

local PadManager       = require(script.PadManager)
local CollisionManager = require(script.CollisionManager)
local TeleportManager  = require(script.TeleportManager)

---------------------------------------------------------------------------
-- Bootstrap
---------------------------------------------------------------------------
LobbyRemotes.setup()
CollisionManager.init()
PadManager.init(LobbyConfig.PAD_COUNT)

-- Grab remote references (created by setup above)
local remotes = {
	requestCreate  = LobbyRemotes.get("RequestCreateLobby"),
	requestCancel  = LobbyRemotes.get("RequestCancelLobby"),
	showUI         = LobbyRemotes.get("ShowLobbyUI"),
	updatePad      = LobbyRemotes.get("UpdatePadState"),
	updateTimer    = LobbyRemotes.get("UpdateTimer"),
	getUnlocks     = LobbyRemotes.get("GetDifficultyUnlocks"),
}

-- Per-player touch debounce
local touchDebounce: { [Player]: boolean } = {}

---------------------------------------------------------------------------
-- Billboard helper
---------------------------------------------------------------------------

local function updateBillboard(padIndex: number, text: string)
	local lobbyPads = workspace:FindFirstChild("LobbyPads")
	if not lobbyPads then return end

	local pad = lobbyPads:FindFirstChild("Pad" .. padIndex)
	if not pad then return end

	local billboard = pad:FindFirstChildWhichIsA("BillboardGui", true)
	if not billboard then return end

	local label = billboard:FindFirstChildWhichIsA("TextLabel", true)
	if not label then return end

	label.Text = text
end

---------------------------------------------------------------------------
-- Teleport-to-spawn helper
---------------------------------------------------------------------------

local function moveToLobbySpawn(player: Player)
	local lobbyPart = workspace:FindFirstChild("LobbyPart")
	if not lobbyPart then
		warn("[LobbySystem] workspace.LobbyPart not found")
		return
	end

	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	-- Slightly above the part to avoid clipping into geometry
	hrp.CFrame = lobbyPart.CFrame + Vector3.new(0, 5, 0)
end

---------------------------------------------------------------------------
-- Full pad reset (state + collision + billboard + UI)
---------------------------------------------------------------------------

local function resetPad(padIndex: number)
	local padState = PadManager.getState(padIndex)
	if not padState then return end

	-- Reset collision for every player in this lobby
	CollisionManager.resetPadCollisions(padIndex, padState.players)

	-- Hide UI for the owner (if still connected)
	if padState.owner and padState.owner.Parent then
		remotes.showUI:FireClient(padState.owner, false)
	end

	-- Reset data
	PadManager.reset(padIndex)

	-- Barrier off, billboard back to idle
	CollisionManager.deactivateBarrier(padIndex)
	updateBillboard(padIndex, "Waiting...")
	remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.WAITING, {})
end

---------------------------------------------------------------------------
-- Countdown & teleport
---------------------------------------------------------------------------

local function startCountdown(padIndex: number)
	local thread = task.spawn(function()
		local padState = PadManager.getState(padIndex)

		for remaining = LobbyConfig.COUNTDOWN_SECONDS, 0, -1 do
			-- Bail if pad was reset/cancelled externally
			if padState.state ~= LobbyConfig.PadState.ACTIVE then return end

			-- Build billboard text
			local ownerName = if padState.owner then padState.owner.Name else "Unknown"
			local diff      = padState.difficulty or "Easy"
			updateBillboard(
				padIndex,
				ownerName .. "'s Lobby\nDifficulty: " .. diff .. "\n" .. remaining .. "s"
			)

			-- Send timer tick to ALL players on this pad
			for _, p in padState.players do
				if p and p.Parent then
					remotes.updateTimer:FireClient(p, padIndex, remaining)
				end
			end

			if remaining > 0 then
				task.wait(1)
			end
		end

		-- Final state check after loop
		if padState.state ~= LobbyConfig.PadState.ACTIVE then return end

		-- ── Teleporting ──
		PadManager.setTeleporting(padIndex)
		updateBillboard(padIndex, "Teleporting Lobby...")
		remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.TELEPORTING, {})

		-- Hide creator UI
		if padState.owner and padState.owner.Parent then
			remotes.showUI:FireClient(padState.owner, false)
		end

		-- Gather valid players
		local toTeleport: { Player } = {}
		for _, p in padState.players do
			if p and p.Parent then
				table.insert(toTeleport, p)
			end
		end

		local ok = TeleportManager.teleportLobby(toTeleport, padState.difficulty or "Easy")

		if not ok then
			warn("[LobbySystem] Teleport failed for Pad" .. padIndex .. " — returning players to spawn")
			for _, p in toTeleport do
				if p and p.Parent then
					moveToLobbySpawn(p)
				end
			end
		end

		-- Brief delay so "Teleporting Lobby..." is visible
		task.wait(1.5)
		resetPad(padIndex)
	end)

	PadManager.setTimerThread(padIndex, thread)
end

---------------------------------------------------------------------------
-- Pad touch handler
---------------------------------------------------------------------------

local function onPadTouched(padIndex: number, hit: BasePart)
	local character = hit.Parent
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	-- Debounce (0.5 s per player)
	if touchDebounce[player] then return end
	touchDebounce[player] = true
	task.delay(0.5, function()
		touchDebounce[player] = nil
	end)

	local padState = PadManager.getState(padIndex)
	if not padState then return end

	-- ── Waiting → Creating ──
	if padState.state == LobbyConfig.PadState.WAITING then
		-- Reject if player is already associated with another pad
		if PadManager.getPlayerPad(player) then return end

		if not PadManager.occupy(padIndex, player) then return end

		-- Collision: allow owner through, then activate barrier
		CollisionManager.allowPlayerOnPad(padIndex, player)
		CollisionManager.activateBarrier(padIndex)

		updateBillboard(padIndex, "Creating Lobby...")
		remotes.showUI:FireClient(player, true, padIndex)
		remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.CREATING, {
			owner = player.Name,
		})

	-- ── Active → join ──
	elseif padState.state == LobbyConfig.PadState.ACTIVE then
		if PadManager.getPlayerPad(player) then return end
		if #padState.players >= LobbyConfig.MAX_LOBBY_PLAYERS then return end

		if not PadManager.addPlayer(padIndex, player) then return end

		-- If we just hit capacity, re-activate barrier for everyone outside
		if #padState.players >= LobbyConfig.MAX_LOBBY_PLAYERS then
			for _, p in padState.players do
				CollisionManager.allowPlayerOnPad(padIndex, p)
			end
			CollisionManager.activateBarrier(padIndex)
		end
	end
end

-- Connect Touched on each pad
for i = 1, LobbyConfig.PAD_COUNT do
	local lobbyPads = workspace:WaitForChild("LobbyPads", 10)
	if not lobbyPads then
		warn("[LobbySystem] workspace.LobbyPads not found")
		continue
	end

	local pad = lobbyPads:WaitForChild("Pad" .. i, 10)
	if not pad then
		warn("[LobbySystem] Pad" .. i .. " not found inside LobbyPads")
		continue
	end

	if pad:IsA("BasePart") then
		pad.Touched:Connect(function(hit) onPadTouched(i, hit) end)
	end
	
	-- Connect invisbox as well in case the player touches it instead of the floor pad
	local invisBox = pad:FindFirstChild("invisbox") or pad:FindFirstChild("InvisBox")
	if not invisBox then
		invisBox = pad:WaitForChild("invisbox", 5)
	end
	
	if invisBox and invisBox:IsA("BasePart") then
		invisBox.Touched:Connect(function(hit) onPadTouched(i, hit) end)
	else
		warn("[LobbySystem] invisbox not found in Pad" .. i)
	end
end

---------------------------------------------------------------------------
-- Remote: player clicked "Create"
---------------------------------------------------------------------------

remotes.requestCreate.OnServerEvent:Connect(function(player: Player, difficulty: string)
	-- Validate difficulty name
	local diffEntry = nil
	for _, d in LobbyConfig.DIFFICULTIES do
		if d.name == difficulty then
			diffEntry = d
			break
		end
	end
	if not diffEntry then
		warn("[LobbySystem] Invalid difficulty from", player.Name, ":", tostring(difficulty))
		return
	end

	-- Validate player is on a pad in Creating state and is the owner
	local padIndex = PadManager.getPlayerPad(player)
	if not padIndex then return end

	local padState = PadManager.getState(padIndex)
	if padState.state ~= LobbyConfig.PadState.CREATING then return end
	if padState.owner ~= player then return end

	-- Enforce unlock requirement
	if diffEntry.unlockRequirement then
		if player:GetAttribute(diffEntry.unlockRequirement) ~= true then
			warn("[LobbySystem]", player.Name, "attempted locked difficulty:", difficulty)
			return
		end
	end

	-- ── Transition Creating → Active ──
	if not PadManager.createLobby(padIndex, difficulty) then return end

	-- Open barrier so other players can walk in and join
	CollisionManager.deactivateBarrier(padIndex)

	updateBillboard(padIndex, player.Name .. "'s Lobby\nDifficulty: " .. difficulty)
	remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.ACTIVE, {
		owner      = player.Name,
		difficulty = difficulty,
	})

	startCountdown(padIndex)
end)

---------------------------------------------------------------------------
-- Remote: player clicked "X" (cancel)
---------------------------------------------------------------------------

remotes.requestCancel.OnServerEvent:Connect(function(player: Player)
	local padIndex = PadManager.getPlayerPad(player)
	if not padIndex then return end

	local padState = PadManager.getState(padIndex)

	-- Only the owner can cancel, and only during Creating
	if padState.state ~= LobbyConfig.PadState.CREATING then return end
	if padState.owner ~= player then return end

	resetPad(padIndex)
	moveToLobbySpawn(player)
end)

---------------------------------------------------------------------------
-- Remote: difficulty unlock query
---------------------------------------------------------------------------

remotes.getUnlocks.OnServerInvoke = function(player: Player)
	local unlocks: { [string]: boolean } = {}
	for _, diff in LobbyConfig.DIFFICULTIES do
		if diff.unlockRequirement == nil then
			unlocks[diff.name] = true
		else
			unlocks[diff.name] = (player:GetAttribute(diff.unlockRequirement) == true)
		end
	end
	return unlocks
end

---------------------------------------------------------------------------
-- Player lifecycle: death & disconnect cleanup
---------------------------------------------------------------------------

local function setupPlayerCleanup(player: Player)
	-- Character removed (death / respawn)
	player.CharacterRemoving:Connect(function()
		local padIndex = PadManager.getPlayerPad(player)
		if not padIndex then return end

		local padState = PadManager.getState(padIndex)
		-- Don't interfere during teleport
		if padState.state == LobbyConfig.PadState.TELEPORTING then return end

		if padState.owner == player then
			resetPad(padIndex)
		else
			PadManager.removePlayer(padIndex, player)
			CollisionManager.resetPlayerCollision(player)
		end
	end)
end

-- Handle existing players (in case script loads late) + new joins
for _, player in Players:GetPlayers() do
	setupPlayerCleanup(player)
end
Players.PlayerAdded:Connect(setupPlayerCleanup)

-- Player fully leaving the game
Players.PlayerRemoving:Connect(function(player: Player)
	local padIndex = PadManager.getPlayerPad(player)
	if padIndex then
		local padState = PadManager.getState(padIndex)
		if padState.state ~= LobbyConfig.PadState.TELEPORTING then
			if padState.owner == player then
				resetPad(padIndex)
			else
				PadManager.removePlayer(padIndex, player)
				CollisionManager.resetPlayerCollision(player)
			end
		end
	end

	touchDebounce[player] = nil
end)

---------------------------------------------------------------------------
-- Initialise billboards & barriers on server start
---------------------------------------------------------------------------

for i = 1, LobbyConfig.PAD_COUNT do
	updateBillboard(i, "Waiting...")
	CollisionManager.deactivateBarrier(i)
end

print("[LobbySystem] Server initialized — " .. LobbyConfig.PAD_COUNT .. " pads ready")
