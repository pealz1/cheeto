# Test suite

Run the whole suite from this directory:

```sh
lune run Test --ci
```

A passing run takes about 15 seconds. `Test.luau` compiles every schema in `Sources/`, loads the generated client and server modules into a simulated Roblox environment (`Shared.luau`, `Client.luau`, `Server.luau`), and then runs:

- roundtrip tests for every event, function and datatype, including byte-exact snapshots of the wire format,
- security tests for policies, auth rules, rate limits, replay protection, honeypots and the client shield,
- a seeded malformed-packet fuzzer that drives random buffers through every endpoint,
- every CLI report mode (`--doctor`, `--strict`, `--check-lock`, `--hardening-checklist` and the rest).

`Datatypes.luau`, `Security.luau`, `Movement.luau` and `Knockback.luau` are also run by `Test.luau`, and each can be run on its own, for example `lune run Datatypes`.

## Watchdog

The suite has a 120 second watchdog. If it fires, it prints `[TIMEOUT] suite stalled for 120s` with the main thread's status and exits with code 19. The simulated Heartbeat loop never ends on its own, so without the watchdog a stalled run would sit until the CI job timed out.

## Replaying a fuzzer failure

The malformed-packet fuzzer uses a fixed seed and prints it on every run.

| Variable | Effect |
| --- | --- |
| `CHEETO_FUZZ_SEED=<n>` | Replay a run with a specific seed |
| `CHEETO_FUZZ_N=<n>` | Run only the first `n` iterations, to narrow down a bad packet |

```sh
CHEETO_FUZZ_SEED=42 CHEETO_FUZZ_N=9 lune run Test --ci
```

## Fixtures

| File | Purpose |
| --- | --- |
| `Sources/Test.cheeto` | The main schema used by most runtime tests |
| `Sources/cheeto.lock` | Wire IDs and schema hashes for `Test.cheeto` |
| `Sources/HardeningGood.cheeto` | A configuration that must pass `--hardening-checklist` |
| `Sources/StrictBad.cheeto`, `LegacyBad.cheeto`, `CharacterIntegrityBad.cheeto` | Configurations that must be rejected |
| `Sources/Datatypes.cheeto` | One event per supported Roblox datatype |
| `Sources/Yields.cheeto` | Coroutine, Future and Promise function emission |
| `Sources/Import.cheeto`, `Sources/Sub-Sources/` | Imports across directories |

### Adding events to `Test.cheeto`

Wire IDs are assigned in declaration order, so **append** new events at the end of the file. Inserting one in the middle shifts every later ID and breaks the wire snapshots. If you change the wire layout on purpose, regenerate the lockfile from the repository root:

```sh
lune run src/CLI/init.luau test/Sources/Test -- --write-lock --yes
```

## Invariants worth keeping

Two of the hardest bugs this suite has caught came from the same mistake: acting on a thread without proof that it was waiting for you. The runtime therefore never closes or resumes a coroutine unless it knows exactly where that coroutine is parked, and `Test.luau` checks that a bystander thread survives a Sync handler that yields. Keep that test green when you touch the receive path.
