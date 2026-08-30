--[[
	TeacherSettings.luau
	Shared configuration for the Teacher AI and FOV visualizer.
]]

local TeacherSettings = {
	-- Vision
	FOV_ANGLE_DEGREES = 70,       -- Total angle of the vision cone
	FOV_RANGE_STUDS   = 35,       -- How far the teacher can see
	
	-- Movement
	PATROL_WALK_SPEED = 5,        -- Slower walking speed for patrolling
	CATCH_WALK_SPEED  = 20,       -- Fast running speed when catching a student
	
	-- Pathfinding (Adjust if you resize the Teacher!)
	AGENT_RADIUS      = 4,        -- How wide the teacher is (prevents bumping into walls)
	AGENT_HEIGHT      = 8,        -- How tall the teacher is
	
	-- Rig Fixes
	RIG_ROTATION_OFFSET_Y = -90,  -- Fixes sideways crabwalking (in degrees, usually -90, 90, or 180)
	
	-- Timings
	IDLE_LOOK_TIME_MIN = 3,       -- Minimum seconds to spend looking around at a LookNode
	IDLE_LOOK_TIME_MAX = 6,       -- Maximum seconds
}

return TeacherSettings
