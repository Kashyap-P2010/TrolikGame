--[[
	ExamController.client.luau

	UI hierarchy (all inside PlayerGui > ExamUI):
	  ExamUI (ScreenGui)
	    OpenExam      (TextButton)              — test trigger
	    Exam           (Frame)
	      Name         (Frame/Container)
	        NameLabel  (TextLabel)              — player Nickname
	      Question     (Frame/Container)
	        Question_Field (TextLabel)          — question text
	      QuestionNo     (TextLabel)            — e.g. "Q: 10/20" (direct child of Exam)
	      A            (TextButton)             — option A unselected
	        Option_A   (TextLabel)              — option A text
	      B            (TextButton)
	        Option_B   (TextLabel)
	      C            (TextButton)
	        Option_C   (TextLabel)
	      A_Selected   (Frame/Button)           — option A selected overlay
	      B_Selected   (Frame/Button)
	      C_Selected   (Frame/Button)
	      ChooseAnswer (TextButton)             — red warning flash only (never interactive)
	      NextQuestion (TextButton)             — always visible; records answer and advances
	      TimerLabel   (TextLabel, CREATED HERE) — "8:00" countdown, screen center-top
]]

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")

local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local ExamRemotes       = require(Shared:WaitForChild("ExamRemotes"))

-- CheatController integration (loaded lazily to avoid circular dependency)
local CheatController = nil
task.defer(function()
	local ok, mod = pcall(function()
		return require(script.Parent:WaitForChild("CheatController", 10))
	end)
	if ok and mod then
		CheatController = mod
		print("[ExamController] CheatController linked ✓")
	else
		warn("[ExamController] CheatController not found — cheats will not work")
	end
end)

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

---------------------------------------------------------------------------
-- Remotes
---------------------------------------------------------------------------
local getExamQuestions = ExamRemotes.get("GetExamQuestions") :: RemoteFunction
local saveExamResult   = ExamRemotes.get("SaveExamResult")   :: RemoteEvent

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local EXAM_DURATION_SECONDS = 8 * 60
local COLOR_RED              = Color3.fromRGB(221, 58, 61)

---------------------------------------------------------------------------
-- UI discovery helpers
---------------------------------------------------------------------------
local function waitFor(parent: Instance, name: string, timeout: number?): Instance?
	local t = timeout or 10
	local inst = parent:WaitForChild(name, t)
	if inst then
		print(string.format("[ExamUI] ✓ '%s' inside '%s'", name, parent.Name))
	else
		warn(string.format("[ExamUI] ✗ MISSING '%s' inside '%s' (waited %ds)", name, parent.Name, t))
	end
	return inst
end

-- Try to find a child label by name; silently returns nil (no warning) for optional items
local function tryFind(parent: Instance?, name: string): TextLabel?
	if not parent then return nil end
	return parent:FindFirstChild(name) :: TextLabel?
end

---------------------------------------------------------------------------
-- Locate top-level containers
---------------------------------------------------------------------------
local examUI = waitFor(playerGui, "ExamUI", 15) :: ScreenGui?
if not examUI then error("[ExamController] ExamUI not found — aborting!") end
examUI.Enabled = true -- Ensure the ScreenGui is enabled!

local timerUI = waitFor(playerGui, "TimerUI", 15) :: ScreenGui?
if timerUI then timerUI.Enabled = true end

local openExamBtn = waitFor(examUI, "OpenExam", 10) :: TextButton?
local examFrame   = waitFor(examUI, "Exam",     10) :: Frame?
if not examFrame then error("[ExamController] Exam frame not found — aborting!") end

---------------------------------------------------------------------------
-- Locate UI elements using CORRECT paths
---------------------------------------------------------------------------

-- Name > NameLabel
local nameContainer = waitFor(examFrame, "Name",     8) :: Instance?
local nameLabel     = nameContainer and waitFor(nameContainer, "NameLabel", 5) :: TextLabel?

-- Question > Question_Field
local questionContainer = waitFor(examFrame, "Question",       8) :: Instance?
local questionField     = questionContainer and waitFor(questionContainer, "Question_Field", 5) :: TextLabel?

