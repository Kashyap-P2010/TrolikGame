--[[
	LobbyUIController — Client-side lobby creation UI.

	UI hierarchy (exact Studio names):
	  StarterGui
	    └─ LobbyUI (ScreenGui)  ← Enabled may be false in Studio; forced true at runtime
	         └─ CreateGame (Frame)
	              ├─ Topbar (Frame)
	              │    └─ TextButton  (X / close)
	              ├─ Before          (ImageButton)
	              ├─ Next            (ImageButton)
	              ├─ Create          (TextButton)   ← green=clickable, grey=locked
	              ├─ Difficulty      (TextLabel)    ← shows "Easy"/"Medium"/"Hard" + color
	              └─ DifficultyLabel (TextLabel)    ← shows "Score 70%..." lock prompt
]]

local Players        = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService   = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

---------------------------------------------------------------------------
-- Shared modules
---------------------------------------------------------------------------
local Shared       = ReplicatedStorage:WaitForChild("Shared")
local LobbyConfig  = require(Shared:WaitForChild("LobbyConfig"))
local LobbyRemotes = require(Shared:WaitForChild("LobbyRemotes"))

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local requestCreate = LobbyRemotes.get("RequestCreateLobby")
local requestCancel = LobbyRemotes.get("RequestCancelLobby")
local showUIRemote  = LobbyRemotes.get("ShowLobbyUI")
local timerRemote   = LobbyRemotes.get("UpdateTimer")
local getUnlocks    = LobbyRemotes.get("GetDifficultyUnlocks")

---------------------------------------------------------------------------
-- UI references
---------------------------------------------------------------------------
local lobbyUI         = playerGui:WaitForChild("LobbyUI")
local createGameFrame = lobbyUI:WaitForChild("CreateGame")
local topBar          = createGameFrame:WaitForChild("Topbar")

local closeButton = topBar:FindFirstChildWhichIsA("TextButton")
	               or topBar:FindFirstChildWhichIsA("ImageButton")
if not closeButton then
	error("[LobbyUIController] No button found inside Topbar")
end

local beforeButton    = createGameFrame:WaitForChild("Before")
local nextButton      = createGameFrame:WaitForChild("Next")
local createButton    = createGameFrame:WaitForChild("Create")    :: TextButton
local difficultyLabel = createGameFrame:WaitForChild("Difficulty")      -- "Easy"/"Medium"/"Hard"
local difficultyPrompt= createGameFrame:WaitForChild("DifficultyLabel") -- lock message

-- Timer label — created programmatically if not in Studio
local timerLabel = createGameFrame:FindFirstChild("Timer")
if not timerLabel then
	timerLabel = Instance.new("TextLabel")
	timerLabel.Name                   = "Timer"
	timerLabel.Size                   = UDim2.new(0.6, 0, 0.08, 0)
	timerLabel.Position               = UDim2.new(0.2, 0, 0.88, 0)
	timerLabel.BackgroundTransparency = 1
	timerLabel.Font                   = Enum.Font.GothamBold
	timerLabel.TextColor3             = Color3.fromRGB(255, 255, 255)
	timerLabel.TextStrokeTransparency = 0.5
	timerLabel.TextScaled             = true
	timerLabel.Text                   = ""
	timerLabel.Visible                = false
	timerLabel.ZIndex                 = 10
	timerLabel.Parent                 = createGameFrame
end

---------------------------------------------------------------------------
-- Colors
---------------------------------------------------------------------------
local COLOR_UNLOCKED = LobbyConfig.CREATE_BUTTON_UNLOCKED_COLOR  -- green
local COLOR_LOCKED   = LobbyConfig.CREATE_BUTTON_LOCKED_COLOR    -- grey
local COLOR_HOVER    = Color3.fromRGB(0, 210, 0)                 -- slightly darker green on hover
local COLOR_PRESSED  = Color3.fromRGB(0, 170, 0)                 -- even darker on press

