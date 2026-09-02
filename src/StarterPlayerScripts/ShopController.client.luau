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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local DataRemotes       = require(Shared:WaitForChild("DataRemotes"))

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local getPlayerData   = DataRemotes.get("GetPlayerData") :: RemoteFunction
local dataUpdated     = DataRemotes.get("DataUpdated") :: RemoteEvent
local purchaseItem    = DataRemotes.get("PurchaseItem") :: RemoteEvent
local purchaseGamepass = DataRemotes.get("PurchaseGamepass") :: RemoteEvent

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
	
	local cg = shopUI:FindFirstChild(itemName)
	if cg and cg:IsA("CanvasGroup") then
		cg.Visible = true
		activeCanvasGroup = cg
		updateBuyButtonState(cg, itemName)
		print("[ShopController] Opened detail view for: " .. itemName)
	else
		warn("[ShopController] CanvasGroup not found for: " .. itemName)
	end
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
		
		if clickTarget:IsA("GuiButton") then
			clickTarget.MouseButton1Click:Connect(function()
				if ownedItems[itemName] then
					warn("[ShopController] Already own " .. itemName)
					return
				end
				print("[ShopController] Purchasing with coins: " .. itemName)
				purchaseItem:FireServer(itemName)
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
		
		if clickTarget:IsA("GuiButton") then
			clickTarget.MouseButton1Click:Connect(function()
				if ownedItems[itemName] then
					warn("[ShopController] Already own " .. itemName)
					return
				end
				print("[ShopController] Purchasing with Robux: " .. itemName)
				purchaseGamepass:FireServer(itemName)
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
	
	-- Wire buy buttons inside the item frame (the mini buy buttons in the list)
	wireBuyButtons(itemFrame, itemName)
	
	print("[ShopController] Wired item frame: " .. itemName)
end

-- Wire buy buttons inside each CanvasGroup (the detail view buy buttons)
for _, itemName in ipairs(ITEM_NAMES) do
	local cg = shopUI:FindFirstChild(itemName)
	if cg and cg:IsA("CanvasGroup") then
		cg.Visible = false -- start hidden
		wireBuyButtons(cg, itemName)
	end
end

---------------------------------------------------------------------------
-- ShopPad proximity detection
---------------------------------------------------------------------------
local shopPad = Workspace:WaitForChild("ShopPad", 30)

if shopPad then
	local touchingParts: { [BasePart]: boolean } = {}
	local isOnPad = false
	
	local function checkPadStatus()
		local playerOnPad = false
		local character = player.Character
		if character then
			for part, _ in pairs(touchingParts) do
				if part:IsDescendantOf(character) then
					playerOnPad = true
					break
				end
			end
		end
		
		if playerOnPad ~= isOnPad then
			isOnPad = playerOnPad
			examTricksShop.Visible = isOnPad
			if not isOnPad then
				closeAllCanvasGroups()
			end
			print("[ShopController] Shop visibility: " .. tostring(isOnPad))
		end
	end
	
	shopPad.Touched:Connect(function(hit: BasePart)
		touchingParts[hit] = true
		checkPadStatus()
	end)
	
	shopPad.TouchEnded:Connect(function(hit: BasePart)
		touchingParts[hit] = nil
		checkPadStatus()
	end)
	
	print("[ShopController] ShopPad connected ✓")
else
	warn("[ShopController] ShopPad not found in Workspace!")
end

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

print("[ShopController] Initialized ✓")