-- QuestionNo is a direct child of Exam (not inside Question)
local questionNoLabel   = waitFor(examFrame, "QuestionNo", 8) :: TextLabel?

-- Option buttons (direct children of Exam)
local btnA = waitFor(examFrame, "A", 8) :: TextButton?
local btnB = waitFor(examFrame, "B", 8) :: TextButton?
local btnC = waitFor(examFrame, "C", 8) :: TextButton?

-- Option text labels (children of each button)
local fieldA = btnA and waitFor(btnA, "Option_A", 5) :: TextLabel?
local fieldB = btnB and waitFor(btnB, "Option_B", 5) :: TextLabel?
local fieldC = btnC and waitFor(btnC, "Option_C", 5) :: TextLabel?

-- Selected-state containers (direct children of Exam)
local btnASelected = waitFor(examFrame, "A_Selected", 8) :: Instance?
local btnBSelected = waitFor(examFrame, "B_Selected", 8) :: Instance?
local btnCSelected = waitFor(examFrame, "C_Selected", 8) :: Instance?

-- Optional: option labels inside the Selected states (copy text there if they exist)
local fieldASelected = tryFind(btnASelected, "Option_A")
local fieldBSelected = tryFind(btnBSelected, "Option_B")
local fieldCSelected = tryFind(btnCSelected, "Option_C")

-- Action buttons
local chooseAnswerBtn = waitFor(examFrame, "ChooseAnswer",  8) :: TextButton?
local nextQuestionBtn = waitFor(examFrame, "NextQuestion",  8) :: TextButton?

-- Validate mandatory elements
local missing: {string} = {}
if not nameLabel       then table.insert(missing, "Name > NameLabel") end
if not questionField   then table.insert(missing, "Question > Question_Field") end
if not btnA            then table.insert(missing, "A (button)") end
if not fieldA          then table.insert(missing, "A > Option_A") end
if not btnB            then table.insert(missing, "B (button)") end
if not fieldB          then table.insert(missing, "B > Option_B") end
if not btnC            then table.insert(missing, "C (button)") end
if not fieldC          then table.insert(missing, "C > Option_C") end
if not btnASelected    then table.insert(missing, "A_Selected") end
if not btnBSelected    then table.insert(missing, "B_Selected") end
if not btnCSelected    then table.insert(missing, "C_Selected") end
if not chooseAnswerBtn then table.insert(missing, "ChooseAnswer") end
if not nextQuestionBtn then table.insert(missing, "NextQuestion") end
if not questionNoLabel then table.insert(missing, "Question > QuestionNo") end

if #missing > 0 then
	warn("[ExamController] MISSING UI ELEMENTS — exam may not work correctly:")
	for _, m in missing do
		warn("  • " .. m)
	end
end

---------------------------------------------------------------------------
-- Create TimerLabel programmatically (centered at top of Exam frame)
---------------------------------------------------------------------------
local timerLabel = Instance.new("TextLabel")
timerLabel.Name                   = "TimerLabel"
timerLabel.Size                   = UDim2.new(0.3, 0, 0.07, 0)
timerLabel.Position               = UDim2.new(0.5, 0, 0, 10)
timerLabel.AnchorPoint            = Vector2.new(0.5, 0)
timerLabel.BackgroundTransparency = 1
timerLabel.Font                   = Enum.Font.GothamBold
timerLabel.TextColor3             = Color3.fromRGB(255, 255, 255)
timerLabel.TextScaled             = true
timerLabel.Text                   = "8:00"
timerLabel.ZIndex                 = 10
timerLabel.Parent                 = timerUI or examUI
timerLabel.Visible                = false

local timerStroke          = Instance.new("UIStroke")
timerStroke.Thickness      = 1.9
timerStroke.Color          = Color3.fromRGB(30, 30, 30)
timerStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
timerStroke.Parent          = timerLabel

print("[ExamUI] ✓ TimerLabel created (center-top, UIStroke 1.9)")

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
type Question = {q: string, a: string, b: string, c: string, correct: string}

