# Contributing to DynamicIsland

Thanks for helping! Bug reports, ideas, translations and code are all welcome.

## Ways to help

- **Report a bug** — open an issue with the *Bug report* template. Include your macOS version, Mac model, and whether the
  display has a notch.
- **Suggest a feature** — open an issue with the *Feature request* template. Features that need a new permission or a
  private API are discussed first (see *Principles*).
- **Translate** — copy `Resources/ru.lproj/Localizable.strings` to `Resources/<lang>.lproj/`, translate the values (the
  English text is the key), and add the language to `CFBundleLocalizations` in `build.sh`.
- **Send code** — see below.

## Build and run

Needs macOS 14+, Apple Silicon and the Command Line Tools (`xcode-select --install`). No Xcode, no dependencies.

```bash
./build.sh                       # builds DynamicIsland.app (self-signed with a persistent local certificate)
open DynamicIsland.app
```

Quick type-check without building the app:

```bash
swiftc -parse-as-library -typecheck -swift-version 5 -target arm64-apple-macos14.0 Sources/*.swift
```

Layout check without clicking around: `ISLAND_SNAPSHOT_DIR=/some/dir DynamicIsland.app/Contents/MacOS/DynamicIsland`
renders each island state to a PNG and quits.

Notes: the command-line toolchain has no SwiftUI macros, so use `@StateObject` / `@ObservedObject` rather than
`@State` / `@Observable`.

## Principles

1. **Documented APIs only** by default (the one existing exception is the experimental *Now Playing from any app* option). An experimental feature that needs a private API must be optional, off by
   default and clearly labelled.
2. **Light at rest.** The idle island must stay cheap: no timers or capture while nothing is shown.
3. **Optional features, minimal permissions.** Ask for a permission only when the feature that needs it is used.
4. **Looks matter.** Smooth animation, crisp text, a pure black island.

## Pull requests

- Branch from `main`, keep changes focused, and describe *what* and *why*.
- Check that it builds (`./build.sh`) and, for UI changes, attach a screenshot or the output of the snapshot run.
- New user-facing strings go through `L("…")` and get a Russian entry (`scripts/check-localization.sh` checks this).
- Add a line to `CHANGELOG.md` under *Unreleased*.
- Commit messages: a short imperative subject and, if useful, a bulleted body.

## Releasing (maintainers)

Releases are signed with a dedicated self-signed certificate (`DynamicIsland Release Signer`), so every release carries the
same code-signing identity and macOS keeps the permissions users granted across updates. The certificate and its
password are the secrets `SIGNING_CERT_P12` / `SIGNING_CERT_PASSWORD` of the GitHub *Environment* `release`, which needs
the maintainer's approval and only accepts `v*` tags. The workflow checks the built app carries the expected
certificate SHA-1 and fails otherwise; to rotate the certificate, create a new one, update the secrets and the
`RELEASE_CERT_SHA1` in `release.yml` (users are asked for the permissions once more).


Bump `VERSION` in `build.sh`, move *Unreleased* to the new version in `CHANGELOG.md`, tag `vX.Y` and push the tag — the
*Release* workflow builds the `.dmg`/`.zip` and attaches them to the GitHub release. Then update `version` and `sha256` in `Casks/dynamicisland.rb`.
