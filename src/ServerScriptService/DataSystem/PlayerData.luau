--[[
	PlayerData.luau — Server-side module for safe, atomic player data operations.
	
	All currency mutations happen here (never on the client).
	Every function that modifies data is atomic — no yielding mid-mutation.
	
	Data Schema:
	{
		Coins         = 0,
		ExamsPassed   = 0,
		TotalExamsTaken = 0,
		BestScore     = 0,        -- highest percentage ever achieved
		OwnedItems    = {},       -- { ["Nerd_Help"] = true, ... }
		GamepassItems = {},       -- { ["Choice_Eraser"] = true, ["Smart_Glasses"] = true }
	}
]]

local Players = game:GetService("Players")

local PlayerData = {}

---------------------------------------------------------------------------
-- In-memory session cache: [Player] = data table
---------------------------------------------------------------------------
local sessionData: { [Player]: { [string]: any } } = {}

-- Callbacks that fire after any data mutation (used by init to sync leaderstats/remotes)
local changeCallbacks: { (player: Player, key: string, value: any) -> () } = {}

---------------------------------------------------------------------------
-- Default template for new players
---------------------------------------------------------------------------
local DEFAULT_DATA = {
	Coins           = 0,
	ExamsPassed     = 0,
	TotalExamsTaken = 0,
	BestScore       = 0,
	OwnedItems      = {},
	GamepassItems   = {},
	LastDailyRewardClaim = 0,
	DailyRewardStreak = 0,
}

