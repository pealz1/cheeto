# Changelog

All notable changes to Cheeto are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version numbers of the compiler, the generated runtime and the Studio plugin move together.

## [Unreleased]

## [1.1.0] - 2026-09-30

This release fixes defects found while rebuilding the documentation against the compiler, and makes every documented feature do what it says. The wire format changed; regenerate both modules together, as always.

### Security

- Unregistered policies and policy groups now drop every packet and warn once. The built-in policy names (`admin`, `currency`, `damage` and the rest), which admitted every connected player, are gone: register a rule for each name your schema uses. `--doctor` lists them.
- `RequirePolicies` accepts `Policy`, `PolicyGroup` or `Auth`, as `--doctor` and `--strict` always did.
- Constraints are enforced by the runtime: `RequireTeam`, `RequireZone`, `RequireMatch` and `RequireCharacterState` before decoding; `MaxDistance`, `RequireOwnership`, `RequireObjectHandle`, `RequireServerKnownId` and `RequireInventoryOwnership` after. New `Security.SetZone`, `GetZone`, `RegisterKnownId`, `ForgetKnownId` and `SetInventoryResolver`.
- The handshake carries a fingerprint of the wire layout instead of `schema-<Version>`, the server sends it to every player, and the server stops decoding players on another schema. `IncompatiblePeerAction = Kick` kicks them.
- `Idempotency` works without `Predict`: client events and functions carry a sequence number, and replayed packets are dropped.
- `Auth`, `Policy`, constraint and idempotency fields on server-sent events and channels are compile errors instead of rules the client could never satisfy.
- Decoy remotes share the real remotes' name format and both classes.
- `Security.SetRateLimit` changes an endpoint's or a remote's rate limit at runtime.

### Fixed

- A broadcast could hand one player's pending batch buffer to another and overwrite its unsent messages.
- A server module with two or more state channels exceeded Luau's 200-local limit and failed to load.
- Backpressure counted bytes for broadcasts and unreliable sends that were never released, eventually shedding every low-priority broadcast.
- A send whose serialization raised left half a frame in the batch.
- Generated invokes ignored the security profile's timeout and `Configure`; they now use the runtime value.
- A call or prediction the server dropped was never answered. It now gets the drop reason, so `Invoke` fails fast and predictions roll back.
- Prediction ids wrapping past 65,535 were dropped as stale.
- `CFrame<A, B>` applied position and rotation the wrong way round.
- Integers outside their type's range were silently wrapped (300 as a `u8` arrived as 44); they now raise. `Color3` channels clamp.
- `f16` NaN decoded as a large finite number.
- Per-endpoint `MaxPacketBytes` measured the whole packet instead of the event.
- String dictionaries desynchronized when a broadcast was copied into players' batches.
- Polled events were queued before their payload checks ran.
- Canonicalization rejected legitimate map keys (struct, negative, fractional and sparse keys).
- `--check-lock` failed on CRLF checkouts.

### Added

- `WireId`, `ReservedId` and `DeprecatedId` are honoured, and `cheeto.lock` keeps ids stable across reorders and removals, with removed endpoints kept as retired.
- `ReliabilityMode = Latest` and `CoalesceKey` send only the last value per recipient per frame; `ReliabilityMode = Sequenced` drops out-of-order packets (`OutOfOrder`).
- Unreliable events are batched per recipient per frame (`BatchUnreliable`).
- Channel `Interest` and `Scope` values `Party`, `Match`, `Team`, `Cell` and `Owner` work, with `SetScope`, `PatchScope` and `FlushScope`.
- `UseColon` makes endpoint methods callable with `:`.
- `map {[K]: V}(Min..Max)` bounds a map's entry count; `type X = SomeStruct` aliases any declared type.
- A function's `On` returns a function that unbinds the handler.
- TypeScript definitions cover channels, `Predict`, `FireGroup`, `Future` results and the runtime API, and are type-checked in CI.
- `--benchmark` and `--load-sim` measure the generated code instead of estimating it.
- New drop reasons `Cooldown` and `OutOfOrder`.

### Removed

- The `ProtocolVersion`, `ProtocolMode` and `AcceptProtocolVersion1` options, which now fail with "was removed". Cheeto has one wire format.
- `Protocol.Info()` no longer reports `LocalProtocolVersion` or `ProtocolMode`; it reports `WireFormat` and `SchemaHash`.

### Changed

- `SyncValidation` is on by default only in the `Development` profile.

## [1.0.0] - 2026-09-30

The first public release.

### Language

- Schema language with options, scopes, imports, events, functions and state channels.
- Numeric, string, buffer, vector, boolean, optional, array, map, set, enum, tagged enum, struct and generic types, with ranges for bounding sizes and values.
- More than 30 Roblox datatypes, including `CFrame`, `Color3`, `UDim2`, `Rect`, `NumberSequence`, `ColorSequence`, `PhysicalProperties`, `Font`, `EnumItem` and `TweenInfo`.
- Explicit wire IDs, and reserved and deprecated IDs for evolving schemas safely.

### Compiler

- Luau output for the client, the server and shared types, plus optional TypeScript definitions.
- `RuntimeOutput` emits the runtime once as a shared module instead of inlining it into every generated module.
- `--watch`, `--doctor`, `--strict`, `--benchmark`, `--load-sim`, `--capture-replay`, `--golden-snapshots`, `--compatibility`, `--schema-docs`, `--hardening-checklist` and `--ci`.
- `cheeto.lock` records wire IDs and schema hashes; `--write-lock` and `--check-lock` keep them under review.

### Runtime

- Strict protocol v2 framing with a capability handshake that checks protocol, schema version and schema hash.
- Batched, buffer-packed reliable and unreliable transport with fragmentation, priority lanes, backpressure and latest-only events.
- Size caps, decode budgets and payload canonicalization before any listener runs.
- Policies, auth rules, rate limits, cooldowns, idempotency, replay protection, honeypot events and a post-decode `Validate` hook.
- Typed drop reasons reported through `Security.OnViolation`.
- `SecurityPreset = Maximum`: client shield, client integrity challenges, server-side character integrity, rotating remote names and decoy remotes.
- Controller connections, state channels with delta replication and interpolation, prediction, server-issued handles and capabilities.
- Packet capture and replay, metrics, an inspector and optional micro-profiler labels.

### Tooling

- Roblox Studio plugin with an editor, schema management, generation and a metrics panel.
- Standalone Infinite Yield detection and movement anti-cheat in `extras/security`.
- Prebuilt binaries for Windows, macOS and Linux, and a pesde package.

[Unreleased]: https://github.com/pealz1/cheeto/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/pealz1/cheeto/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/pealz1/cheeto/releases/tag/v1.0.0
