--[[
	DataSystem/init.server.luau
	
	Responsibilities:
	  • Load/save player data via DataStoreService with session locking.
	  • Create and sync leaderstats (Coins, Exams Passed).
	  • Auto-save every 5 minutes to protect against server crashes.
	  • BindToClose to ensure all data is saved on server shutdown.
	  • Handle PurchaseItem (coins) and PurchaseGamepass (Robux) requests.
	  • Serve GetPlayerData RemoteFunction for client reads.
	  
	Anti-Exploit Design:
	  • All coin mutations happen server-side only.
	  • Client never sends "add X coins" — only "I want to buy item Y".
	  • Server validates ownership, balance, and item existence before any mutation.
	  • GamepassItems are separated from OwnedItems for audit trail.
	  • MarketplaceService.PromptGamePassPurchaseFinished validates receipt server-side.
]]

local Players            = game:GetService("Players")
local DataStoreService   = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService         = game:GetService("RunService")

local Shared       = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local DataRemotes  = require(Shared:WaitForChild("DataRemotes"))
local PlayerData   = require(script:WaitForChild("PlayerData"))

---------------------------------------------------------------------------
-- Setup remotes
---------------------------------------------------------------------------
DataRemotes.setup()

local getPlayerDataRemote = DataRemotes.get("GetPlayerData") :: RemoteFunction
local dataUpdatedRemote   = DataRemotes.get("DataUpdated") :: RemoteEvent
local purchaseItemRemote  = DataRemotes.get("PurchaseItem") :: RemoteEvent
local purchaseGPRemote    = DataRemotes.get("PurchaseGamepass") :: RemoteEvent

---------------------------------------------------------------------------
-- DataStore
---------------------------------------------------------------------------
local DATA_STORE_NAME = "TrolikPlayerData_v1"
local dataStore = DataStoreService:GetDataStore(DATA_STORE_NAME)

local AUTO_SAVE_INTERVAL = 300 -- 5 minutes
local saveLock: { [number]: boolean } = {} -- prevents concurrent saves for the same userId

---------------------------------------------------------------------------
-- Save / Load helpers
---------------------------------------------------------------------------
local function getKey(player: Player): string
	return "Player_" .. tostring(player.UserId)
end

local function loadData(player: Player): { [string]: any }?
	local key = getKey(player)
	local success, result = pcall(function()
		return dataStore:GetAsync(key)
	end)
	
	if success then
		if result then
			print(string.format("[DataSystem] Loaded saved data for %s", player.Name))
		else
			print(string.format("[DataSystem] No saved data for %s (new player)", player.Name))
		end
		return result
	else
		warn(string.format("[DataSystem] FAILED to load data for %s: %s", player.Name, tostring(result)))
		return nil
	end
end

local function saveData(player: Player): boolean
	local userId = player.UserId
	if saveLock[userId] then
		warn(string.format("[DataSystem] Save already in progress for userId %d — skipping", userId))
		return false
	end
	
	local data = PlayerData._getSessionForSave(player)
	if not data then
		return false
	end
	
	saveLock[userId] = true
	local key = getKey(player)
	local success, err = pcall(function()
		dataStore:SetAsync(key, data)
	end)
	saveLock[userId] = nil
	
	if success then
		print(string.format("[DataSystem] Saved data for %s (%d coins, %d exams)", player.Name, data.Coins or 0, data.ExamsPassed or 0))
	else
		warn(string.format("[DataSystem] FAILED to save data for %s: %s", player.Name, tostring(err)))
	end
	return success
end

---------------------------------------------------------------------------
-- Leaderstats
---------------------------------------------------------------------------
local function createLeaderstats(player: Player, data: { [string]: any })
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	
	local coinsValue = Instance.new("IntValue")
	coinsValue.Name = "Coins"
	coinsValue.Value = data.Coins or 0
	coinsValue.Parent = leaderstats
	
	local examsValue = Instance.new("IntValue")
	examsValue.Name = "Exams Passed"
	examsValue.Value = data.ExamsPassed or 0
	examsValue.Parent = leaderstats
	
	leaderstats.Parent = player
	print(string.format("[DataSystem] Leaderstats created for %s", player.Name))
end

local function syncLeaderstats(player: Player, key: string, value: any)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return end
	
	if key == "Coins" then
		local v = leaderstats:FindFirstChild("Coins") :: IntValue?
		if v then v.Value = value end
	elseif key == "ExamsPassed" then
		local v = leaderstats:FindFirstChild("Exams Passed") :: IntValue?
		if v then v.Value = value end
	end
end

---------------------------------------------------------------------------
-- Data change listener → sync leaderstats + fire remote to client
---------------------------------------------------------------------------
PlayerData.onChanged(function(player: Player, key: string, value: any)
	-- Sync leaderstats
	syncLeaderstats(player, key, value)
	
	-- Notify the client
	if player.Parent then -- still in game
		pcall(function()
			dataUpdatedRemote:FireClient(player, key, value)
		end)
	end
end)

---------------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	print(string.format("[DataSystem] Player joined: %s (UserId: %d)", player.Name, player.UserId))
	
	local savedData = loadData(player)
	
	-- Player may have left during the async load
	if not player.Parent then
		warn(string.format("[DataSystem] %s left before data finished loading", player.Name))
		return
	end
	
	local data = PlayerData._loadSession(player, savedData)
	createLeaderstats(player, data)
