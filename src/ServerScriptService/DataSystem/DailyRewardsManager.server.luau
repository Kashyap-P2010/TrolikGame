--[[
	DailyRewardsManager.server.luau
	Handles streak calculation and claiming of daily rewards.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataRemotes = require(Shared:WaitForChild("DataRemotes"))
local PlayerData = require(ServerScriptService.DataSystem:WaitForChild("PlayerData"))

local claimDailyReward = DataRemotes.get("ClaimDailyReward") :: RemoteFunction

-- Configuration
local SECONDS_IN_DAY = 86400
local REWARDS = {
	[1] = { type = "Coins", amount = 200 },
	[2] = { type = "Item", name = "Tv_Glitch" },
	[3] = { type = "Coins", amount = 200 },
	[4] = { type = "Coins", amount = 200 },
	[5] = { type = "Coins", amount = 200 },
	[6] = { type = "Coins", amount = 200 },
	[7] = { type = "Item", name = "Genius_Potion" },
}

-- Utility: Get UTC midnight for a given timestamp
local function getUTCMidnight(timestamp: number)
	return math.floor(timestamp / SECONDS_IN_DAY) * SECONDS_IN_DAY
end

claimDailyReward.OnServerInvoke = function(player: Player)
	if not PlayerData.hasSession(player) then
		return { success = false, msg = "Data loading..." }
	end

	local lastClaim = PlayerData.get(player, "LastDailyRewardClaim") or 0
	local currentStreak = PlayerData.get(player, "DailyRewardStreak") or 0
	
	local lastClaimMidnight = getUTCMidnight(lastClaim)
	local currentMidnight = getUTCMidnight(os.time())
	
	-- Check eligibility
	if currentMidnight == lastClaimMidnight then
		return { success = false, msg = "Already claimed today!" }
	end
	
	-- Update streak
	if currentMidnight == lastClaimMidnight + SECONDS_IN_DAY then
		-- Consecutive day
		currentStreak = currentStreak + 1
	else
		-- Missed a day or first time
		currentStreak = 1
	end
	
	if currentStreak > 7 then
		currentStreak = 1 -- Reset after day 7
	end
	
	-- Give Reward
	local reward = REWARDS[currentStreak]
	if not reward then
		return { success = false, msg = "Invalid reward configuration." }
	end
	
	if reward.type == "Coins" then
		PlayerData.addCoins(player, reward.amount)
	elseif reward.type == "Item" then
		PlayerData.addItem(player, reward.name)
	end
	
	-- Save data
	PlayerData.set(player, "LastDailyRewardClaim", os.time())
	PlayerData.set(player, "DailyRewardStreak", currentStreak)
	
	return { success = true, msg = "Claimed Day " .. currentStreak .. "!", streak = currentStreak }
end

print("[DailyRewardsManager] Loaded")
