--[[
	TeacherAI.server.luau
	Controls the state machine, pathfinding, and vision checks for the Teacher.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")

local TeacherSettings = require(script.Parent:WaitForChild("TeacherSettings"))
local TweenService = game:GetService("TweenService")

---------------------------------------------------------------------------
-- References & Setup
---------------------------------------------------------------------------
local teacher = Workspace:WaitForChild("Teacher", 60)
if not teacher then error("[TeacherAI] Teacher model not found!") end

-- The rig uses an AnimationController instead of a Humanoid
local animController = teacher:WaitForChild("AnimationController", 10) :: AnimationController
local head = teacher:WaitForChild("Head") :: Part
local rootPart = teacher:WaitForChild("RootPart") :: Part

local waypointsFolder = Workspace:WaitForChild("TeacherWaypoints", 60)
if not waypointsFolder then warn("[TeacherAI] TeacherWaypoints folder not found!") end

-- Animations
local IDLE_ANIM_ID = "rbxassetid://98820429377987"
local WALK_ANIM_ID = "rbxassetid://75525743234669"
local LOOK_ANIM_ID = "rbxassetid://88647926841758"

-- Create an Animator if one doesn't exist
local animator = animController:FindFirstChildOfClass("Animator")
if not animator then
	animator = Instance.new("Animator")
	animator.Parent = animController
end

-- Placeholder loaded animations (we wrap in pcall in case IDs are invalid)
local function loadAnimation(id: string): AnimationTrack?
	if id == "rbxassetid://0" or id == "" then return nil end
	local anim = Instance.new("Animation")
	anim.AnimationId = id
	local success, track = pcall(function() return animator:LoadAnimation(anim) end)
	if success then return track end
	return nil
end

local idleTrack = loadAnimation(IDLE_ANIM_ID)
local walkTrack = loadAnimation(WALK_ANIM_ID)
local lookTrack = loadAnimation(LOOK_ANIM_ID)

---------------------------------------------------------------------------
-- State Machine & Pathfinding Variables
---------------------------------------------------------------------------
type AIState = "WAITING" | "PATROLLING" | "LOOKING_AROUND" | "CATCHING"
local currentState: AIState = "WAITING"
local currentWaypointIndex = 1
local waypointsList: {Instance} = {}

if waypointsFolder then
	waypointsList = waypointsFolder:GetChildren()
end

local function playTrack(track: AnimationTrack?)
	if not track then return end
	if not track.IsPlaying then track:Play() end
end

local function stopTrack(track: AnimationTrack?)
	if not track then return end
	if track.IsPlaying then track:Stop() end
end

local function setState(newState: AIState)
	print("[TeacherAI] State changed to:", newState)
	currentState = newState
	
	if newState == "WAITING" then
		stopTrack(walkTrack)
		stopTrack(lookTrack)
		playTrack(idleTrack)
		
	elseif newState == "PATROLLING" then
		stopTrack(idleTrack)
		stopTrack(lookTrack)
		playTrack(walkTrack)
		
	elseif newState == "LOOKING_AROUND" then
		stopTrack(walkTrack)
		stopTrack(idleTrack)
		playTrack(lookTrack)
	end
end

---------------------------------------------------------------------------
-- Pathfinding Logic
---------------------------------------------------------------------------
local function getNextWaypoint(): Instance?
	if #waypointsList == 0 then return nil end
	-- Randomly pick a new waypoint that isn't the current one
	local nextIdx = currentWaypointIndex
	while nextIdx == currentWaypointIndex and #waypointsList > 1 do
		nextIdx = math.random(1, #waypointsList)
	end
	currentWaypointIndex = nextIdx
	return waypointsList[currentWaypointIndex]
end

-- Specific waypoints where the teacher is allowed to stop and look around
local LOOK_NODES = {
	["8"] = true, ["9"] = true, ["10"] = true, ["11"] = true, ["12"] = true,
	["13"] = true, ["14"] = true, ["17"] = true, ["22"] = true, ["23"] = true,
	["24"] = true, ["25"] = true, ["27"] = true
}

local function walkToTarget(targetPosition: Vector3)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = false,
	})
	
	local success, err = pcall(function()
		path:ComputeAsync(rootPart.Position, targetPosition)
	end)
	
	local function moveToPoint(pos: Vector3)
		-- Calculate duration based on distance and WalkSpeed
		local distance = (rootPart.Position - pos).Magnitude
		local duration = distance / TeacherSettings.PATROL_WALK_SPEED
		
		-- Look at the target (ignore Y axis so he doesn't tilt up/down)
		local lookAt = Vector3.new(pos.X, rootPart.Position.Y, pos.Z)
		local targetCFrame = CFrame.lookAt(rootPart.Position, lookAt)
		-- Immediately snap rotation
		rootPart.CFrame = targetCFrame
		
		if duration > 0.05 then
			local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear)
			local tween = TweenService:Create(rootPart, tweenInfo, {CFrame = targetCFrame + (pos - targetCFrame.Position)})
			tween:Play()
			tween.Completed:Wait()
		else
			rootPart.Position = pos
			task.wait()
		end
	end

	if success and path.Status == Enum.PathStatus.Success then
		local points = path:GetWaypoints()
		-- Skip the first waypoint as it is usually the current position
		for i = 2, #points do
			if currentState ~= "PATROLLING" then break end
			moveToPoint(points[i].Position)
		end
	else
		warn("[TeacherAI] Pathfinding failed:", err or path.Status, "- walking direct")
		moveToPoint(targetPosition)
	end
end

local function patrolLoop()
	while task.wait() do
		if currentState == "PATROLLING" then
			local targetNode = getNextWaypoint()
			if not targetNode then 
				task.wait(1)
				continue 
			end
			
			walkToTarget((targetNode :: BasePart).Position)
			
			-- Reached the node. Should we look around?
			if currentState == "PATROLLING" then
				local nodeName = targetNode.Name
				if LOOK_NODES[nodeName] then
					-- E.g. 40% chance to stop and look around when hitting a designated chair node
					if math.random() <= 0.40 then
						setState("LOOKING_AROUND")
						local lookTime = math.random(TeacherSettings.IDLE_LOOK_TIME_MIN, TeacherSettings.IDLE_LOOK_TIME_MAX)
						task.wait(lookTime)
						setState("PATROLLING")
					end
				else
					-- Even at normal nodes, maybe a tiny pause
					task.wait(math.random() * 0.5)
				end
			end
		end
	end
end

---------------------------------------------------------------------------
-- Vision (FOV) Detection Loop
---------------------------------------------------------------------------
-- Raycast parameters to ignore the Teacher and FOV cone itself
local rayParams = RaycastParams.new()
rayParams.FilterDescendantsInstances = {teacher}
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function checkFOV()
	local fovAngle = TeacherSettings.FOV_ANGLE_DEGREES
	local range = TeacherSettings.FOV_RANGE_STUDS
	-- The minimum dot product for our cone angle
	local minDot = math.cos(math.rad(fovAngle / 2))
	
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local targetHRP = char.HumanoidRootPart :: Part
			local dirToPlayer = targetHRP.Position - head.Position
			local distance = dirToPlayer.Magnitude
			
			if distance <= range then
				local normalizedDir = dirToPlayer.Unit
				-- Teacher Head looks along -Z natively, but Head CFrame LookVector is standard forward.
				-- We will use the Head's LookVector.
				local dot = head.CFrame.LookVector:Dot(normalizedDir)
				
				if dot >= minDot then
					-- Player is inside the cone! Now check line of sight.
					local rayResult = Workspace:Raycast(head.Position, dirToPlayer, rayParams)
					if rayResult and rayResult.Instance:IsDescendantOf(char) then
						-- Player is fully visible!
						-- TODO: Check if player is cheating.
						-- print("[TeacherAI] Sees player:", plr.Name)
					end
				end
			end
		end
	end
end

RunService.Heartbeat:Connect(function()
	-- Only check vision if the teacher is actually active (patrolling or looking around)
	if currentState == "PATROLLING" or currentState == "LOOKING_AROUND" then
		checkFOV()
	end
end)

---------------------------------------------------------------------------
-- Initialization Flow
---------------------------------------------------------------------------
local function startUp()
	setState("WAITING")
	
	-- Wait for at least 1 player to join (or game loop to signal start)
	while #Players:GetPlayers() == 0 do
		task.wait(1)
	end
	
	print("[TeacherAI] Players found. Waiting 5 seconds before starting patrol...")
	task.wait(5)
	
	print("[TeacherAI] Starting patrols!")
	setState("PATROLLING")
end

-- Begin loops
task.spawn(startUp)
task.spawn(patrolLoop)