local examActive:     boolean    = false
local questions:      {Question} = {}
local currentIndex:   number     = 1
local selectedAns:    string?    = nil   -- "A", "B", or "C"
local score:          number     = 0
local timerThread:    thread?    = nil
local examOpenGuard:  boolean    = false
local warnInProgress: boolean    = false  -- prevents spam during 2s red flash
local globalTimerActive: boolean = false
local examCompleted:  boolean    = false
local myPaperPrompt: ProximityPrompt? = nil

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function formatTime(secs: number): string
	secs = math.max(0, math.round(secs))
	return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

local function setVisible(inst: Instance?, v: boolean)
	if inst then (inst :: any).Visible = v end
end

-- Toggle selected overlay (A/B/C buttons NEVER get hidden — text stays visible)
local function setOptionSelected(btn: Instance?, btnSel: Instance?, selected: boolean)
	-- `btn` (A/B/C) is always visible so Option_A/B/C text is never hidden.
	-- `btnSel` (A_Selected etc.) overlays on top as the selection indicator.
	setVisible(btnSel, selected)
end

local function clearAllSelections()
	setOptionSelected(btnA, btnASelected, false)
	setOptionSelected(btnB, btnBSelected, false)
	setOptionSelected(btnC, btnCSelected, false)
	selectedAns = nil
end

local function applySelection(letter: string)
	clearAllSelections()
	selectedAns = letter
	if letter == "A" then setOptionSelected(btnA, btnASelected, true) end
	if letter == "B" then setOptionSelected(btnB, btnBSelected, true) end
	if letter == "C" then setOptionSelected(btnC, btnCSelected, true) end
end


