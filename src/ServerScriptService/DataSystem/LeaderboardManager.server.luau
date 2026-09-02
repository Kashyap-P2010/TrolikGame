--[[
	LeaderboardManager.server.luau
	
	Manages the "Most Exams Passed" in-world leaderboard.
	
	• Uses an OrderedDataStore to rank players globally.
	• Refreshes the SurfaceGui every 60 seconds.
	• Animates a countdown timer on the TimeLabel.
	• Updates the OrderedDataStore whenever a player passes an exam.
]]

local Players          = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local Workspace        = game:GetService("Workspace")

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

---------------------------------------------------------------------------
-- OrderedDataStore
---------------------------------------------------------------------------
local ORDERED_DS_NAME = "MostExamsPassed_v1"
local orderedDS = DataStoreService:GetOrderedDataStore(ORDERED_DS_NAME)

local REFRESH_INTERVAL = 60 -- seconds
local MAX_ENTRIES      = 100

---------------------------------------------------------------------------
-- Listen for exams passed changes → update OrderedDataStore
---------------------------------------------------------------------------
PlayerData.onChanged(function(player: Player, key: string, value: any)
	if key ~= "ExamsPassed" then return end
	if type(value) ~= "number" then return end
	
	task.spawn(function()
		local success, err = pcall(function()
			orderedDS:SetAsync(tostring(player.UserId), value)
		end)
		if success then
			print(string.format("[LeaderboardManager] Updated OrderedDS for %s: %d exams", player.Name, value))
		else
			warn(string.format("[LeaderboardManager] Failed to update OrderedDS for %s: %s", player.Name, tostring(err)))
		end
	end)
end)

---------------------------------------------------------------------------
-- Find the leaderboard model in Workspace
---------------------------------------------------------------------------
local lbModel = Workspace:WaitForChild("MostExamsPassedLB", 30)
if not lbModel then
	warn("[LeaderboardManager] MostExamsPassedLB model not found in Workspace!")
	return
end

local lbPart = lbModel:WaitForChild("LeaderboardPart", 10)
if not lbPart then
	warn("[LeaderboardManager] LeaderboardPart not found!")
	return
end

local surfaceGui = lbPart:WaitForChild("SurfaceGui", 10)
if not surfaceGui then
	warn("[LeaderboardManager] SurfaceGui not found!")
	return
end

local scrollFrame = surfaceGui:WaitForChild("ScrollingFrame", 10)
if not scrollFrame then
	warn("[LeaderboardManager] ScrollingFrame not found!")
	return
end

local container = scrollFrame:WaitForChild("Container", 10)
if not container then
	warn("[LeaderboardManager] Container not found!")
	return
end

local playerTemplate = container:WaitForChild("PlayerTemplate", 10)
if not playerTemplate then
	warn("[LeaderboardManager] PlayerTemplate not found!")
	return
end

-- Hide the template itself — we clone it for each entry
playerTemplate.Visible = false

local timeLabel = surfaceGui:FindFirstChild("TimeLabel")

print("[LeaderboardManager] All UI references found ✓")

---------------------------------------------------------------------------
-- Refresh the leaderboard
---------------------------------------------------------------------------
local function clearOldEntries()
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Frame") and child ~= playerTemplate then
			child:Destroy()
		end
	end
end

local function refreshLeaderboard()
	print("[LeaderboardManager] Refreshing leaderboard...")
	
	local success, pages = pcall(function()
		return orderedDS:GetSortedAsync(false, MAX_ENTRIES) -- descending
	end)
	
	if not success or not pages then
		warn("[LeaderboardManager] Failed to fetch leaderboard data: " .. tostring(pages))
		return
	end
	
	local entries = {}
	local ok, err = pcall(function()
		local currentPage = pages:GetCurrentPage()
		for _, entry in ipairs(currentPage) do
			table.insert(entries, {
				userId = tonumber(entry.key),
				value  = entry.value,
			})
		end
	end)
	
	if not ok then
		warn("[LeaderboardManager] Failed to read leaderboard page: " .. tostring(err))
		return
	end
	
	-- Clear old entries
	clearOldEntries()
	
	-- Populate new entries
	for rank, entry in ipairs(entries) do
		local clone = playerTemplate:Clone()
		clone.Name = "Entry_" .. rank
		clone.Visible = true
		
		-- Set rank number
		local numberFrame = clone:FindFirstChild("Number")
		if numberFrame then
			local numberLabel = numberFrame:FindFirstChild("NumberLabel")
			if numberLabel then
				numberLabel.Text = "#" .. tostring(rank)
			end
		end
		
		-- Set player name
		local nameLabel = clone:FindFirstChild("NameLabel")
		if nameLabel then
			local nameSuccess, displayName = pcall(function()
				return Players:GetNameFromUserIdAsync(entry.userId)
			end)
			if nameSuccess then
				nameLabel.Text = displayName
			else
				nameLabel.Text = "Player_" .. tostring(entry.userId)
			end
		end
		
		-- Set player headshot
		local imageLabel = clone:FindFirstChild("ImageLabel")
		if imageLabel then
			local imgSuccess, imgContent = pcall(function()
				return Players:GetUserThumbnailAsync(
					entry.userId,
					Enum.ThumbnailType.HeadShot,
					Enum.ThumbnailSize.Size100x100
				)
			end)
			if imgSuccess and imgContent then
				imageLabel.Image = imgContent
			end
		end
		
		clone.Parent = container
	end
	
	print(string.format("[LeaderboardManager] Leaderboard refreshed with %d entries", #entries))
end

---------------------------------------------------------------------------
-- Timer countdown + refresh loop
---------------------------------------------------------------------------
task.spawn(function()
	-- Initial refresh
	refreshLeaderboard()
	
	while true do
		-- Count down from REFRESH_INTERVAL to 0
		for secondsLeft = REFRESH_INTERVAL, 1, -1 do
			if timeLabel then
				timeLabel.Text = string.format("Updating the board in %ds", secondsLeft)
			end
			task.wait(1)
		end
		
		-- Refresh
		if timeLabel then
			timeLabel.Text = "Updating..."
		end
		
		refreshLeaderboard()
	end
end)

print("[LeaderboardManager] Initialized ✓")
