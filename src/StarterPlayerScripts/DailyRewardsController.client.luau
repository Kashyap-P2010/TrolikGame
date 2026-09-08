--[[
	DailyRewardsController.client.luau
	Handles UI updates and claim requests for the Daily Rewards system.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local shopUI = playerGui:WaitForChild("ShopUI")
local dailyRewardsUI = shopUI:WaitForChild("DailyRewards")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DataRemotes = require(Shared:WaitForChild("DataRemotes"))

local getPlayerData = DataRemotes.get("GetPlayerData") :: RemoteFunction
local claimDailyReward = DataRemotes.get("ClaimDailyReward") :: RemoteFunction

local SECONDS_IN_DAY = 86400
local currentStreak = 0
local lastClaim = 0

-- Create a Test Trigger Button
local triggerBtn = Instance.new("TextButton")
triggerBtn.Name = "TestDailyRewardsBtn"
triggerBtn.Size = UDim2.new(0, 150, 0, 50)
triggerBtn.Position = UDim2.new(0, 10, 0.5, 0)
triggerBtn.Text = "Daily Rewards"
triggerBtn.BackgroundColor3 = Color3.fromRGB(40, 160, 255)
triggerBtn.TextColor3 = Color3.new(1, 1, 1)
triggerBtn.Font = Enum.Font.GothamBold
triggerBtn.TextSize = 18
triggerBtn.Parent = shopUI

local function getUTCMidnight(timestamp: number)
	return math.floor(timestamp / SECONDS_IN_DAY) * SECONDS_IN_DAY
end

local function updateUI()
	local lastClaimMidnight = getUTCMidnight(lastClaim)
	local currentMidnight = getUTCMidnight(os.time())
	
	local claimedToday = (currentMidnight == lastClaimMidnight)
	local expectedStreak = currentStreak
	
	if currentMidnight > lastClaimMidnight + SECONDS_IN_DAY and not claimedToday then
		expectedStreak = 0 -- Will reset to 1 on claim
	end
	
	local nextRewardDay = expectedStreak + 1
	if expectedStreak >= 7 and not claimedToday then
		nextRewardDay = 1
	elseif claimedToday then
		nextRewardDay = expectedStreak + 1
	end
	
	for i = 1, 7 do
		local rewardFrame = dailyRewardsUI:FindFirstChild("Reward" .. i)
		if not rewardFrame then continue end
		
		local claimBtn = rewardFrame:FindFirstChild("Claim")
		local notYetBtn = rewardFrame:FindFirstChild("NotYet")
		local activeGradient = rewardFrame:FindFirstChild("SketchActiveGradient")
		
		if claimBtn then claimBtn.Visible = false end
		if notYetBtn then notYetBtn.Visible = false end
		if activeGradient then activeGradient.Enabled = false end
		
		if i < nextRewardDay or (claimedToday and i <= expectedStreak) then
			-- Already claimed
			if claimBtn then claimBtn.Visible = false end
		elseif i == nextRewardDay and not claimedToday then
			-- Ready to claim!
			if claimBtn then
				claimBtn.Visible = true
				claimBtn.Text = "Claim"
				claimBtn.BackgroundColor3 = Color3.fromRGB(0, 200, 0)
			end
			if activeGradient then activeGradient.Enabled = true end
		else
			-- Future reward
			if notYetBtn then notYetBtn.Visible = false end
			if claimBtn then claimBtn.Visible = false end
		end
	end
end

local function onClaimClicked()
	local result = claimDailyReward:InvokeServer()
	if result and result.success then
		print("[DailyRewards] Successfully claimed!")
		-- Refresh data
		local data = getPlayerData:InvokeServer()
		if data then
			lastClaim = data.LastDailyRewardClaim or 0
			currentStreak = data.DailyRewardStreak or 0
			updateUI()
		end
	else
		warn("[DailyRewards] Failed to claim: " .. tostring(result and result.msg))
	end
end

-- Bind buttons
for i = 1, 7 do
	local rewardFrame = dailyRewardsUI:FindFirstChild("Reward" .. i)
	if rewardFrame then
		local claimBtn = rewardFrame:FindFirstChild("Claim")
		if claimBtn and claimBtn:IsA("GuiButton") then
			claimBtn.MouseButton1Click:Connect(onClaimClicked)
		end
	end
end

-- Topbar close button
local topbar = dailyRewardsUI:FindFirstChild("Topbar")
if topbar then
	local closeBtn = topbar:FindFirstChildWhichIsA("GuiButton")
	if closeBtn then
		closeBtn.MouseButton1Click:Connect(function()
			dailyRewardsUI.Visible = false
		end)
	end
end

-- Trigger button
triggerBtn.MouseButton1Click:Connect(function()
	dailyRewardsUI.Visible = not dailyRewardsUI.Visible
end)

-- Initial Load
task.spawn(function()
	local data = getPlayerData:InvokeServer()
	if data then
		lastClaim = data.LastDailyRewardClaim or 0
		currentStreak = data.DailyRewardStreak or 0
		updateUI()
		
		-- Auto open on join if a reward is ready
		local lastClaimMidnight = getUTCMidnight(lastClaim)
		local currentMidnight = getUTCMidnight(os.time())
		if currentMidnight ~= lastClaimMidnight then
			dailyRewardsUI.Visible = true
		end
	end
end)
