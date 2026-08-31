--[[
	SeatingManager.server.luau
	Handles forced seating of players when they join the Exam place.
	The seat allocation strictly follows specific patterns for 1, 2, or 3 players.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local function assignSeats()
	local players = Players:GetPlayers()
	if #players == 0 then return end

	local seatsFolder = Workspace:WaitForChild("Seats", 10)
	if not seatsFolder then
		warn("[SeatingManager] Workspace.Seats folder not found!")
		return
	end

	local availableSeats = {}
	for _, seat in ipairs(seatsFolder:GetChildren()) do
		if seat:IsA("Seat") then
			table.insert(availableSeats, seat)
		end
	end

	local assignments = {} -- [Player] = Seat

	if #players == 1 then
		assignments[players[1]] = seatsFolder:FindFirstChild("Seat10")
	elseif #players == 2 then
		assignments[players[1]] = seatsFolder:FindFirstChild("Seat10")
		assignments[players[2]] = seatsFolder:FindFirstChild("Seat9")
	elseif #players == 3 then
		assignments[players[1]] = seatsFolder:FindFirstChild("Seat9")
		assignments[players[2]] = seatsFolder:FindFirstChild("Seat10")
		assignments[players[3]] = seatsFolder:FindFirstChild("Seat13")
	else
		-- Random distribution for > 3 players
		local shuffledSeats = table.clone(availableSeats)
		for i = #shuffledSeats, 2, -1 do
			local j = math.random(1, i)
			shuffledSeats[i], shuffledSeats[j] = shuffledSeats[j], shuffledSeats[i]
		end

		for i, player in ipairs(players) do
			if i <= #shuffledSeats then
				assignments[player] = shuffledSeats[i]
			end
		end
	end

	-- Force them into their assigned seats
	for player, seat in pairs(assignments) do
		if seat and seat:IsA("Seat") then
			task.spawn(function()
				local character = player.Character or player.CharacterAdded:Wait()
				local humanoid = character:WaitForChild("Humanoid", 10)
				local hrp = character:WaitForChild("HumanoidRootPart", 10)
				
				if humanoid and hrp then
					print(string.format("[SeatingManager] Assigning %s to %s", player.Name, seat.Name))
					-- Teleport slightly above the seat and force the sit method
					hrp.CFrame = seat.CFrame + Vector3.new(0, 3, 0)
					task.wait(0.2)
					seat:Sit(humanoid)
				end
			end)
		else
			warn("[SeatingManager] Could not find a valid seat for " .. player.Name)
		end
	end
end

-- Since players are teleported together, we wait for the first player to join,
-- wait a brief moment for the rest to connect, and then assign seats.
task.spawn(function()
	while #Players:GetPlayers() == 0 do
		task.wait(0.5)
	end
	
	-- Allow an extra 3 seconds for the rest of the teleporting group to load in
	task.wait(3)
	assignSeats()
end)