---------------------------------------------------------------------------
-- Tween helpers for Create button
---------------------------------------------------------------------------
local TWEEN_HOVER_IN  = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_HOVER_OUT = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_PRESS     = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_RELEASE   = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Store original Size once on load
local CREATE_BASE_SIZE = createButton.Size

local activeTween: Tween? = nil
local function tweenCreate(info: TweenInfo, props: {[string]: any})
	if activeTween then activeTween:Cancel() end
	activeTween = TweenService:Create(createButton, info, props)
	activeTween:Play()
end

---------------------------------------------------------------------------
-- Local state
---------------------------------------------------------------------------
local currentDiffIndex: number     = 1
local unlocks: {[string]: boolean} = {}
local isOnPad: boolean             = false
local activePadIndex: number?      = nil
local hasClickedCreate: boolean    = false
local isCurrentlyUnlocked: boolean = false  -- track for hover color logic

---------------------------------------------------------------------------
-- Startup: hide UI
---------------------------------------------------------------------------
lobbyUI.Enabled         = false
createGameFrame.Visible = false

---------------------------------------------------------------------------
-- Unlock query
---------------------------------------------------------------------------
local function refreshUnlocks()
	local ok, result = pcall(function()
		return getUnlocks:InvokeServer()
	end)
	if ok and type(result) == "table" then
		unlocks = result
	else
		unlocks = { Easy = true, Medium = false, Hard = false }
	end
end

---------------------------------------------------------------------------
-- Update difficulty display + button state
---------------------------------------------------------------------------
local function updateDisplay()
	local diff = LobbyConfig.DIFFICULTIES[currentDiffIndex]
	if not diff then return end

	difficultyLabel.Text       = diff.name
	difficultyLabel.TextColor3 = diff.color

	isCurrentlyUnlocked = (diff.name == "Easy") or (unlocks[diff.name] == true)

	if isCurrentlyUnlocked then
		difficultyPrompt.Visible      = false
		createButton.BackgroundColor3 = COLOR_UNLOCKED
		createButton.Active           = true  -- allow MouseButton1Click to fire
	else
		difficultyPrompt.Text         = diff.promptText
		difficultyPrompt.Visible      = true
		createButton.BackgroundColor3 = COLOR_LOCKED
		createButton.Active           = false -- block all click events
	end
end

