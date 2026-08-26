--[[
	CollisionManager — Invisible border barrier management for lobby pads.

	InvisBorder1–InvisBorder4 are Models, direct children of workspace.LobbyPads.
	Each contains 4 BasePart walls that physically cage a lobby pad.

	Barrier states:
	  Waiting     → CanCollide = false  (anyone can walk through)
	  Creating    → CanCollide = true   (owner is teleported inside; barrier traps them)
	  Active      → CanCollide = true   (joiners touch the WALL to be teleported in)
	  Teleporting → CanCollide = true   (no new entries)

	No PhysicsService collision groups are used — plain CanCollide is sufficient
	because all entries/exits are handled via server teleportation, not physical walking.

	API kept fully compatible with callers in init.server.luau.
	allowPlayerOnPad / resetPlayerCollision / resetPadCollisions are no-ops.
]]

local Players     = game:GetService("Players")
local LobbyConfig = require(
	game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("LobbyConfig")
)

local CollisionManager = {}

---------------------------------------------------------------------------
-- Pre-cached BasePart lists per pad — populated once during init()
---------------------------------------------------------------------------
local borderPartsCache: { [number]: { BasePart } } = {}

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

--- Recursively collect all BaseParts inside a Model (any nesting depth).
--- Falls back to direct children if GetDescendants returns nothing.
local function collectBorderParts(model: Model): { BasePart }
	local parts: { BasePart } = {}

	for _, desc in model:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end

	-- Fallback: some environments don't surface descendants immediately
	if #parts == 0 then
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(parts, child)
			end
		end
	end

	return parts
end

--- Apply CanCollide to every cached part for a pad.
local function applyCanCollide(padIndex: number, state: boolean)
	local parts = borderPartsCache[padIndex]
	if not parts or #parts == 0 then
		warn("[CollisionManager] No cached parts for InvisBorder" .. padIndex)
		return
	end

	for _, part in parts do
		if part and part.Parent then
			part.CanCollide = state
		end
	end

	print(string.format("[CollisionManager] InvisBorder%d → CanCollide=%s (%d parts)",
		padIndex, tostring(state), #parts))
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Cache InvisBorder part references. Must be called once at server startup.
function CollisionManager.init()
	local lobbyPads = workspace:WaitForChild("LobbyPads", 10)
	assert(lobbyPads, "[CollisionManager] workspace.LobbyPads not found!")

	for i = 1, LobbyConfig.PAD_COUNT do
		local border = lobbyPads:WaitForChild("InvisBorder" .. i, 10)

		if not border or not border:IsA("Model") then
			warn("[CollisionManager] InvisBorder" .. i
				.. " not found or not a Model — barrier won't work for this pad!")
			borderPartsCache[i] = {}
			continue
		end

		-- Roblox can load a Model before its children arrive.
		-- Poll until BaseParts appear (up to 5 seconds).
		local parts: { BasePart } = {}
		local deadline = os.clock() + 5
		while #parts == 0 and os.clock() < deadline do
			parts = collectBorderParts(border)
			if #parts == 0 then
				task.wait(0.1)
			end
		end

		if #parts == 0 then
			warn("[CollisionManager] InvisBorder" .. i
				.. " still has no BasePart descendants after 5 s — check Studio hierarchy!")
		else
			print(string.format("[CollisionManager] InvisBorder%d cached — %d part(s)", i, #parts))
		end

		borderPartsCache[i] = parts

		-- Ensure walls are fixed in place (Anchored), completely invisible (Transparency = 1),
		-- and off (CanCollide = false) at startup.
		for _, part in parts do
			part.Anchored     = true
			part.Transparency = 1
			part.CastShadow   = false
			part.CanCollide   = false
		end
	end

	Players.PlayerRemoving:Connect(function(player)
		-- No collision-group cleanup needed; kept for API symmetry
		CollisionManager.resetPlayerCollision(player)
	end)
end

--- Returns the cached BasePart list for a pad's InvisBorder.
--- Used by init.server.luau to connect Touched events for joiner detection.
function CollisionManager.getBorderParts(padIndex: number): { BasePart }
	return borderPartsCache[padIndex] or {}
end

--- Enable the barrier — blocks everyone physically.
function CollisionManager.activateBarrier(padIndex: number)
	applyCanCollide(padIndex, true)
end

--- Disable the barrier — anyone can pass through.
function CollisionManager.deactivateBarrier(padIndex: number)
	applyCanCollide(padIndex, false)
end

--- No-op — kept for API compatibility. No special collision groups are used.
function CollisionManager.allowPlayerOnPad(_padIndex: number, _player: Player) end

--- No-op — kept for API compatibility.
function CollisionManager.resetPlayerCollision(_player: Player) end

--- No-op — kept for API compatibility.
function CollisionManager.resetPadCollisions(_padIndex: number, _players: { Player }) end

return CollisionManager
