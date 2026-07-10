--!nonstrict
--[[
	Suspicion-scoring engine for the movement anti-cheat.

	This is the false-positive safety of the whole system: a raw cheat condition
	(e.g. "moving faster than physics allows") never kicks on its own. It feeds a
	score that ramps up only while the condition holds and decays when it clears,
	so brief physics glitches, lag, and legitimate edge cases never cross the line.
	A rollback threshold self-corrects the player; a much higher report threshold
	is what actually escalates to the server.

	Pure and deterministic: callers pass the current time, frame delta, and whether
	an anti-cheat grace window is active, so the whole engine is unit-testable with
	no game running. Adapted from the reference anti-cheat's scoring core.
]]

local MAX_SCORE_STEP = 30

export type State = {
	score: number,
	nextRollbackAt: number,
	nextReportAt: number,
}

export type Action = {
	rollback: boolean,
	report: boolean,
}

local function createState(): State
	return {
		score = 0,
		nextRollbackAt = 0,
		nextReportAt = 0,
	}
end

--> Ramp the score while `condition` holds, decay it otherwise. During a grace
--> window the score always decays (twice as fast) so post-teleport / post-lag
--> states can never accumulate suspicion.
local function update(state: State, condition: boolean, dt: number, suspicionRate: number, decayRate: number, graceActive: boolean)
	if graceActive then
		state.score = math.max(0, state.score - math.min(decayRate * dt * 120, MAX_SCORE_STEP * 2))
		return
	end

	if condition then
		state.score += math.min(suspicionRate * dt * 60, MAX_SCORE_STEP)
	else
		state.score = math.max(0, state.score - math.min(decayRate * dt * 60, MAX_SCORE_STEP))
	end
end

--> Like `update` but adds a fixed lump on a discrete event (e.g. a single
--> teleport) rather than ramping over time.
local function addScore(state: State, condition: boolean, dt: number, scoreAdd: number, decayRate: number, graceActive: boolean)
	if graceActive then
		state.score = math.max(0, state.score - math.min(decayRate * dt * 120, MAX_SCORE_STEP * 2))
		return
	end

	if condition then
		state.score += math.min(scoreAdd, MAX_SCORE_STEP)
	else
		state.score = math.max(0, state.score - math.min(decayRate * dt * 60, MAX_SCORE_STEP))
	end
end

--> Decides what to do this tick. Returns whether to roll the player back and/or
--> report to the server, honouring per-action cooldowns and the grace window.
local function process(
	state: State,
	condition: boolean,
	now: number,
	rollbackLimit: number,
	reportLimit: number,
	rollbackCooldown: number,
	reportCooldown: number,
	graceActive: boolean
): Action
	local action: Action = { rollback = false, report = false }

	if graceActive or not condition then
		return action
	end

	if state.score >= rollbackLimit and now >= state.nextRollbackAt then
		state.nextRollbackAt = now + rollbackCooldown
		action.rollback = true
	end
	if state.score >= reportLimit and now >= state.nextReportAt then
		state.nextReportAt = now + reportCooldown
		action.report = true
	end

	return action
end

return {
	MAX_SCORE_STEP = MAX_SCORE_STEP,
	createState = createState,
	update = update,
	addScore = addScore,
	process = process,
}
