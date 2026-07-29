# Test suite

`lune run Test --ci` from `test/`. A passing run takes **13-14 seconds**.

The suite has a 120-second watchdog. If it fires you get `[TIMEOUT] suite
stalled for 120s` plus the main thread's status, and exit code 19 -- never a
silent hang. That matters because `Shared.luau`'s Heartbeat driver is a
`while true` loop, so once the main thread is gone Lune has no reason to exit
and the process would otherwise sit there until the CI job's own timeout.

The malformed-packet fuzzer is seeded (default `0x0C4EE70`, printed on every
run). Replay a run with `CHEETO_FUZZ_SEED=<n>`, narrow a bad packet with
`CHEETO_FUZZ_N=<iterations>`.

## Fixed: the intermittent stall was `coroutine.close` on a bystander

For a long time the suite hung on roughly 40% of runs (measured 2026-07-28: 2/5
on `main`), and the cause was mis-attributed to a "malformed packet that does
not terminate". It was neither malformed-packet-specific nor a deadlock.
**Cheeto was closing an unrelated coroutine.**

With `SyncValidation` on, the generator emitted this at the top of each packet
processor:

    if SerdesThread and coroutine.status(SerdesThread) == "suspended" then
        warn(`[Cheeto]: Yielded in a Sync call. ...`)
        coroutine.close(SerdesThread)
    end
    SerdesThread = coroutine.running()

`SerdesThread` was assigned on every packet and **never cleared**, so any thread
that had ever processed a packet stayed a standing kill target. The next packet
closed it if it merely happened to be `suspended` -- for any reason whatsoever.

In the suite that thread is the main thread (`FireSignalSync` and
`StepReplication` run the processor inline on the caller). It fired an event
early on, later parked awaiting `require("./Datatypes")`, and a subsequent
packet closed it mid-await. The module body finished on its own thread, had
nobody left to return to, and the process idled -- measured at **0.42s of CPU
over 600s of wall clock**, which is what finally ruled out both "slow" and
"spinning".

`coroutine.close` is not an error, so `pcall` around the `require` caught
nothing and the thread simply became `dead`. That is why every earlier theory
(loop bounds, pending invocations, `CancelInvocations`) failed, and why adding
any yield point appeared to "fix" it -- it changed which thread was suspended at
the moment the next packet arrived.

### The fix

`SerdesThread` is now set only while a Sync listener is actually on the stack
and cleared the moment it returns, so finding it suspended is real proof that a
Sync handler yielded. The `coroutine.close` is gone: the diagnostic is the
warning, and aborting somebody else's coroutine half-way through is not a
diagnostic.

This was never test-only. Any game thread that fired a Cheeto Sync event and
then waited on something unrelated could be killed, silently.

### Verification

12/12 seeds green, including all five that previously hung (2, 42, 555, 31337,
12345678) and the old reproducer `CHEETO_FUZZ_SEED=2 CHEETO_FUZZ_N=9`. Three
consecutive default runs green. Restoring the old `coroutine.close` makes the
suite stall again and the watchdog reports it, so the bystander check in
`Test.luau` plus the watchdog are a real regression gate, not decoration.

## Other bugs found while chasing it

All fixed, none of them were the stall:

- `WriteVarint` / `EncodeVarint` loop `until Remaining <= 0`, which **neither
  NaN nor +inf ever satisfies**, so a non-finite value reaching a varint write
  spins forever. Both now reject non-finite and negative input.
- `ExpireInvocations()` existed but **was never called from anywhere**, so
  configured invoke timeouts never fired: an Invoke whose reply never arrives
  left its thread suspended for the life of the server, leaking a coroutine per
  lost reply. It is now swept every frame from `StepReplication`.
- `CheckAuth` **raised** on an unregistered auth rule. That call sits per-event
  inside the batched receive loop, so one typo'd rule name aborted the rest of
  the packet and took unrelated events down with it. It now drops and warns
  once, matching `CheckPolicy`. The `Auth` path had no test coverage at all,
  which is why it survived; it does now.
- An invocation could be resumed without proof that its thread was waiting for
  it. The identifier selecting which invocation to resolve is a `u8` read
  straight off the wire, and if anything threw between taking an identifier and
  reaching the yield, the entry outlived its thread -- so a later packet could
  resume a thread that had since parked on something else. `AwaitInvocation`
  now records the parked thread and only that thread is resumed, once.
- `CheckReplay` swept the whole seen-sequence table on **every** packet, and the
  sender controls how many sequence numbers are tracked, so a linear send rate
  bought quadratic work. It now sweeps only once the window is over capacity.

## Adding events to `Sources/Test.cheeto`

WireIds are assigned in declaration order, so **append**; inserting mid-file
shifts every later id and breaks the golden wire snapshots.
