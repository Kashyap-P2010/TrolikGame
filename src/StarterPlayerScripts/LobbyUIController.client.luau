--[[
	LobbyUIController — Client-side lobby creation UI.

	UI hierarchy (exact Studio names):
	  StarterGui
	    └─ LobbyUI (ScreenGui)  ← Enabled may be false in Studio; we force true at runtime
	         └─ CreateGame (Frame)
	              ├─ Topbar (Frame)
	              │    └─ TextButton  (X / close)
	              ├─ Before          (ImageButton)
	              ├─ Next            (ImageButton)
	              ├─ Create          (TextButton or ImageButton)
	              ├─ Difficulty      (TextLabel — shows "Easy" / "Medium" / "Hard" + color)
	              └─ DifficultyLabel (TextLabel — shows "Score 70%..." lock prompt)

	State machine (client-side):
	  Hidden  →  [server fires ShowLobbyUI true]  →  Visible/Idle
	  Visible  →  [Create clicked]  →  Countdown mode (buttons hidden, timer shown)
	  Visible  →  [X clicked]       →  Hidden (server cancels)
	  Countdown  →  [server fires ShowLobbyUI false]  →  Hidden
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
-- UI references  (WaitForChild on everything — no infinite yields)
---------------------------------------------------------------------------
local lobbyUI         = playerGui:WaitForChild("LobbyUI")
local createGameFrame = lobbyUI:WaitForChild("CreateGame")
local topBar          = createGameFrame:WaitForChild("Topbar")

-- Close button — could be TextButton or ImageButton inside Topbar
local closeButton = topBar:FindFirstChildWhichIsA("TextButton")
	               or topBar:FindFirstChildWhichIsA("ImageButton")
if not closeButton then
	error("[LobbyUIController] No TextButton/ImageButton found inside Topbar")
end

local beforeButton    = createGameFrame:WaitForChild("Before")
local nextButton      = createGameFrame:WaitForChild("Next")
local createButton    = createGameFrame:WaitForChild("Create")
local difficultyLabel = createGameFrame:WaitForChild("Difficulty")      -- TextLabel: "Easy"/"Medium"/"Hard"
local difficultyPrompt= createGameFrame:WaitForChild("DifficultyLabel") -- TextLabel: lock message

-- Timer label — create it if not in Studio yet
local timerLabel = createGameFrame:FindFirstChild("Timer")
if not timerLabel then
	timerLabel = Instance.new("TextLabel")
	timerLabel.Name                 = "Timer"
	timerLabel.Size                 = UDim2.new(0.6, 0, 0.08, 0)
	timerLabel.Position             = UDim2.new(0.2, 0, 0.88, 0)
	timerLabel.BackgroundTransparency = 1
	timerLabel.Font                 = Enum.Font.GothamBold
	timerLabel.TextColor3           = Color3.fromRGB(255, 255, 255)
	timerLabel.TextStrokeTransparency = 0.5
	timerLabel.TextScaled           = true
	timerLabel.Text                 = ""
	timerLabel.Visible              = false
	timerLabel.ZIndex               = 10
	timerLabel.Parent               = createGameFrame
end

---------------------------------------------------------------------------
-- Local state
---------------------------------------------------------------------------
local currentDiffIndex: number  = 1
local unlocks: {[string]: boolean} = {}
local isOnPad: boolean          = false
local activePadIndex: number?   = nil
local hasClickedCreate: boolean = false

---------------------------------------------------------------------------
-- Ensure ScreenGui starts hidden properly
-- (Force Enabled=false so it doesn't flash before server tells us to show)
---------------------------------------------------------------------------
lobbyUI.Enabled           = false
createGameFrame.Visible   = false

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
		-- Safe fallback: only Easy unlocked
		unlocks = { Easy = true, Medium = false, Hard = false }
	end
end

---------------------------------------------------------------------------
-- Update difficulty display
---------------------------------------------------------------------------
local function updateDisplay()
	local diff = LobbyConfig.DIFFICULTIES[currentDiffIndex]
	if not diff then return end

	difficultyLabel.Text       = diff.name
	difficultyLabel.TextColor3 = diff.color

	local isUnlocked = (diff.name == "Easy") or (unlocks[diff.name] == true)

	if isUnlocked then
		difficultyPrompt.Visible        = false
		createButton.BackgroundColor3   = LobbyConfig.CREATE_BUTTON_UNLOCKED_COLOR
	else
		difficultyPrompt.Text    = diff.promptText
		difficultyPrompt.Visible = true
		createButton.BackgroundColor3 = LobbyConfig.CREATE_BUTTON_LOCKED_COLOR
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
	-- Enable ScreenGui first — it may be disabled in Studio by default
	lobbyUI.Enabled         = true
	createGameFrame.Visible = true

	-- Reset state
	isOnPad          = true
	activePadIndex   = padIndex
	hasClickedCreate = false
	currentDiffIndex = 1

	-- Reset button visibility and ensure interactivity
	beforeButton.Visible = true
	beforeButton.Active  = true
	nextButton.Visible   = true
	nextButton.Active    = true
	createButton.Visible = true
	createButton.Active  = true
	timerLabel.Visible   = false
	timerLabel.Text      = ""

	refreshUnlocks()
	updateDisplay()

	print("[LobbyUI] Shown for pad", padIndex)
end

local function hideUI()
	createGameFrame.Visible = false
	lobbyUI.Enabled         = false

	isOnPad        = false
	activePadIndex = nil

	print("[LobbyUI] Hidden")
end

---------------------------------------------------------------------------
-- Button connections
---------------------------------------------------------------------------
nextButton.Activated:Connect(nextDifficulty)
beforeButton.Activated:Connect(prevDifficulty)

closeButton.Activated:Connect(function()
	if not isOnPad then return end
	requestCancel:FireServer()
	hideUI()
end)

createButton.Activated:Connect(function()
	print("[LobbyUI] Create clicked | isOnPad:", isOnPad, "| hasClickedCreate:", hasClickedCreate)

	if not isOnPad then
		print("[LobbyUI] Blocked: not on pad")
		return
	end
	if hasClickedCreate then
		print("[LobbyUI] Blocked: already clicked")
		return
	end

	local diff = LobbyConfig.DIFFICULTIES[currentDiffIndex]
	if not diff then
		print("[LobbyUI] Blocked: diff nil at index", currentDiffIndex)
		return
	end

	local isUnlocked = (diff.name == "Easy") or (unlocks[diff.name] == true)
	if not isUnlocked then
		print("[LobbyUI] Blocked: difficulty locked:", diff.name)
		return
	end

	hasClickedCreate = true

	-- Fire to server
	requestCreate:FireServer(diff.name)
	print("[LobbyUI] Fired RequestCreateLobby:", diff.name)

	-- Switch UI to countdown mode
	beforeButton.Visible    = false
	nextButton.Visible      = false
	createButton.Visible    = false
	difficultyPrompt.Visible = false
	timerLabel.Visible      = true
	timerLabel.Text         = LobbyConfig.COUNTDOWN_SECONDS .. "s"
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
