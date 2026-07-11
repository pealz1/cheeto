# Cheeto Security — Infinite Yield detection

Client/server module that detects the [Infinite Yield](https://github.com/EdgeIY/infiniteyield)
admin/exploit script and kicks the player, over a signed report channel with a
heartbeat-timeout fallback.

## Files

| File | Role |
|------|------|
| `IYSignatures.luau` | Pure fingerprint matcher. Given a GUI container, reports whether Infinite Yield is present and which signal matched. No side effects — this is the tested core. |
| `SecureReport.luau` | Signing helpers (`sign` / `verify`) for the report channel. |
| `Config.luau` | Shared constants (remote name, intervals, timeouts) so client and server never drift. |
| `IYDetector.client.luau` | LocalScript. Handshakes, sweeps readable GUI containers, sends signed detection reports + heartbeats. Put in `StarterPlayerScripts`. |
| `IYGuard.server.luau` | Server Script. Issues session secrets, verifies reports, kicks on detection or on heartbeat timeout. Put in `ServerScriptService`. |

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

`test/Security.luau` builds real instance trees with `@lune/roblox`: it asserts every
IY-shaped tree is detected with the right signal, asserts legitimate GUIs (including
one with a `Holder` frame and a `Cmdbar`-adjacent search box) are **not** detected —
the false-positive guard — and checks that tampered, replayed, and malformed
signatures are rejected. Run with `lune run Security` from `test/`.
