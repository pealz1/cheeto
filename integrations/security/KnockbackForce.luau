--!nonstrict
--[[
	Pure horizontal-force summation for the anti-knockback detector.

	Given the VectorForces parented under Workspace.Terrain (how knockback auras
	are commonly applied), this sums the horizontal component of every force
	attached to the player's root attachment, and reports whether any such force
	is currently enabled or was found disabled (a common bypass — the exploiter
	disables the force so it can't push them).

	Kept separate and side-effect free so it can be unit-tested with mock
	VectorForces; the raycasting wall-check and the scoring live in the client
	detector. Ported from the reference anti-cheat.
]]

--> Returns:
--   total     — summed magnitude of all horizontal forces on this attachment
--   net       — vector sum of those horizontal forces
--   hasForce  — at least one enabled VectorForce targets this attachment
--   hasDisabled — at least one VectorForce targets it but is disabled
local function sumHorizontalForce(
	children: { Instance },
	rootAttachment: Instance,
	primaryPart: BasePart?
): (number, Vector3, boolean, boolean)
	local total = 0
	local net = Vector3.zero
	local hasForce = false
	local hasDisabled = false

	for _, object in children do
		if not object:IsA("VectorForce") or (object :: any).Attachment0 ~= rootAttachment then
			continue
		end

		if not (object :: any).Enabled then
			hasDisabled = true
			continue
		end

		hasForce = true
		local force = (object :: any).Force
		--> A force expressed relative to its attachment must be rotated into world
		--> space before we can compare it to world-space movement.
		if (object :: any).RelativeTo == Enum.ActuatorRelativeTo.Attachment0 and primaryPart then
			force = primaryPart.CFrame:VectorToWorldSpace((object :: any).Force)
		end

		local horizontal = Vector3.new(force.X, 0, force.Z)
		total += horizontal.Magnitude
		net += horizontal
	end

	return total, net, hasForce, hasDisabled
end

return {
	sumHorizontalForce = sumHorizontalForce,
}
