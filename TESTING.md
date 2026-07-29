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

### What is established

- **It is a deadlock, not an infinite loop.** A `task.delay` watchdog fires
  during the stall, so the scheduler is alive and the main thread is *waiting*
  on a resume that never comes. This is why loop guards never helped, and why
  inserting any yield point (an `fs.writeFile`) makes the stall disappear --
  it is a heisenbug, so instrument with care.
- **Only ServerReliable triggers it.** Fuzzing each direction alone: server
  reliable 3/3 hang, server unreliable / client reliable / client unreliable
  0/3 each.
- **It needs accumulated state.** With only ServerReliable, N=8 passes and N=9
  hangs, reproducibly.
- **Not a pending invocation.** Calling `CancelInvocations()` on both sides
  from a watchdog does not release it.
- A fixed seed is necessary but not sufficient: it still varies run to run
  (2/3), so something clock-driven participates -- rate limits, cooldowns and
  invocation bookkeeping all key off `os.clock()`.
- The runtime itself contains no `coroutine.yield`; the waits that exist are
  `task.wait` inside spawned probe threads.

### Ruled out (guards kept anyway)

Bounding the read loop (`ReadGuard`) and forcing forward progress in
`EndReadMessage` did not fix it. Both were kept: bounding a loop that runs over
attacker-controlled bytes is worth having on its own merits.

### Two real bugs found while chasing it

Neither is this hang, both are genuine and are fixed:

- `WriteVarint` / `EncodeVarint` loop `until Remaining <= 0`, and **neither NaN
  nor +inf ever satisfies that**, so a non-finite value reaching a varint write
  spins forever. That is an unauthenticated server hang if attacker-influenced
  data can reach it. Both now reject non-finite and negative input.
- `ExpireInvocations()` existed but **was never called from anywhere**, so
  configured invoke timeouts never fired: an Invoke whose reply never arrives
  left its thread suspended for the life of the server, leaking a coroutine per
  lost reply. It is now swept every frame from `StepReplication`.

### Next step

The stall is a suspended thread. Enumerate what can suspend and never be
resumed on the *server reliable receive* path specifically, given invocations
are excluded. A per-thread registry that records creation sites, dumped from
the watchdog, would name it directly.
