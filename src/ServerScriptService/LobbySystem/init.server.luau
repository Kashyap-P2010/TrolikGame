--[[
	LobbySystem — Server-authoritative orchestrator.
	
	Pad lifecycle:
	  Waiting → Creating → Active → Teleporting → Waiting

	New behaviours:
	  • When a player steps on an empty pad (Waiting → Creating):
	      - Teleported to the centre of the pad floor so they land inside the barriers.
	      - NOT frozen — they can walk freely inside the InvisBorder walls.
	      - InvisBorder is activated immediately.
	      - A CREATION_TIMEOUT countdown starts; if the owner doesn't click
	        Create in time they are reset and returned to LobbyPart (AFK guard).
	  • Active lobby timer (COUNTDOWN_SECONDS) unchanged.
	  • Exit button (client) fires RequestLeaveLobby during Active state.
	    Owner leaving → full pad reset. Joiner leaving → removed from pad + sent to spawn.

	Workspace requirements:
	  workspace.LobbyPads
	    ├─ InvisBorder1 .. InvisBorder4  (Model — wall barriers, direct children)
	    └─ Pad1 .. Pad4                  (BasePart — floor pads)
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
	requestEnter        = LobbyRemotes.get("RequestEnterPad"),
	requestCreate       = LobbyRemotes.get("RequestCreateLobby"),
	requestCancel       = LobbyRemotes.get("RequestCancelLobby"),
	requestLeave        = LobbyRemotes.get("RequestLeaveLobby"),
	showUI              = LobbyRemotes.get("ShowLobbyUI"),
	showExitButton      = LobbyRemotes.get("ShowExitButton"),
	updatePad           = LobbyRemotes.get("UpdatePadState"),
	updateTimer         = LobbyRemotes.get("UpdateTimer"),
	updateCreationTimer = LobbyRemotes.get("UpdateCreationTimer"),
	getUnlocks          = LobbyRemotes.get("GetDifficultyUnlocks"),
}

-- Timestamp-based debounce: value = os.clock() expiry time.
-- Longer writes always win — no race between task.delay closures.
local touchDebounce: { [Player]: number } = {}

-- Tracks per-pad creation-timeout thread so we can cancel it when Create is clicked
local creationTimerThreads: { [number]: thread? } = {}

---------------------------------------------------------------------------
-- Cache pad references at startup (avoids repeated WaitForChild per call)
---------------------------------------------------------------------------
local lobbyPadsFolder = workspace:WaitForChild("LobbyPads", 10)
assert(lobbyPadsFolder, "[LobbySystem] workspace.LobbyPads not found!")

-- padParts[i] = the Pad BasePart (floor)
local padParts: { [number]: BasePart } = {}
for i = 1, LobbyConfig.PAD_COUNT do
	local pad = lobbyPadsFolder:WaitForChild("Pad" .. i, 10)
	if pad and pad:IsA("BasePart") then
		padParts[i] = pad
		print("[LobbySystem] Cached Pad" .. i)
	else
		warn("[LobbySystem] Pad" .. i .. " not found or not a BasePart!")
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
-- Freeze / unfreeze  (still used for Active-state joiners)
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
local function getLobbySpawnPart(): BasePart?
	local spawn = workspace:FindFirstChild("LobbyPart")
		or workspace:FindFirstChild("LobbyPart", true)
		or workspace:FindFirstChild("SpawnLocation")
		or workspace:FindFirstChild("SpawnLocation", true)
		or workspace:FindFirstChildWhichIsA("SpawnLocation", true)

	if spawn and spawn:IsA("BasePart") then
		return spawn
	end
	return nil
end

local SPAWN_DEBOUNCE_SECONDS = 0.5  -- quick debounce after leaving/teleporting to spawn

local function moveToLobbySpawn(player: Player)
	local spawnPart = getLobbySpawnPart()
	if not spawnPart then
		warn("[LobbySystem] LobbyPart / SpawnLocation not found in workspace!")
		return
	end

	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		hrp.AssemblyLinearVelocity  = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end

	local padHalfY = spawnPart.Size.Y / 2
	local targetCF = spawnPart.CFrame + Vector3.new(0, padHalfY + 4, 0)
	character:PivotTo(targetCF)

	-- Stamp a 5-second expiry. No task.delay needed — the check in onPadTouched
	-- uses the timestamp directly, so a shorter prior write cannot override this.
	touchDebounce[player] = os.clock() + SPAWN_DEBOUNCE_SECONDS
end

---------------------------------------------------------------------------
-- Teleport player to the centre of a pad (so they land inside InvisBorder)
---------------------------------------------------------------------------
local function moveToPadCentre(player: Player, padIndex: number)
	local pad = padParts[padIndex]
	if not pad then return end

	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end

	-- Place the player slightly above the pad's top surface
	local padCF     = pad.CFrame
	local padHalfY  = pad.Size.Y / 2
	character:PivotTo(padCF + Vector3.new(0, padHalfY + 5, 0))
end

---------------------------------------------------------------------------
-- Cancel the per-pad creation timer thread
---------------------------------------------------------------------------
local function cancelCreationTimer(padIndex: number)
	local thread = creationTimerThreads[padIndex]
	if thread then
		pcall(task.cancel, thread)
		creationTimerThreads[padIndex] = nil
	end
end

---------------------------------------------------------------------------
-- Region enforcer — checks if player is within pad boundaries
---------------------------------------------------------------------------
local function isInPadRegion(player: Player, padIndex: number): boolean
	local pad = padParts[padIndex]
	if not pad then return true end

	local character = player.Character
	if not character then return true end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return true end

	local localPos = pad.CFrame:PointToObjectSpace(hrp.Position)
	local halfX    = (pad.Size.X / 2) + 2
	local halfZ    = (pad.Size.Z / 2) + 2
	return math.abs(localPos.X) <= halfX and math.abs(localPos.Z) <= halfZ
end

---------------------------------------------------------------------------
-- Full pad reset
---------------------------------------------------------------------------
local function resetPad(padIndex: number)
	local padState = PadManager.getState(padIndex)
	if not padState then return end

	-- Cancel creation AFK timer if it's still running
	cancelCreationTimer(padIndex)

	-- Unfreeze all players before wiping state
	for _, p in padState.players do
		if p and p.Parent then
			unfreezePlayer(p)
		end
	end

	-- Reset collision groups for all lobby players
	CollisionManager.resetPadCollisions(padIndex, padState.players)

	-- Hide CreateGame UI for the owner (if still in game)
	if padState.owner and padState.owner.Parent then
		remotes.showUI:FireClient(padState.owner, false)
	end

	-- Hide Exit button for all players who were in this lobby
	for _, p in padState.players do
		if p and p.Parent then
			remotes.showExitButton:FireClient(p, false)
		end
	end

	-- Wipe pad data
	PadManager.reset(padIndex)

	-- Deactivate barrier and reset billboard
	CollisionManager.deactivateBarrier(padIndex)
	updateBillboard(padIndex, "Waiting...")
	remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.WAITING, {})