---------------------------------------------------------------------------
-- Item catalog (prices in coins; 0 means Robux-only)
---------------------------------------------------------------------------
PlayerData.ITEM_CATALOG = {
	Nerd_Help        = { price = 1000, currency = "Coins" },
	Radio_Answer     = { price = 1000, currency = "Coins" },
	Window_Friend    = { price = 1000, currency = "Coins" },
	["Teacher's_Desk"]  = { price = 1000, currency = "Coins" },
	Neighbor_Cheats  = { price = 1000, currency = "Coins" },
	Genius_Potion    = { price = 1000, currency = "Coins" },
	Choice_Eraser    = { price = 0,    currency = "Robux", gamepassId = 0 }, -- placeholder
	Smart_Glasses    = { price = 0,    currency = "Robux", gamepassId = 0 }, -- placeholder
}

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------
local function deepCopy(t)
	if type(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = deepCopy(v)
	end
	return copy
end

local function notifyChange(player: Player, key: string, value: any)
	for _, cb in ipairs(changeCallbacks) do
		task.spawn(cb, player, key, value)
	end
end

---------------------------------------------------------------------------
-- Session management (called by init.server.luau)
---------------------------------------------------------------------------

--- Register a callback that fires on every data change.
function PlayerData.onChanged(callback: (player: Player, key: string, value: any) -> ())
	table.insert(changeCallbacks, callback)
end

--- Load a player's data into the session cache. Returns the data table.
function PlayerData._loadSession(player: Player, savedData: { [string]: any }?): { [string]: any }
	local data = deepCopy(DEFAULT_DATA)
	
	-- Merge saved data on top of defaults (handles schema migrations gracefully)
	if savedData and type(savedData) == "table" then
		for key, default in pairs(DEFAULT_DATA) do
			if savedData[key] ~= nil then
				if type(default) == "table" and type(savedData[key]) == "table" then
					data[key] = deepCopy(savedData[key])
				else
					data[key] = savedData[key]
				end
			end
		end
	end
	
	sessionData[player] = data
	print(string.format("[PlayerData] Session loaded for %s: %d Coins, %d Exams", player.Name, data.Coins, data.ExamsPassed))
	return data
end

--- Get the raw data table for saving. Returns nil if no session.
function PlayerData._getSessionForSave(player: Player): { [string]: any }?
	return sessionData[player]
end

--- Remove session from cache.
function PlayerData._clearSession(player: Player)
	sessionData[player] = nil
end

--- Check if a session is active.
function PlayerData.hasSession(player: Player): boolean
	return sessionData[player] ~= nil
end

---------------------------------------------------------------------------
-- Public read API
---------------------------------------------------------------------------

--- Get a single key from the player's data.
function PlayerData.get(player: Player, key: string): any
	local data = sessionData[player]
	if not data then
		warn("[PlayerData] No session for " .. player.Name .. " when reading '" .. key .. "'")
		return nil
	end
	return data[key]
end

--- Get a full snapshot of the player's data (deep copy for safety).
function PlayerData.getAll(player: Player): { [string]: any }?
	local data = sessionData[player]
	if not data then return nil end
	return deepCopy(data)
end

---------------------------------------------------------------------------
-- Public write API (all atomic — no yields inside mutations)
---------------------------------------------------------------------------

--- Set a single key.
function PlayerData.set(player: Player, key: string, value: any)
	local data = sessionData[player]
	if not data then
		warn("[PlayerData] No session for " .. player.Name .. " when writing '" .. key .. "'")
		return
	end
	data[key] = value
	notifyChange(player, key, value)
end

--- Add coins to the player. Returns the new balance.
function PlayerData.addCoins(player: Player, amount: number): number
	local data = sessionData[player]
	if not data then
		warn("[PlayerData] No session for " .. player.Name .. " when adding coins")
		return 0
	end
	
	amount = math.max(0, math.round(amount)) -- never add negative or fractional
	data.Coins = data.Coins + amount
	notifyChange(player, "Coins", data.Coins)
	print(string.format("[PlayerData] %s gained %d coins (total: %d)", player.Name, amount, data.Coins))
	return data.Coins
end

--- Spend coins. Returns true if successful, false if insufficient balance.
function PlayerData.spendCoins(player: Player, amount: number): boolean
	local data = sessionData[player]
	if not data then
		warn("[PlayerData] No session for " .. player.Name .. " when spending coins")
		return false
	end
	
	amount = math.max(0, math.round(amount))
	if data.Coins < amount then
		warn(string.format("[PlayerData] %s tried to spend %d coins but only has %d", player.Name, amount, data.Coins))
		return false
	end
	
	data.Coins = data.Coins - amount
	notifyChange(player, "Coins", data.Coins)
	print(string.format("[PlayerData] %s spent %d coins (remaining: %d)", player.Name, amount, data.Coins))
	return true
end

--- Check if a player owns an item (either coin-bought or gamepass).
function PlayerData.owns(player: Player, itemName: string): boolean
	local data = sessionData[player]
	if not data then return false end
	
	return (data.OwnedItems[itemName] == true) or (data.GamepassItems[itemName] == true)
end

--- Grant a coin-purchased item.
function PlayerData.grantItem(player: Player, itemName: string)
	local data = sessionData[player]
	if not data then
		warn("[PlayerData] No session for " .. player.Name .. " when granting item")
		return
	end
	
	data.OwnedItems[itemName] = true
	notifyChange(player, "OwnedItems", deepCopy(data.OwnedItems))
	print(string.format("[PlayerData] %s now owns item: %s", player.Name, itemName))
end

--- Grant a gamepass-purchased item (separate table for anti-exploit auditing).
function PlayerData.grantGamepassItem(player: Player, itemName: string)
	local data = sessionData[player]
	if not data then
		warn("[PlayerData] No session for " .. player.Name .. " when granting gamepass item")
		return
	end
	
	data.GamepassItems[itemName] = true
	notifyChange(player, "GamepassItems", deepCopy(data.GamepassItems))
	print(string.format("[PlayerData] %s now owns gamepass item: %s", player.Name, itemName))
end

--- Increment exams passed counter. Returns new count.
function PlayerData.incrementExamsPassed(player: Player): number
	local data = sessionData[player]
	if not data then
		warn("[PlayerData] No session for " .. player.Name)
		return 0
	end
	
	data.ExamsPassed = data.ExamsPassed + 1
	notifyChange(player, "ExamsPassed", data.ExamsPassed)
	print(string.format("[PlayerData] %s exams passed: %d", player.Name, data.ExamsPassed))
	return data.ExamsPassed
end

--- Increment total exams taken counter.
function PlayerData.incrementExamsTaken(player: Player): number
	local data = sessionData[player]
	if not data then return 0 end
	
	data.TotalExamsTaken = data.TotalExamsTaken + 1
	notifyChange(player, "TotalExamsTaken", data.TotalExamsTaken)
	return data.TotalExamsTaken
end

--- Update best score if the new score is higher. Returns true if it was a new best.
function PlayerData.updateBestScore(player: Player, percentage: number): boolean
	local data = sessionData[player]
	if not data then return false end
	
	percentage = math.clamp(math.round(percentage), 0, 100)
	if percentage > data.BestScore then
		data.BestScore = percentage
		notifyChange(player, "BestScore", data.BestScore)
		print(string.format("[PlayerData] %s new best score: %d%%", player.Name, percentage))
		return true
	end
	return false
end

return PlayerData
