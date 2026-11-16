# Working on Brim

Brim is a hard fork of [Vorssaint](https://github.com/vorssaint/vorssaint-utils),
maintained by Eliseo Robles. It builds with `build.sh` and plain `swiftc`, with
no Xcode project and no package dependencies; `Package.swift` exists only for
editor indexing. Contributions are under GPL-3.0-or-later.

Bugs and ideas go in [GitHub Issues](https://github.com/eliseorobles/brim/issues);
security problems go through [SECURITY.md](SECURITY.md). For anything larger
than a small fix, open an issue first so we can agree on the approach.

## Build and test

You need macOS 14 or newer, Apple Silicon and the Xcode Command Line Tools.

```sh
./build.sh --dev                    # the Developer app, staged in build/stage.noindex
./build/BrimDeveloper --selftest
build/brim-claude --selftest        # the Claude accounts helper
./build.sh --test                   # every test group plus the shell tests
./build.sh --list-tests             # the groups
./build.sh --test-suite=NAME        # one group
./build.sh --dev --install          # install Brim (Developer) in /Applications
./build.sh                          # the release build, in build/stage
```

The Developer app (`com.roblesconsulting.brim.dev`, built with
`-D BRIM_DEVELOPMENT`) has its own preferences, permissions, login item, fan
service and `~/.config/brim-dev` state, so it runs beside the release app.

Run one build or test run at a time: parallel compiles have run this Mac out of
memory. `BRIM_JOBS` caps the compiler's parallel jobs (default 6).

## Signing

Every build is signed with one identity, chosen explicitly by build.sh:
`BRIM_SIGN_IDENTITY` (a certificate's SHA-1 or full name, or `-` for ad hoc, as
CI uses), or else the first valid "Developer ID Application" or "Apple
Development" certificate of team 53X2V2R96G (Robles Consulting LLC). Without
either the build stops; it never creates a keychain or an identity. A team
signature keeps macOS's privacy grants across rebuilds, and the fan helper
accepts only an app signed by the same team.

Without that team's certificate, sign with your own identity or ad hoc:
`BRIM_SIGN_IDENTITY=- ./build.sh --dev`. Everything but fan control works in
such a build; an ad hoc signature changes on every build, so macOS asks for
privacy permissions again after each one.

`Tools/identity.sh` is the one file that names the app, its bundle IDs, the team
and the copyright.

## Layout

- `Sources/Brim/App` app lifecycle, `Core` catalogs, strings and preferences,
  `Services` behavior, `UI` views, `Support` selftest and diagnostics.
- `Sources/Brim/Modules/ClaudeAccounts` Claude Code accounts. Its top level is
  Foundation-only and is also compiled into the `brim-claude` helper
  (`Sources/BrimClaude`); `App/` holds the app's side.
- `Sources/Brim/Modules/Memory` the Memory module.
- `Sources/FanControlHelper` the privileged fan helper; `Sources/VMStatisticsCompat`
  a C shim for `host_statistics64`.
- `Resources` Info.plist, entitlements, the fan helper's launchd plist, the zsh
  integration (`claude.zsh`) and `Brand/`, Brim's artwork
  (`swift Tools/MakeBrimBrand.swift` regenerates it).
- `Tests` the test runner.
- `docs` the privacy, permissions and troubleshooting notes, and the project
  website (GitHub Pages serves this folder).

`T-NN` in a comment refers to the maintainer's own log of deferred work. Public
work is tracked in GitHub Issues.

## Tests

- Groups are registered in `Tests/MetricsTests.swift`.
- The test binary compiles the sources listed in `TEST_SOURCES` in build.sh,
  plus `build/generated-tests`. A passing test run does not prove the app
  builds: build the app and run its selftest too.
- `Tests/generate_sources.py` copies production method bodies into generated
  tests by declaration prefix and fails when a prefix no longer matches. Change
  a copied body and its generator block together.
- `Tests/mutation_checks.py` checks that the tests fail when key lines are
  mutated; keep its anchors matching the sources.
- A behavior test should fail without the fix it covers.
- One test is known to fail on macOS 27 only:
  `Tests/NotchCompactTests.swift:159` (rail realization). CI runs macOS 15 and
  macOS 26.

## Rules

- No polling: use the system's push mechanisms or refresh on an explicit event.
  A timer needs its reason recorded in a comment beside it.
- Replace, don't layer: no fallbacks, `_v2` copies or parallel implementations.
- New source files carry the SPDX license header.
- Builds finish without warnings.
