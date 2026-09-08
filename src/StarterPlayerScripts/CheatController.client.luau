--[[
	CheatController.client.luau
	
	Client-side controller for ALL cheat activation and visual effects.
	Responsibilities:
	  • Cheat Menu UI (opened with F key during exam).
	  • Dispatches cheat activation to server via ActivateCheat remote.
	  • Runs client-side visual effects for each cheat.
	  • Syncs current question index to server.
	  • Handles warning/catch events from server.
	
	The Cheat Menu ScreenGui is expected to be inside PlayerGui as "CheatMenuUI".
	If it doesn't exist yet, we create a minimal placeholder.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local Lighting          = game:GetService("Lighting")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Shared       = ReplicatedStorage:WaitForChild("Shared")
local CheatRemotes = require(Shared:WaitForChild("CheatRemotes"))

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local activateCheat     = CheatRemotes.get("ActivateCheat") :: RemoteFunction
local getCheatCooldowns = CheatRemotes.get("GetCheatCooldowns") :: RemoteFunction
local cheatWarning      = CheatRemotes.get("CheatWarning") :: RemoteEvent
local teacherCatch      = CheatRemotes.get("TeacherCatch") :: RemoteEvent
local syncQuestionIndex = CheatRemotes.get("SyncQuestionIndex") :: RemoteEvent
local phoneClick        = CheatRemotes.get("PhoneClick") :: RemoteEvent

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local isExamActive = false
local isCheatMenuOpen = false
local currentQuestionIndex = 1
local totalQuestions = 20
local cooldowns: { [string]: number } = {}  -- cheatName -> os.clock() expiry
local activeEffects: { [string]: boolean } = {} -- track which effects are running

-- Smart Glasses / Genius Potion: highlighted answers
local highlightedAnswers: { [number]: string } = {} -- questionIndex -> correct letter
local smartGlassesActive = false
local smartGlassesQuestionsLeft = 0

-- Phone cheat state
local phoneSessionId: string? = nil
local phoneClickCount = 0
local phoneClicksRequired = 15
local phoneAnswerRevealed = false

-- Choice Eraser state
local erasedOption: string? = nil

---------------------------------------------------------------------------
-- Cheat Menu UI (Placeholder — user will design the real one later)
---------------------------------------------------------------------------
local cheatMenuUI = playerGui:FindFirstChild("CheatMenuUI") :: ScreenGui?
if not cheatMenuUI then
	cheatMenuUI = Instance.new("ScreenGui")
	cheatMenuUI.Name = "CheatMenuUI"
	cheatMenuUI.ResetOnSpawn = false
	cheatMenuUI.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	cheatMenuUI.Parent = playerGui
end
cheatMenuUI.Enabled = false

-- Create a simple placeholder frame for the cheat menu
local menuFrame = cheatMenuUI:FindFirstChild("MenuFrame") :: Frame?
if not menuFrame then
	menuFrame = Instance.new("Frame")
	menuFrame.Name = "MenuFrame"
	menuFrame.Size = UDim2.new(0.6, 0, 0.7, 0)
	menuFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	menuFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	menuFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 35)
	menuFrame.BackgroundTransparency = 0.15
	menuFrame.BorderSizePixel = 0
	menuFrame.Parent = cheatMenuUI
	
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = menuFrame
	
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(80, 200, 255)
	stroke.Parent = menuFrame
	
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 40)
	title.BackgroundTransparency = 1
	title.Text = "🎒 Exam Cheats"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 22
	title.Parent = menuFrame
	
	-- Grid layout for cheat buttons
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0, 140, 0, 60)
	gridLayout.CellPadding = UDim2.new(0, 10, 0, 10)
	gridLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	gridLayout.SortOrder = Enum.SortOrder.Name
	gridLayout.Parent = menuFrame
	
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 50)
	padding.PaddingLeft = UDim.new(0, 20)
	padding.PaddingRight = UDim.new(0, 20)
	padding.Parent = menuFrame
end

