--[[
	ShopController.client.luau
	
	Handles all shop UI interactions:
	  • ShopPad proximity detection (show/hide ExamTricksShop).
	  • Item frame clicks → open corresponding CanvasGroup detail view.
	  • Buy buttons (Money / Robux) → fire server remotes.
	  • Real-time ownership updates via DataUpdated remote.
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local DataRemotes       = require(Shared:WaitForChild("DataRemotes"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local getPlayerData    = DataRemotes.get("GetPlayerData") :: RemoteFunction
local dataUpdated      = DataRemotes.get("DataUpdated") :: RemoteEvent
local purchaseItem     = DataRemotes.get("PurchaseItem") :: RemoteFunction
local purchaseGamepass = DataRemotes.get("PurchaseGamepass") :: RemoteFunction

---------------------------------------------------------------------------
-- UI References
---------------------------------------------------------------------------
local shopUI = playerGui:WaitForChild("ShopUI", 15) :: ScreenGui?
if not shopUI then
	warn("[ShopController] ShopUI not found in PlayerGui!")
	return
end
shopUI.Enabled = true

local examTricksShop = shopUI:WaitForChild("ExamTricksShop", 10) :: Frame?
if not examTricksShop then
	warn("[ShopController] ExamTricksShop not found inside ShopUI!")
	return
end

local itemsFolder = examTricksShop:WaitForChild("Items", 10)
if not itemsFolder then
	warn("[ShopController] Items folder not found inside ExamTricksShop!")
	return
end

-- Start hidden
examTricksShop.Visible = false

---------------------------------------------------------------------------
-- Notifications UI
---------------------------------------------------------------------------
local notifLabel = Instance.new("TextLabel")
notifLabel.Name = "ShopNotification"
notifLabel.Size = UDim2.new(0, 400, 0, 50)
notifLabel.AnchorPoint = Vector2.new(0.5, 0)
notifLabel.Position = UDim2.new(0.5, 0, -0.2, 0) -- Starts off-screen (top)
notifLabel.BackgroundTransparency = 1
notifLabel.Font = Enum.Font.Montserrat
notifLabel.TextSize = 24
notifLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
notifLabel.Text = ""
notifLabel.ZIndex = 100
notifLabel.Parent = shopUI

local notifStroke = Instance.new("UIStroke")
notifStroke.Thickness = 3
notifStroke.Color = Color3.fromRGB(0, 0, 0)
notifStroke.Parent = notifLabel

local activeNotifThread: thread? = nil

local function showNotification(text: string, color: Color3)
	if activeNotifThread then
		task.cancel(activeNotifThread)
	end
	
	notifLabel.Text = text
	notifLabel.TextColor3 = color
	
	local tweenIn = TweenService:Create(notifLabel, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0.1, 0)
	})
	tweenIn:Play()
	
	activeNotifThread = task.spawn(function()
		task.wait(3)
		local tweenOut = TweenService:Create(notifLabel, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, -0.2, 0)
		})
		tweenOut:Play()
	end)
end

---------------------------------------------------------------------------
-- Item names that map to CanvasGroups (siblings of ExamTricksShop in ShopUI)
---------------------------------------------------------------------------
local ITEM_NAMES = {
	"Choice_Eraser",
	"Genius_Potion",
	"Neighbor_Cheats",
	"Nerd_Help",
	"Radio_Answer",
	"Smart_Glasses",
	"Teacher's_Desk",
	"Window_Friend",
}

-- Which items are Robux-only (must match PlayerData.ITEM_CATALOG)
local ROBUX_ITEMS = {
	["Choice_Eraser"] = true,
	["Smart_Glasses"] = true,
}

-- Aliases for CanvasGroups if their name in Studio differs from the itemName
local CANVAS_ALIASES = {
	["Window_Friend"] = "Neighbor_Cheats", -- The user reported the CanvasGroup is named Neighbor_Cheats
}

---------------------------------------------------------------------------
-- Local state
---------------------------------------------------------------------------
local ownedItems: { [string]: boolean } = {}
local activeCanvasGroup: CanvasGroup? = nil

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function closeAllCanvasGroups()
	for _, name in ipairs(ITEM_NAMES) do
		local cg = shopUI:FindFirstChild(name)
		if cg and cg:IsA("CanvasGroup") then
			cg.Visible = false
		end
	end
	activeCanvasGroup = nil
