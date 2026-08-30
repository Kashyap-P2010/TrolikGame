--[[
	TeacherSettings.luau
	Shared configuration for the Teacher AI and FOV visualizer.
]]

local TeacherSettings = {
	-- Vision
	FOV_ANGLE_DEGREES = 70,       -- Total angle of the vision cone
	FOV_RANGE_STUDS   = 35,       -- How far the teacher can see
	
	-- Movement
	PATROL_WALK_SPEED = 8,        -- Slower walking speed for patrolling
	CATCH_WALK_SPEED  = 20,       -- Fast running speed when catching a student
	
	-- Timings
	IDLE_LOOK_TIME_MIN = 3,       -- Minimum seconds to spend looking around at a LookNode
	IDLE_LOOK_TIME_MAX = 6,       -- Maximum seconds
}

return TeacherSettings
