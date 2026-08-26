--[[
	LobbyRemotes — Shared module for creating / finding lobby RemoteEvents.
	
	Server calls LobbyRemotes.setup() once at startup to create all remotes.
	Client calls LobbyRemotes.get(name) to obtain a reference (waits until available).
	
	Remotes created:
	  Events:
	    RequestCreateLobby  — Client → Server  (difficulty: string)
	    RequestCancelLobby  — Client → Server  ()  ← cancel during Creating state (X button)
	    RequestLeaveLobby   — Client → Server  ()  ← leave during Active state (Exit button)
	    ShowLobbyUI         — Server → Client  (show: boolean, padIndex: number?)
	    ShowExitButton      — Server → Client  (show: boolean)  ← shown when lobby is Active
	    UpdatePadState      — Server → All     (padIndex, state, data: {})
	    UpdateTimer         — Server → Client  (padIndex, remaining: number)
	    UpdateCreationTimer — Server → Client  (padIndex, remaining: number)
	  Functions:
	    GetDifficultyUnlocks — Client → Server → {[string]: boolean}
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LobbyRemotes = {}

local REMOTE_EVENTS = {
	"RequestEnterPad",     -- Client → Server: instant client-side pad touch trigger
	"RequestCreateLobby",
	"RequestCancelLobby",   -- cancel during Creating state (X close button)
	"RequestLeaveLobby",    -- leave during Active state (Exit Lobby button)
	"ShowLobbyUI",
	"ShowExitButton",       -- Server → Client: show/hide the in-lobby Exit button
	"UpdatePadState",
	"UpdateTimer",
	"UpdateCreationTimer",  -- Server → Client: AFK countdown while Creating
}

local REMOTE_FUNCTIONS = {
	"GetDifficultyUnlocks",
}

local remotesFolder: Folder? = nil

--- Create all RemoteEvents/Functions. Must be called once from server.
function LobbyRemotes.setup()
	assert(RunService:IsServer(), "LobbyRemotes.setup() must be called from the server")

	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "LobbyRemotes"

	for _, name in REMOTE_EVENTS do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = remotesFolder
	end

	for _, name in REMOTE_FUNCTIONS do
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = remotesFolder
	end

	remotesFolder.Parent = ReplicatedStorage
end

--- Get a remote by name. Blocks on client until available (up to 10 s).
function LobbyRemotes.get(name: string): RemoteEvent | RemoteFunction
	if not remotesFolder then
		remotesFolder = ReplicatedStorage:WaitForChild("LobbyRemotes", 10)
		assert(remotesFolder, "[LobbyRemotes] Folder not found — did the server call setup()?")
	end

	local remote = remotesFolder:WaitForChild(name, 10)
	assert(remote, "[LobbyRemotes] Remote '" .. name .. "' not found")
	return remote
end

return LobbyRemotes
