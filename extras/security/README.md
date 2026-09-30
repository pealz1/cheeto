# Security toolkit

Standalone client and server detectors that run alongside any networking setup. Two detectors share one signed report channel with a heartbeat-timeout fallback:

- **Infinite Yield detection** fingerprints the [Infinite Yield](https://github.com/EdgeIY/infiniteyield) admin script and removes the player.
- **Movement anti-cheat** catches speed, fly, noclip, infinite jump, mass, void teleport, anti-gravity and anti-knockback, and rolls the player back well before it ever reports them.

> [!TIP]
> If your game already uses a Cheeto schema, start with [`SecurityPreset = Maximum`](https://pealz.cc/cheeto/security/maximum-security) instead. It runs liveness challenges and server-side character checks over Cheeto's own transport, without a second RemoteEvent. This toolkit is for games that have not moved their networking to Cheeto yet, or that want an extra layer.

## Files

Every script requires its dependencies from `script.Parent`, so keep the modules next to the scripts that use them.

| File | Kind | Where | Role |
| --- | --- | --- | --- |
| `IYDetector.client.luau` | LocalScript | `StarterPlayerScripts` | Scans readable GUI containers and reports Infinite Yield hits |
| `MovementAnticheat.client.luau` | LocalScript | `StarterPlayerScripts` | Runs the movement detectors, corrects the player and reports |
| `IYGuard.server.luau` | Script | `ServerScriptService` | Issues session secrets, verifies reports, removes players on a verified detection or a missed heartbeat |
| `SecureChannel.luau` | ModuleScript | shared | Client side of the channel: handshake, heartbeat and signed `send` |
| `SecureReport.luau` | ModuleScript | shared | `sign` and `verify` helpers |
| `IYSignatures.luau` | ModuleScript | shared | Pure fingerprint matcher, no side effects |
| `SuspicionScore.luau` | ModuleScript | shared | Pure scoring engine behind every movement detector |
| `KnockbackForce.luau` | ModuleScript | shared | Pure horizontal force summation for the anti-knockback detector |
| `Config.luau` | ModuleScript | shared | Channel constants: remote name, intervals, timeouts |
| `MovementConfig.luau` | ModuleScript | shared | Movement tuning, grouped per detector |

## How it works

1. **Handshake.** The client sends `hello` and the server answers with a per-session `secret` and `nonce`.
2. **Scan.** Every few seconds the client runs `IYSignatures.scan` over every GUI container it can read and sends a signed `detect` report on a hit.
3. **Verify.** The server checks the signature and a strictly increasing sequence number, which blocks replay, then removes the player.
4. **Heartbeat.** The client also sends signed heartbeats. If a client that completed the handshake goes quiet for longer than `HeartbeatTimeout`, because the detector was deleted or its reports are being blocked, the server removes it too. A join grace period and lag-hitch forgiveness keep loading or lagging players safe.

## Detection signals

Each signal keys off something Infinite Yield renders and ordinary games do not, so a single match is enough:

- **`brand-text`**: any GUI text containing `Infinite Yield`. It matches a substring, so version bumps and the seasonal emoji in the title do not matter.
- **`credits-text`**: the script's verbatim credits line.
- **`cmdbar-textbox`**: a `TextBox` named `Cmdbar` with the placeholder `Command Bar`.
- **`holder-cmdbar-structure`**: a `Frame` named `Holder` containing a `TextBox` named `Cmdbar`, which still matches if the placeholder changes.

Because the signals are independent, renaming the root `ScreenGui` does not defeat detection.

## Movement anti-cheat

Each detector computes a per-tick "is this happening right now?" condition and feeds it to `SuspicionScore`. The score ramps while the condition holds and decays when it clears.

- Crossing the low **rollback** threshold corrects the player by resetting the offending property and CFrame.
- Crossing the much higher **report** threshold sends a signed report and the server removes the player.

The gap between the two thresholds, together with a teleport grace window and a lag-skip guard, is what keeps physics glitches, lag spikes and server teleports from ever reaching a report.

Detectors: walk speed, jump power, hip height, illegal humanoid states, infinite jump, CFrame walk-fly mismatch, mass density, void teleport, frozen-Y anti-gravity and anti-knockback (ignoring or pushing through a strong `VectorForce` under `Terrain`). Disabled or missing knockback forces are deliberately not flagged because they have too many legitimate causes.

Tune everything in `MovementConfig.luau`.

## Limitations

This raises the bar considerably, but it is not a guarantee:

- **Only readable containers are scanned.** Recent versions of Infinite Yield parent their UI to protected `CoreGui` through `gethui()`, which a normal LocalScript cannot see. When the UI lands somewhere readable, as it does on many executors and older versions, detection is immediate and has no false positives. An executor that hides the UI and also disables this script will not be caught by the scan; the heartbeat timeout is the fallback for that case. No game-side Luau can fully defend against code running at a higher privilege level.
- **The session secret lives in client memory.** Someone who reads the script can reproduce a signature. Signing is defence in depth; the heartbeat timeout is what carries the weight.

## Tests

The pure modules are covered by the main test suite:

- `test/Security.luau` builds real instance trees with `@lune/roblox`, checks that every Infinite Yield shape is detected with the right signal, checks that lookalike legitimate GUIs are not, and rejects tampered, replayed and malformed signatures.
- `test/Movement.luau` drives `SuspicionScore` deterministically: ramp and decay, grace windows, cooldowns, and rollback firing well before report.
- `test/Knockback.luau` checks force summation for world and attachment relative forces, disabled forces, unrelated children and vertical-only forces.

Run them with the rest of the suite (`lune run Test` from `test/`), or individually with `lune run Security`, `lune run Movement` and `lune run Knockback`.
