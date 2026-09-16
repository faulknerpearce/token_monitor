# Contributing to TokenMon

Thanks for helping improve TokenMon. This project is a native macOS menu bar app; small, focused changes are easiest to review.

## Development setup

1. Install [Xcode 15+](https://developer.apple.com/xcode/) on macOS 14+.
2. Clone the repo and open `TokenMon.xcodeproj`.
3. Select the **TokenMon** scheme → **My Mac** → Run.

```bash
git clone https://github.com/faulknerpearce/token_monitor.git
cd token_monitor
open TokenMon.xcodeproj
```

After adding or removing source files, regenerate the Xcode project:

```bash
xcodegen generate
```

To regenerate the TokenMon app icon:

```bash
swift Scripts/generate_icon.swift TokenMon/Resources/Assets.xcassets/AppIcon.appiconset
```

## Before you open a PR

- Keep changes focused on one concern.
- Prefer clear commit messages that explain *why*.
- Run the full test suite. This is the required gate: it builds the app host and
  covers Cursor usage, auth sessions, pollers, and UI behavior:

```bash
make test
```

- `make test-core` is an optional, fast CLT-only smoke. It compiles the Grok
  parsers plus the Daily Budget preview/Thursday-week assert, and does **not**
  cover Cursor daily quota, auth sessions, pollers, or UI. A green core run is
  not sufficient for billing or auth changes:

```bash
make test-core
```

## Pull requests

1. Branch from `master`.
2. Describe the problem and how you verified the fix.
3. Note any user-facing behavior changes (menu bar, sign-in, privacy).
4. Do not commit secrets, signing certificates, provisioning profiles, or personal session cookies.

## Scope notes

- TokenMon is an **unofficial** client. It uses authenticated grok.com surfaces that can change without notice.
- Avoid scraping that violates xAI terms; prefer the existing auth + endpoint approach documented in `Docs/AUTH_AND_ENDPOINTS.md`.
- Do not add telemetry or third-party analytics without discussion.

## Code of conduct

By participating, you agree to uphold our [Code of Conduct](CODE_OF_CONDUCT.md).
