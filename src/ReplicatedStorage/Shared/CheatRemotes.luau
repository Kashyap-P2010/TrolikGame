--[[
	CheatRemotes — Shared module for Cheat system RemoteEvents / RemoteFunctions.

	Remotes:
	  Functions:
	    ActivateCheat     — Client → Server  (cheatName: string)
	                        Server validates ownership, cooldown, rolls detection,
	                        returns answer data.
	    GetCheatCooldowns — Client → Server
	                        Returns { [cheatName]: remainingSeconds }
	  Events:
	    CheatWarning      — Server → Client  (warningNumber: 1|2|3)
	    TeacherCatch      — Server → Client  (game over for that player)
	    SyncQuestionIndex — Client → Server  (questionIndex: number)
	                        Keeps server in sync with client's current question.
	    PhoneClick        — Client → Server  (cheatSessionId: string)
	                        Each click during Phone cheat, server tracks progress.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local CheatRemotes = {}

local REMOTE_FUNCTIONS = {
	"ActivateCheat",
	"GetCheatCooldowns",
}

local REMOTE_EVENTS = {
	"CheatWarning",
	"TeacherCatch",
	"SyncQuestionIndex",
	"PhoneClick",
}

local remotesFolder: Folder? = nil

--- Create all RemoteEvents / RemoteFunctions. Call once from the server.
function CheatRemotes.setup()
	assert(RunService:IsServer(), "CheatRemotes.setup() must be called from the server")

	remotesFolder      = Instance.new("Folder")
	remotesFolder.Name = "CheatRemotes"

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
function CheatRemotes.get(name: string): RemoteEvent | RemoteFunction
	if RunService:IsServer() then
		assert(remotesFolder, "CheatRemotes.setup() has not been called yet!")
		local r = remotesFolder:FindFirstChild(name)
		assert(r, "CheatRemotes: remote '" .. name .. "' not found!")
		return r :: any
	else
		local folder = ReplicatedStorage:WaitForChild("CheatRemotes", 15)
		assert(folder, "[CheatRemotes] CheatRemotes folder not found in ReplicatedStorage!")
		local r = folder:WaitForChild(name, 10)
		assert(r, "[CheatRemotes] Remote '" .. name .. "' not found!")
		return r :: any
	end
end

return CheatRemotes
