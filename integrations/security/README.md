# Cheeto Security

Client/server security layer for Cheeto. It runs two detectors over one shared,
signed report channel with a heartbeat-timeout fallback:

- **Infinite Yield detection** — fingerprints the [Infinite Yield](https://github.com/EdgeIY/infiniteyield)
  admin/exploit script and kicks the player.
- **Movement anti-cheat** — speed / fly / noclip / infinite-jump / mass / void-teleport
  / anti-gravity detection with self-correcting rollback before it ever escalates.

## Files

| File | Role |
|------|------|
| `IYSignatures.luau` | Pure IY fingerprint matcher. Given a GUI container, reports whether Infinite Yield is present and which signal matched. No side effects — a tested core. |
| `SuspicionScore.luau` | Pure suspicion-scoring engine for the movement anti-cheat — the false-positive safety. A tested core. |
| `KnockbackForce.luau` | Pure horizontal-force summation over `Terrain` VectorForces for the anti-knockback detector. A tested core. |
| `SecureReport.luau` | Signing helpers (`sign` / `verify`) for the report channel. |
| `SecureChannel.luau` | Shared client channel: one handshake + heartbeat + signed `send`, used by every detector. |
| `Config.luau` | Shared channel constants (remote name, intervals, timeouts). |
| `MovementConfig.luau` | Movement-detector tuning, grouped per detector. |
| `IYDetector.client.luau` | LocalScript. Sweeps readable GUI containers, reports IY hits. `StarterPlayerScripts`. |
| `MovementAnticheat.client.luau` | LocalScript. Runs the movement detectors, self-corrects, reports. `StarterPlayerScripts`. |
| `IYGuard.server.luau` | Server Script. Issues session secrets, verifies reports, kicks on detection or heartbeat timeout. `ServerScriptService`. |

## How it works

1. **Handshake** — the client sends `hello`; the server issues a per-session
   `secret` + `nonce` and stores them.
2. **Scan** — every few seconds the client runs `IYSignatures.scan` over every GUI
   container it can read and, on a hit, sends a signed `detect` report.
3. **Verify + kick** — the server verifies the signature and the strictly
   increasing sequence number (which blocks replay), then kicks.
4. **Heartbeat fallback** — the client sends signed heartbeats; if a client that
   finished the handshake goes silent past `HeartbeatTimeout` (detector removed or
   its reports blocked), the server kicks it too. Lag hitches are forgiven and a
   join grace applies, so legitimate players are never falsely kicked.

## Detection signals

Each is individually high-confidence — a single match is a kick, with effectively
zero false positives, because each keys off something IY renders that legitimate
games do not:

- **`brand-text`** — any GUI text containing `Infinite Yield` (matches the substring,
  so it survives version bumps and the seasonal emoji injected into the title).
- **`credits-text`** — IY's verbatim credits line.
- **`cmdbar-textbox`** — a `TextBox` named `Cmdbar` whose placeholder is `Command Bar`.
- **`holder-cmdbar-structure`** — a `Frame` named `Holder` containing a descendant
  `TextBox` named `Cmdbar` (catches the command bar even if the placeholder changes).

Multiple independent signals mean IY randomizing its root `ScreenGui` name does not
defeat detection — the inner text and structure stay constant.

## Movement anti-cheat

Runs per character. Each detector computes a per-tick "cheating right now?" boolean
and feeds it to `SuspicionScore`, which ramps a score while the condition holds and
decays it otherwise. Crossing a low **rollback** threshold self-corrects the player
(resets the offending property + CFrame); crossing a much higher **report** threshold
reports over the secure channel and the server kicks. A teleport-grace window and a
lag-skip guard mean legitimate physics glitches, lag spikes, and server teleports
never accumulate suspicion — that gap between rollback and report is what keeps it
free of false kicks.

Ported detectors: walkspeed / jump-power / hip-height / illegal humanoid state /
infinite-jump, CFrame walk-fly mismatch, mass-density, panic void-teleport,
frozen-Y anti-gravity, and **anti-knockback** (ignoring a strong `VectorForce`
knockback aura in `Terrain`, or shoving straight through it). Following the
reference, the disabled-force / missing-force variants are deliberately not flagged —
they have too many legitimate triggers.

## Honest limitations

Read this before trusting it as a guarantee — it is not one:

- **It only sees IY in containers a game script may read.** Modern IY parents its UI
  into protected `CoreGui` via `gethui()` and marks itself on `getgenv().IY_LOADED`,
  both invisible to a normal-privilege LocalScript. When IY's UI lands somewhere
  readable (common on many executors, older IY, or a misconfigured `gethui`) it is
  caught with zero false positives and an instant kick. A fully cloaked executor
  that also neuters this script evades it — **no game-side Luau can beat
  higher-privilege code.** This raises the bar hard against stock IY; it is not
  absolute.
- **The session secret lives in client memory**, so an exploiter who reads this
  script can reproduce a signature. The signing is defence in depth; the
  load-bearing fallback is the heartbeat-timeout kick.

## Tests

- `test/Security.luau` builds real instance trees with `@lune/roblox`: asserts every
  IY-shaped tree is detected with the right signal, asserts legitimate GUIs (including
  one with a `Holder` frame and a `Cmdbar`-adjacent search box) are **not** detected —
  the false-positive guard — and checks tampered / replayed / malformed signatures are
  rejected.
- `test/Movement.luau` drives the `SuspicionScore` engine deterministically: scores
  ramp only under sustained conditions and decay when clean, the grace window
  suppresses scoring and actions, per-action cooldowns hold, and the rollback
  threshold trips well before the report threshold.
- `test/Knockback.luau` builds real `VectorForce` instances with `@lune/roblox` and
  asserts the horizontal-force summation: world- and attachment-relative forces,
  disabled forces (a bypass signal, not counted), wrong-attachment and non-force
  children ignored, and vertical-only forces contributing no horizontal push.

Both run inside the CI `Test` suite; run individually with `lune run Security` /
`lune run Movement` from `test/`.
