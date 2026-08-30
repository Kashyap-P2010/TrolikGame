--[[
	TeacherFOVVisualizer.server.luau
	Creates and updates a visual 3D cone representing the Teacher's Field of View.
]]

local Workspace = game:GetService("Workspace")
local TeacherSettings = require(script.Parent:WaitForChild("TeacherSettings"))

local DEBUG_MODE = true
local function debugLog(...)
	if DEBUG_MODE then
		print("[TeacherFOV_DEBUG]", ...)
	end
end

local function initializeFOV()
	debugLog("Starting FOV initialization...")
	local teacher = Workspace:WaitForChild("Teacher_Rig", 60)
	if not teacher then
		warn("[TeacherFOV_ERROR] Teacher_Rig model not found in Workspace after 60s!")
		return
	end

	local head = teacher:WaitForChild("Head", 10)
	if not head then
		warn("[TeacherFOV_ERROR] Teacher_Rig has no Head. Cannot attach FOV cone.")
		return
	end

	debugLog("Found Teacher_Rig and Head. Calculating FOV dimensions...")

	-- Calculate FOV Cone Dimensions
	local range = TeacherSettings.FOV_RANGE_STUDS
	local angleRad = math.rad(TeacherSettings.FOV_ANGLE_DEGREES)
	local diameter = 2 * range * math.tan(angleRad / 2)
	
	debugLog(string.format("FOV Dimensions -> Range: %.1f, Angle: %ddeg, Diameter: %.1f", range, TeacherSettings.FOV_ANGLE_DEGREES, diameter))

	-- Create the Cone Part
	local fovPart = Instance.new("Part")
	fovPart.Name = "FOVCone"
	fovPart.Anchored = false 
	fovPart.CanCollide = false
	fovPart.CanQuery = false
	fovPart.CanTouch = false
	fovPart.Massless = true
	fovPart.CastShadow = false
	fovPart.Color = Color3.fromRGB(255, 50, 50)
	fovPart.Material = Enum.Material.Neon
	fovPart.Transparency = 0.7
	fovPart.Size = Vector3.new(diameter, range, diameter)
	
	-- Add the actual cone mesh
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Cone
	mesh.Parent = fovPart
	
	fovPart.Parent = teacher

	-- Weld it to the head
	local weld = Instance.new("Weld")
	weld.Name = "FOVWeld"
	weld.Part0 = head
	weld.Part1 = fovPart
	weld.C0 = CFrame.Angles(math.rad(-90), 0, 0) * CFrame.new(0, range / 2, 0)
	weld.Parent = fovPart

	print("[TeacherFOV] Visualizer initialized and successfully welded to Head.")
end

task.spawn(initializeFOV)
