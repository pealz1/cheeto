--[[
	Coverage for the movement anti-cheat's suspicion-scoring engine — the piece
	that keeps the whole system free of false positives. Pure arithmetic, so it is
	fully deterministic here.
]]

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Suspicion = require("../integrations/security/SuspicionScore")

local function Ok(message: string)
	stdio.write(`[{stdio.color("green")}OK{stdio.color("reset")}] {message}\n`)
end

local function check(condition: boolean, message: string)
	if not condition then
		stdio.write(`[{stdio.color("red")}FAIL{stdio.color("reset")}] {message}\n`)
		process.exit(23)
	end
end

--> Per-tick ramp is capped at MAX_SCORE_STEP regardless of how large the rate is.
do
	local state = Suspicion.createState()
	Suspicion.update(state, true, 0.5, 4, 3, false)
	check(state.score == Suspicion.MAX_SCORE_STEP, "single tick ramps by exactly MAX_SCORE_STEP")
	Ok("Score ramps by the capped step while cheating")
end

--> Sustained cheating eventually crosses both thresholds; a brief spike does not.
do
	local state = Suspicion.createState()
	local rollbackLimit, reportLimit = 45, 300

	--> Two ticks: over the rollback line, well under the report line.
	Suspicion.update(state, true, 0.5, 4, 3, false)
	Suspicion.update(state, true, 0.5, 4, 3, false)
	check(state.score == 60, "two ticks accumulate to 60")
	local brief = Suspicion.process(state, true, 100, rollbackLimit, reportLimit, 0.3, 8, false)
	check(brief.rollback == true, "60 >= rollback limit rolls back")
	check(brief.report == false, "60 < report limit does not report")

	--> Keep cheating until the report threshold is crossed.
	for _ = 1, 8 do
		Suspicion.update(state, true, 0.5, 4, 3, false)
	end
	check(state.score >= reportLimit, "sustained cheating reaches the report threshold")
	local sustained = Suspicion.process(state, true, 200, rollbackLimit, reportLimit, 0.3, 8, false)
	check(sustained.report == true, "crossing the report threshold reports")
	Ok("Thresholds require sustained conditions, not a brief spike")
end

--> Score decays back to zero once the condition clears.
do
	local state = Suspicion.createState()
	for _ = 1, 12 do
		Suspicion.update(state, true, 0.5, 4, 3, false)
	end
	check(state.score > 0, "score built up")
	for _ = 1, 20 do
		Suspicion.update(state, false, 0.5, 4, 3, false)
	end
	check(state.score == 0, "score decays to zero when clean")
	Ok("Score decays to zero when the condition clears")
end

--> Grace forces decay even while the condition is still true (post-teleport /
--> post-lag), and process refuses to act during grace.
do
	local state = Suspicion.createState()
	for _ = 1, 12 do
		Suspicion.update(state, true, 0.5, 4, 3, false)
	end
	local high = state.score
	Suspicion.update(state, true, 0.5, 4, 3, true)
	check(state.score < high, "grace decays the score even while cheating flag is set")
	local action = Suspicion.process(state, true, 300, 45, 300, 0.3, 8, true)
	check(action.rollback == false and action.report == false, "process never acts during grace")
	Ok("Grace window suppresses scoring and actions")
end

--> Action cooldowns prevent the same escalation from firing every tick.
do
	local state = Suspicion.createState()
	for _ = 1, 12 do
		Suspicion.update(state, true, 0.5, 4, 3, false)
	end
	local first = Suspicion.process(state, true, 500, 45, 300, 0.3, 8, false)
	check(first.rollback == true, "first process rolls back")
	local second = Suspicion.process(state, true, 500, 45, 300, 0.3, 8, false)
	check(second.rollback == false, "rollback is on cooldown within the same window")
	local later = Suspicion.process(state, true, 501, 45, 300, 0.3, 8, false)
	check(later.rollback == true, "rollback fires again after the cooldown elapses")
	Ok("Per-action cooldowns are honoured")
end

--> addScore lumps a discrete event but is still capped per tick.
do
	local state = Suspicion.createState()
	Suspicion.addScore(state, true, 0.5, 150, 8, false)
	check(state.score == Suspicion.MAX_SCORE_STEP, "discrete add is capped at MAX_SCORE_STEP")
	Ok("Discrete-event scoring is capped")
end

stdio.write(`{stdio.color("green")}All movement scoring tests passed!{stdio.color("reset")}\n`)

return true