end

---------------------------------------------------------------------------
-- AFK guard: countdown for Creating state
-- If owner doesn't click Create within CREATION_TIMEOUT_SECONDS, reset.
---------------------------------------------------------------------------
local function startCreationTimer(padIndex: number)
	cancelCreationTimer(padIndex)  -- safety: clear any stale thread

	local thread = task.spawn(function()
		local padState = PadManager.getState(padIndex)
		local owner    = padState and padState.owner

		for remaining = LobbyConfig.CREATION_TIMEOUT_SECONDS, 0, -1 do
			-- Bail early if the pad is no longer in Creating state
			padState = PadManager.getState(padIndex)
			if not padState or padState.state ~= LobbyConfig.PadState.CREATING then return end

			-- Send tick to the owner's client
			if owner and owner.Parent then
				remotes.updateCreationTimer:FireClient(owner, padIndex, remaining)
			end

			-- Enforce: owner must stay inside the pad region
			if owner and owner.Parent and not isInPadRegion(owner, padIndex) then
				warn("[LobbySystem] Owner escaped pad" .. padIndex .. " — teleporting back")
				moveToPadCentre(owner, padIndex)
			end

			if remaining > 0 then
				task.wait(1)
			end
		end

		-- Timer hit 0 — the owner went AFK, reset the pad
		padState = PadManager.getState(padIndex)
		if not padState or padState.state ~= LobbyConfig.PadState.CREATING then return end

		warn("[LobbySystem] Owner AFK on Pad" .. padIndex .. " — resetting pad")

		local owner2 = padState.owner
		if owner2 and owner2.Parent then
			unfreezePlayer(owner2)
			moveToLobbySpawn(owner2)
		end

		resetPad(padIndex)
	end)

	creationTimerThreads[padIndex] = thread
end

