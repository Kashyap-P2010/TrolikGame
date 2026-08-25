--[[
	TeleportManager — Wraps TeleportService:TeleportAsync with retry logic.
	
	Reserves a private server for each lobby and passes the difficulty
	value via TeleportData so the destination place can read it with:
	  player:GetJoinData().TeleportData.Difficulty
]]

local TeleportService = game:GetService("TeleportService")

local LobbyConfig = require(
	game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("LobbyConfig")
)

local TeleportManager = {}

--- Teleport a list of players to the target place with difficulty data.
--- Filters out disconnected players, retries up to TELEPORT_RETRY_ATTEMPTS.
--- Returns true on success, false if all attempts fail or no valid players remain.
function TeleportManager.teleportLobby(players: { Player }, difficulty: string): boolean
	if #players == 0 then
		return false
	end

	local teleportOptions = Instance.new("TeleportOptions")
	teleportOptions.ShouldReserveServer = true
	teleportOptions:SetTeleportData({
		Difficulty = difficulty,
	})

	for attempt = 1, LobbyConfig.TELEPORT_RETRY_ATTEMPTS do
		-- Filter to players still in the game
		local validPlayers: { Player } = {}
		for _, player in players do
			if player and player.Parent then
				table.insert(validPlayers, player)
			end
		end

		if #validPlayers == 0 then
			warn("[TeleportManager] No valid players remaining — aborting")
			return false
		end

		local success, result = pcall(function()
			return TeleportService:TeleportAsync(
				LobbyConfig.TARGET_PLACE_ID,
				validPlayers,
				teleportOptions
			)
		end)

		if success then
			return true
		end

		warn(
			"[TeleportManager] Attempt "
				.. attempt
				.. "/"
				.. LobbyConfig.TELEPORT_RETRY_ATTEMPTS
				.. " failed: "
				.. tostring(result)
		)

		if attempt < LobbyConfig.TELEPORT_RETRY_ATTEMPTS then
			task.wait(LobbyConfig.TELEPORT_RETRY_DELAY)
		end
	end

	warn("[TeleportManager] All teleport attempts exhausted")
	return false
end

return TeleportManager