---------------------------------------------------------------------------
-- Cheat button definitions (display names + order)
---------------------------------------------------------------------------
local CHEAT_DISPLAY = {
	{ name = "Phone",           display = "📱 Phone",           locked = false },
	{ name = "Toilet_Notes",    display = "🚽 Toilet Notes",    locked = false },
	{ name = "Choice_Eraser",   display = "✏️ Choice Eraser",   locked = true },
	{ name = "Smart_Glasses",   display = "🤓 Smart Glasses",   locked = true },
	{ name = "Genius_Potion",   display = "🧪 Genius Potion",   locked = true },
	{ name = "Neighbor_Cheats", display = "👀 Neighbor Cheats", locked = true },
	{ name = "Radio_Answer",    display = "📻 Radio Answer",    locked = true },
	{ name = "Nerd_Help",       display = "🤓 Nerd Help",       locked = true },
	{ name = "Teacher's_Desk",  display = "📝 Teacher's Desk",  locked = true },
	{ name = "Window_Friend",   display = "🪟 Window Friend",   locked = true },
}

local cheatButtons: { [string]: TextButton } = {}

local function createCheatButtons()
	-- Clear existing buttons
	for _, child in menuFrame:GetChildren() do
		if child:IsA("TextButton") then child:Destroy() end
	end
	cheatButtons = {}
	
	for i, cheatInfo in CHEAT_DISPLAY do
		local btn = Instance.new("TextButton")
		btn.Name = string.format("%02d_%s", i, cheatInfo.name)
		btn.Text = cheatInfo.display
		btn.Font = Enum.Font.GothamBold
		btn.TextSize = 14
		btn.TextColor3 = Color3.fromRGB(255, 255, 255)
		btn.BackgroundColor3 = Color3.fromRGB(40, 40, 70)
		btn.BorderSizePixel = 0
		btn.Parent = menuFrame
		
		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, 8)
		btnCorner.Parent = btn
		
		local btnStroke = Instance.new("UIStroke")
		btnStroke.Thickness = 1
		btnStroke.Color = Color3.fromRGB(60, 60, 100)
		btnStroke.Parent = btn
		
		cheatButtons[cheatInfo.name] = btn
		
		btn.MouseButton1Click:Connect(function()
			onCheatClicked(cheatInfo.name)
		end)
	end
end

---------------------------------------------------------------------------
-- Update button states (owned, cooldown, locked)
---------------------------------------------------------------------------
local function updateCheatButtons()
	-- Fetch cooldowns from server
	local serverCooldowns = pcall(function()
		return getCheatCooldowns:InvokeServer()
	end)
	
	-- TODO: Also fetch ownership from PlayerData when real UI is built
	-- For now, buttons just show the cheat name
end

---------------------------------------------------------------------------
-- Cheat Menu Toggle (F key)
---------------------------------------------------------------------------
local function toggleCheatMenu()
	if not isExamActive then return end
	isCheatMenuOpen = not isCheatMenuOpen
	cheatMenuUI.Enabled = isCheatMenuOpen
	if isCheatMenuOpen then
		updateCheatButtons()
	end
end

---------------------------------------------------------------------------
-- ExamController Integration API
-- These functions are called by ExamController to keep us in sync.
---------------------------------------------------------------------------
local CheatController = {}

function CheatController.setExamActive(active: boolean)
	isExamActive = active
	if not active then
		isCheatMenuOpen = false
		cheatMenuUI.Enabled = false
		-- Clear all active effects
		highlightedAnswers = {}
		smartGlassesActive = false
		erasedOption = nil
		phoneSessionId = nil
		phoneClickCount = 0
		phoneAnswerRevealed = false
		-- Remove blue tint if active
		local colorCorrection = Lighting:FindFirstChild("SmartGlassesTint")
		if colorCorrection then colorCorrection:Destroy() end
	end
end

function CheatController.setCurrentQuestion(index: number, total: number)
	currentQuestionIndex = index
	totalQuestions = total
	-- Sync to server
	syncQuestionIndex:FireServer(index)
	
	-- Reset per-question effects
	erasedOption = nil
	phoneSessionId = nil
	phoneClickCount = 0
	phoneAnswerRevealed = false
	
	-- Check if Smart Glasses / Genius Potion highlighting is done
	if smartGlassesActive then
		if not highlightedAnswers[index] then
			smartGlassesQuestionsLeft -= 1
		end
		if smartGlassesQuestionsLeft <= 0 then
			smartGlassesActive = false
			highlightedAnswers = {}
			-- Remove blue tint
			local colorCorrection = Lighting:FindFirstChild("SmartGlassesTint")
			if colorCorrection then
				TweenService:Create(colorCorrection, TweenInfo.new(0.5), {
					TintColor = Color3.new(1, 1, 1)
				}):Play()
				task.delay(0.5, function()
					if colorCorrection.Parent then colorCorrection:Destroy() end
				end)
			end
			print("[CheatController] Smart Glasses effect ended")
		end
	end