---------------------------------------------------------------------------
-- Display a question
---------------------------------------------------------------------------
local function displayQuestion(index: number)
	if index < 1 or index > #questions then return end
	local q = questions[index]
	print(string.format("[ExamUI] Displaying Q%d/%d: %s", index, #questions, q.q))

	warnInProgress = false
	clearAllSelections()

	-- Notify CheatController of question change
	if CheatController then
		CheatController.setCurrentQuestion(index, #questions)
	end

	-- ChooseAnswer always hidden; NextQuestion always shown
	setVisible(chooseAnswerBtn, false)
	setVisible(nextQuestionBtn, true)

	-- Question counter "Question: X/Y"
	if questionNoLabel then
		questionNoLabel.Text = string.format("Question: %d/%d", index, #questions)
	end

	-- Question text (no number prefix — QuestionNo handles that)
	if questionField then
		questionField.Text = q.q
	end

	-- Option texts
	if fieldA then fieldA.Text = q.a end
	if fieldB then fieldB.Text = q.b end
	if fieldC then fieldC.Text = q.c end

	if fieldASelected then fieldASelected.Text = q.a end
	if fieldBSelected then fieldBSelected.Text = q.b end
	if fieldCSelected then fieldCSelected.Text = q.c end

	-- Reset all options to visible (in case Choice Eraser hid one previously)
	if btnA then btnA.Visible = true end
	if btnB then btnB.Visible = true end
	if btnC then btnC.Visible = true end

	-- Apply Choice Eraser effect (hide one wrong option)
	if CheatController then
		local erased = CheatController.getErasedOption()
		if erased then
			if erased == "A" and btnA then btnA.Visible = false end
			if erased == "B" and btnB then btnB.Visible = false end
			if erased == "C" and btnC then btnC.Visible = false end
		end

		-- Apply Smart Glasses / Genius Potion highlight effect
		local highlighted = CheatController.getHighlightedAnswer(index)
		if highlighted then
			-- Add a green glow border to the correct answer button
			local targetBtn = (highlighted == "A" and btnA) or (highlighted == "B" and btnB) or (highlighted == "C" and btnC)
			if targetBtn then
				-- Remove any previous highlight strokes
				for _, child in targetBtn:GetChildren() do
					if child.Name == "CheatHighlight" then child:Destroy() end
				end
				local highlightStroke = Instance.new("UIStroke")
				highlightStroke.Name = "CheatHighlight"
				highlightStroke.Thickness = 3
				highlightStroke.Color = Color3.fromRGB(0, 255, 100)
				highlightStroke.Parent = targetBtn
			end
		end
	end
end

---------------------------------------------------------------------------
-- End the exam
---------------------------------------------------------------------------
local function endExam()
	if not examActive and not globalTimerActive then return end
	examActive = false
	globalTimerActive = false

	-- Notify CheatController that exam ended
	if CheatController then
		CheatController.setExamActive(false)
	end

	if timerThread then
		pcall(task.cancel, timerThread)
		timerThread = nil
	end

	local total = #questions
	local pct   = (total > 0) and math.round((score / total) * 100) or 0
	print(string.format("[ExamController] Exam over — %d/%d (%d%%)", score, total, pct))

	saveExamResult:FireServer(score, total)

	if chooseAnswerBtn then chooseAnswerBtn.Visible = false end
	setVisible(nextQuestionBtn, false)

	if questionField then
		questionField.Text = string.format("Exam complete!\n%d / %d correct (%d%%)", score, total, pct)
	end
	if fieldA then fieldA.Text = "" end
	if fieldB then fieldB.Text = "" end
	if fieldC then fieldC.Text = "" end

	-- Hide after 3 seconds
	task.delay(3, function()
		if examFrame then examFrame.Visible = false end
		if timerLabel then timerLabel.Visible = false end
		
		-- Destroy prompt and button permanently
		if myPaperPrompt then
			myPaperPrompt:Destroy()
			myPaperPrompt = nil
		end
		if openExamBtn then
			openExamBtn.Visible = false
		end
		
		examCompleted = true
	end)
end

---------------------------------------------------------------------------
-- Start the exam
---------------------------------------------------------------------------
local function startExam()
	if examCompleted or examOpenGuard then
		warn("[ExamController] Exam already open or completed — ignoring duplicate")
		return
	end
	examOpenGuard = true
	examActive    = false

	-- Fill player Nickname
	local nickname: string = player:GetAttribute("Nickname") or ""
	if nickname == "" then nickname = player.DisplayName end
	if nameLabel then nameLabel.Text = nickname end

	-- Show frame with loading state
	examFrame.Visible = true
	
	-- Hide prompt since UI is open
	if myPaperPrompt then
		myPaperPrompt.Enabled = false
	end
	
	if openExamBtn then
		openExamBtn.Visible = true
		openExamBtn.Text = "Close Exam UI"
	end
	if questionField   then questionField.Text = "Loading questions..." end
	if timerLabel      then timerLabel.Text    = "8:00" end
	if fieldA          then fieldA.Text        = "" end
	if fieldB          then fieldB.Text        = "" end
	if fieldC          then fieldC.Text        = "" end
	setVisible(chooseAnswerBtn, false)
	setVisible(nextQuestionBtn, false)
	clearAllSelections()

	-- Request questions from server
	local ok, result = pcall(function()
		return getExamQuestions:InvokeServer()
	end)

	if not ok or type(result) ~= "table" or #result == 0 then
		warn("[ExamController] Failed to get questions: " .. tostring(result))
		if questionField then questionField.Text = "Error loading questions.\nPlease try again." end
		examOpenGuard = false
		return
	end

	questions    = result
	currentIndex = 1
	score        = 0
	examActive   = true

	-- Notify CheatController that exam is active
	if CheatController then
		CheatController.setExamActive(true)
	end

	print(string.format("[ExamController] Got %d questions — exam starts!", #questions))
	displayQuestion(currentIndex)
end

---------------------------------------------------------------------------
-- Global Timer Logic
---------------------------------------------------------------------------
local function startGlobalTimer()
	if examCompleted or globalTimerActive then return end
	globalTimerActive = true
	
	print("[ExamController] Global timer started (8 minutes)!")
	if timerLabel then timerLabel.Visible = true end
	
	-- Make the ProximityPrompt visible now that the exam period has begun!
	if myPaperPrompt and not examFrame.Visible then
		myPaperPrompt.Enabled = true
	end
	
	local startTime = os.clock()
	timerThread = task.spawn(function()
		while globalTimerActive do
			local remaining = EXAM_DURATION_SECONDS - (os.clock() - startTime)
			if remaining <= 0 then
				if timerLabel then timerLabel.Text = "0:00" end
				endExam()
				break
			end
			if timerLabel then timerLabel.Text = formatTime(remaining) end
			task.wait(1)
		end
	end)
end

---------------------------------------------------------------------------
-- Button connections
---------------------------------------------------------------------------

-- UI Visibility Toggling
local function toggleExamUI()
	if not examActive or examCompleted then return end
	examFrame.Visible = not examFrame.Visible
	
	if openExamBtn then
		openExamBtn.Text = examFrame.Visible and "Close Exam UI" or "Open Exam UI"
	end
	
	-- Toggle prompt based on UI visibility
	if myPaperPrompt then
		myPaperPrompt.Enabled = not examFrame.Visible
	end
end

-- OpenExam button now acts as a toggle instead of starting the exam
if openExamBtn then
	openExamBtn.Visible = false -- Hidden until exam actually starts
	openExamBtn.MouseButton1Click:Connect(toggleExamUI)
end

-- E to toggle (Only works AFTER exam starts)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or examCompleted then return end
	if input.KeyCode == Enum.KeyCode.E then
		toggleExamUI()
	end
end)

-- Auto-start the GLOBAL TIMER 5 seconds after sitting in a valid seat
local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid then
		humanoid.Seated:Connect(function(isSeated, seatPart)
			if isSeated and seatPart then
				local seatNum = string.match(seatPart.Name, "^Seat(%d+)$")
				if seatNum then
					if not globalTimerActive and not examCompleted then
						print(string.format("[ExamController] Seated in %s! Timer starts in 5 seconds...", seatPart.Name))
						task.delay(5, function()
							if not globalTimerActive and not examCompleted then
								-- Find their specific paper
								local papersFolder = Workspace:FindFirstChild("Papers")
								if papersFolder then
									local myPaper = papersFolder:FindFirstChild("Paper" .. seatNum)
									if myPaper and myPaper:IsA("BasePart") then
										-- Create the prompt ONLY for their paper
										local prompt = Instance.new("ProximityPrompt")
										prompt.ActionText = "Open Paper"
										prompt.KeyboardKeyCode = Enum.KeyCode.E
										prompt.HoldDuration = 0
										prompt.MaxActivationDistance = 6
										prompt.RequiresLineOfSight = false
										prompt.Parent = myPaper
										
										myPaperPrompt = prompt
										
										prompt.Triggered:Connect(function(playerWhoTriggered)
											if playerWhoTriggered == player then
												if not examActive and not examOpenGuard then
													print("[ExamController] Exam started via ProximityPrompt on " .. myPaper.Name)
													startExam()
												elseif examActive then
													-- If exam is already active, just open the UI
													if not examFrame.Visible then
														toggleExamUI()
													end
												end
											end
										end)
									else
										warn("[ExamController] Could not find Paper" .. seatNum .. " in Workspace.Papers!")
									end
								end
								
								startGlobalTimer()
							end
						end)
					end
				end
			end
		end)
	end
end

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

-- Darken a color by reducing HSV value component
local function darkenColor(c: Color3, factor: number): Color3
	local h, s, v = Color3.toHSV(c)
	return Color3.fromHSV(h, s, math.max(0, v * factor))
end

-- Attach hover effect to an option button (and its inner option text)
local function addHoverEffect(btn: TextButton?)
	if not btn then return end
	local origBgColor    = btn.BackgroundColor3
	local origBgTransp   = btn.BackgroundTransparency
	local origTextColor  = btn.TextColor3
	
	local optLabel       = btn:FindFirstChildWhichIsA("TextLabel")
	local origOptColor   = optLabel and optLabel.TextColor3

	local hoverBgColor   = Color3.fromHex("#d9d9d9")
	local hoverTextColor = Color3.fromRGB(255, 255, 255)

	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3       = hoverBgColor
		btn.TextColor3             = hoverTextColor
		if origBgTransp < 0.9 then
			btn.BackgroundTransparency = math.max(0, origBgTransp - 0.08)
		end
		if optLabel then
			optLabel.TextColor3 = hoverTextColor
		end
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3       = origBgColor
		btn.TextColor3             = origTextColor
		btn.BackgroundTransparency = origBgTransp
		if optLabel and origOptColor then
			optLabel.TextColor3 = origOptColor
		end
	end)
end

addHoverEffect(btnA)
addHoverEffect(btnB)
addHoverEffect(btnC)

-- Generic option handler — just toggle selection, no button state change needed
local function onOptionClicked(letter: string)
	if not examActive then return end
	if selectedAns == letter then
		clearAllSelections()   -- deselect (toggle off)
	else
		applySelection(letter)
	end
end

-- A button (unselected state)
if btnA then
	btnA.MouseButton1Click:Connect(function() onOptionClicked("A") end)
end

-- A_Selected — clicking it again deselects
if btnASelected then
	local btn = btnASelected:FindFirstChildWhichIsA("TextButton")
	local target: Instance? = (btnASelected:IsA("TextButton") and btnASelected) or btn
	if target then
		(target :: TextButton).MouseButton1Click:Connect(function()
			if not examActive then return end
			clearAllSelections()
		end)
	end
end

-- B button
if btnB then
	btnB.MouseButton1Click:Connect(function() onOptionClicked("B") end)
end
if btnBSelected then
	local btn = btnBSelected:FindFirstChildWhichIsA("TextButton")
	local target: Instance? = (btnBSelected:IsA("TextButton") and btnBSelected) or btn
	if target then
		(target :: TextButton).MouseButton1Click:Connect(function()
			if not examActive then return end
			clearAllSelections()
		end)
	end
end

-- C button
if btnC then
	btnC.MouseButton1Click:Connect(function() onOptionClicked("C") end)
end
if btnCSelected then
	local btn = btnCSelected:FindFirstChildWhichIsA("TextButton")
	local target: Instance? = (btnCSelected:IsA("TextButton") and btnCSelected) or btn
	if target then
		(target :: TextButton).MouseButton1Click:Connect(function()
			if not examActive then return end
			clearAllSelections()
		end)
	end
end

-- ChooseAnswer — no click handler. It is ONLY used as a 2-second red warning flash.
-- (Setting Active=false and never hooking up a click handler is sufficient.)
if chooseAnswerBtn then
	chooseAnswerBtn.Active = false
end

-- NextQuestion
--   • No selection → flash ChooseAnswer RED for 2s as a "you must pick an option" warning
--   • Option selected → record answer, advance to next question / finish
if nextQuestionBtn then
	nextQuestionBtn.MouseButton1Click:Connect(function()
		if not examActive then return end

		-- No option selected — warn the player
		if selectedAns == nil then
			if warnInProgress then return end
			warnInProgress = true

			setVisible(nextQuestionBtn, false)
			if chooseAnswerBtn then
				chooseAnswerBtn.BackgroundColor3 = COLOR_RED
				chooseAnswerBtn.Active           = false
				chooseAnswerBtn.Visible          = true
			end
			task.delay(2, function()
				if not examActive then return end
				setVisible(chooseAnswerBtn, false)
				setVisible(nextQuestionBtn, true)
				warnInProgress = false
			end)
			return
		end

		-- Option was selected — record and advance
		local q = questions[currentIndex]
		if q and selectedAns == q.correct then
			score = score + 1
			print(string.format("[ExamUI] Q%d CORRECT (%s)", currentIndex, selectedAns))
		else
			print(string.format("[ExamUI] Q%d WRONG (selected: %s, correct: %s)",
				currentIndex, tostring(selectedAns), q and q.correct or "?"))
		end

		currentIndex += 1
		if currentIndex > #questions then
			endExam()
		else
			displayQuestion(currentIndex)
		end
	end)
end

---------------------------------------------------------------------------
-- Initial state
---------------------------------------------------------------------------
examFrame.Visible = false
timerLabel.Visible = false
print("[ExamController] Initialized ✓")
