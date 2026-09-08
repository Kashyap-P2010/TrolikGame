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

-- CheatManager integration (for strike system)
local CheatManager = nil
task.defer(function()
	local ok, mod = pcall(function()
		local cheatSystem = game:GetService("ServerScriptService"):FindFirstChild("CheatSystem")
		if cheatSystem then
			return require(cheatSystem:FindFirstChild("CheatManager"))
		end
		return nil
	end)
	if ok and mod then
		CheatManager = mod
		debugLog("CheatManager linked successfully")
	else
		warn("[TeacherAI] CheatManager not found — catching system will not issue strikes")
	end
end)

---------------------------------------------------------------------------
-- Debugging Setup
---------------------------------------------------------------------------
local DEBUG_MODE = false
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
	LOOK = "rbxassetid://98820429377987" -- arms_crossed
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
	
	-- Debug print the exact order so the user can verify no waypoints were skipped
	local orderStr = ""
	for i, wp in ipairs(waypointsList) do
		orderStr = orderStr .. wp.index .. (i < #waypointsList and " -> " or "")
	end
	debugLog(string.format("Registered and sorted %d numerical waypoints. Order: %s", #waypointsList, orderStr))
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
		
	elseif newState == "CATCHING" then
		stopTrack("IDLE")
		stopTrack("LOOK")
		playTrack("WALK")
		humanoid.WalkSpeed = TeacherSettings.CATCH_WALK_SPEED
	end
end

-- Target player the teacher is currently chasing
local catchTarget: Player? = nil

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
	
	-- 1% chance to randomly flip direction, as long as we aren't at the very edge (for testing)
	if math.random() <= 0.01 and currentWaypointIndex > 1 and currentWaypointIndex < #waypointsList then
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

local function walkToTarget(targetPosition: Vector3, sessionId: number, isDirectWalk: boolean?)
	if isDirectWalk then
		debugLog("Executing DIRECT walk (ignoring PathfindingService) to target...")
		humanoid:MoveTo(targetPosition)
		
		local completed = false
		local conn
		conn = humanoid.MoveToFinished:Connect(function(reached)
			completed = true
			if conn then conn:Disconnect() end
		end)
		
		local timeout = 0
		while not completed and patrolSessionId == sessionId and currentState == "PATROLLING" do
			task.wait(0.05)
			timeout += 0.05
			if timeout > 10 then break end -- 10 second timeout for direct walks
			
			-- Smooth walking trick: If we are close enough to the target, break early so we can 
			-- immediately issue the next MoveTo command before he starts decelerating!
			local dist = (rootPart.Position - targetPosition)
			local flatDist = Vector3.new(dist.X, 0, dist.Z).Magnitude
			if flatDist < 2.5 then
				break
			end
		end
		if conn then conn:Disconnect() end
		return
	end
	
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
		
		local timeout = 0
		-- Wait for completion or interruption
		while not completed do
			if patrolSessionId ~= sessionId or currentState ~= "PATROLLING" then
				debugLog("Movement cancelled mid-path due to state change.")
				humanoid:MoveTo(rootPart.Position) -- Stop instantly
				if conn then conn:Disconnect() end
				return false
			end
			
			timeout += 0.05
			if timeout > 8 then break end
			
			-- Smooth walking trick: If we are close enough to the target, break early so we can 
			-- immediately issue the next MoveTo command before he starts decelerating!
			local dist = (rootPart.Position - pos)
			local flatDist = Vector3.new(dist.X, 0, dist.Z).Magnitude
			if flatDist < 2.5 then
				break
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
			local nextNode = getNextWaypoint()
			if not nextNode then 
				warn("[TeacherAI_WARNING] No valid waypoints found, retrying in 1s...")
				task.wait(1)
				continue 
			end
			
			local targetPos = (nextNode :: BasePart).Position
			debugLog("Patrolling to waypoint: " .. nextNode.Name)
			
			local forceDirect = TeacherSettings.DIRECT_WALK_WAYPOINTS[nextNode.Name] or false
			local currentSession = patrolSessionId
			walkToTarget(targetPos, currentSession, forceDirect)
			
			-- Ensure we are still patrolling and this wasn't interrupted by a catch/suspect event
			if currentState == "PATROLLING" and patrolSessionId == currentSession then
				local nodeName = nextNode.Name
				if LOOK_NODES[nodeName] then
					debugLog(string.format("Reached LookNode '%s'. Rolling for look animation (20%% chance)...", nodeName))
					if math.random() <= 0.20 then
						debugLog("Roll successful! Teacher is looking around.")
						setState("LOOKING_AROUND")
						
						-- Fetch the exact length of the animation so we don't cut it off!
						local track = loadedTracks["LOOK"]
						local lookTime = math.random(TeacherSettings.IDLE_LOOK_TIME_MIN, TeacherSettings.IDLE_LOOK_TIME_MAX)
						
						if track then
							-- Wait for Roblox to load the length data if it hasn't yet, but DO NOT wait forever!
							if track.Length == 0 then
								local t = 0
								while track.Length == 0 and t < 1 do
									task.wait(0.1)
									t += 0.1
								end
							end
							
							-- If it successfully loaded the length
							if track.Length > 0 then
								lookTime = track.Length
								if lookTime < 1 then
									lookTime = track.Length * math.random(3, 5) -- Loop it a few times if it's a 0.5s anim
								end
							else
								-- Fallback if animation length completely failed to load
								lookTime = 3
							end
						end
						
						debugLog(string.format("Looking around for exact animation duration: %.2f seconds...", lookTime))
						
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
	-- Only check when teacher is looking around (not while walking)
	if currentState ~= "LOOKING_AROUND" then return end
	
	local range = TeacherSettings.FOV_RANGE_STUDS
	
	for _, plr in ipairs(Players:GetPlayers()) do
		local isCheating = plr:GetAttribute("IsCheating") == true
		local isOutOfSeat = plr:GetAttribute("IsOutOfSeat") == true
		
		-- Only care about players who are actively cheating or out of seat
		if not isCheating and not isOutOfSeat then continue end
		
		local char = plr.Character
		if not char then continue end
		local targetHRP = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetHRP then continue end
		
		local dirToPlayer = targetHRP.Position - head.Position
		local distance = dirToPlayer.Magnitude
		
		if distance > range then continue end
		
		-- Line of sight check (raycast)
		local rayResult = Workspace:Raycast(head.Position, dirToPlayer, rayParams)
		if rayResult and rayResult.Instance:IsDescendantOf(char) then
			-- Player is cheating AND in line of sight — CATCH THEM!
			print(string.format("[TeacherAI] SPOTTED %s cheating! Initiating catch!", plr.Name))
			catchTarget = plr
			task.spawn(catchPlayer, plr)
			return -- Only chase one player at a time
		end
	end
end

---------------------------------------------------------------------------
-- Catch Player Logic
---------------------------------------------------------------------------
function catchPlayer(targetPlayer: Player)
	local char = targetPlayer.Character
	if not char then return end
	local targetHRP = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not targetHRP then return end
	
	setState("CATCHING")
	local sessionId = patrolSessionId
	
	-- Sprint toward the player
	print(string.format("[TeacherAI] Sprinting to catch %s!", targetPlayer.Name))
	
	local chaseStartTime = os.clock()
	local MAX_CHASE_TIME = 8 -- seconds, give up after this
	
	while currentState == "CATCHING" and patrolSessionId == sessionId do
		-- Re-check character exists
		char = targetPlayer.Character
		if not char then break end
		targetHRP = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetHRP then break end
		
		-- Move toward player
		humanoid:MoveTo(targetHRP.Position)
		
		-- Check if close enough to "catch" them
		local dist = (rootPart.Position - targetHRP.Position).Magnitude
		if dist < 6 then
			-- CAUGHT!
			print(string.format("[TeacherAI] Reached %s — issuing warning!", targetPlayer.Name))
			humanoid:MoveTo(rootPart.Position) -- Stop moving
			
			-- Play the look/warning animation
			stopTrack("WALK")
			playTrack("LOOK")
			
			-- Issue strike via CheatManager
			if CheatManager then
				CheatManager.addStrike(targetPlayer)
			end
			
			-- Hold for 2 seconds (warning animation)
			task.wait(2)
			break
		end
		
		-- Timeout check
		if os.clock() - chaseStartTime > MAX_CHASE_TIME then
			print(string.format("[TeacherAI] Chase timed out for %s — returning to patrol", targetPlayer.Name))
			break
		end
		
		task.wait(0.1)
	end
	
	-- Return to patrolling
	catchTarget = nil
	if currentState == "CATCHING" and patrolSessionId == sessionId then
		setState("PATROLLING")
	end
end

-- Only check FOV periodically (every 0.5s) instead of every Heartbeat to save performance
local fovCheckAccumulator = 0
RunService.Heartbeat:Connect(function(dt)
	if currentState ~= "LOOKING_AROUND" then
		fovCheckAccumulator = 0
		return
	end
	fovCheckAccumulator += dt
	if fovCheckAccumulator >= 0.5 then
		fovCheckAccumulator = 0
		checkFOV()
	end
end)

---------------------------------------------------------------------------
-- Collision Handling (No Player-Teacher Collisions)
---------------------------------------------------------------------------
local PhysicsService = game:GetService("PhysicsService")

-- Register groups safely
pcall(function()
	PhysicsService:RegisterCollisionGroup("TeacherAI_Group")
	PhysicsService:RegisterCollisionGroup("Player_Group")
end)
PhysicsService:CollisionGroupSetCollidable("TeacherAI_Group", "Player_Group", false)
-- IMPORTANT: Players must still collide with the floor and seats (Default group)!
PhysicsService:CollisionGroupSetCollidable("Player_Group", "Default", true)

local function setCollisionGroup(model: Model, groupName: string)
	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			obj.CollisionGroup = groupName
		end
	end
end

-- Assign the teacher
setCollisionGroup(teacher, "TeacherAI_Group")

-- Assign all players
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		-- Wait a frame for parts to load
		task.wait()
		setCollisionGroup(character, "Player_Group")
	end)
end)
for _, player in ipairs(Players:GetPlayers()) do
	if player.Character then
		setCollisionGroup(player.Character, "Player_Group")
	end
end

---------------------------------------------------------------------------
-- Script-Side Rig Orientation Fix (Crabwalking Fix)
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
