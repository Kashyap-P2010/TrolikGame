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
}

local REMOTE_EVENTS = {
	"DataUpdated",
	"PurchaseItem",
	"PurchaseGamepass",
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
		local folder = ReplicatedStorage:WaitForChild("DataRemotes", 15)
		assert(folder, "[DataRemotes] DataRemotes folder not found in ReplicatedStorage!")
		local r = folder:WaitForChild(name, 10)
		assert(r, "[DataRemotes] Remote '" .. name .. "' not found!")
		return r :: any
	end
end

return DataRemotes
