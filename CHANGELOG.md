# Changelog

All notable changes to Cheeto are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version numbers of the compiler, the generated runtime and the Studio plugin move together.

## [Unreleased]

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

[Unreleased]: https://github.com/pealz1/cheeto/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/pealz1/cheeto/releases/tag/v1.0.0