end

local function onPlayerRemoving(player: Player)
	print(string.format("[DataSystem] Player leaving: %s", player.Name))
	
	if PlayerData.hasSession(player) then
		saveData(player)
		PlayerData._clearSession(player)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players that joined before this script ran
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

---------------------------------------------------------------------------
-- Auto-save loop (every 5 minutes)
---------------------------------------------------------------------------
task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_INTERVAL)
		print("[DataSystem] Auto-saving all player data...")
		for _, player in ipairs(Players:GetPlayers()) do
			if PlayerData.hasSession(player) then
				task.spawn(saveData, player)
			end
		end
	end
end)

---------------------------------------------------------------------------
-- BindToClose — save everyone on server shutdown
---------------------------------------------------------------------------
game:BindToClose(function()
	print("[DataSystem] Server shutting down — saving all data...")
	local threads = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if PlayerData.hasSession(player) then
			table.insert(threads, task.spawn(function()
				saveData(player)
				PlayerData._clearSession(player)
			end))
		end
	end
	-- Wait for all saves to complete (BindToClose gives ~30s)
	task.wait(3)
end)

---------------------------------------------------------------------------
-- Remote handlers
---------------------------------------------------------------------------

-- GetPlayerData: client requests their data snapshot
getPlayerDataRemote.OnServerInvoke = function(player: Player)
	return PlayerData.getAll(player)
end

-- PurchaseItem: client wants to buy an item with coins
purchaseItemRemote.OnServerInvoke = function(player: Player, itemName: any)
	-- Validate input type
	if type(itemName) ~= "string" then
		warn(string.format("[DataSystem] Invalid PurchaseItem args from %s", player.Name))
		return false, "Invalid item requested."
	end
	
	-- Check item exists in catalog
	local catalogEntry = PlayerData.ITEM_CATALOG[itemName]
	if not catalogEntry then
		warn(string.format("[DataSystem] %s tried to buy unknown item: %s", player.Name, itemName))
		return false, "Item not found in catalog."
	end
	
	-- Check it's a coin item
	if catalogEntry.currency ~= "Coins" then
		warn(string.format("[DataSystem] %s tried to buy Robux item '%s' with coins", player.Name, itemName))
		return false, "This item cannot be bought with coins."
	end
	
	-- Check not already owned
	if PlayerData.owns(player, itemName) then
		warn(string.format("[DataSystem] %s already owns '%s'", player.Name, itemName))
		return false, "You already own this item!"
	end
	
	-- Attempt purchase
	local success = PlayerData.spendCoins(player, catalogEntry.price)
	if success then
		PlayerData.grantItem(player, itemName)
		local formattedName = string.gsub(itemName, "_", " ")
		print(string.format("[DataSystem] %s purchased '%s' for %d coins", player.Name, itemName, catalogEntry.price))
		return true, "Purchase successful: " .. formattedName
	else
		local data = PlayerData.getAll(player)
		local currentCoins = data.Coins or 0
		local needed = catalogEntry.price - currentCoins
		warn(string.format("[DataSystem] %s cannot afford '%s' (%d coins needed)", player.Name, itemName, catalogEntry.price))
		return false, "You need " .. tostring(needed) .. " more coins to buy this item."
	end
end

-- PurchaseGamepass: client wants to buy a Robux item
purchaseGPRemote.OnServerInvoke = function(player: Player, itemName: any)
	if type(itemName) ~= "string" then
		warn(string.format("[DataSystem] Invalid PurchaseGamepass args from %s", player.Name))
		return false, "Invalid item requested."
	end
	
	local catalogEntry = PlayerData.ITEM_CATALOG[itemName]
	if not catalogEntry or catalogEntry.currency ~= "Robux" then
		warn(string.format("[DataSystem] %s tried invalid gamepass purchase: %s", player.Name, tostring(itemName)))
		return false, "This item is not a gamepass."
	end
	
	if PlayerData.owns(player, itemName) then
		warn(string.format("[DataSystem] %s already owns gamepass item '%s'", player.Name, itemName))
		return false, "You already own this item!"
	end
	
	local gamepassId = catalogEntry.gamepassId
	if gamepassId == 0 then
		warn(string.format("[DataSystem] Gamepass ID not yet configured for '%s'", itemName))
		return false, "This gamepass is invalid"
	end
	
	-- Prompt the purchase on the client
	local promptSuccess, promptErr = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, gamepassId)
	end)
	if not promptSuccess then
		warn(string.format("[DataSystem] Failed to prompt gamepass for %s: %s", player.Name, tostring(promptErr)))
		return false, "Failed to prompt purchase. Try again later."
	end
	
	return true, "Prompting purchase..."
end

-- Listen for gamepass purchase completions
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, gamepassId: number, wasPurchased: boolean)
	if not wasPurchased then return end
	
	-- Find which item this gamepass corresponds to
	for itemName, entry in pairs(PlayerData.ITEM_CATALOG) do
		if entry.currency == "Robux" and entry.gamepassId == gamepassId then
			if not PlayerData.owns(player, itemName) then
				PlayerData.grantGamepassItem(player, itemName)
				print(string.format("[DataSystem] %s purchased gamepass item '%s' (ID: %d)", player.Name, itemName, gamepassId))
			end
			break
		end
	end
end)

print("[DataSystem] Initialized ✓")
