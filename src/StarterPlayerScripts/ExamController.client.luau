--[[
	ExamController.client.luau
	
	Manages the entire Exam UI interaction:
	  • OpenExam button  → shows Exam frame and starts the exam
	  • Timer            → 8-minute countdown in TimerLabel
	  • A / B / C        → toggle answer selection (swaps to *_Selected variants)
	  • ChooseAnswer     → red (no selection) → green (selection made) → locked after click
	  • NextQuestion     → advances to next question after an answer is locked
	  • Auto-end         → when timer hits 0 OR all questions answered
	  • Result           → fires SaveExamResult to server, hides Exam frame
	
	UI hierarchy expected (all inside PlayerGui > ExamUI):
	  ExamUI (ScreenGui)
	    OpenExam (TextButton)
	    Exam (Frame)
	      NameField      (TextLabel)   — player's Nickname attribute
	      QuestionField  (TextLabel)   — question text
	      TimerLabel     (TextLabel)   — "8:00" countdown
	      A              (TextButton)  — option A (unselected)
	      A_Selected     (TextButton)  — option A (selected state)
	      A_Field        (TextLabel)   — option A text
	      B              (TextButton)
	      B_Selected     (TextButton)
	      B_Field        (TextLabel)
	      C              (TextButton)
	      C_Selected     (TextButton)
	      C_Field        (TextLabel)
	      ChooseAnswer   (TextButton)  — red / green / disabled
	      NextQuestion   (TextButton)  — hidden until answer locked
]]

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared            = ReplicatedStorage:WaitForChild("Shared")
local ExamRemotes       = require(Shared:WaitForChild("ExamRemotes"))

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
local EXAM_DURATION_SECONDS = 8 * 60   -- 8 minutes
local COLOR_RED              = Color3.fromRGB(221, 58,  61)
local COLOR_GREEN            = Color3.fromRGB(149, 255, 65)

---------------------------------------------------------------------------
-- UI element discovery (with thorough debug logging)
---------------------------------------------------------------------------
local function waitFor(parent: Instance, name: string, timeout: number?): Instance?
	timeout = timeout or 10
	local inst = parent:WaitForChild(name, timeout)
	if inst then
		print(string.format("[ExamUI] ✓ Found '%s' inside '%s'", name, parent.Name))
	else
		warn(string.format("[ExamUI] ✗ MISSING '%s' inside '%s' (waited %ds)", name, parent.Name, timeout))
	end
	return inst
end

-- Top-level ScreenGui
local examUI = waitFor(playerGui, "ExamUI", 15) :: ScreenGui?
if not examUI then
	error("[ExamController] ExamUI ScreenGui not found in PlayerGui — aborting!")
end

local openExamBtn = waitFor(examUI, "OpenExam") :: TextButton?
local examFrame   = waitFor(examUI, "Exam")     :: Frame?

if not openExamBtn or not examFrame then
	error("[ExamController] OpenExam button or Exam frame missing — aborting!")
end

-- Elements inside the Exam frame
local nameField     = waitFor(examFrame, "NameField")     :: TextLabel?
local questionField = waitFor(examFrame, "QuestionField") :: TextLabel?
local timerLabel    = waitFor(examFrame, "TimerLabel")    :: TextLabel?

local btnA          = waitFor(examFrame, "A")             :: TextButton?
local btnASelected  = waitFor(examFrame, "A_Selected")    :: TextButton?
local fieldA        = waitFor(examFrame, "A_Field")       :: TextLabel?

local btnB          = waitFor(examFrame, "B")             :: TextButton?
local btnBSelected  = waitFor(examFrame, "B_Selected")    :: TextButton?
local fieldB        = waitFor(examFrame, "B_Field")       :: TextLabel?

local btnC          = waitFor(examFrame, "C")             :: TextButton?
local btnCSelected  = waitFor(examFrame, "C_Selected")    :: TextButton?
local fieldC        = waitFor(examFrame, "C_Field")       :: TextLabel?

local chooseAnswerBtn = waitFor(examFrame, "ChooseAnswer")   :: TextButton?
local nextQuestionBtn = waitFor(examFrame, "NextQuestion")   :: TextButton?

-- Verify all mandatory elements are present
local allFound = nameField and questionField and timerLabel
	and btnA and btnASelected and fieldA
	and btnB and btnBSelected and fieldB
	and btnC and btnCSelected and fieldC
	and chooseAnswerBtn and nextQuestionBtn

if not allFound then
	warn("[ExamController] One or more UI elements are MISSING. Exam functionality may be broken.")
	warn("[ExamController] Required: NameField, QuestionField, TimerLabel, A, A_Selected, A_Field, B, B_Selected, B_Field, C, C_Selected, C_Field, ChooseAnswer, NextQuestion")
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
type Question = {q: string, a: string, b: string, c: string, correct: string}

