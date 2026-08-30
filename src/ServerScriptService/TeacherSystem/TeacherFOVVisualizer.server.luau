--[[
	TeacherFOVVisualizer.server.luau
	Creates and updates a visual 3D cone representing the Teacher's Field of View.
]]

local Workspace = game:GetService("Workspace")
local TeacherSettings = require(script.Parent:WaitForChild("TeacherSettings"))

-- Try to find the teacher model
local function initializeFOV()
	local teacher = Workspace:WaitForChild("Teacher", 60)
	if not teacher then
		warn("[TeacherFOV] Teacher model not found in Workspace.")
		return
	end

	local head = teacher:WaitForChild("Head", 10)
	if not head then
		warn("[TeacherFOV] Teacher has no Head.")
		return
	end

	-- Calculate FOV Cone Dimensions
	local range = TeacherSettings.FOV_RANGE_STUDS
	local angleRad = math.rad(TeacherSettings.FOV_ANGLE_DEGREES)
	local diameter = 2 * range * math.tan(angleRad / 2)

	-- Create the Cone Part
	local fovPart = Instance.new("Part")
	fovPart.Name = "FOVCone"
	fovPart.Anchored = false -- Must be unanchored to weld to moving character
	fovPart.CanCollide = false
	fovPart.CanQuery = false
	fovPart.CanTouch = false
	fovPart.Massless = true
	fovPart.CastShadow = false
	fovPart.Color = Color3.fromRGB(255, 50, 50)
	fovPart.Material = Enum.Material.Neon
	fovPart.Transparency = 0.7
	-- The cone is oriented along the Y axis by default, so its "height" is Y.
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
	
	-- We need to offset the cone so its tip (top of the Y axis) is at the head,
	-- and the base extends outwards.
	-- 1. Offset forward by half the range (so tip is at head, not center).
	-- 2. Rotate it so its local Y axis points along the Head's local -Z axis (forward).
	weld.C0 = CFrame.Angles(math.rad(-90), 0, 0) * CFrame.new(0, range / 2, 0)
	
	weld.Parent = fovPart

	print("[TeacherFOV] Visualizer initialized and welded to Head.")
end

-- Start initialization in a separate thread so we don't block other scripts if Teacher is missing
task.spawn(initializeFOV)
