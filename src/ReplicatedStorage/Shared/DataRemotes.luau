--[[
	DataRemotes — Shared module for Data system RemoteEvents / RemoteFunctions.

	Remotes:
	  Functions:
	    GetPlayerData     — Client → Server → { Coins, ExamsPassed, OwnedItems, ... }
	  Events:
	    DataUpdated       — Server → Client  (key: string, value: any)
	                        Fires whenever the player's data changes so UI updates in real-time.
	    PurchaseItem      — Client → Server  (itemName: string)
	                        Request to buy an item with coins.
	    PurchaseGamepass  — Client → Server  (itemName: string)
	                        Request to initiate a Robux gamepass purchase.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local DataRemotes = {}

local REMOTE_FUNCTIONS = {
	"GetPlayerData",
	"PurchaseItem",
	"PurchaseGamepass",
	"ClaimDailyReward",
}

local REMOTE_EVENTS = {
	"DataUpdated",
}

local remotesFolder: Folder? = nil

--- Create all RemoteEvents / RemoteFunctions. Call once from the server.
function DataRemotes.setup()
	assert(RunService:IsServer(), "DataRemotes.setup() must be called from the server")

	remotesFolder      = Instance.new("Folder")
	remotesFolder.Name = "DataRemotes"

	for _, name in REMOTE_FUNCTIONS do
		local rf      = Instance.new("RemoteFunction")
		rf.Name       = name
		rf.Parent     = remotesFolder
	end

	for _, name in REMOTE_EVENTS do
		local re      = Instance.new("RemoteEvent")
		re.Name       = name
		re.Parent     = remotesFolder
	end

	remotesFolder.Parent = ReplicatedStorage
end

--- Get a RemoteEvent or RemoteFunction by name. Waits until available (client).
function DataRemotes.get(name: string): RemoteEvent | RemoteFunction
	if RunService:IsServer() then
		assert(remotesFolder, "DataRemotes.setup() has not been called yet!")
		local r = remotesFolder:FindFirstChild(name)
		assert(r, "DataRemotes: remote '" .. name .. "' not found!")
		return r :: any
	else
		-- Wait generously for the server to create the folder
		local folder = ReplicatedStorage:WaitForChild("DataRemotes", 30)
		if not folder then
			-- Retry once more — server scripts can be slow to initialize
			warn("[DataRemotes] DataRemotes folder not found yet, retrying...")
			folder = ReplicatedStorage:WaitForChild("DataRemotes", 30)
		end
		assert(folder, "[DataRemotes] DataRemotes folder not found in ReplicatedStorage after 60s!")
		local r = folder:WaitForChild(name, 15)
		assert(r, "[DataRemotes] Remote '" .. name .. "' not found!")
		return r :: any
	end
end

return DataRemotes
