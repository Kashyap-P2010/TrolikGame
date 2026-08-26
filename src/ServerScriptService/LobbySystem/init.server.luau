--[[
	LobbySystem — Server-authoritative orchestrator.
	
	Pad lifecycle:
	  Waiting → Creating → Active → Teleporting → Waiting

	Workspace requirements:
	  workspace.LobbyPads
	    └─ Pad1 .. Pad4  (BasePart)
	         ├─ invisbox    (BasePart — the barrier wall)
	         └─ BillboardGui > TextLabel
	  workspace.LobbyPart  (SpawnLocation — cancel destination)
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

local remotes = {
	requestCreate  = LobbyRemotes.get("RequestCreateLobby"),
	requestCancel  = LobbyRemotes.get("RequestCancelLobby"),
	showUI         = LobbyRemotes.get("ShowLobbyUI"),
	updatePad      = LobbyRemotes.get("UpdatePadState"),
	updateTimer    = LobbyRemotes.get("UpdateTimer"),
	getUnlocks     = LobbyRemotes.get("GetDifficultyUnlocks"),
}

local touchDebounce: { [Player]: boolean } = {}

---------------------------------------------------------------------------
-- Cache pad references at startup (avoids repeated WaitForChild per call)
---------------------------------------------------------------------------
local lobbyPadsFolder = workspace:WaitForChild("LobbyPads", 10)
assert(lobbyPadsFolder, "[LobbySystem] workspace.LobbyPads not found!")

-- padParts[i] = the Pad BasePart
local padParts: { [number]: BasePart } = {}
for i = 1, LobbyConfig.PAD_COUNT do
	local pad = lobbyPadsFolder:WaitForChild("Pad" .. i, 10)
	if pad then
		padParts[i] = pad
		print("[LobbySystem] Cached Pad" .. i, "| Children:", table.concat((function()
			local names = {}
			for _, c in pad:GetChildren() do table.insert(names, c.Name) end
			return names
		end)(), ", "))
	else
		warn("[LobbySystem] Pad" .. i .. " not found!")
	end
end

---------------------------------------------------------------------------
-- Billboard helper
---------------------------------------------------------------------------
local function updateBillboard(padIndex: number, text: string)
	local pad = padParts[padIndex]
	if not pad then return end

	local billboard = pad:FindFirstChildWhichIsA("BillboardGui", true)
	if not billboard then return end

	local label = billboard:FindFirstChildWhichIsA("TextLabel", true)
	if not label then return end

	label.Text = text
end

---------------------------------------------------------------------------
-- Freeze / unfreeze
---------------------------------------------------------------------------
local DEFAULT_WALKSPEED  = 16
local DEFAULT_JUMPHEIGHT = 7.2

local function freezePlayer(player: Player)
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	humanoid.WalkSpeed  = 0
	humanoid.JumpHeight = 0
end

local function unfreezePlayer(player: Player)
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	humanoid.WalkSpeed  = DEFAULT_WALKSPEED
	humanoid.JumpHeight = DEFAULT_JUMPHEIGHT
end

---------------------------------------------------------------------------
-- Teleport to spawn (cancel / teleport failure fallback)
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

	hrp.CFrame = lobbyPart.CFrame + Vector3.new(0, 5, 0)
end

---------------------------------------------------------------------------
-- Full pad reset
---------------------------------------------------------------------------
local function resetPad(padIndex: number)
	local padState = PadManager.getState(padIndex)
	if not padState then return end

	-- Unfreeze all players before wiping state
	for _, p in padState.players do
		if p and p.Parent then
			unfreezePlayer(p)
		end
	end

	-- Reset collision groups for all lobby players
	CollisionManager.resetPadCollisions(padIndex, padState.players)

	-- Hide UI for the owner (if still in game)
	if padState.owner and padState.owner.Parent then
		remotes.showUI:FireClient(padState.owner, false)
	end

	-- Wipe pad data
	PadManager.reset(padIndex)

	-- Deactivate barrier and reset billboard
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
			if padState.state ~= LobbyConfig.PadState.ACTIVE then return end

			local ownerName = padState.owner and padState.owner.Name or "Unknown"
			local diff      = padState.difficulty or "Easy"
			updateBillboard(padIndex,
				ownerName .. "'s Lobby\nDifficulty: " .. diff .. "\n" .. remaining .. "s"
			)

			for _, p in padState.players do
				if p and p.Parent then
					remotes.updateTimer:FireClient(p, padIndex, remaining)
				end
			end

			if remaining > 0 then
				task.wait(1)
			end
		end

		-- Guard: ensure state still Active after the loop
		if padState.state ~= LobbyConfig.PadState.ACTIVE then return end

		-- ── Teleporting ──
		PadManager.setTeleporting(padIndex)
		updateBillboard(padIndex, "Teleporting...")
		remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.TELEPORTING, {})

		-- Close UI on owner's screen
		if padState.owner and padState.owner.Parent then
			remotes.showUI:FireClient(padState.owner, false)
		end

		local toTeleport: { Player } = {}
		for _, p in padState.players do
			if p and p.Parent then
				table.insert(toTeleport, p)
			end
		end

		local ok = TeleportManager.teleportLobby(toTeleport, padState.difficulty or "Easy")

		if not ok then
			warn("[LobbySystem] Teleport failed for Pad" .. padIndex .. " — returning to spawn")
			for _, p in toTeleport do
				if p and p.Parent then
					unfreezePlayer(p)    -- unfreeze before moving them back
					moveToLobbySpawn(p)
				end
			end
		end

		task.wait(1.5)
		resetPad(padIndex)
	end)

	PadManager.setTimerThread(padIndex, thread)
