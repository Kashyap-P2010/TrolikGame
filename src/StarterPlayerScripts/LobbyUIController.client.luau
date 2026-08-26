--[[
	LobbyUIController — Client-side lobby creation UI.

	UI hierarchy (exact Studio names):
	  StarterGui
	    └─ LobbyUI (ScreenGui)
	         └─ CreateGame (Frame)
	              ├─ Topbar (Frame)
	              │    └─ TextButton  (X / close)  ← cancels during Creating state
	              ├─ Before          (ImageButton)
	              ├─ Next            (ImageButton)
	              ├─ CreateBtn       (TextButton)   ← green=clickable, grey=locked
	              ├─ Leave           (TextButton)   ← red, shown only in Active state
	              ├─ Difficulty      (TextLabel)    ← "Easy"/"Medium"/"Hard" + color
	              └─ DifficultyLabel (TextLabel)    ← "Score 70%..." lock prompt

	Programmatic additions (created if missing from Studio):
	  • CreationTimerLabel — AFK countdown at the top of CreateGame
	  • Timer              — Active-lobby countdown (below CreateBtn)
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")

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
local requestEnter        = LobbyRemotes.get("RequestEnterPad")
local requestCreate       = LobbyRemotes.get("RequestCreateLobby")
local requestCancel       = LobbyRemotes.get("RequestCancelLobby")   -- Creating state (X button)
local requestLeave        = LobbyRemotes.get("RequestLeaveLobby")    -- Active state (Leave button)
local showUIRemote        = LobbyRemotes.get("ShowLobbyUI")
local showExitRemote      = LobbyRemotes.get("ShowExitButton")
local timerRemote         = LobbyRemotes.get("UpdateTimer")
local creationTimerRemote = LobbyRemotes.get("UpdateCreationTimer")
local getUnlocks          = LobbyRemotes.get("GetDifficultyUnlocks")

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
local createButton    = createGameFrame:WaitForChild("CreateBtn") :: TextButton
local leaveButton     = createGameFrame:WaitForChild("Leave")     :: TextButton  -- red exit button
local difficultyLabel = createGameFrame:WaitForChild("Difficulty")       -- "Easy"/"Medium"/"Hard"
local difficultyPrompt= createGameFrame:WaitForChild("DifficultyLabel")  -- lock message

---------------------------------------------------------------------------
-- AFK / creation timer label
-- Studio label: CreateGame > Topbar > TimerLabel
-- Text format: " ⌛ 22s" in red
---------------------------------------------------------------------------
local creationTimerLabel = topBar:FindFirstChild("TimerLabel")
if not creationTimerLabel then
	-- Fallback: create it programmatically if Studio label missing
	creationTimerLabel = Instance.new("TextLabel")
	creationTimerLabel.Name                   = "TimerLabel"
	creationTimerLabel.Size                   = UDim2.new(0.25, 0, 1, 0)
	creationTimerLabel.Position               = UDim2.new(0.55, 0, 0, 0)
	creationTimerLabel.AnchorPoint            = Vector2.new(0, 0)
	creationTimerLabel.BackgroundTransparency = 1
	creationTimerLabel.Font                   = Enum.Font.GothamBold
	creationTimerLabel.TextColor3             = Color3.fromRGB(255, 255, 255)
	creationTimerLabel.TextScaled             = true
	creationTimerLabel.Text                   = ""
	creationTimerLabel.Visible                = false
	creationTimerLabel.ZIndex                 = 10
	creationTimerLabel.Parent                 = topBar
end
-- Force white text
creationTimerLabel.TextColor3 = Color3.fromRGB(255, 255, 255)

---------------------------------------------------------------------------
-- Active-lobby countdown label (below CreateBtn)
---------------------------------------------------------------------------
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
-- Colors for Create button
---------------------------------------------------------------------------
local COLOR_UNLOCKED = LobbyConfig.CREATE_BUTTON_UNLOCKED_COLOR  -- green
local COLOR_LOCKED   = LobbyConfig.CREATE_BUTTON_LOCKED_COLOR    -- grey
local COLOR_HOVER    = Color3.fromRGB(0, 210, 0)
local COLOR_PRESSED  = Color3.fromRGB(0, 170, 0)

-- Colors for Leave button (red palette matching its Studio color)
local LEAVE_BASE_COLOR    = leaveButton.BackgroundColor3          -- use whatever you set in Studio
local LEAVE_HOVER_COLOR   = Color3.fromRGB(
	math.min(LEAVE_BASE_COLOR.R * 255 + 30, 255),
	math.max(LEAVE_BASE_COLOR.G * 255 - 10, 0),
	math.max(LEAVE_BASE_COLOR.B * 255 - 10, 0)
)
local LEAVE_PRESSED_COLOR = Color3.fromRGB(
	math.max(LEAVE_BASE_COLOR.R * 255 - 40, 0),
	math.max(LEAVE_BASE_COLOR.G * 255 - 20, 0),
	math.max(LEAVE_BASE_COLOR.B * 255 - 20, 0)
)

---------------------------------------------------------------------------
-- Tween helpers
---------------------------------------------------------------------------
local TWEEN_HOVER_IN  = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_HOVER_OUT = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_PRESS     = TweenInfo.new(0.07, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_RELEASE   = TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local CREATE_BASE_SIZE = createButton.Size
local LEAVE_BASE_SIZE  = leaveButton.Size

local activeTween: Tween? = nil
local function tweenCreate(info: TweenInfo, props: {[string]: any})
	if activeTween then activeTween:Cancel() end
	activeTween = TweenService:Create(createButton, info, props)
	activeTween:Play()
end

local activeLeave: Tween? = nil
local function tweenLeave(info: TweenInfo, props: {[string]: any})
	if activeLeave then activeLeave:Cancel() end
	activeLeave = TweenService:Create(leaveButton, info, props)
	activeLeave:Play()
end

---------------------------------------------------------------------------
-- Local state
---------------------------------------------------------------------------
local currentDiffIndex: number     = 1
local unlocks: {[string]: boolean} = {}
local isOnPad: boolean             = false
local activePadIndex: number?      = nil
local hasClickedCreate: boolean    = false
local isCurrentlyUnlocked: boolean = false
local isInActiveLobby: boolean     = false  -- true after Create; controls Leave button

-- Cache frame appearance values once at load time so we can restore them
local FRAME_ORIG_BG_ALPHA  = createGameFrame.BackgroundTransparency
local FRAME_ORIG_BORDER    = createGameFrame.BorderSizePixel
local FRAME_UISTROKE       = createGameFrame:FindFirstChildOfClass("UIStroke")

lobbyUI.Enabled         = true
createGameFrame.Visible = false
leaveButton.Visible     = false   -- hidden until server says show

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
-- Update difficulty display + Create button state
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
		createButton.Active           = true
	else
		difficultyPrompt.Text         = diff.promptText
		difficultyPrompt.Visible      = true
		createButton.BackgroundColor3 = COLOR_LOCKED
		createButton.Active           = false
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
-- Show / hide the Creating-state UI (CreateGame frame)
---------------------------------------------------------------------------
local function showUI(padIndex: number)
	createGameFrame.Visible = true

	isOnPad          = true
	activePadIndex   = padIndex
	hasClickedCreate = false
	isInActiveLobby  = false
	currentDiffIndex = 1

	-- Creating-state controls
	beforeButton.Visible   = true
	beforeButton.Active    = true
	nextButton.Visible     = true
	nextButton.Active      = true
	createButton.Visible   = true
	createButton.Size      = CREATE_BASE_SIZE
	difficultyLabel.Visible = true  -- restore after showLeaveButton hid it

	-- Leave button stays inside CreateGame and is hidden during Creating
	leaveButton.Visible = false

	-- Creation AFK timer: show immediately with full time
	creationTimerLabel.Text    = "(" .. tostring(LobbyConfig.CREATION_TIMEOUT_SECONDS) .. "s)"
	creationTimerLabel.Visible = true

	timerLabel.Visible = false
	timerLabel.Text    = ""

	refreshUnlocks()
	updateDisplay()

	print("[LobbyUI] Shown for pad", padIndex)
end

local function hideUI()
	createGameFrame.Visible    = false
	isOnPad                    = false
	activePadIndex             = nil
	isInActiveLobby            = false
	creationTimerLabel.Visible = false
	creationTimerLabel.Text    = ""
	print("[LobbyUI] Hidden")
end

---------------------------------------------------------------------------
-- Show / hide the Leave button (Active-state only)
-- Strategy: keep CreateGame visible but make it fully invisible
-- (transparent background, zero border, disabled UIStroke, hidden Topbar)
-- so ONLY the Leave button is rendered inside it.
---------------------------------------------------------------------------
local function showLeaveButton()
	isInActiveLobby = true

	-- Strip the frame's visible chrome completely
	createGameFrame.BackgroundTransparency = 1
	createGameFrame.BorderSizePixel        = 0
	if FRAME_UISTROKE then FRAME_UISTROKE.Enabled = false end
	topBar.Visible = false

	-- Hide all creating-state controls
	beforeButton.Visible       = false
	nextButton.Visible         = false
	createButton.Visible       = false
	difficultyLabel.Visible    = false
	difficultyPrompt.Visible   = false
	creationTimerLabel.Visible = false

	-- Use the frame as an invisible container and show Leave
	createGameFrame.Visible = true
	leaveButton.Visible     = true
	leaveButton.Size        = LEAVE_BASE_SIZE
end

local function hideLeaveButton()
	isInActiveLobby     = false
	activePadIndex      = nil
	leaveButton.Visible = false

	-- Restore frame appearance
	createGameFrame.BackgroundTransparency = FRAME_ORIG_BG_ALPHA
	createGameFrame.BorderSizePixel        = FRAME_ORIG_BORDER
	if FRAME_UISTROKE then FRAME_UISTROKE.Enabled = true end
	topBar.Visible = true

	-- Close the frame unless the Creating UI needs it open
	if not isOnPad then
		createGameFrame.Visible = false
	end
end

---------------------------------------------------------------------------
-- Create button hover & click animations
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
	tweenCreate(TWEEN_RELEASE, {
		BackgroundColor3 = COLOR_HOVER,
		Size = UDim2.new(
			CREATE_BASE_SIZE.X.Scale * 1.04, CREATE_BASE_SIZE.X.Offset,
			CREATE_BASE_SIZE.Y.Scale * 1.08, CREATE_BASE_SIZE.Y.Offset
		),
	})
end)

---------------------------------------------------------------------------
-- Leave button hover & click animations
---------------------------------------------------------------------------
leaveButton.MouseEnter:Connect(function()
	if not isInActiveLobby then return end
	tweenLeave(TWEEN_HOVER_IN, {
		BackgroundColor3 = LEAVE_HOVER_COLOR,
		Size = UDim2.new(
			LEAVE_BASE_SIZE.X.Scale * 1.04, LEAVE_BASE_SIZE.X.Offset,
			LEAVE_BASE_SIZE.Y.Scale * 1.08, LEAVE_BASE_SIZE.Y.Offset
		),
	})
end)

leaveButton.MouseLeave:Connect(function()
	if not isInActiveLobby then return end
	tweenLeave(TWEEN_HOVER_OUT, {
		BackgroundColor3 = LEAVE_BASE_COLOR,
		Size             = LEAVE_BASE_SIZE,
	})
end)

leaveButton.MouseButton1Down:Connect(function()
	if not isInActiveLobby then return end
	tweenLeave(TWEEN_PRESS, {
		BackgroundColor3 = LEAVE_PRESSED_COLOR,
		Size = UDim2.new(
			LEAVE_BASE_SIZE.X.Scale * 0.96, LEAVE_BASE_SIZE.X.Offset,
			LEAVE_BASE_SIZE.Y.Scale * 0.93, LEAVE_BASE_SIZE.Y.Offset
		),
	})
end)

leaveButton.MouseButton1Up:Connect(function()
	if not isInActiveLobby then return end
	tweenLeave(TWEEN_RELEASE, {
		BackgroundColor3 = LEAVE_HOVER_COLOR,
		Size = UDim2.new(
			LEAVE_BASE_SIZE.X.Scale * 1.04, LEAVE_BASE_SIZE.X.Offset,
			LEAVE_BASE_SIZE.Y.Scale * 1.08, LEAVE_BASE_SIZE.Y.Offset
		),
	})
end)

---------------------------------------------------------------------------
-- Button connections
---------------------------------------------------------------------------
nextButton.MouseButton1Click:Connect(nextDifficulty)
beforeButton.MouseButton1Click:Connect(prevDifficulty)

-- X / close — cancel during Creating state only
closeButton.MouseButton1Click:Connect(function()
	if not isOnPad then return end
	requestCancel:FireServer()
	hideUI()
end)

-- Leave — exit during Active state (owner or joiner)
leaveButton.MouseButton1Click:Connect(function()
	if not isInActiveLobby then return end
	requestLeave:FireServer()
	hideLeaveButton()
	-- Also fully hide the CreateGame frame since we're leaving
	createGameFrame.Visible = false
end)

-- Create button
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

	-- Snap button back to base state before hiding
	if activeTween then activeTween:Cancel() end
	createButton.Size             = CREATE_BASE_SIZE
	createButton.BackgroundColor3 = COLOR_UNLOCKED

	requestCreate:FireServer(diff.name)
	print("[LobbyUI] Fired RequestCreateLobby:", diff.name)

	-- Hide the CreateGame UI — server will fire ShowExitButton when Active
	hideUI()
end)

---------------------------------------------------------------------------
-- Server → Client events
---------------------------------------------------------------------------

-- Show/hide the Creating-state UI (ShowLobbyUI)
showUIRemote.OnClientEvent:Connect(function(show: boolean, padIndex: number?)
	if show then
		showUI(padIndex or 0)
	else
		hideUI()
	end
end)

-- Show/hide the Leave button (ShowExitButton) — fired when lobby goes Active or resets
showExitRemote.OnClientEvent:Connect(function(show: boolean, padIndex: number?)
	if show then
		if padIndex then
			activePadIndex = padIndex
		end
		showLeaveButton()
	else
		hideLeaveButton()
	end
end)

-- Active-lobby countdown ticks
timerRemote.OnClientEvent:Connect(function(padIndex: number, remaining: number)
	if activePadIndex ~= nil and activePadIndex ~= padIndex then return end
	if not timerLabel.Visible then return end
	timerLabel.Text = remaining .. "s"
end)

-- AFK / creation countdown ticks
creationTimerRemote.OnClientEvent:Connect(function(padIndex: number, remaining: number)
	if not isOnPad then return end
	if activePadIndex ~= nil and activePadIndex ~= padIndex then return end

	creationTimerLabel.Visible = true
	creationTimerLabel.Text    = "(" .. remaining .. "s)"
end)

---------------------------------------------------------------------------
-- Client-side boundary tether
-- Guarantees local player cannot walk outside pad borders while creating or waiting.
---------------------------------------------------------------------------
local clientPadParts: { [number]: BasePart } = {}
task.spawn(function()
	local padsFolder = workspace:WaitForChild("LobbyPads", 10)
	if not padsFolder then return end

	for i = 1, LobbyConfig.PAD_COUNT do
		local pad = padsFolder:WaitForChild("Pad" .. i, 5)
		if pad and pad:IsA("BasePart") then
			clientPadParts[i] = pad
			-- Instant local touch detection on floor pad
			pad.Touched:Connect(function(hit)
				local char = hit:FindFirstAncestorOfClass("Model")
				if char == player.Character and not isOnPad and not isInActiveLobby then
					requestEnter:FireServer(i)
				end
			end)
		end

		-- Instant local touch detection on border walls
		local borderModel = padsFolder:WaitForChild("InvisBorder" .. i, 5)
		if borderModel then
			for _, part in borderModel:GetDescendants() do
				if part:IsA("BasePart") then
					part.Touched:Connect(function(hit)
						local char = hit:FindFirstAncestorOfClass("Model")
						if char == player.Character and not isOnPad and not isInActiveLobby then
							requestEnter:FireServer(i)
						end
					end)
				end
			end
		end
	end
end)

RunService.Heartbeat:Connect(function()
	if not (isOnPad or isInActiveLobby) then return end
	if not activePadIndex then return end

	local pad = clientPadParts[activePadIndex]
	if not pad then return end

	local char = player.Character
	if not char then return end

	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local localPos = pad.CFrame:PointToObjectSpace(hrp.Position)
	local halfX = math.max((pad.Size.X / 2) - 0.5, 1)
	local halfZ = math.max((pad.Size.Z / 2) - 0.5, 1)

	local clampedX = math.clamp(localPos.X, -halfX, halfX)
	local clampedZ = math.clamp(localPos.Z, -halfZ, halfZ)

	if clampedX ~= localPos.X or clampedZ ~= localPos.Z then
		local correctedPos = pad.CFrame:PointToWorldSpace(Vector3.new(clampedX, localPos.Y, clampedZ))
		hrp.CFrame = CFrame.new(correctedPos) * (hrp.CFrame - hrp.Position)
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
	end
end)

print("[LobbyUIController] Client initialized")