local examActive:       boolean  = false
local questions:        {Question} = {}
local currentIndex:     number   = 1
local selectedAnswer:   string?  = nil  -- "A", "B", or "C"
local answerLocked:     boolean  = false
local score:            number   = 0
local timerThread:      thread?  = nil
local examOpenGuard:    boolean  = false  -- prevents double-open

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function formatTime(seconds: number): string
	seconds = math.max(0, math.round(seconds))
	local m = math.floor(seconds / 60)
	local s = seconds % 60
	return string.format("%d:%02d", m, s)
end

-- Update unselected/selected visibility for one option row
local function setOptionSelected(btn: TextButton?, btnSel: TextButton?, selected: boolean)
	if btn    then btn.Visible    = not selected end
	if btnSel then btnSel.Visible = selected     end
end

-- Reset all three option rows to unselected state
local function clearAllSelections()
	setOptionSelected(btnA, btnASelected, false)
	setOptionSelected(btnB, btnBSelected, false)
	setOptionSelected(btnC, btnCSelected, false)
	selectedAnswer = nil
end

-- Apply the selection for a given letter
local function applySelection(letter: string)
	clearAllSelections()  -- first clear
	selectedAnswer = letter
	if letter == "A" then setOptionSelected(btnA, btnASelected, true) end
	if letter == "B" then setOptionSelected(btnB, btnBSelected, true) end
	if letter == "C" then setOptionSelected(btnC, btnCSelected, true) end
end

-- Update ChooseAnswer button color based on whether an option is selected
local function refreshChooseAnswerColor()
	if not chooseAnswerBtn then return end
	if selectedAnswer ~= nil then
		chooseAnswerBtn.BackgroundColor3 = COLOR_GREEN
		chooseAnswerBtn.Active           = true
	else
		chooseAnswerBtn.BackgroundColor3 = COLOR_RED
		chooseAnswerBtn.Active           = false
	end
end

