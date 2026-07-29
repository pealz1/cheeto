# Test suite: known intermittent hang

`lune run Test --ci` hangs roughly 40% of the time on `main`, unrelated to any
recent change. Measured 2026-07-28 by running it repeatedly on an unmodified
checkout:

    main            2 hangs / 5 runs
    feat/shared-runtime  2 / 3
    ab6cdb1 (partial)    1 / 3

A passing run takes **13-14 seconds**. A hanging run produces no further output
and burns whatever timeout you give it, so a long run is always a hang, never
slow work. The stall point varies between runs (observed at 112 and 133 lines of
output, i.e. inside or just after the datatype roundtrips), which is what you
would expect from the malformed-packet fuzzing closure: it drives 128 iterations
of `RandomBuffer(math.random(1, 96))` through every reliable and unreliable
endpoint, so the input differs per process.

## Why this matters

The failure mode is indistinguishable from a regression. Two conclusions were
drawn from single hanging runs during this work and both turned out to be wrong:

- that swapping the manual copy loops in `Base.luau` for `table.clone` hangs the
  suite -- it does not, that was this flake
- that the first run after regenerating is slow because it recompiles the test
  schemas -- it is not, passing runs are 14 seconds either way

**Run the suite at least three times before believing a hang is yours.**

## Fixed: the fuzzer is seeded

The closure now seeds `math.randomseed` with a fixed value and prints it. The
suite is deterministic: 5/5 green on the default seed, where it was ~40% hangs
before. Replay any run with `CHEETO_FUZZ_SEED=<n>`, and narrow a bad packet down
with `CHEETO_FUZZ_N=<iterations>`.

## Still open: a malformed packet that does not terminate

Seeding made the hang reproducible, not gone. Seeds **2, 3, 7 and 1337** still
hang; 1, 42, 99999 and the default do not. Reproducer:

    CHEETO_FUZZ_SEED=2 CHEETO_FUZZ_N=9 lune run Test --ci

Bisected to fuzz iteration 9 (N=8 passes, N=9 hangs). What is known:

- the fuzz loop itself completes; the stall is later
- stage markers show `require("./Datatypes")` never returns, while its final
  line still reaches stdout -- stdout is block-buffered, so the visible tail is
  not a reliable indicator of where execution actually stopped
- bounding the read loop (`ReadGuard`) and forcing forward progress in
  `EndReadMessage` did NOT fix it, so it is not the top-level message loop

Both guards were kept anyway: bounding a loop that runs over attacker-controlled
bytes is worth having regardless of this particular bug.

Next step would be a standalone harness that replays the offending packet
outside the suite, so the stall can be caught without the buffering confusion.
