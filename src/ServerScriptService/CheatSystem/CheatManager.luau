--[[
	CheatManager.luau — Server-side ModuleScript
	
	Authority for ALL cheat logic:
	  • Validates item ownership before allowing cheat use.
	  • Enforces per-player, per-cheat cooldowns.
	  • Provides correct answers from the server-side exam state.
	  • Rolls detection chance and sets IsCheating attribute for Teacher FOV.
	  • Tracks "leave desk" cheats and enforces return timers.
	  • Manages the 3-strike warning/catching system.
	
	ANTI-EXPLOIT: The server NEVER sends the full answer key.
	It only reveals answers for the specific questions the cheat unlocks.
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local CheatRemotes = require(Shared:WaitForChild("CheatRemotes"))
local PlayerData   = require(ServerScriptService:WaitForChild("DataSystem"):WaitForChild("PlayerData"))

---------------------------------------------------------------------------
-- Cheat Definitions
---------------------------------------------------------------------------
export type CheatDef = {
	cooldown: number,
	detectionChance: number,
	questionsRevealed: number,
	category: "ui" | "leave_desk" | "camera" | "phone",
	timeLimit: number?,
	requiresOwnership: boolean,
}

local CHEAT_DEFS: { [string]: CheatDef } = {
	Phone = {
		cooldown = 20,
		detectionChance = 0.01,
		questionsRevealed = 1,
		category = "phone",
		requiresOwnership = false,
	},
	Toilet_Notes = {
		cooldown = 60,
		detectionChance = 0,
		questionsRevealed = 2,
		category = "leave_desk",
		timeLimit = 25,
		requiresOwnership = false,
	},
	Neighbor_Cheats = {
		cooldown = 40,
		detectionChance = 0,
		questionsRevealed = 1,
		category = "leave_desk",
		timeLimit = 12,
		requiresOwnership = true,
	},
	Radio_Answer = {
		cooldown = 45,
		detectionChance = 0.02,
		questionsRevealed = 1,
		category = "camera",
		requiresOwnership = true,
	},
	Choice_Eraser = {
		cooldown = 30,
		detectionChance = 0,
		questionsRevealed = 0,
		category = "ui",
		requiresOwnership = true,
	},
	Smart_Glasses = {
		cooldown = 60,
		detectionChance = 0.005,
		questionsRevealed = 3,
		category = "ui",
		requiresOwnership = true,
	},
	["Teacher's_Desk"] = {
		cooldown = 60,
		detectionChance = 0,
		questionsRevealed = 2,
		category = "leave_desk",
		timeLimit = 20,
		requiresOwnership = true,
	},
	Genius_Potion = {
		cooldown = 45,
		detectionChance = 0.005,
		questionsRevealed = 2,
		category = "ui",
		requiresOwnership = true,
	},
	Nerd_Help = {
		cooldown = 40,
		detectionChance = 0.02,
		questionsRevealed = 1,
		category = "camera",
		requiresOwnership = true,
	},
	Window_Friend = {
		cooldown = 50,
		detectionChance = 0.01,
		questionsRevealed = 1,
		category = "camera",
		requiresOwnership = true,
	},
}

---------------------------------------------------------------------------
-- Per-Player State
---------------------------------------------------------------------------
type PlayerCheatState = {
	cooldowns: { [string]: number },
	currentQuestionIndex: number,
	examQuestions: { any }?,
	strikes: number,
	isOutOfSeat: boolean,
	activePhoneSession: string?,
	phoneClicks: number,
}

local playerStates: { [Player]: PlayerCheatState } = {}

local function getState(player: Player): PlayerCheatState?
	return playerStates[player]
end

local function initState(player: Player)
	playerStates[player] = {
		cooldowns = {},
		currentQuestionIndex = 1,
		examQuestions = nil,
		strikes = 0,
		isOutOfSeat = false,
		activePhoneSession = nil,
		phoneClicks = 0,
	}
end

local function cleanupState(player: Player)
	playerStates[player] = nil
	pcall(function()
		player:SetAttribute("IsCheating", nil)
		player:SetAttribute("IsOutOfSeat", nil)
		player:SetAttribute("CheatStrikes", nil)
	end)
end

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------
local function getCorrectAnswer(state: PlayerCheatState, questionIndex: number): string?
	if not state.examQuestions then return nil end
	local q = state.examQuestions[questionIndex]
	if not q then return nil end
	return q.correct
end

local function getQuestionData(state: PlayerCheatState, questionIndex: number): any?
	if not state.examQuestions then return nil end
	return state.examQuestions[questionIndex]
end

local function isOnCooldown(state: PlayerCheatState, cheatName: string): (boolean, number)
	local expiry = state.cooldowns[cheatName]
	if not expiry then return false, 0 end
	local remaining = expiry - os.clock()
	if remaining <= 0 then
		state.cooldowns[cheatName] = nil
		return false, 0
	end
	return true, remaining
end

local function setCooldown(state: PlayerCheatState, cheatName: string, seconds: number)
	state.cooldowns[cheatName] = os.clock() + seconds
end

local function rollDetection(player: Player, cheatName: string, chance: number): boolean
	if chance <= 0 then return false end
	if math.random() < chance then
		print(string.format("[CheatManager] %s was DETECTED using %s! (%.1f%% chance)", player.Name, cheatName, chance * 100))
		player:SetAttribute("IsCheating", true)
		task.delay(5, function()
			if player.Parent then
				player:SetAttribute("IsCheating", nil)
			end
		end)
		return true
	end
	return false
end

---------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------
local CheatManager = {}

-- Remote references (populated in init)
local activateCheat: RemoteFunction
local getCheatCooldowns: RemoteFunction
local cheatWarning: RemoteEvent
local teacherCatch: RemoteEvent
local syncQuestionIndex: RemoteEvent
local phoneClick: RemoteEvent

---------------------------------------------------------------------------
-- Strike system
---------------------------------------------------------------------------
local function addStrike(player: Player)
	local state = getState(player)
	if not state then return end
	
	state.strikes = math.min(state.strikes + 1, 3)
	player:SetAttribute("CheatStrikes", state.strikes)
	
	if state.strikes >= 3 then
		print(string.format("[CheatManager] %s CAUGHT! 3 strikes — game over!", player.Name))
		teacherCatch:FireClient(player)
	else
		print(string.format("[CheatManager] %s received warning #%d", player.Name, state.strikes))
		cheatWarning:FireClient(player, state.strikes)
	end
end

CheatManager.addStrike = addStrike

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function CheatManager.registerExamQuestions(player: Player, questions: { any })
	local state = getState(player)
	if state then
		state.examQuestions = questions
		state.currentQuestionIndex = 1
		print(string.format("[CheatManager] Registered %d exam questions for %s", #questions, player.Name))
	end
end

function CheatManager.onExamEnd(player: Player)
	local state = getState(player)
	if state then
		state.examQuestions = nil
		state.currentQuestionIndex = 1
		state.activePhoneSession = nil
		state.phoneClicks = 0
		state.isOutOfSeat = false
		pcall(function()
			player:SetAttribute("IsCheating", nil)
			player:SetAttribute("IsOutOfSeat", nil)
		end)
	end
end

function CheatManager.playerReturnedToSeat(player: Player)
	local state = getState(player)
	if state and state.isOutOfSeat then
		state.isOutOfSeat = false
		player:SetAttribute("IsOutOfSeat", nil)
		print(string.format("[CheatManager] %s returned to seat safely", player.Name))
	end
end

function CheatManager.getCheatDefs(): { [string]: CheatDef }
	return CHEAT_DEFS
end

---------------------------------------------------------------------------
-- init() — called by init.server.luau after remotes are set up
---------------------------------------------------------------------------
function CheatManager.init()
	activateCheat     = CheatRemotes.get("ActivateCheat") :: RemoteFunction
	getCheatCooldowns = CheatRemotes.get("GetCheatCooldowns") :: RemoteFunction
	cheatWarning      = CheatRemotes.get("CheatWarning") :: RemoteEvent
	teacherCatch      = CheatRemotes.get("TeacherCatch") :: RemoteEvent
	syncQuestionIndex = CheatRemotes.get("SyncQuestionIndex") :: RemoteEvent
	phoneClick        = CheatRemotes.get("PhoneClick") :: RemoteEvent

	-- ActivateCheat handler
	activateCheat.OnServerInvoke = function(player: Player, cheatName: string)
		local state = getState(player)
		if not state then
			return { success = false, msg = "No cheat state (not in exam?)" }
		end
		
		local def = CHEAT_DEFS[cheatName]
		if not def then
			return { success = false, msg = "Unknown cheat: " .. tostring(cheatName) }
		end
		
		if def.requiresOwnership then
			if not PlayerData.owns(player, cheatName) then
				return { success = false, msg = "You don't own " .. cheatName }
			end
		end
		
		local onCooldown, remaining = isOnCooldown(state, cheatName)
		if onCooldown then
			return { success = false, msg = "On cooldown", cooldownRemaining = remaining }
		end
		
		if not state.examQuestions or #state.examQuestions == 0 then
			return { success = false, msg = "No active exam" }
		end
		
		setCooldown(state, cheatName, def.cooldown)
		local detected = rollDetection(player, cheatName, def.detectionChance)
		
		local currentQ = state.currentQuestionIndex
		local response: { [string]: any } = {
			success = true,
			detected = detected,
			cheatName = cheatName,
			category = def.category,
		}
		
		if cheatName == "Phone" then
			local sessionId = tostring(os.clock()) .. "_" .. tostring(math.random(1000, 9999))
			state.activePhoneSession = sessionId
			state.phoneClicks = 0
			response.sessionId = sessionId
			response.clicksRequired = 15
			
		elseif cheatName == "Choice_Eraser" then
			local q = getQuestionData(state, currentQ)
			if q then
				local correct = q.correct
				local wrongOptions = {}
				for _, letter in {"A", "B", "C"} do
					if letter ~= correct then
						table.insert(wrongOptions, letter)
					end
				end
				response.removeOption = wrongOptions[math.random(1, #wrongOptions)]
			else
				response.success = false
				response.msg = "Could not read current question"
			end
			
		else
			local answers = {}
			for i = 0, def.questionsRevealed - 1 do
				local qIndex = currentQ + i
				local correct = getCorrectAnswer(state, qIndex)
				if correct then
					table.insert(answers, { index = qIndex, correct = correct })
				end
			end
			response.answers = answers
			
			if def.category == "leave_desk" then
				response.timeLimit = def.timeLimit
				state.isOutOfSeat = true
				player:SetAttribute("IsOutOfSeat", true)
				
				local timeLimit = def.timeLimit or 20
				task.delay(timeLimit + 2, function()
					if player.Parent and state.isOutOfSeat then
						warn(string.format("[CheatManager] %s failed to return in time for %s!", player.Name, cheatName))
						state.isOutOfSeat = false
						player:SetAttribute("IsOutOfSeat", nil)
						addStrike(player)
					end
				end)
			end
		end
		
		return response
	end

	-- SyncQuestionIndex handler
	syncQuestionIndex.OnServerEvent:Connect(function(player: Player, questionIndex: number)
		local state = getState(player)
		if not state then return end
		if type(questionIndex) ~= "number" then return end
		questionIndex = math.clamp(math.floor(questionIndex), 1, 100)
		state.currentQuestionIndex = questionIndex
	end)

	-- PhoneClick handler
	phoneClick.OnServerEvent:Connect(function(player: Player, sessionId: string)
		local state = getState(player)
		if not state then return end
		if state.activePhoneSession ~= sessionId then return end
		
		state.phoneClicks += 1
		
		if state.phoneClicks >= 15 then
			local correct = getCorrectAnswer(state, state.currentQuestionIndex)
			if correct then
				phoneClick:FireClient(player, sessionId, correct)
			end
			state.activePhoneSession = nil
			state.phoneClicks = 0
		end
	end)

	-- GetCheatCooldowns handler
	getCheatCooldowns.OnServerInvoke = function(player: Player)
		local state = getState(player)
		if not state then return {} end
		
		local result: { [string]: number } = {}
		for cheatName, expiry in state.cooldowns do
			local remaining = expiry - os.clock()
			if remaining > 0 then
				result[cheatName] = math.ceil(remaining)
			end
		end
		return result
	end

	-- Player lifecycle
	Players.PlayerAdded:Connect(function(player)
		initState(player)
	end)
	for _, player in Players:GetPlayers() do
		initState(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		cleanupState(player)
	end)

	print("[CheatManager] Initialized ✓")
end

return CheatManager