end

--- Returns the correct answer letter if this question is highlighted, nil otherwise.
function CheatController.getHighlightedAnswer(questionIndex: number): string?
	return highlightedAnswers[questionIndex]
end

--- Returns the option letter to hide for Choice Eraser, nil if not active.
function CheatController.getErasedOption(): string?
	return erasedOption
end

--- Returns true if Phone cheat is active and awaiting clicks.
function CheatController.isPhoneActive(): boolean
	return phoneSessionId ~= nil and not phoneAnswerRevealed
end

--- Call this when the player clicks the phone.
function CheatController.onPhoneClick(): string?
	if not phoneSessionId then return nil end
	
	phoneClickCount += 1
	phoneClick:FireServer(phoneSessionId)
	
	-- The answer comes back via the PhoneClick event listener below
	return nil
end

--- Returns phone click progress as a fraction (0.0 to 1.0).
function CheatController.getPhoneProgress(): number
	if not phoneSessionId then return 0 end
	return math.clamp(phoneClickCount / phoneClicksRequired, 0, 1)
end

---------------------------------------------------------------------------
-- Cheat Activation
---------------------------------------------------------------------------
function onCheatClicked(cheatName: string)
	if not isExamActive then return end
	if activeEffects[cheatName] then return end -- prevent double-click
	
	-- Close menu
	isCheatMenuOpen = false
	cheatMenuUI.Enabled = false
	
	print(string.format("[CheatController] Activating cheat: %s", cheatName))
	activeEffects[cheatName] = true
	
	local ok, result = pcall(function()
		return activateCheat:InvokeServer(cheatName)
	end)
	
	if not ok or not result or not result.success then
		local msg = (result and result.msg) or "Server error"
		warn(string.format("[CheatController] Cheat failed: %s — %s", cheatName, msg))
		activeEffects[cheatName] = nil
		return
	end
	
	-- Dispatch to the correct effect handler
	if cheatName == "Phone" then
		runPhoneCheat(result)
	elseif cheatName == "Choice_Eraser" then
		runChoiceEraser(result)
	elseif cheatName == "Smart_Glasses" then
		runSmartGlasses(result)
	elseif cheatName == "Genius_Potion" then
		runGeniusPotion(result)
	elseif cheatName == "Toilet_Notes" then
		runLeaveDeskCheat(cheatName, result)
	elseif cheatName == "Neighbor_Cheats" then
		runLeaveDeskCheat(cheatName, result)
	elseif cheatName == "Teacher's_Desk" then
		runLeaveDeskCheat(cheatName, result)
	elseif cheatName == "Radio_Answer" then
		runCameraCutscene(cheatName, result)
	elseif cheatName == "Nerd_Help" then
		runCameraCutscene(cheatName, result)
	elseif cheatName == "Window_Friend" then
		runCameraCutscene(cheatName, result)
	end
	
	-- Clear active flag after cooldown
	task.delay(2, function()
		activeEffects[cheatName] = nil
	end)
end

---------------------------------------------------------------------------
-- Effect Handlers: UI-Only Cheats
---------------------------------------------------------------------------

function runChoiceEraser(result: { [string]: any })
	local optionToRemove = result.removeOption
	if not optionToRemove then return end
	
	erasedOption = optionToRemove
	print(string.format("[CheatController] Choice Eraser: hiding option %s", optionToRemove))
	
	-- The actual hiding is done by ExamController when it reads getErasedOption()
	-- We fire a BindableEvent or directly call into ExamController
	-- For now, ExamController polls getErasedOption() in displayQuestion()
end

