--[[
	LobbyUIController — Client-side UI logic for lobby creation.
	
	Controls the CreateGame frame inside the LobbyUI ScreenGui:
	  • Before / Next buttons cycle through Easy → Medium → Hard
	  • Difficulty label shows name + color
	  • DifficultyPrompt shows lock message for Medium/Hard when locked
	  • Create button is greyed out when the selected difficulty is locked
	  • Timer label shows countdown after clicking Create
	  • X button cancels lobby creation
	
	All game-state mutations go through RemoteEvents to the server.
	The client never modifies pad state directly.
	
	UI hierarchy (actual Studio structure):
	  StarterGui
	    └─ LobbyUI (ScreenGui)
	         └─ CreateGame (Frame)
	              ├─ Topbar (Frame)     — note lowercase 'b'
	              │    └─ TextButton    (X / close)
	              ├─ Before             (ImageButton)
	              ├─ Next               (ImageButton)
	              ├─ Difficulty         (Frame — visual container)
	              ├─ DifficultyLabel   (TextLabel — shows "Easy"/"Medium"/"Hard")
	              ├─ DifficultyPrompt  (TextLabel — created programmatically if missing)
	              └─ Create             (TextButton)
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local topBar          = createGameFrame:WaitForChild("Topbar") -- lowercase 'b' in Studio
local closeButton     = topBar:FindFirstChildWhichIsA("TextButton")
	                   or topBar:FindFirstChildWhichIsA("ImageButton")

local beforeButton    = createGameFrame:WaitForChild("Before")
local nextButton      = createGameFrame:WaitForChild("Next")
local createButton    = createGameFrame:WaitForChild("Create")

-- "Difficulty" in Studio is a Frame (visual container, e.g. stone icon).
-- "DifficultyLabel" is the actual TextLabel that shows "Easy" / "Medium" / "Hard".
local difficultyFrame = createGameFrame:WaitForChild("Difficulty")
local difficultyLabel = createGameFrame:WaitForChild("DifficultyLabel")

-- DifficultyPrompt may not exist in Studio yet — create programmatically if missing
local difficultyPrompt = createGameFrame:FindFirstChild("DifficultyPrompt")
if not difficultyPrompt then
	difficultyPrompt = Instance.new("TextLabel")
	difficultyPrompt.Name = "DifficultyPrompt"
	difficultyPrompt.Size = UDim2.new(0.9, 0, 0.08, 0)
	difficultyPrompt.Position = UDim2.new(0.05, 0, 0.72, 0)
	difficultyPrompt.BackgroundTransparency = 1
	difficultyPrompt.Font = Enum.Font.GothamBold
	difficultyPrompt.TextColor3 = Color3.fromRGB(255, 255, 255)
	difficultyPrompt.TextStrokeTransparency = 0.3
	difficultyPrompt.TextScaled = true
	difficultyPrompt.Text = ""
	difficultyPrompt.Visible = false
	difficultyPrompt.ZIndex = 10
	difficultyPrompt.Parent = createGameFrame
end

-- Create a Timer label programmatically if it doesn't exist yet
local timerLabel = createGameFrame:FindFirstChild("Timer")
if not timerLabel then
	timerLabel = Instance.new("TextLabel")
	timerLabel.Name = "Timer"
	timerLabel.Size = UDim2.new(0.6, 0, 0.08, 0)
	timerLabel.Position = UDim2.new(0.2, 0, 0.88, 0)
	timerLabel.AnchorPoint = Vector2.new(0, 0)
	timerLabel.BackgroundTransparency = 1
	timerLabel.Font = Enum.Font.GothamBold
	timerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	timerLabel.TextStrokeTransparency = 0.5
	timerLabel.TextScaled = true
	timerLabel.Text = ""
	timerLabel.Visible = false
	timerLabel.ZIndex = 10
	timerLabel.Parent = createGameFrame
end

---------------------------------------------------------------------------
-- Local state
---------------------------------------------------------------------------
local currentDiffIndex: number = 1
local unlocks: { [string]: boolean } = {}
local isOnPad: boolean = false
local activePadIndex: number? = nil
local hasClickedCreate: boolean = false

---------------------------------------------------------------------------
-- Unlock fetch
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
-- Display update
---------------------------------------------------------------------------

local function updateDisplay()
	local diff = LobbyConfig.DIFFICULTIES[currentDiffIndex]
	if not diff then return end

	-- Difficulty name & colour
	difficultyLabel.Text = diff.name
	difficultyLabel.TextColor3 = diff.color

	-- Unlock check
	local isUnlocked = true
	if diff.name ~= "Easy" then
		isUnlocked = (unlocks[diff.name] == true)
	end

	-- Prompt visibility
	if diff.name == "Easy" or isUnlocked then
		difficultyPrompt.Visible = false
	else
		difficultyPrompt.Text = diff.promptText
		difficultyPrompt.Visible = true
	end

	-- Create button colour
	if isUnlocked then
		createButton.BackgroundColor3 = LobbyConfig.CREATE_BUTTON_UNLOCKED_COLOR
	else
		createButton.BackgroundColor3 = LobbyConfig.CREATE_BUTTON_LOCKED_COLOR
	end
end

---------------------------------------------------------------------------
-- Difficulty cycling
---------------------------------------------------------------------------

local function nextDifficulty()
	if hasClickedCreate then return end -- Lock cycling after Create
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

local function setUIVisible(visible: boolean)
	lobbyUI.Enabled = visible
	createGameFrame.Visible = visible

	if visible then
		-- Reset to Easy every time the UI opens
		currentDiffIndex = 1
		hasClickedCreate = false
		timerLabel.Visible = false
		timerLabel.Text = ""

		-- Restore buttons (may have been hidden from a previous Create)
		beforeButton.Visible = true
		nextButton.Visible = true
		createButton.Visible = true

		refreshUnlocks()
		updateDisplay()
	end

	isOnPad = visible
end

-- Start hidden
setUIVisible(false)

---------------------------------------------------------------------------
-- Button connections
---------------------------------------------------------------------------

nextButton.Activated:Connect(nextDifficulty)
beforeButton.Activated:Connect(prevDifficulty)

closeButton.Activated:Connect(function()
	if not isOnPad then return end
	requestCancel:FireServer()
	setUIVisible(false)
end)

createButton.Activated:Connect(function()
	if not isOnPad then return end
	if hasClickedCreate then return end -- Prevent double-click

	local diff = LobbyConfig.DIFFICULTIES[currentDiffIndex]
	if not diff then return end

	-- Block if locked
	local isUnlocked = (diff.name == "Easy") or (unlocks[diff.name] == true)
	if not isUnlocked then return end

	hasClickedCreate = true

	-- Fire to server
	requestCreate:FireServer(diff.name)

	-- Swap UI into "countdown" mode
	beforeButton.Visible = false
	nextButton.Visible = false
	createButton.Visible = false
	difficultyPrompt.Visible = false
	timerLabel.Visible = true
	timerLabel.Text = LobbyConfig.COUNTDOWN_SECONDS .. "s"
end)

---------------------------------------------------------------------------
-- Server → Client events
---------------------------------------------------------------------------

showUIRemote.OnClientEvent:Connect(function(show: boolean, padIndex: number?)
	setUIVisible(show)
	activePadIndex = if show then padIndex else nil
end)

timerRemote.OnClientEvent:Connect(function(padIndex: number, remaining: number)
	if isOnPad and timerLabel.Visible then
		-- Only update if this timer is for our pad (or we don't track pad — safe either way)
		if activePadIndex == nil or activePadIndex == padIndex then
			timerLabel.Text = remaining .. "s"
		end
	end
end)

print("[LobbyUIController] Client initialized")
