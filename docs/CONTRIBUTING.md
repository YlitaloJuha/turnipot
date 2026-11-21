# Contributing to Turnipot

Turnipot is a small Mac app that puts Claude Code in the MacBook's notch. It's built with Swift Package Manager and the Command Line Tools; Xcode isn't needed. Start with the [README](../README.md), then [DEVELOPMENT.md](DEVELOPMENT.md) (how it behaves, flags, renders) and [CONTRACTS.md](../CONTRACTS.md) (types, files and the exact hook and socket I/O).

## Asking for features and reporting bugs

- **A bug:** open an [issue](https://github.com/YlitaloJuha/turnipot/issues/new). Say what you did, what you expected and what happened, plus your macOS version, Mac model (notch or not), Turnipot version (⚙ menu) and Claude Code version. The output of `/Applications/Turnipot.app/Contents/MacOS/Turnipot --dump` helps a lot. Check it first: it lists your session titles and folders.
- **A feature:** open an issue with the problem first, then your idea. One per issue.
- **Asked already?** Add 👍 to the issue's first post instead of a new issue or a "+1" comment.
- **A security problem:** never in an issue. See [SECURITY.md](SECURITY.md).

## Setup

```sh
xcode-select --install          # once: the Command Line Tools
scripts/build-app.sh --open     # build build/Turnipot.app and launch it
swift run turnipot-selftest     # the tests
```

`swift test` doesn't work with the Command Line Tools alone (no XCTest), so the tests are a plain executable: `turnipot-selftest` prints each failure and exits non-zero if any check fails. For a quick look at every state without real sessions, use the demo and render modes in [DEVELOPMENT.md](DEVELOPMENT.md#debugging-and-renders).

## Code rules

- `NotchCore` holds the models, monitors, sockets and rules, and imports no AppKit or SwiftUI. Logic goes there, with self-tests in `Sources/turnipot-selftest/`. The app target (`Sources/Turnipot/`) draws and wires things up.
- `turnipot-hook` stays Foundation-only and tiny: Claude Code runs it for every permission request, so it has to start in milliseconds.
- A bug fix starts with a self-test that reproduces it.
- Anything that can answer Claude for the user (permissions, questions, plans, quick reply) keeps its guards: the 400 ms input delay on new drop-downs (`FreshContentGate`) and no typing into a terminal that may be showing Claude's own prompt (`TerminalDialogGuard`). See CONTRACTS.md, "NotchCore safety guards".
- No network calls besides the update check, no telemetry, and no reading of keychain items or tokens. The README's Privacy section is a promise.
- Keep comments to short notes on why.

## Docs

When behaviour changes, update the README, [DEVELOPMENT.md](DEVELOPMENT.md), [CONTRACTS.md](../CONTRACTS.md) and `CHANGELOG.md` under "Unreleased". If the change shows in the README pictures, re-export them (`--export-media`, see DEVELOPMENT.md); they use made-up demo data only.

## Licence

Turnipot is under the [MIT licence](../LICENSE). What you contribute is under the same licence. There's no contributor agreement to sign.

## Releases

See [Install, versions and releases](DEVELOPMENT.md#install-versions-and-releases). Releases are signed with the maintainer's Developer ID and notarized by Apple.
