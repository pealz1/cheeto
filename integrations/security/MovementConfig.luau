--!nonstrict
--[[
	Tuning for the movement anti-cheat, grouped by detector. Every detector feeds
	the shared SuspicionScore engine: `rate`/`decay` shape how fast the score rises
	and falls, `rollback` is the (low) score at which the player is self-corrected,
	and `report` is the (much higher) score at which the server is told to kick.
	The wide gap between the two is deliberate — rollback is cheap and forgiving,
	reporting is not.

	Values are ported from the reference anti-cheat.
]]

return {
	--> Shared loop pacing and grace.
	StepInterval = 0.5,
	MaxStepDt = 0.75,
	LagSkipThreshold = 1.0,
	TeleportGraceSeconds = 1.5,
	RollbackGraceSeconds = 0.75,

	--> Enum.HumanoidStateType values that are illegal for a living, non-sitting
	--> player and usually mean fly/noclip.
	SuspiciousStates = { "Flying", "Physics", "RunningNoPhysics", "StrafingNoPhysics" },

	Basic = {
		MaxWalkSpeed = 35,
		MaxJumpPower = 70,
		MaxJumpHeight = 11,
		MaxHipHeight = 8,
		InfiniteJumpAirGrace = 0.18,
		InfiniteJumpVerticalSpeed = 42,

		WalkSpeed = { rollback = 36, report = 300, rate = 4, decay = 3, rollbackCooldown = 0.3, reportCooldown = 8 },
		Jump = { rollback = 36, report = 300, rate = 4, decay = 3, rollbackCooldown = 0.3, reportCooldown = 8 },
		State = { rollback = 45, report = 300, rate = 4, decay = 3, rollbackCooldown = 0.25, reportCooldown = 8 },
		InfiniteJump = { rollback = 50, report = 300, add = 40, decay = 4, rollbackCooldown = 0.2, reportCooldown = 8 },
		HipHeight = { rollback = 30, report = 300, rate = 4, decay = 3, rollbackCooldown = 0.3, reportCooldown = 8 },
	},

	--> CFrame walk/fly: moving quickly with no matching physics velocity.
	CFrameFly = {
		toleranceVelocity = 2,
		minMoveSpeed = 6,
		rollback = 60,
		report = 360,
		rate = 4,
		decay = 3,
		rollbackCooldown = 0.3,
		reportCooldown = 8,
	},

	--> Mass/density manipulation.
	Density = {
		maxDensity = 50,
		rollback = 36,
		report = 360,
		rate = 4,
		decay = 3,
		rollbackCooldown = 0.3,
		reportCooldown = 8,
	},

	--> Panic-mode void teleport (from far below the map back up).
	PanicTeleport = {
		yThreshold = -2,
		minDistance = 50,
		rollback = 60,
		report = 360,
		add = 150,
		decay = 8,
		rollbackCooldown = 0.3,
		reportCooldown = 8,
	},

	--> Anti-knockback: ignoring a strong horizontal force with no wall blocking it.
	Knockback = {
		forceThreshold = 200,
		rollback = 45,
		report = 600,
		rate = 4,
		decay = 3,
		minResponseSpeed = 1,
		minWalkSpeed = 4,
		idleGraceSeconds = 2,
		oppositeGraceSeconds = 1.5,
		oppositeDotThreshold = -0.5,
		walkDecayMultiplier = 2,
		wallCheckDistance = 3,
		rollbackCooldown = 0.35,
		reportCooldown = 10,
	},

	--> Frozen-Y anti-gravity: hanging in the air with no vertical velocity and no
	--> ground beneath.
	FrozenY = {
		rollback = 72,
		report = 360,
		rate = 4,
		decay = 3,
		rollbackCooldown = 0.3,
		reportCooldown = 8,
	},

	--> A known cheat "handshake" animation id.
	Animation = {
		badAnimationId = "rbxassetid://507770239",
		rollback = 36,
		report = 300,
		rate = 6,
		decay = 3,
		rollbackCooldown = 0.3,
		reportCooldown = 8,
	},
}