function runSmartGlasses(result: { [string]: any })
	local answers = result.answers
	if not answers or #answers == 0 then return end
	
	-- Store highlighted answers
	for _, answerData in answers do
		highlightedAnswers[answerData.index] = answerData.correct
	end
	smartGlassesActive = true
	smartGlassesQuestionsLeft = #answers
	
	-- Apply blue tint
	local colorCorrection = Lighting:FindFirstChild("SmartGlassesTint")
	if not colorCorrection then
		colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = "SmartGlassesTint"
		colorCorrection.TintColor = Color3.new(1, 1, 1) -- start normal
		colorCorrection.Parent = Lighting
	end
	TweenService:Create(colorCorrection, TweenInfo.new(0.5), {
		TintColor = Color3.fromRGB(200, 210, 255) -- subtle blue tint
	}):Play()
	
	print(string.format("[CheatController] Smart Glasses: highlighting %d answers", #answers))
end

function runGeniusPotion(result: { [string]: any })
	local answers = result.answers
	if not answers or #answers == 0 then return end
	
	-- Store highlighted answers (same system as Smart Glasses)
	for _, answerData in answers do
		highlightedAnswers[answerData.index] = answerData.correct
	end
	smartGlassesActive = true -- reuse the same tracking
	smartGlassesQuestionsLeft = #answers
	
	-- TODO: Play particle effect on screen for 2 seconds
	-- (Will be implemented when assets are ready)
	print(string.format("[CheatController] Genius Potion: highlighting %d answers", #answers))
end

function runPhoneCheat(result: { [string]: any })
	phoneSessionId = result.sessionId
	phoneClickCount = 0
	phoneClicksRequired = result.clicksRequired or 15
	phoneAnswerRevealed = false
	
	print(string.format("[CheatController] Phone cheat started — need %d clicks", phoneClicksRequired))
	-- The actual phone UI and click handling is done by ExamController
	-- which calls CheatController.onPhoneClick() and reads isPhoneActive()
end

---------------------------------------------------------------------------
-- Effect Handlers: Leave-Desk Cheats (Stub — waiting for assets)
---------------------------------------------------------------------------

function runLeaveDeskCheat(cheatName: string, result: { [string]: any })
	local answers = result.answers
	local timeLimit = result.timeLimit
	
	-- Store answers for display when player reaches destination
	if answers then
		for _, answerData in answers do
			highlightedAnswers[answerData.index] = answerData.correct
		end
	end
	
	print(string.format("[CheatController] %s: leave-desk cheat started (time limit: %ds)", cheatName, timeLimit or 0))
	-- TODO: Implement when assets are ready:
	-- 1. Unsit player
	-- 2. Show arrow waypoints
	-- 3. Show countdown timer
	-- 4. ProximityPrompt at destination showing answers
	-- 5. Arrow waypoints back to seat
	-- 6. Player sits back down
end

---------------------------------------------------------------------------
-- Effect Handlers: Camera Cutscene Cheats (Stub — waiting for assets)
---------------------------------------------------------------------------

function runCameraCutscene(cheatName: string, result: { [string]: any })
	local answers = result.answers
	
	print(string.format("[CheatController] %s: camera cutscene cheat activated", cheatName))
	-- TODO: Implement when assets are ready:
	-- Radio Answer: camera to radio, speech bubble "...", then answer
	-- Nerd Help: throw paper ball, nerd throws airplane back, show answer
	-- Window Friend: camera to window, friend appears with answer
	
	-- For now, just store the answer so it can be displayed
	if answers and #answers > 0 then
		highlightedAnswers[answers[1].index] = answers[1].correct
	end
end

---------------------------------------------------------------------------
-- Phone answer callback (server sends answer after 15 clicks)
---------------------------------------------------------------------------
phoneClick.OnClientEvent:Connect(function(sessionId: string, answer: string)
	if phoneSessionId ~= sessionId then return end
	
	phoneAnswerRevealed = true
	print(string.format("[CheatController] Phone answer revealed: %s", answer))
	
	-- Store as highlighted so ExamController can display it
	highlightedAnswers[currentQuestionIndex] = answer
end)

---------------------------------------------------------------------------
-- Warning / Catch event handlers
---------------------------------------------------------------------------
cheatWarning.OnClientEvent:Connect(function(warningNumber: number)
	print(string.format("[CheatController] ⚠️ WARNING #%d from teacher!", warningNumber))
	-- TODO: Play warning animation / UI popup
	-- warningNumber 1 = "Warning!", 2 = "Final Warning!"
end)

teacherCatch.OnClientEvent:Connect(function()
	print("[CheatController] 🚨 CAUGHT! Game over!")
	-- TODO: Black screen, game over UI
	isExamActive = false
	isCheatMenuOpen = false
	cheatMenuUI.Enabled = false
end)

---------------------------------------------------------------------------
-- F key toggle
---------------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F then
		toggleCheatMenu()
	end
end)

---------------------------------------------------------------------------
-- Create buttons on startup
---------------------------------------------------------------------------
createCheatButtons()

print("[CheatController] Initialized ✓")

return CheatController