end

local function updateBuyButtonState(container: Instance, itemName: string)
	local buyFolder = container:FindFirstChild("Buy")
	if not buyFolder then return end
	
	local moneyBtn = buyFolder:FindFirstChild("Money")
	local robuxBtn = buyFolder:FindFirstChild("Robux")
	
	if ownedItems[itemName] then
		-- Item is owned — show "Owned" state
		if moneyBtn then
			if moneyBtn:IsA("TextButton") or moneyBtn:IsA("TextLabel") then
				moneyBtn.Text = "Owned"
			end
		end
		if robuxBtn then
			if robuxBtn:IsA("TextButton") or robuxBtn:IsA("TextLabel") then
				robuxBtn.Text = "Owned"
			end
		end
	end
end

local function openCanvasGroup(itemName: string)
	closeAllCanvasGroups()
	
	local cgName = CANVAS_ALIASES[itemName] or itemName
	local cg = shopUI:FindFirstChild(cgName)
	if cg and cg:IsA("CanvasGroup") then
		cg.Visible = true
		activeCanvasGroup = cg
		updateBuyButtonState(cg, itemName)
		print("[ShopController] Opened detail view for: " .. itemName)
	else
		warn("[ShopController] CanvasGroup not found for: " .. itemName .. " (searched for " .. cgName .. ")")
	end
end

---------------------------------------------------------------------------
-- Hover Animations
---------------------------------------------------------------------------
local function applyHoverAnimation(guiButton: GuiButton, targetFrame: GuiObject)
	local uiScale = targetFrame:FindFirstChildWhichIsA("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = targetFrame
	end
	
	local originalColor = targetFrame.BackgroundColor3
	local r, g, b = originalColor.R, originalColor.G, originalColor.B
	local hoverColor = Color3.new(math.max(0, r - 0.15), math.max(0, g - 0.15), math.max(0, b - 0.15))
	
	local tweenInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	
	guiButton.MouseEnter:Connect(function()
		TweenService:Create(uiScale, tweenInfo, {Scale = 1.05}):Play()
		TweenService:Create(targetFrame, tweenInfo, {BackgroundColor3 = hoverColor}):Play()
	end)
	
	guiButton.MouseLeave:Connect(function()
		TweenService:Create(uiScale, tweenInfo, {Scale = 1}):Play()
		TweenService:Create(targetFrame, tweenInfo, {BackgroundColor3 = originalColor}):Play()
	end)
end

---------------------------------------------------------------------------
-- Rainbow Outline Animation
---------------------------------------------------------------------------
local function applyRainbowOutline(frame: GuiObject)
	local uiStroke = frame:FindFirstChildWhichIsA("UIStroke")
	if not uiStroke then
		uiStroke = Instance.new("UIStroke")
		uiStroke.Thickness = 3
		uiStroke.Parent = frame
	end
	uiStroke.Color = Color3.new(1, 1, 1) -- Must be white for gradient to show colors
	
	local gradient = uiStroke:FindFirstChildWhichIsA("UIGradient")
	if not gradient then
		gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
			ColorSequenceKeypoint.new(0.16, Color3.fromRGB(255, 255, 0)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
			ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
			ColorSequenceKeypoint.new(0.66, Color3.fromRGB(0, 0, 255)),
			ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
			ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0))
		})
		gradient.Parent = uiStroke
	end
	
	RunService.RenderStepped:Connect(function(dt)
		if examTricksShop and examTricksShop.Visible then
			gradient.Rotation = (gradient.Rotation + dt * 100) % 360
		end
	end)
end

