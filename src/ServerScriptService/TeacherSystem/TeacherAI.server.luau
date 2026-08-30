--[[
	TeacherAI.server.luau
	Controls the state machine, pathfinding, and vision checks for the Teacher.
	Includes extensive debugging and race condition prevention.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")

local TeacherSettings = require(script.Parent:WaitForChild("TeacherSettings"))

---------------------------------------------------------------------------
-- Debugging Setup
---------------------------------------------------------------------------
local DEBUG_MODE = true
local function debugLog(...)
	if DEBUG_MODE then
		print("[TeacherAI_DEBUG]", ...)
	end
end

debugLog("Initializing TeacherAI script...")

---------------------------------------------------------------------------
-- References & Setup
---------------------------------------------------------------------------
local teacher = Workspace:WaitForChild("Teacher_Rig", 60)
if not teacher then 
	warn("[TeacherAI_ERROR] Teacher_Rig model not found after 60s!") 
	return 
end

debugLog("Found Teacher_Rig. Waiting for core parts...")
local humanoid = teacher:WaitForChild("Humanoid", 10) :: Humanoid
local head = teacher:WaitForChild("Head", 10) :: Part
local rootPart = teacher:WaitForChild("HumanoidRootPart", 10) :: Part

if not humanoid or not head or not rootPart then
	warn("[TeacherAI_ERROR] Missing critical rig components (Humanoid, Head, or HumanoidRootPart).")
	return
end
debugLog("Core parts loaded successfully.")

-- IMPORTANT: Unanchor everything so the Humanoid can physically move!
for _, desc in ipairs(teacher:GetDescendants()) do
	if desc:IsA("BasePart") then
		desc.Anchored = false
	end
end
rootPart.Anchored = false

-- Custom rigs often have HipHeight = 0 by default, causing them to get stuck in the floor.
-- The user will tune this in Studio manually.
if humanoid.HipHeight <= 0 then
	warn("[TeacherAI_WARNING] Teacher's HipHeight is 0! If he gets stuck in the floor, please manually increase Humanoid.HipHeight in the model.")
end

---------------------------------------------------------------------------
-- Script-Side Rig Orientation Fix (Crabwalking Fix)
---------------------------------------------------------------------------
-- Since the builder's rig has the HumanoidRootPart rotated sideways relative to the mesh, 
-- Humanoid.AutoRotate will make him walk sideways. This overrides AutoRotate and manually 
-- aligns the rig correctly based on the offset in TeacherSettings.
local function fixCrabWalking()
	debugLog("Applying script-side crabwalking fix...")
	local attachment = rootPart:FindFirstChild("CrabwalkAtt") or Instance.new("Attachment", rootPart)
	attachment.Name = "CrabwalkAtt"
	
	local alignOri = rootPart:FindFirstChild("CrabwalkOri") or Instance.new("AlignOrientation", rootPart)
	alignOri.Name = "CrabwalkOri"
	alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.Attachment0 = attachment
	alignOri.MaxTorque = 10000000
	alignOri.Responsiveness = 40
	
	humanoid.AutoRotate = false
	
	-- Default to where he's currently facing
	local currentLookDir = rootPart.CFrame.LookVector
	
	RunService.Heartbeat:Connect(function()
		if not rootPart or not rootPart.Parent then return end
		
		-- Update look direction only if he's actually trying to walk somewhere
		if humanoid.MoveDirection.Magnitude > 0.05 then
			currentLookDir = Vector3.new(humanoid.MoveDirection.X, 0, humanoid.MoveDirection.Z).Unit
		end
		
		if currentLookDir.Magnitude > 0.05 then
			local offset = CFrame.Angles(0, math.rad(TeacherSettings.RIG_ROTATION_OFFSET_Y), 0)
			alignOri.CFrame = CFrame.lookAt(Vector3.zero, currentLookDir) * offset
		end
	end)
end
task.spawn(fixCrabWalking)

local waypointsFolder = Workspace:WaitForChild("TeacherWaypoints", 60)
if not waypointsFolder then 
	warn("[TeacherAI_ERROR] TeacherWaypoints folder not found in Workspace!") 
end

---------------------------------------------------------------------------
-- Asset Loading & Animations
---------------------------------------------------------------------------
local ANIMATIONS = {
	IDLE = "rbxassetid://98820429377987",
	WALK = "rbxassetid://75525743234669",
	LOOK = "rbxassetid://88647926841758" -- arms_crossed
}

local animator = humanoid:FindFirstChildOfClass("Animator")
if not animator then
	debugLog("No Animator found in Humanoid. Creating one...")
	animator = Instance.new("Animator")
	animator.Parent = humanoid
end

local loadedTracks: {[string]: AnimationTrack} = {}

local function loadAnimations()
	debugLog("Starting animation preload sequence...")
	local assetsToPreload = {}
	
	for name, id in pairs(ANIMATIONS) do
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		table.insert(assetsToPreload, anim)
		
		local success, track = pcall(function() return animator:LoadAnimation(anim) end)
		if success and track then
			loadedTracks[name] = track
			debugLog(string.format("Successfully loaded track: %s (%s)", name, id))
		else
			warn(string.format("[TeacherAI_ERROR] Failed to load animation: %s (%s)", name, id))
		end
	end
	
	-- Preload assets to ensure clients see them immediately (Optional but good practice)
	task.spawn(function()
		local success, err = pcall(function()
			ContentProvider:PreloadAsync(assetsToPreload)
		end)
		if success then
			debugLog("All animations successfully preloaded via ContentProvider.")
		else
			warn("[TeacherAI_WARNING] ContentProvider failed to preload some animations:", err)
		end
	end)
end

loadAnimations()

local function playTrack(name: string)
	local track = loadedTracks[name]
	if track and not track.IsPlaying then 
		debugLog("Playing animation:", name)
		track:Play() 
	end
end

local function stopTrack(name: string)
	local track = loadedTracks[name]
	if track and track.IsPlaying then 
		debugLog("Stopping animation:", name)
		track:Stop() 
	end
end

---------------------------------------------------------------------------
-- State Machine & Pathfinding Variables
---------------------------------------------------------------------------
type AIState = "WAITING" | "PATROLLING" | "LOOKING_AROUND" | "CATCHING"
local currentState: AIState = "WAITING"
local currentWaypointIndex = 0
local patrolDirection = 1
local waypointsList: {any} = {}

if waypointsFolder then
	for _, child in ipairs(waypointsFolder:GetChildren()) do
		local num = tonumber(child.Name)
		if num then
			table.insert(waypointsList, {node = child, index = num})
		else
			debugLog("Ignoring non-numerical waypoint:", child.Name)
		end
	end
	table.sort(waypointsList, function(a, b) return a.index < b.index end)
	debugLog(string.format("Registered and sorted %d numerical waypoints.", #waypointsList))
end

-- Used for race-condition prevention (cancelling tweens if state changes)
local patrolSessionId = 0

local function setState(newState: AIState)
	if currentState == newState then return end
	debugLog(string.format("--- STATE CHANGE: %s -> %s ---", currentState, newState))
	currentState = newState
	patrolSessionId += 1 -- Invalidate any running tweens/loops for the old state
	
	if newState == "WAITING" then
		stopTrack("WALK")
		stopTrack("LOOK")
		playTrack("IDLE")
		humanoid.WalkSpeed = 0
		
	elseif newState == "PATROLLING" then
		stopTrack("IDLE")
		stopTrack("LOOK")
		playTrack("WALK")
		humanoid.WalkSpeed = TeacherSettings.PATROL_WALK_SPEED
		
	elseif newState == "LOOKING_AROUND" then
		stopTrack("WALK")
		stopTrack("IDLE")
		playTrack("LOOK")
		humanoid.WalkSpeed = 0
	end
end

---------------------------------------------------------------------------
-- Pathfinding Logic
---------------------------------------------------------------------------
local LOOK_NODES = {
	["8"] = true, ["9"] = true, ["10"] = true, ["11"] = true, ["12"] = true,
	["13"] = true, ["14"] = true, ["17"] = true, ["22"] = true, ["23"] = true,
	["24"] = true, ["25"] = true, ["27"] = true
}

local function getNextWaypoint(): Instance?
	if #waypointsList == 0 then return nil end
	
	-- 8% chance to randomly flip direction, as long as we aren't at the very edge
	if math.random() <= 0.08 and currentWaypointIndex > 1 and currentWaypointIndex < #waypointsList then
		patrolDirection = -patrolDirection
		debugLog("Randomly flipping patrol direction!")
	end
	
	currentWaypointIndex = currentWaypointIndex + patrolDirection
	if currentWaypointIndex > #waypointsList then
		currentWaypointIndex = math.max(1, #waypointsList - 1)
		patrolDirection = -1
		debugLog("Hit end of path, reversing.")
	elseif currentWaypointIndex < 1 then
		currentWaypointIndex = math.min(#waypointsList, 2)
		patrolDirection = 1
		debugLog("Hit start of path, reversing.")
	end
	
	local nextNode = waypointsList[currentWaypointIndex].node
	debugLog(string.format("Selected next sequential waypoint: %s", nextNode.Name))
	return nextNode
end

local function walkToTarget(targetPosition: Vector3, sessionId: number)
	debugLog(string.format("Computing path to target: %.1f, %.1f, %.1f", targetPosition.X, targetPosition.Y, targetPosition.Z))
	local path = PathfindingService:CreatePath({
		AgentRadius = TeacherSettings.AGENT_RADIUS,
		AgentHeight = TeacherSettings.AGENT_HEIGHT,
		AgentCanJump = false,
	})
	
	local success, err = pcall(function()
		path:ComputeAsync(rootPart.Position, targetPosition)
	end)
	
	local function moveToPoint(pos: Vector3)
		if patrolSessionId ~= sessionId or currentState ~= "PATROLLING" then 
			debugLog("Movement aborted: State changed during path execution.")
			return false 
		end
		
		humanoid:MoveTo(pos)
		
		local completed = false
		local conn
		conn = humanoid.MoveToFinished:Connect(function(reached)
			completed = true
			if conn then conn:Disconnect() end
		end)
		
		-- Wait for completion or interruption
		while not completed do
			if patrolSessionId ~= sessionId or currentState ~= "PATROLLING" then
				debugLog("Movement cancelled mid-path due to state change.")
				humanoid:MoveTo(rootPart.Position) -- Stop instantly
				if conn then conn:Disconnect() end
				return false
			end
			task.wait(0.05)
		end
		return true
	end

	if success and path.Status == Enum.PathStatus.Success then
		local points = path:GetWaypoints()
		debugLog(string.format("Path computed successfully with %d waypoints.", #points))
		
		-- Skip the first waypoint as it is usually the current position
		for i = 2, #points do
			if points[i].Action == Enum.PathWaypointAction.Jump then
				humanoid.Jump = true
			end
			local moveSuccess = moveToPoint(points[i].Position)
			if not moveSuccess then break end
		end
	else
		warn("[TeacherAI_WARNING] Pathfinding failed:", err or path.Status, "- attempting direct walk")
		moveToPoint(targetPosition)
	end
end

local function patrolLoop()
	debugLog("Patrol loop started.")
	while task.wait() do
		if currentState == "PATROLLING" then
			local targetNode = getNextWaypoint()
			if not targetNode then 
				warn("[TeacherAI_WARNING] No valid waypoints found, retrying in 1s...")
				task.wait(1)
				continue 
			end
			
			local currentSession = patrolSessionId
			walkToTarget((targetNode :: BasePart).Position, currentSession)
			
			-- Ensure we are still patrolling and this wasn't interrupted by a catch/suspect event
			if currentState == "PATROLLING" and patrolSessionId == currentSession then
				local nodeName = targetNode.Name
				if LOOK_NODES[nodeName] then
					debugLog(string.format("Reached LookNode '%s'. Rolling for look animation (20%% chance)...", nodeName))
					if math.random() <= 0.20 then
						debugLog("Roll successful! Teacher is looking around.")
						setState("LOOKING_AROUND")
						local lookTime = math.random(TeacherSettings.IDLE_LOOK_TIME_MIN, TeacherSettings.IDLE_LOOK_TIME_MAX)
						
						-- Hold state, but check if we got interrupted
						local waitStart = os.clock()
						while os.clock() - waitStart < lookTime do
							if currentState ~= "LOOKING_AROUND" then break end
							task.wait(0.1)
						end
						
						-- If we weren't interrupted, resume patrolling
						if currentState == "LOOKING_AROUND" then
							debugLog("Finished looking around. Resuming patrol.")
							setState("PATROLLING")
						end
					else
						debugLog("Roll failed. Continuing patrol.")
					end
				else
					-- Even at normal nodes, a tiny pause makes the robot-like movement feel more natural
					task.wait(math.random() * 0.5)
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Vision (FOV) Detection Loop
---------------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterDescendantsInstances = {teacher}
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function checkFOV()
	local fovAngle = TeacherSettings.FOV_ANGLE_DEGREES
	local range = TeacherSettings.FOV_RANGE_STUDS
	local minDot = math.cos(math.rad(fovAngle / 2))
	
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local targetHRP = char.HumanoidRootPart :: Part
			local dirToPlayer = targetHRP.Position - head.Position
			local distance = dirToPlayer.Magnitude
			
			if distance <= range then
				local normalizedDir = dirToPlayer.Unit
				local dot = head.CFrame.LookVector:Dot(normalizedDir)
				
				if dot >= minDot then
					local rayResult = Workspace:Raycast(head.Position, dirToPlayer, rayParams)
					if rayResult and rayResult.Instance:IsDescendantOf(char) then
						-- TODO: Check if player is cheating.
						-- debugLog(string.format("Player %s is currently within line of sight!", plr.Name))
					end
				end
			end
		end
	end
end

RunService.Heartbeat:Connect(function()
	if currentState == "PATROLLING" or currentState == "LOOKING_AROUND" then
		checkFOV()
	end
end)

---------------------------------------------------------------------------
-- Initialization Flow
---------------------------------------------------------------------------
local function startUp()
	debugLog("Startup sequence initiated.")
	setState("WAITING")
	
	while #Players:GetPlayers() == 0 do
		task.wait(1)
	end
	
	debugLog("Players detected. Waiting 5 seconds before initializing patrols...")
	task.wait(5)
	
	print("[TeacherAI] System fully loaded and starting patrols!")
	setState("PATROLLING")
end

task.spawn(startUp)
task.spawn(patrolLoop)
