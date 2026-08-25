--[[
	PadManager — Pure-data state machine for lobby pads.
	
	Each pad tracks:
	  state     — "Waiting" | "Creating" | "Active" | "Teleporting"
	  owner     — Player who initiated the lobby (nil when Waiting)
	  difficulty — chosen difficulty string (nil until Active)
	  players   — array of all players currently in this lobby
	  timerThread — reference to the countdown coroutine (for cancellation)
	
	Also maintains a reverse map: player → padIndex, so we can quickly
	look up which pad (if any) a player is associated with.
	
	This module has NO side-effects (no collision, no UI, no remotes).
	The orchestrator (init.server.luau) is responsible for calling the
	right side-effect modules after each state transition.
]]

local PadManager = {}

local padStates: { [number]: {
	state: string,
	owner: Player?,
	difficulty: string?,
	players: { Player },
	timerThread: thread?,
} } = {}

-- Reverse map: player → padIndex
local playerToPad: { [Player]: number } = {}

---------------------------------------------------------------------------
-- Initialization
---------------------------------------------------------------------------

--- Create default state entries for `padCount` pads.
function PadManager.init(padCount: number)
	for i = 1, padCount do
		padStates[i] = {
			state = "Waiting",
			owner = nil,
			difficulty = nil,
			players = {},
			timerThread = nil,
		}
	end
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

function PadManager.getState(padIndex: number)
	return padStates[padIndex]
end

function PadManager.getPlayerPad(player: Player): number?
	return playerToPad[player]
end

---------------------------------------------------------------------------
-- State Transitions
---------------------------------------------------------------------------

--- A player steps onto an empty pad → Creating.
--- Returns false if the pad isn't Waiting or the player is already on a pad.
function PadManager.occupy(padIndex: number, player: Player): boolean
	local pad = padStates[padIndex]
	if not pad or pad.state ~= "Waiting" then
		return false
	end
	if playerToPad[player] then
		return false
	end

	pad.state = "Creating"
	pad.owner = player
	pad.players = { player }
	playerToPad[player] = padIndex
	return true
end

--- Owner clicked Create → Active.
--- Returns false if pad isn't in Creating state.
function PadManager.createLobby(padIndex: number, difficulty: string): boolean
	local pad = padStates[padIndex]
	if not pad or pad.state ~= "Creating" then
		return false
	end

	pad.state = "Active"
	pad.difficulty = difficulty
	return true
end

--- Another player joins an Active lobby.
--- Returns false if pad isn't Active, is full, or player is already on a pad.
function PadManager.addPlayer(padIndex: number, player: Player): boolean
	local pad = padStates[padIndex]
	if not pad or pad.state ~= "Active" then
		return false
	end
	if #pad.players >= 12 then
		return false
	end
	if playerToPad[player] then
		return false
	end

	table.insert(pad.players, player)
	playerToPad[player] = padIndex
	return true
end

--- Remove a single player from a pad (disconnect, death, etc.).
--- Does NOT reset the pad — caller decides whether to reset.
function PadManager.removePlayer(padIndex: number, player: Player)
	local pad = padStates[padIndex]
	if not pad then return end

	local idx = table.find(pad.players, player)
	if idx then
		table.remove(pad.players, idx)
	end
	playerToPad[player] = nil
end

--- Mark pad as Teleporting (countdown reached 0).
function PadManager.setTeleporting(padIndex: number)
	local pad = padStates[padIndex]
	if pad then
		pad.state = "Teleporting"
	end
end

--- Store the countdown thread so we can best-effort cancel it on reset.
function PadManager.setTimerThread(padIndex: number, thread: thread)
	local pad = padStates[padIndex]
	if pad then
		pad.timerThread = thread
	end
end

--- Full reset back to Waiting.  Clears all player associations.
function PadManager.reset(padIndex: number)
	local pad = padStates[padIndex]
	if not pad then return end

	-- Clear reverse map for every player on this pad
	for _, player in pad.players do
		playerToPad[player] = nil
	end

	-- Best-effort cancel timer thread
	if pad.timerThread then
		pcall(task.cancel, pad.timerThread)
		pad.timerThread = nil
	end

	pad.state = "Waiting"
	pad.owner = nil
	pad.difficulty = nil
	pad.players = {}
end

return PadManager