---------------------------------------------------------------------------
-- Wire up buy buttons inside a container (either an item frame or a CanvasGroup)
---------------------------------------------------------------------------
local function wireBuyButtons(container: Instance, itemName: string)
	local buyFolder = container:FindFirstChild("Buy")
	if not buyFolder then return end
	
	local moneyBtn = buyFolder:FindFirstChild("Money")
	local robuxBtn = buyFolder:FindFirstChild("Robux")
	
	if moneyBtn then
		-- Make it clickable if it's a Frame (wrap with invisible button)
		local clickTarget = moneyBtn
		if moneyBtn:IsA("Frame") then
			local btn = Instance.new("TextButton")
			btn.Name = "MoneyClickOverlay"
			btn.Size = UDim2.new(1, 0, 1, 0)
			btn.BackgroundTransparency = 1
			btn.Text = ""
			btn.ZIndex = 10
			btn.Parent = moneyBtn
			clickTarget = btn
		end
		
		applyHoverAnimation(clickTarget, moneyBtn)
		
		if clickTarget:IsA("GuiButton") then
			clickTarget.MouseButton1Click:Connect(function()
				if ownedItems[itemName] then
					showNotification("You already own this item!", Color3.fromRGB(255, 100, 100))
					return
				end
				print("[ShopController] Purchasing with coins: " .. itemName)
				local success, msg = purchaseItem:InvokeServer(itemName)
				
				if success then
					showNotification(msg, Color3.fromRGB(100, 255, 100))
				else
					showNotification(msg, Color3.fromRGB(255, 100, 100))
				end
			end)
		end
	end
	
	if robuxBtn then
		local clickTarget = robuxBtn
		if robuxBtn:IsA("Frame") then
			local btn = Instance.new("TextButton")
			btn.Name = "RobuxClickOverlay"
			btn.Size = UDim2.new(1, 0, 1, 0)
			btn.BackgroundTransparency = 1
			btn.Text = ""
			btn.ZIndex = 10
			btn.Parent = robuxBtn
			clickTarget = btn
		end
		
		applyHoverAnimation(clickTarget, robuxBtn)
		
		if clickTarget:IsA("GuiButton") then
			clickTarget.MouseButton1Click:Connect(function()
				if ownedItems[itemName] then
					showNotification("You already own this item!", Color3.fromRGB(255, 100, 100))
					return
				end
				print("[ShopController] Purchasing with Robux: " .. itemName)
				local success, msg = purchaseGamepass:InvokeServer(itemName)
				
				if success then
					-- Don't show success text here, Roblox's native prompt covers it
				else
					showNotification(msg, Color3.fromRGB(255, 100, 100))
				end
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Wire up item frames (inside ExamTricksShop > Items)
---------------------------------------------------------------------------
for _, itemName in ipairs(ITEM_NAMES) do
	local itemFrame = itemsFolder:FindFirstChild(itemName)
	if not itemFrame then
		warn("[ShopController] Item frame not found: " .. itemName)
		continue
	end
	
	-- Make the frame clickable by adding an invisible button overlay
	local clickBtn = Instance.new("TextButton")
	clickBtn.Name = "ItemClickOverlay"
	clickBtn.Size = UDim2.new(1, 0, 1, 0)
	clickBtn.BackgroundTransparency = 1
	clickBtn.Text = ""
	clickBtn.ZIndex = 10
	clickBtn.Parent = itemFrame
	
	clickBtn.MouseButton1Click:Connect(function()
		openCanvasGroup(itemName)
	end)
	
	-- Add hover anims to the item list frames too!
	applyHoverAnimation(clickBtn, itemFrame)
	
	if itemName == "Choice_Eraser" or itemName == "Genius_Potion" then
		applyRainbowOutline(itemFrame)
	end
	
	-- Wire buy buttons inside the item frame (the mini buy buttons in the list)
	wireBuyButtons(itemFrame, itemName)
	
	print("[ShopController] Wired item frame: " .. itemName)
end

-- Wire buy buttons inside each CanvasGroup (the detail view buy buttons)
for _, itemName in ipairs(ITEM_NAMES) do
	local cgName = CANVAS_ALIASES[itemName] or itemName
	local cg = shopUI:FindFirstChild(cgName)
	if cg and cg:IsA("CanvasGroup") then
		cg.Visible = false -- start hidden
		wireBuyButtons(cg, itemName)
	end
end

---------------------------------------------------------------------------
-- ShopPad Proximity Detection (Distance-based for reliability)
---------------------------------------------------------------------------
local shopPad: BasePart? = nil
task.spawn(function()
	while not shopPad do
		shopPad = Workspace:FindFirstChild("ShopPad", true) :: BasePart
		if shopPad then
			print("[ShopController] Found ShopPad at: " .. shopPad:GetFullName())
			break
		end
		task.wait(1)
	end
end)

local isOnPad = false
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include

RunService.Heartbeat:Connect(function()
	if not shopPad then return end
	local char = player.Character
	if not char then return end
	
	overlapParams.FilterDescendantsInstances = {char}
	
	-- Create a virtual hitbox matching the pad's footprint, but extending 5 studs upwards
	-- This captures players standing on it regardless of their HipHeight
	local padCFrame = shopPad.CFrame
	local hitboxSize = shopPad.Size + Vector3.new(0, 5, 0)
	local hitboxCFrame = padCFrame * CFrame.new(0, 2.5, 0)
	
	local touchingParts = Workspace:GetPartBoundsInBox(hitboxCFrame, hitboxSize, overlapParams)
	local playerOnPad = #touchingParts > 0
	
	if playerOnPad ~= isOnPad then
		isOnPad = playerOnPad
		examTricksShop.Visible = isOnPad
		if not isOnPad then
			closeAllCanvasGroups()
		else
			-- Automatically show Nerd_Help when first opening the shop
			openCanvasGroup("Nerd_Help")
		end
	end
end)

print("[ShopController] ShopPad distance scanner active ✓")

---------------------------------------------------------------------------
-- Real-time data updates from server
---------------------------------------------------------------------------
local function refreshOwnership()
	local data = getPlayerData:InvokeServer()
	if data then
		if type(data.OwnedItems) == "table" then
			for k, v in pairs(data.OwnedItems) do
				ownedItems[k] = v
			end
		end
		if type(data.GamepassItems) == "table" then
			for k, v in pairs(data.GamepassItems) do
				ownedItems[k] = v
			end
		end
		print("[ShopController] Ownership data refreshed")
	end
end

-- Initial load
task.spawn(refreshOwnership)

-- Listen for updates
dataUpdated.OnClientEvent:Connect(function(key: string, value: any)
	if key == "OwnedItems" or key == "GamepassItems" then
		if type(value) == "table" then
			for k, v in pairs(value) do
				ownedItems[k] = v
			end
		end
		
		-- Update all visible buy buttons
		for _, itemName in ipairs(ITEM_NAMES) do
			local itemFrame = itemsFolder:FindFirstChild(itemName)
			if itemFrame then
				updateBuyButtonState(itemFrame, itemName)
			end
			
			local cg = shopUI:FindFirstChild(itemName)
			if cg then
				updateBuyButtonState(cg, itemName)
			end
		end
	end
end)

---------------------------------------------------------------------------
-- Manual clipping for 'Glow' frames bleeding outside ScrollingFrame bounds
---------------------------------------------------------------------------
local function updateGlowVisibility()
	if not examTricksShop then return end
	-- The exact bounds of the visible scroll window
	local topBound = examTricksShop.AbsolutePosition.Y
	local bottomBound = topBound + examTricksShop.AbsoluteSize.Y
	
	for _, itemName in ipairs(ITEM_NAMES) do
		local itemFrame = itemsFolder:FindFirstChild(itemName)
		if itemFrame then
			local effectsFolder = itemFrame:FindFirstChild("Effects")
			if effectsFolder then
				-- Calculate the top/bottom Y coordinates of this specific item in the list
				local itemTop = itemFrame.AbsolutePosition.Y
				local itemBottom = itemTop + itemFrame.AbsoluteSize.Y
				
				-- If it's clipping the top or bottom bound, hide its glowing effects
				-- We add a slight margin of 10 studs to hide it slightly early before the glow bleeds
				local isClipping = (itemTop < topBound - 10) or (itemBottom > bottomBound + 10)
				
				for _, glowFrame in ipairs(effectsFolder:GetChildren()) do
					if glowFrame:IsA("GuiObject") then
						glowFrame.Visible = not isClipping
					end
				end
			end
		end
	end
end

if examTricksShop:IsA("ScrollingFrame") then
	examTricksShop:GetPropertyChangedSignal("CanvasPosition"):Connect(updateGlowVisibility)
end
examTricksShop:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateGlowVisibility)
examTricksShop:GetPropertyChangedSignal("AbsolutePosition"):Connect(updateGlowVisibility)

-- Run once on startup (must wait a frame for Absolute bounds to settle if UI is disabled initially)
task.spawn(function()
	RunService.Heartbeat:Wait()
	updateGlowVisibility()
end)

print("[ShopController] Initialized ✓")
