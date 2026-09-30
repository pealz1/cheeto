--[[
	Coverage for the anti-knockback force summation. VectorForce is available in
	@lune/roblox, so we build real ones and assert the pure summation directly.
	The raycast wall-check and scoring are covered elsewhere (Movement.luau) or
	need a running game.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local stdio = require("@lune/stdio")

local V3 = roblox.Vector3
local Enum = roblox.Enum

--> The module uses the Roblox globals Vector3/Enum, which are not ambient in
--> Lune, so load it with those injected (same technique as the datatype tests).
local Environment = { Vector3 = V3, Enum = Enum, _G = {} }
local Bytecode = luau.compile(fs.readFile("../extras/security/KnockbackForce.luau"), { optimizationLevel = 1 })
local Knockback = luau.load(Bytecode, { debugName = "KnockbackForce", environment = Environment })()

local function check(condition: boolean, message: string)
	if not condition then
		stdio.write(`[{stdio.color("red")}FAIL{stdio.color("reset")}] {message}\n`)
		process.exit(24)
	end
end

local function Ok(message: string)
	stdio.write(`[{stdio.color("green")}OK{stdio.color("reset")}] {message}\n`)
end

local rootAtt = roblox.Instance.new("Attachment")
local otherAtt = roblox.Instance.new("Attachment")

local function force(vector, attachment, enabled, relativeTo)
	local vf = roblox.Instance.new("VectorForce")
	vf.Force = vector
	vf.Attachment0 = attachment
	vf.Enabled = enabled
	vf.RelativeTo = relativeTo
	return vf
end

local World = Enum.ActuatorRelativeTo.World
local Local = Enum.ActuatorRelativeTo.Attachment0

do
	local total, net, hasForce, hasDisabled =
		Knockback.sumHorizontalForce({ force(V3.new(300, 0, 0), rootAtt, true, World) }, rootAtt, nil)
	check(total == 300, "single force total")
	check(net == V3.new(300, 0, 0), "single force net vector")
	check(hasForce and not hasDisabled, "single enabled force flags")
	Ok("Single horizontal force summed correctly")
end

do
	local total, net = Knockback.sumHorizontalForce({
		force(V3.new(300, 0, 0), rootAtt, true, World),
		force(V3.new(0, 0, 400), rootAtt, true, World),
	}, rootAtt, nil)
	check(total == 700, "two forces magnitude sum")
	check(net == V3.new(300, 0, 400), "two forces net vector")
	Ok("Multiple forces summed correctly")
end

do
	local _, _, hasForce, hasDisabled =
		Knockback.sumHorizontalForce({ force(V3.new(300, 0, 0), rootAtt, false, World) }, rootAtt, nil)
	check(not hasForce, "disabled force is not counted")
	check(hasDisabled, "disabled force is flagged (bypass signal)")
	Ok("Disabled force detected as a bypass, not counted")
end

do
	local total, _, hasForce =
		Knockback.sumHorizontalForce({ force(V3.new(300, 0, 0), otherAtt, true, World) }, rootAtt, nil)
	check(total == 0 and not hasForce, "force on a different attachment is ignored")
	Ok("Force on another attachment is ignored")
end

do
	local total = Knockback.sumHorizontalForce({ roblox.Instance.new("Part") }, rootAtt, nil)
	check(total == 0, "non-VectorForce child is ignored")
	Ok("Non-VectorForce children are ignored")
end

do
	--> Attachment0-relative force with an identity-CFrame primary part resolves to
	--> the same world-space vector.
	local part = roblox.Instance.new("Part")
	local total = Knockback.sumHorizontalForce({ force(V3.new(300, 0, 0), rootAtt, true, Local) }, rootAtt, part)
	check(total == 300, "attachment-relative force resolves to world space")
	Ok("Attachment-relative force resolved via primary part")
end

do
	local total, net, hasForce =
		Knockback.sumHorizontalForce({ force(V3.new(0, 500, 0), rootAtt, true, World) }, rootAtt, nil)
	check(total == 0, "purely vertical force has no horizontal magnitude")
	check(net == V3.zero, "purely vertical force nets to zero horizontally")
	check(hasForce, "vertical force still counts as an active force")
	Ok("Vertical-only force contributes no horizontal push")
end

stdio.write(`{stdio.color("green")}All anti-knockback force tests passed!{stdio.color("reset")}\n`)

return true