---------------------------------------------------------------------------
-- Difficulty cycling
---------------------------------------------------------------------------
local function nextDifficulty()
	if hasClickedCreate then return end
	currentDiffIndex = (currentDiffIndex % #LobbyConfig.DIFFICULTIES) + 1
	updateDisplay()
end

local function prevDifficulty()
	if hasClickedCreate then return end
	currentDiffIndex = ((currentDiffIndex - 2) % #LobbyConfig.DIFFICULTIES) + 1
	updateDisplay()
end

---------------------------------------------------------------------------
-- Show / hide UI
---------------------------------------------------------------------------
local function showUI(padIndex: number)
	lobbyUI.Enabled         = true   -- must be true for buttons to receive input
	createGameFrame.Visible = true

	isOnPad          = true
	activePadIndex   = padIndex
	hasClickedCreate = false
	currentDiffIndex = 1

	beforeButton.Visible = true
	beforeButton.Active  = true
	nextButton.Visible   = true
	nextButton.Active    = true
	createButton.Visible = true
	createButton.Size    = CREATE_BASE_SIZE  -- reset any press-scale

	timerLabel.Visible = false
	timerLabel.Text    = ""

	refreshUnlocks()
	updateDisplay()

	print("[LobbyUI] Shown for pad", padIndex)
end

local function hideUI()
	createGameFrame.Visible = false
	lobbyUI.Enabled         = false
	isOnPad                 = false
	activePadIndex          = nil
	print("[LobbyUI] Hidden")
end

---------------------------------------------------------------------------
-- Create button hover & click animations
-- Only animate when button is unlocked (Active=true, green)
---------------------------------------------------------------------------
createButton.MouseEnter:Connect(function()
	if not isCurrentlyUnlocked or hasClickedCreate then return end
	tweenCreate(TWEEN_HOVER_IN, {
		BackgroundColor3 = COLOR_HOVER,
		Size = UDim2.new(
			CREATE_BASE_SIZE.X.Scale * 1.04, CREATE_BASE_SIZE.X.Offset,
			CREATE_BASE_SIZE.Y.Scale * 1.08, CREATE_BASE_SIZE.Y.Offset
		),
	})
end)

createButton.MouseLeave:Connect(function()
	if not isCurrentlyUnlocked or hasClickedCreate then return end
	tweenCreate(TWEEN_HOVER_OUT, {
		BackgroundColor3 = COLOR_UNLOCKED,
		Size             = CREATE_BASE_SIZE,
	})
end)

createButton.MouseButton1Down:Connect(function()
	if not isCurrentlyUnlocked or hasClickedCreate then return end
	tweenCreate(TWEEN_PRESS, {
		BackgroundColor3 = COLOR_PRESSED,
		Size = UDim2.new(
			CREATE_BASE_SIZE.X.Scale * 0.96, CREATE_BASE_SIZE.X.Offset,
			CREATE_BASE_SIZE.Y.Scale * 0.93, CREATE_BASE_SIZE.Y.Offset
		),
	})
end)

createButton.MouseButton1Up:Connect(function()
	if not isCurrentlyUnlocked or hasClickedCreate then return end
	-- Bounce back to hover color since mouse is still over button
	tweenCreate(TWEEN_RELEASE, {
		BackgroundColor3 = COLOR_HOVER,
		Size = UDim2.new(
			CREATE_BASE_SIZE.X.Scale * 1.04, CREATE_BASE_SIZE.X.Offset,
			CREATE_BASE_SIZE.Y.Scale * 1.08, CREATE_BASE_SIZE.Y.Offset
		),
	})
end)

---------------------------------------------------------------------------
-- Button connections
---------------------------------------------------------------------------
nextButton.MouseButton1Click:Connect(nextDifficulty)
beforeButton.MouseButton1Click:Connect(prevDifficulty)

closeButton.MouseButton1Click:Connect(function()
	if not isOnPad then return end
	requestCancel:FireServer()
	hideUI()
end)

-- Create uses MouseButton1Click so it fires regardless of Active state edge-cases.
-- We double-check isCurrentlyUnlocked ourselves before acting.
createButton.MouseButton1Click:Connect(function()
	print("[LobbyUI] Create clicked | isOnPad:", isOnPad,
		"| hasClickedCreate:", hasClickedCreate,
		"| isCurrentlyUnlocked:", isCurrentlyUnlocked)

	if not isOnPad then return end
	if hasClickedCreate then return end
	if not isCurrentlyUnlocked then
		print("[LobbyUI] Blocked — difficulty locked")
		return
	end

	local diff = LobbyConfig.DIFFICULTIES[currentDiffIndex]
	if not diff then return end

	hasClickedCreate = true

	-- Snap button back to normal size/color before hiding it
	if activeTween then activeTween:Cancel() end
	createButton.Size             = CREATE_BASE_SIZE
	createButton.BackgroundColor3 = COLOR_UNLOCKED

	requestCreate:FireServer(diff.name)
	print("[LobbyUI] Fired RequestCreateLobby:", diff.name)

	-- Switch to countdown mode
	beforeButton.Visible     = false
	nextButton.Visible       = false
	createButton.Visible     = false
	difficultyPrompt.Visible = false
	timerLabel.Visible       = true
	timerLabel.Text          = LobbyConfig.COUNTDOWN_SECONDS .. "s"
end)

---------------------------------------------------------------------------
-- Server → Client events
---------------------------------------------------------------------------
showUIRemote.OnClientEvent:Connect(function(show: boolean, padIndex: number?)
	if show then
		showUI(padIndex or 0)
	else
		hideUI()
	end
end)

timerRemote.OnClientEvent:Connect(function(padIndex: number, remaining: number)
	if not isOnPad then return end
	if not timerLabel.Visible then return end
	if activePadIndex ~= nil and activePadIndex ~= padIndex then return end
	timerLabel.Text = remaining .. "s"
end)

print("[LobbyUIController] Client initialized")
