# Contributing to Cheeto

Thanks for taking the time to help. Bug reports, documentation fixes, new datatypes and performance work are all welcome. This guide covers how to get set up and what a good pull request looks like.

By participating you agree to follow the [code of conduct](CODE_OF_CONDUCT.md).

## Ways to help

- **Report a bug.** Open an [issue](https://github.com/pealz1/cheeto/issues/new/choose) with a minimal schema that reproduces it.
- **Suggest a feature.** Describe the problem you are solving before the solution you have in mind.
- **Improve the docs.** Every page on the site has an "Edit this page" link.
- **Send a fix.** Issues labelled `good first issue` are a good place to start.

Security issues should not be reported in public issues. See [SECURITY.md](SECURITY.md).

## Development setup

You need [Rokit](https://github.com/rojo-rbx/rokit). It installs the exact tool versions pinned in `rokit.toml`: Lune, Rojo, StyLua, selene and darklua.

```sh
git clone https://github.com/pealz1/cheeto.git
cd cheeto
rokit install
lune setup   # generates type definitions for luau-lsp
```

For editor support, install the [Luau Language Server](https://github.com/JohnnyMorganz/luau-lsp) and [StyLua](https://github.com/JohnnyMorganz/StyLua) extensions. The repository's `.vscode/settings.json` formats on save.

Run the compiler from source with Lune:

```sh
lune run src/CLI/init.luau path/to/schema -- --yes
```

## Project layout

| Path | Contents |
| --- | --- |
| `src/Lexer.luau`, `src/Parser.luau` | Tokenizer and parser for `.cheeto` files |
| `src/Generator/` | Code generation for Luau and TypeScript output |
| `src/Templates/` | The runtime that is emitted into every generated module |
| `src/CLI/` | Command-line entry point, compilation and report modes |
| `plugin/` | Roblox Studio plugin |
| `extras/security/` | Standalone anti-exploit detectors |
| `test/` | Test suite, fixtures under `test/Sources/` |
| `benchmark/` | In-Studio benchmark harness |
| `docs/` | Documentation site |

## Checks

Run these before opening a pull request. CI runs the same commands.

```sh
# Tests (from the test directory)
cd test && lune run Test --ci && cd ..

# Wire lockfile and hardening checks
lune run src/CLI/init.luau test/Sources/Test -- --check-lock --yes
lune run src/CLI/init.luau test/Sources/HardeningGood -- --hardening-checklist --yes

# Formatting and lints
stylua --check src test benchmark plugin extras
selene src test benchmark plugin
```

Format everything with `stylua src test benchmark plugin extras`.

See [test/README.md](test/README.md) for how the suite is organised, how to replay a fuzzer failure, and how to add fixtures.

### Changing the wire format

`test/Sources/cheeto.lock` records the wire IDs and schema hashes for the main test schema. If your change alters them on purpose, regenerate the lockfile and explain why in the pull request:

```sh
lune run src/CLI/init.luau test/Sources/Test -- --write-lock --yes
```

An unexpected lockfile diff almost always means a compatibility break.

### Working on the docs

```sh
cd docs
npm ci
npm run dev
```

Pages live in `docs/pages` as MDX. The sidebar order comes from each folder's `_meta.json`.

## Pull requests

- Keep each pull request focused on one change.
- Add or update tests for behaviour changes. Runtime changes should be covered in `test/Test.luau`.
- Update the documentation when you change the language, the CLI or the runtime API.
- Add a line to the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md) for anything users will notice.
- Make sure CI is green.

### Commit messages

Cheeto uses [Conventional Commits](https://www.conventionalcommits.org):

```text
fix(runtime): reject non-finite varints
feat(types): serialize NumberRange
docs: clarify replay window options
```

Common types are `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `ci`, `build` and `chore`. Use the body to explain why the change is needed.

## Releasing

Releases are cut by maintainers.

1. Run `lune run bump` and enter the new version. It updates `pesde.toml` and the darklua configs.
2. Move the `Unreleased` notes in `CHANGELOG.md` under a new version heading.
3. Commit with `chore: release vX.Y.Z` and open a pull request.
4. After it merges, tag the merge commit and push the tag:

   ```sh
   git tag -a vX.Y.Z -m "Cheeto vX.Y.Z"
   git push origin vX.Y.Z
   ```

The release workflow builds every binary and the Studio plugin, creates the GitHub release with the matching changelog section, and publishes to pesde.
