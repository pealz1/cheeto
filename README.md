<div align="center">

<a href="https://pealz1.github.io/cheeto">
  <img src="docs/public/og.png" alt="Cheeto: typed, buffer-packed and hard-to-abuse networking for Roblox" width="100%">
</a>

<br>
<br>

[![CI](https://img.shields.io/github/actions/workflow/status/pealz1/cheeto/ci.yml?branch=main&style=flat-square&label=CI&color=f97316)](https://github.com/pealz1/cheeto/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/pealz1/cheeto?style=flat-square&color=f97316)](https://github.com/pealz1/cheeto/releases/latest)
[![Docs](https://img.shields.io/badge/docs-pealz1.github.io%2Fcheeto-f97316?style=flat-square)](https://pealz1.github.io/cheeto)
[![License](https://img.shields.io/github/license/pealz1/cheeto?style=flat-square&color=f97316)](LICENSE)
[![Luau](https://img.shields.io/badge/written%20in-Luau-00a2ff?style=flat-square)](https://luau.org)

**[Documentation](https://pealz1.github.io/cheeto)** ·
**[Quick start](https://pealz1.github.io/cheeto/getting-started/quick-start)** ·
**[Language reference](https://pealz1.github.io/cheeto/language/options)** ·
**[Releases](https://github.com/pealz1/cheeto/releases)**

</div>

---

Cheeto is a compiler for Roblox networking. You describe your events, functions and state in a small schema language, and Cheeto generates the Luau modules that send and receive them: buffer-packed, fully typed on both sides, and guarded by validation, rate limits and replay protection before your code ever runs.

```cheeto
option ClientOutput = "Network/Client.luau"
option ServerOutput = "Network/Server.luau"

struct Hit {
    Target: Instance(Player),
    Damage: u16(0..500)
}

event DealDamage {
    From: Client,
    Type: Reliable,
    Call: SingleAsync,
    Policy: "damage",
    CooldownSeconds: 0.25,
    Data: Hit
}
```

```lua
-- Server
local Network = require(ReplicatedStorage.Network.Server)

Network.Security.RegisterPolicy("damage", function(context)
    return context.Source.Character ~= nil, "no-character"
end)

Network.DealDamage.On(function(player, hit)
    Combat.Apply(player, hit.Target, hit.Damage)
end)
```

```lua
-- Client
local Network = require(ReplicatedStorage.Network.Client)

Network.DealDamage.Fire({ Target = target, Damage = 25 })
```

Checking `Damage` against `0..500`, enforcing the cooldown, running the policy and rejecting malformed packets all happen in generated code. Anything that does not match the schema is dropped before it reaches yours.

## Features

**Fast by construction**
- Every field is written at its declared width. Integers are varint-encoded, booleans bit-pack, and events are batched into one buffer per frame.
- 30+ Roblox datatypes with purpose-built encodings, including `CFrame`, `Color3`, `UDim2`, `NumberSequence`, `Font` and `EnumItem`.
- Reliable fragmentation, priority lanes and latest-only unreliable events for high-frequency state.

**Typed end to end**
- Generated Luau types for the client and the server, with full autocomplete.
- Optional TypeScript definitions for roblox-ts projects.
- Structs, enums, tagged enums, maps, sets, optionals, generics and imports.

**Hard to abuse**
- Size caps, decode budgets and payload canonicalization drop malformed data before a listener runs.
- Per-event policies, auth rules, rate limits, cooldowns and idempotency.
- Replay protection, honeypot events and a v2 handshake that checks protocol, schema version and schema hash.
- `SecurityPreset = Maximum` adds a client shield, integrity challenges, server-side movement checks, rotating remote names and decoy remotes.

**Built for production**
- `--doctor`, `--strict` and `--hardening-checklist` catch unsafe configuration before release.
- `cheeto.lock` pins wire IDs so schema changes never silently break live servers.
- Packet capture and replay, golden wire snapshots, load simulation, metrics and an inspector.
- State channels with delta replication, interpolation and prediction.

**Fits your workflow**
- A single binary for Windows, macOS and Linux, a pesde package, and a Roblox Studio plugin.
- Watch mode recompiles whenever a schema or one of its imports changes.

## Installation

With [Rokit](https://github.com/rojo-rbx/rokit) (recommended):

```sh
rokit add pealz1/cheeto
```

With [pesde](https://pesde.dev):

```sh
pesde add --dev pealz1/cheeto
```

Or download a binary or the Studio plugin from the [latest release](https://github.com/pealz1/cheeto/releases/latest).

## Usage

```sh
cheeto network            # compile network.cheeto
cheeto network --watch    # recompile on every change
cheeto network --doctor   # validate without writing files
cheeto network --ci --yes # run every report and lockfile check
```

`cheeto --help` lists every option. The [command line guide](https://pealz1.github.io/cheeto/getting-started/cli) covers them in detail.

## Security model

No networking library can hide data from the client that receives it, and Cheeto does not pretend to. Instead it keeps authority on the server and makes captured traffic hard to use: every client request is checked against the schema and your policies before a handler runs, replayed and duplicate packets are rejected, and every drop is reported through `Security.OnViolation` with a typed reason you can act on.

Read [Maximum Security](https://pealz1.github.io/cheeto/guides/maximum-security) for the full model, and [SECURITY.md](SECURITY.md) to report a vulnerability.

## Documentation

| | |
| --- | --- |
| [Installation](https://pealz1.github.io/cheeto/getting-started/installation) | Every way to install the compiler and the plugin |
| [Quick start](https://pealz1.github.io/cheeto/getting-started/quick-start) | Your first schema in five minutes |
| [Language reference](https://pealz1.github.io/cheeto/language/options) | Options, types, events, functions, scopes and imports |
| [Production hardening](https://pealz1.github.io/cheeto/guides/production) | Policies, capture and replay, migrations and CI reports |
| [Protocol v2](https://pealz1.github.io/cheeto/guides/protocol-v2) | Wire format, lockfiles, handles and the runtime API |
| [Comparison](https://pealz1.github.io/cheeto/guides/comparison) | How Cheeto relates to Zap, Jolt and NetRay |

## Repository layout

```text
src/         the compiler: lexer, parser, generator and CLI
plugin/      the Roblox Studio plugin
extras/      optional standalone security detectors
test/        the test suite and schema fixtures
benchmark/   the in-Studio benchmark harness
docs/        the documentation site
```

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) to get set up, and follow the [code of conduct](CODE_OF_CONDUCT.md). In short:

```sh
rokit install
cd test && lune run Test --ci
```

## Contributors

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="25%"><a href="https://github.com/pealz1"><img src="https://github.com/pealz1.png?size=100" width="80px;" alt="pealz1"/><br /><sub><b>pealz1</b></sub></a><br />Maintainer</td>
      <td align="center" valign="top" width="25%"><a href="https://github.com/1Axen"><img src="https://github.com/1Axen.png?size=100" width="80px;" alt="1Axen"/><br /><sub><b>1Axen</b></sub></a><br />Original compiler</td>
      <td align="center" valign="top" width="25%"><a href="https://github.com/ArvidSilverlock"><img src="https://github.com/ArvidSilverlock.png?size=100" width="80px;" alt="ArvidSilverlock"/><br /><sub><b>ArvidSilverlock</b></sub></a><br />float16 encoding</td>
    </tr>
  </tbody>
</table>
<!-- ALL-CONTRIBUTORS-LIST:END -->

Want to see your name here? Pick up an issue and open a pull request.

## Acknowledgements

- Cheeto's compiler core is derived from MIT-licensed work by [1Axen](https://github.com/1Axen).
- The range and array syntax is inspired by [Zap](https://zap.redblox.dev).
- The float16 implementation is by [ArvidSilverlock](https://github.com/ArvidSilverlock).
- The syntax grammar and code theme under `docs/public/syntax` are MIT licensed by Tijn Epema and checkraisefold.
- Studio plugin autocomplete icons come from [vscode-icons](https://github.com/microsoft/vscode-icons) by Microsoft, licensed under [CC BY 4.0](https://github.com/microsoft/vscode-icons/blob/main/LICENSE). <a href="https://www.flaticon.com/free-icons/speed" title="speed icons">Speed icons created by alkhalifi design - Flaticon</a>.

## License

Cheeto is released under the [MIT License](LICENSE).
