--[[
	ExamRemotes — Shared module for Exam system RemoteEvents / RemoteFunctions.

	Remotes:
	  Functions:
	    GetExamQuestions  — Client → Server → { q, a, b, c, correct }[]
	                        Server returns 20-question set for the player's difficulty.
	  Events:
	    SaveExamResult    — Client → Server  (score: number, total: number)
	                        Server saves percentage to player attribute.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local ExamRemotes = {}

local REMOTE_FUNCTIONS = {
	"GetExamQuestions",
}

local REMOTE_EVENTS = {
	"SaveExamResult",
}

local remotesFolder: Folder? = nil

--- Create all RemoteEvents / RemoteFunctions. Call once from the server.
function ExamRemotes.setup()
	assert(RunService:IsServer(), "ExamRemotes.setup() must be called from the server")

	remotesFolder      = Instance.new("Folder")
	remotesFolder.Name = "ExamRemotes"

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
function ExamRemotes.get(name: string): RemoteEvent | RemoteFunction
	if RunService:IsServer() then
		assert(remotesFolder, "ExamRemotes.setup() has not been called yet!")
		local r = remotesFolder:FindFirstChild(name)
		assert(r, "ExamRemotes: remote '" .. name .. "' not found!")
		return r :: any
	else
		local folder = ReplicatedStorage:WaitForChild("ExamRemotes", 15)
		assert(folder, "[ExamRemotes] ExamRemotes folder not found in ReplicatedStorage!")
		local r = folder:WaitForChild(name, 10)
		assert(r, "[ExamRemotes] Remote '" .. name .. "' not found!")
		return r :: any
	end
end

return ExamRemotes