---------------------------------------------------------------------------
-- Countdown & teleport (Active state)
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

			-- Enforce: all lobby members must stay inside the pad region
			for _, p in padState.players do
				if p and p.Parent and not isInPadRegion(p, padIndex) then
					warn("[LobbySystem] Player", p.Name, "escaped pad" .. padIndex .. " — teleporting back")
					moveToPadCentre(p, padIndex)
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
-- Core pad entrance handler (used by client remote and server physics touch)
---------------------------------------------------------------------------
local function handlePlayerEnterPad(padIndex: number, player: Player)
	local character = player.Character
	if not character then return end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local pad = padParts[padIndex]
	if not pad then return end

	-- Validate proximity (prevent far-away triggers)
	local distance = (hrp.Position - pad.Position).Magnitude
	local maxAllowed = (pad.Size.Magnitude / 2) + 15
	if distance > maxAllowed then return end

	local now = os.clock()
	if touchDebounce[player] and touchDebounce[player] > now then return end

	local padState = PadManager.getState(padIndex)
	if not padState then return end

	-- ── Waiting → Creating ──
	if padState.state == LobbyConfig.PadState.WAITING then
		if PadManager.getPlayerPad(player) then return end
		if not PadManager.occupy(padIndex, player) then return end

		touchDebounce[player] = now + 0.3

		CollisionManager.activateBarrier(padIndex)
		moveToPadCentre(player, padIndex)

		updateBillboard(padIndex, "Creating Lobby...")
		remotes.showUI:FireClient(player, true, padIndex)
		remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.CREATING, {
			owner = player.Name,
		})

		startCreationTimer(padIndex)

	-- ── Active → join ──
	elseif padState.state == LobbyConfig.PadState.ACTIVE then
		if PadManager.getPlayerPad(player) then return end
		if #padState.players >= LobbyConfig.MAX_LOBBY_PLAYERS then return end
		if not PadManager.addPlayer(padIndex, player) then return end

		touchDebounce[player] = now + 0.3

		moveToPadCentre(player, padIndex)
		freezePlayer(player)
		remotes.showExitButton:FireClient(player, true, padIndex)

		print("[LobbySystem] Joiner", player.Name, "entered Pad" .. padIndex)
	end
end

-- Client remote event for 0ms instant touch response
remotes.requestEnter.OnServerEvent:Connect(function(player: Player, padIndex: number)
	if type(padIndex) ~= "number" or padIndex < 1 or padIndex > LobbyConfig.PAD_COUNT then return end
	handlePlayerEnterPad(padIndex, player)
end)

---------------------------------------------------------------------------
-- Server physics touch fallback handlers
---------------------------------------------------------------------------
local function onPadTouched(padIndex: number, hit: BasePart)
	local character = hit:FindFirstAncestorOfClass("Model")
	if not character then return end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	handlePlayerEnterPad(padIndex, player)
end

for i = 1, LobbyConfig.PAD_COUNT do
	local pad = padParts[i]
	if pad and pad:IsA("BasePart") then
		pad.Touched:Connect(function(hit) onPadTouched(i, hit) end)
	end
end

local function onBorderTouched(padIndex: number, hit: BasePart)
	local character = hit:FindFirstAncestorOfClass("Model")
	if not character then return end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	handlePlayerEnterPad(padIndex, player)
end

for i = 1, LobbyConfig.PAD_COUNT do
	for _, borderPart in CollisionManager.getBorderParts(i) do
		borderPart.Touched:Connect(function(hit) onBorderTouched(i, hit) end)
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

	-- Cancel AFK timer — owner successfully created the lobby
	cancelCreationTimer(padIndex)

	-- Barrier stays UP — owners can't walk out; joiners enter via border-wall Touched

	updateBillboard(padIndex, player.Name .. "'s Lobby\nDifficulty: " .. difficulty)
	remotes.updatePad:FireAllClients(padIndex, LobbyConfig.PadState.ACTIVE, {
		owner      = player.Name,
		difficulty = difficulty,
	})

	-- Show the Exit Lobby button to the owner (they're now in an Active lobby)
	remotes.showExitButton:FireClient(player, true, padIndex)

	startCountdown(padIndex)
end)

---------------------------------------------------------------------------
-- Remote: Cancel lobby (X button — only valid during Creating state)
---------------------------------------------------------------------------
remotes.requestCancel.OnServerEvent:Connect(function(player: Player)
	local padIndex = PadManager.getPlayerPad(player)
	if not padIndex then return end

	local padState = PadManager.getState(padIndex)
	if padState.state ~= LobbyConfig.PadState.CREATING then return end
	if padState.owner ~= player then return end

	unfreezePlayer(player)
	moveToLobbySpawn(player)
	resetPad(padIndex)
end)

---------------------------------------------------------------------------
-- Remote: Leave lobby (Exit button — valid during Active state)
-- Owner leaving resets the whole pad; joiners are individually removed.
---------------------------------------------------------------------------
remotes.requestLeave.OnServerEvent:Connect(function(player: Player)
	local padIndex = PadManager.getPlayerPad(player)
	if not padIndex then return end

	local padState = PadManager.getState(padIndex)
	if padState.state ~= LobbyConfig.PadState.ACTIVE then return end

	if padState.owner == player then
		-- Owner leaves → teleport everyone to spawn, then reset pad
		local playersToReturn: { Player } = {}
		for _, p in padState.players do
			if p and p.Parent then
				table.insert(playersToReturn, p)
			end
		end

		for _, p in playersToReturn do
			if p and p.Parent then
				unfreezePlayer(p)
				moveToLobbySpawn(p)
			end
		end

		resetPad(padIndex)
	else
		-- Joiner leaves → remove from pad and teleport to spawn
		unfreezePlayer(player)
		CollisionManager.resetPlayerCollision(player)
		PadManager.removePlayer(padIndex, player)
		remotes.showExitButton:FireClient(player, false)
		moveToLobbySpawn(player)
	end
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