end

---------------------------------------------------------------------------
-- Pad touch handler
-- NOTE: Only connected to the floor pad (Pad1-4), NOT to invisbox.
--       The invisbox is a barrier wall; its Touched fires constantly when
--       a player stands against it which would spam this handler.
---------------------------------------------------------------------------
local function onPadTouched(padIndex: number, hit: BasePart)
	local character = hit.Parent
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	-- Per-player debounce
	if touchDebounce[player] then return end
	touchDebounce[player] = true
	task.delay(0.5, function()
		touchDebounce[player] = nil
	end)

	local padState = PadManager.getState(padIndex)
	if not padState then return end

	-- ── Waiting → Creating ──
	if padState.state == LobbyConfig.PadState.WAITING then
		if PadManager.getPlayerPad(player) then return end
		if not PadManager.occupy(padIndex, player) then return end

		freezePlayer(player)
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

		freezePlayer(player)

		-- Re-activate barrier if lobby is now full
		if #padState.players >= LobbyConfig.MAX_LOBBY_PLAYERS then
			for _, p in padState.players do
				CollisionManager.allowPlayerOnPad(padIndex, p)
			end
			CollisionManager.activateBarrier(padIndex)
		end
	end
end

-- Connect Touched only to the floor pad (not invisbox)
for i = 1, LobbyConfig.PAD_COUNT do
	local pad = padParts[i]
	if pad and pad:IsA("BasePart") then
		pad.Touched:Connect(function(hit) onPadTouched(i, hit) end)
	end
end

---------------------------------------------------------------------------
-- Remote: Create lobby
---------------------------------------------------------------------------
remotes.requestCreate.OnServerEvent:Connect(function(player: Player, difficulty: string)
	-- Validate difficulty
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

	local padIndex = PadManager.getPlayerPad(player)
	if not padIndex then return end

	local padState = PadManager.getState(padIndex)
	if padState.state ~= LobbyConfig.PadState.CREATING then return end
	if padState.owner ~= player then return end

	-- Server-side unlock check
	if diffEntry.unlockRequirement then
		if player:GetAttribute(diffEntry.unlockRequirement) ~= true then
			warn("[LobbySystem]", player.Name, "attempted locked difficulty:", difficulty)
			return
		end
	end

	if not PadManager.createLobby(padIndex, difficulty) then return end

	-- Open barrier for joiners
	CollisionManager.deactivateBarrier(padIndex)

	updateBillboard(padIndex, player.Name .. "'s Lobby\nDifficulty: " .. difficulty)
	remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.ACTIVE, {
		owner      = player.Name,
		difficulty = difficulty,
	})

	startCountdown(padIndex)
end)

---------------------------------------------------------------------------
-- Remote: Cancel lobby
---------------------------------------------------------------------------
remotes.requestCancel.OnServerEvent:Connect(function(player: Player)
	local padIndex = PadManager.getPlayerPad(player)
	if not padIndex then return end

	local padState = PadManager.getState(padIndex)
	if padState.state ~= LobbyConfig.PadState.CREATING then return end
	if padState.owner ~= player then return end

	resetPad(padIndex)
	moveToLobbySpawn(player)
end)

---------------------------------------------------------------------------
-- Remote: Difficulty unlock query
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
-- Player lifecycle: death / disconnect
---------------------------------------------------------------------------
local function setupPlayerCleanup(player: Player)
	player.CharacterRemoving:Connect(function()
		local padIndex = PadManager.getPlayerPad(player)
		if not padIndex then return end

		local padState = PadManager.getState(padIndex)
		if padState.state == LobbyConfig.PadState.TELEPORTING then return end

		if padState.owner == player then
			resetPad(padIndex)
		else
			unfreezePlayer(player)
			PadManager.removePlayer(padIndex, player)
			CollisionManager.resetPlayerCollision(player)
		end
	end)
end

for _, player in Players:GetPlayers() do
	setupPlayerCleanup(player)
end
Players.PlayerAdded:Connect(setupPlayerCleanup)

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
-- Init: set billboard text and ensure barriers are off
---------------------------------------------------------------------------
for i = 1, LobbyConfig.PAD_COUNT do
	updateBillboard(i, "Waiting...")
	CollisionManager.deactivateBarrier(i)
end

print("[LobbySystem] Server initialized — " .. LobbyConfig.PAD_COUNT .. " pads ready")
