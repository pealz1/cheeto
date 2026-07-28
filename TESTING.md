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

## Fixing it

Not attempted here. The fuzzing closure is the obvious suspect: seed it
deterministically (or log the seed) so a hang can be reproduced, then narrow
down which malformed packet fails to terminate. Until then a hang says nothing
about the change under test.
