--!nonstrict
--[[
	Client movement anti-cheat.

	Ported from the reference anti-cheat and restructured to drive the pure
	SuspicionScore engine and report over the shared SecureChannel. Each detector
	computes a per-tick "is this cheating right now" boolean, feeds it to the
	scoring engine, self-corrects the player at the rollback threshold, and reports
	to the server at the (much higher) report threshold. The score ramps/decays and
	a teleport-grace window keeps legitimate physics glitches, lag, and server
	teleports from ever escalating.

	Detectors: walkspeed / jump / hip-height / illegal-state / infinite-jump,
	CFrame walk-fly mismatch, mass-density, panic void-teleport, anti-knockback,
	frozen-Y anti-gravity, and a known cheat-handshake animation.

	Place this LocalScript with its sibling modules (e.g. StarterPlayerScripts).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local Config = require(script.Parent.MovementConfig)
local Suspicion = require(script.Parent.SuspicionScore)
local SecureChannel = require(script.Parent.SecureChannel)

local player = Players.LocalPlayer

local suspiciousStates: { [Enum.HumanoidStateType]: boolean } = {}
for _, name in Config.SuspiciousStates do
	suspiciousStates[Enum.HumanoidStateType[name]] = true
end

--> Grace shared by every detector: after a server teleport or a local rollback,
--> scoring pauses briefly so the correction itself is never flagged.
local graceUntil = 0
local function graceActive(): boolean
	return os.clock() <= graceUntil
end
local function startGrace(duration: number)
	graceUntil = math.max(graceUntil, os.clock() + duration)
end

local function stepDt(lastClock: number): (number, number, number)
	local now = os.clock()
	local realDt = now - lastClock
	local dt = realDt
	if dt <= 0 then
		dt = 1 / 60
		realDt = dt
	elseif dt > Config.MaxStepDt then
		dt = Config.MaxStepDt
	end
	return dt, realDt, now
end

local function rollback(root: BasePart, safe: CFrame?)
	if safe and root and root.Parent then
		startGrace(Config.RollbackGraceSeconds)
		root.CFrame = safe
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

--> Runs one detector signal: score it, then apply rollback/report actions.
local function evaluate(
	state: Suspicion.State,
	condition: boolean,
	dt: number,
	now: number,
	cfg: { rollback: number, report: number, rate: number?, decay: number, rollbackCooldown: number, reportCooldown: number, add: number? },
	onRollback: () -> (),
	reason: string
)
	if cfg.add then
		Suspicion.addScore(state, condition, dt, cfg.add, cfg.decay, graceActive())
	else
		Suspicion.update(state, condition, dt, cfg.rate, cfg.decay, graceActive())
	end
	local action = Suspicion.process(state, condition, now, cfg.rollback, cfg.report, cfg.rollbackCooldown, cfg.reportCooldown, graceActive())
	if action.rollback then
		onRollback()
	end
	if action.report then
		SecureChannel.send("detect", reason)
	end
end

local activeToken = 0

local function raycastBlocked(from: Vector3, direction: Vector3, character: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.IgnoreWater = true
	local hit = Workspace:Raycast(from, direction, params)
	if not hit then
		return false
	end
	local instance = hit.Instance
	if instance and instance:IsA("BasePart") then
		return instance.CanCollide
	end
	return instance ~= nil
end

local function runDetectors(character: Model)
	activeToken += 1
	local token = activeToken

	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid
	if not root or not humanoid then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 5)

	--> Per-signal scoring state.
	local walkSpeed = Suspicion.createState()
	local jump = Suspicion.createState()
	local stateSignal = Suspicion.createState()
	local infiniteJump = Suspicion.createState()
	local hipHeight = Suspicion.createState()
	local cframeFly = Suspicion.createState()
	local density = Suspicion.createState()
	local panic = Suspicion.createState()
	local frozenY = Suspicion.createState()
	local animation = Suspicion.createState()

	local safeCFrame = root.CFrame
	local lastPosition = root.Position
	local lastVelocityXZ = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	local lastGroundedAt = os.clock()
	local previousState = humanoid:GetState()
	local lastClock = os.clock()

	while task.wait(Config.StepInterval) do
		if token ~= activeToken or not character.Parent or not root.Parent or not humanoid.Parent then
			break
		end

		local dt, realDt, now = stepDt(lastClock)
		lastClock = now

		--> A big real gap is lag, not cheating: resync the baselines and skip.
		if realDt > Config.LagSkipThreshold then
			safeCFrame = root.CFrame
			lastPosition = root.Position
			lastVelocityXZ = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
			previousState = humanoid:GetState()
			lastGroundedAt = now
			continue
		end

		local position = root.Position
		local velocity = root.AssemblyLinearVelocity
		local currentState = humanoid:GetState()
		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
		if grounded then
			lastGroundedAt = now
		end
		local onRollback = function()
			rollback(root, safeCFrame)
		end

		--> Basic humanoid property bypasses.
		local walkSpeedBad = humanoid.WalkSpeed > Config.Basic.MaxWalkSpeed + 0.01
		evaluate(walkSpeed, walkSpeedBad, dt, now, Config.Basic.WalkSpeed, function()
			humanoid.WalkSpeed = Config.Basic.MaxWalkSpeed
			onRollback()
		end, "WalkSpeedBypass")

		local jumpBad = if humanoid.UseJumpPower
			then humanoid.JumpPower > Config.Basic.MaxJumpPower + 0.01
			else humanoid.JumpHeight > Config.Basic.MaxJumpHeight + 0.01
		evaluate(jump, jumpBad, dt, now, Config.Basic.Jump, function()
			if humanoid.UseJumpPower then
				humanoid.JumpPower = Config.Basic.MaxJumpPower
			else
				humanoid.JumpHeight = Config.Basic.MaxJumpHeight
			end
			onRollback()
		end, "JumpBypass")

		local hipBad = humanoid.HipHeight > Config.Basic.MaxHipHeight + 0.01
		evaluate(hipHeight, hipBad, dt, now, Config.Basic.HipHeight, function()
			humanoid.HipHeight = Config.Basic.MaxHipHeight
			onRollback()
		end, "HipHeightBypass")

		local stateBad = suspiciousStates[currentState] and humanoid.Health > 0 and not humanoid.Sit
		evaluate(stateSignal, stateBad, dt, now, Config.Basic.State, function()
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
			onRollback()
		end, "IllegalHumanoidState")

		--> Infinite jump: re-entering Jumping while airborne, or an air boost.
		local airtime = now - lastGroundedAt
		local airJump = currentState == Enum.HumanoidStateType.Jumping
			and previousState ~= Enum.HumanoidStateType.Jumping
			and airtime > Config.Basic.InfiniteJumpAirGrace
		local airBoost = not grounded
			and airtime > Config.Basic.InfiniteJumpAirGrace
			and velocity.Y > Config.Basic.InfiniteJumpVerticalSpeed
			and currentState ~= Enum.HumanoidStateType.Climbing
			and currentState ~= Enum.HumanoidStateType.Swimming
		evaluate(infiniteJump, airJump or airBoost, dt, now, Config.Basic.InfiniteJump, function()
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
			onRollback()
		end, "InfiniteJump")

		--> CFrame walk/fly: horizontal displacement with no physics velocity.
		local moveXZ = (Vector3.new(position.X, 0, position.Z) - Vector3.new(lastPosition.X, 0, lastPosition.Z)).Magnitude
		local speedXZ = moveXZ / realDt
		local velocityXZ = Vector3.new(velocity.X, 0, velocity.Z)
		local avgPhysXZ = (velocityXZ.Magnitude + lastVelocityXZ.Magnitude) / 2
		local cframeBad = speedXZ > Config.CFrameFly.minMoveSpeed and avgPhysXZ < Config.CFrameFly.toleranceVelocity
		evaluate(cframeFly, cframeBad, dt, now, Config.CFrameFly, onRollback, "CFrameFlyMismatch")

		--> Frozen-Y anti-gravity: airborne, no vertical velocity, no ground below.
		local frozenBad = false
		if not graceActive() and humanoid.FloorMaterial == Enum.Material.Air and math.abs(velocity.Y) < 0.1 and position.Y > lastPosition.Y - 0.1 then
			frozenBad = not raycastBlocked(position, Vector3.new(0, -4, 0), character)
		end
		evaluate(frozenY, frozenBad, dt, now, Config.FrozenY, onRollback, "FrozenAntiGravity")

		--> Mass/density manipulation.
		local props = root.CustomPhysicalProperties
		local densityBad = props ~= nil and props.Density > Config.Density.maxDensity
		evaluate(density, densityBad, dt, now, Config.Density, function()
			root.CustomPhysicalProperties = nil
			onRollback()
		end, "MassDensity")

		--> Panic void teleport: from far below the map back above it in one step.
		local moved = (position - lastPosition).Magnitude
		local panicBad = lastPosition.Y < Config.PanicTeleport.yThreshold
			and position.Y > 0
			and moved > Config.PanicTeleport.minDistance
		evaluate(panic, panicBad, dt, now, Config.PanicTeleport, onRollback, "PanicVoidTeleport")

		--> Bad handshake animation.
		local badAnim = false
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				local anim = track.Animation
				if anim and anim.AnimationId == Config.Animation.badAnimationId then
					badAnim = true
					break
				end
			end
		end
		evaluate(animation, badAnim, dt, now, Config.Animation, onRollback, "CheatAnimation")

		--> Advance baselines only when this tick looked clean, so a safe CFrame is
		--> never captured mid-cheat.
		local anySignal = walkSpeedBad or jumpBad or hipBad or stateBad or airJump or airBoost or cframeBad or frozenBad or densityBad or panicBad or badAnim
		if graceActive() then
			safeCFrame = root.CFrame
		elseif not anySignal and (grounded or math.abs(velocity.Y) > 1) then
			safeCFrame = root.CFrame
		end
		lastPosition = position
		lastVelocityXZ = velocityXZ
		previousState = currentState
	end
end

--> Server teleports should not be flagged; the server tells us via the channel.
--> (The server can send { k = "grace", time = n }; wire it here if desired.)

if player.Character then
	task.spawn(runDetectors, player.Character)
end
player.CharacterAdded:Connect(function(character)
	task.spawn(runDetectors, character)
end)