---------------------------------------------------------------------------
-- Display a question
---------------------------------------------------------------------------
local function displayQuestion(index: number)
	if index > #questions then return end
	local q = questions[index]

	print(string.format("[ExamUI] Displaying question %d/%d", index, #questions))

	-- Reset selection state
	answerLocked = false
	clearAllSelections()
	if chooseAnswerBtn then
		chooseAnswerBtn.BackgroundColor3 = COLOR_RED
		chooseAnswerBtn.Active           = false
		chooseAnswerBtn.Visible          = true
	end
	if nextQuestionBtn then
		nextQuestionBtn.Visible = false
	end

	-- Populate text
	if questionField then
		questionField.Text = string.format("Q%d. %s", index, q.q)
	end
	if fieldA then fieldA.Text = q.a end
	if fieldB then fieldB.Text = q.b end
	if fieldC then fieldC.Text = q.c end
end

---------------------------------------------------------------------------
-- End the exam
---------------------------------------------------------------------------
local function endExam()
	if not examActive then return end
	examActive = false

	-- Kill timer
	if timerThread then
		pcall(task.cancel, timerThread)
		timerThread = nil
	end

	local total = #questions
	print(string.format("[ExamController] Exam ended — score: %d/%d", score, total))

	-- Send to server
	saveExamResult:FireServer(score, total)

	-- Disable all interactive elements
	if chooseAnswerBtn then chooseAnswerBtn.Active = false end
	if nextQuestionBtn then nextQuestionBtn.Visible = false end

	-- Show result in QuestionField as a courtesy (server stores the real %)
	local pct = (total > 0) and math.round((score / total) * 100) or 0
	if questionField then
		questionField.Text = string.format("Exam complete!\nYou got %d/%d (%d%%)", score, total, pct)
	end
	if fieldA then fieldA.Text = "" end
	if fieldB then fieldB.Text = "" end
	if fieldC then fieldC.Text = "" end

	-- Close the exam frame after a short display delay
	task.delay(3, function()
		examFrame.Visible = false
		examOpenGuard     = false
	end)
end

---------------------------------------------------------------------------
-- Start exam
---------------------------------------------------------------------------
local function startExam()
	if examOpenGuard then
		warn("[ExamController] Exam already open — ignoring duplicate open request")
		return
	end
	examOpenGuard = true
	examActive    = false  -- will be set true after questions arrive

	-- Display player Nickname (or Name as fallback)
	local nickname = player:GetAttribute("Nickname")
	if type(nickname) ~= "string" or nickname == "" then
		nickname = player.DisplayName
	end
	if nameField then nameField.Text = nickname end

	-- Show the frame immediately with a loading state
	examFrame.Visible = true
	if questionField   then questionField.Text  = "Loading questions..." end
	if timerLabel      then timerLabel.Text     = "8:00" end
	if fieldA          then fieldA.Text          = "" end
	if fieldB          then fieldB.Text          = "" end
	if fieldC          then fieldC.Text          = "" end
	if chooseAnswerBtn then chooseAnswerBtn.Active = false; chooseAnswerBtn.BackgroundColor3 = COLOR_RED end
	if nextQuestionBtn then nextQuestionBtn.Visible = false end
	clearAllSelections()

	-- Fetch questions from server
	local ok, result = pcall(function()
		return getExamQuestions:InvokeServer()
	end)

	if not ok or type(result) ~= "table" or #result == 0 then
		warn("[ExamController] Failed to get questions from server: " .. tostring(result))
		if questionField then questionField.Text = "Error loading questions.\nPlease try again." end
		examOpenGuard = false
		return
	end

	questions    = result
	currentIndex = 1
	score        = 0
	examActive   = true

	print(string.format("[ExamController] Received %d questions — starting exam", #questions))

	-- Display first question
	displayQuestion(currentIndex)

	-- Start 8-minute countdown timer
	local startTime = os.clock()
	local remaining = EXAM_DURATION_SECONDS

	timerThread = task.spawn(function()
		while examActive do
			remaining = EXAM_DURATION_SECONDS - (os.clock() - startTime)
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

-- OpenExam button (testing trigger)
openExamBtn.MouseButton1Click:Connect(function()
	startExam()
end)

-- Option A
if btnA then
	btnA.MouseButton1Click:Connect(function()
		if not examActive or answerLocked then return end
		if selectedAnswer == "A" then
			-- Deselect
			clearAllSelections()
		else
			applySelection("A")
		end
		refreshChooseAnswerColor()
	end)
end

if btnASelected then
	btnASelected.MouseButton1Click:Connect(function()
		if not examActive or answerLocked then return end
		-- Clicking selected state also deselects
		clearAllSelections()
		refreshChooseAnswerColor()
	end)
end

-- Option B
if btnB then
	btnB.MouseButton1Click:Connect(function()
		if not examActive or answerLocked then return end
		if selectedAnswer == "B" then
			clearAllSelections()
		else
			applySelection("B")
		end
		refreshChooseAnswerColor()
	end)
end

if btnBSelected then
	btnBSelected.MouseButton1Click:Connect(function()
		if not examActive or answerLocked then return end
		clearAllSelections()
		refreshChooseAnswerColor()
	end)
end

-- Option C
if btnC then
	btnC.MouseButton1Click:Connect(function()
		if not examActive or answerLocked then return end
		if selectedAnswer == "C" then
			clearAllSelections()
		else
			applySelection("C")
		end
		refreshChooseAnswerColor()
	end)
end

if btnCSelected then
	btnCSelected.MouseButton1Click:Connect(function()
		if not examActive or answerLocked then return end
		clearAllSelections()
		refreshChooseAnswerColor()
	end)
end

-- ChooseAnswer button — locks the selected answer
if chooseAnswerBtn then
	chooseAnswerBtn.MouseButton1Click:Connect(function()
		if not examActive or answerLocked then return end
		if selectedAnswer == nil then return end  -- guard: should never happen since button is inactive

		answerLocked = true

		-- Check correctness
		local q = questions[currentIndex]
		if q and selectedAnswer == q.correct then
			score = score + 1
			print(string.format("[ExamUI] Q%d CORRECT (answer: %s)", currentIndex, selectedAnswer))
		else
			print(string.format("[ExamUI] Q%d WRONG (selected: %s, correct: %s)", currentIndex, tostring(selectedAnswer), q and q.correct or "?"))
		end

		-- Lock UI — disable ChooseAnswer, show NextQuestion
		chooseAnswerBtn.Active  = false
		chooseAnswerBtn.Visible = false

		if nextQuestionBtn then
			local isLast = (currentIndex >= #questions)
			nextQuestionBtn.Visible = true
			nextQuestionBtn.Text    = isLast and "Finish Exam" or "Next Question"
		end
	end)
end

-- NextQuestion button — advance or end
if nextQuestionBtn then
	nextQuestionBtn.MouseButton1Click:Connect(function()
		if not examActive then return end

		currentIndex = currentIndex + 1
		if currentIndex > #questions then
			endExam()
		else
			displayQuestion(currentIndex)
		end
	end)
end

---------------------------------------------------------------------------
-- Initial state — hide exam frame, show only the OpenExam button
---------------------------------------------------------------------------
examFrame.Visible = false
print("[ExamController] Initialized ✓")
