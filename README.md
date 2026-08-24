# TokenMon

<p align="center">
  <img src="Docs/tokenmon-logo.png" alt="TokenMon" width="280">
</p>

A native macOS menu bar app for tracking your AI provider usage — **SuperGrok**, **OpenCode**, **Cursor**,  **Claude**, **ChatGPT** and **OpenRouter** — in real time.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://github.com/faulknerpearce/token_monitor)
[![Swift](https://img.shields.io/badge/Swift-5.10-orange)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/faulknerpearce/token_monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/faulknerpearce/token_monitor/actions/workflows/ci.yml)

> **Unofficial.** TokenMon is not affiliated with, endorsed by, or supported by xAI. It uses authenticated grok.com surfaces that may change without notice.

## Overview

TokenMon sits in the macOS menu bar and shows how much of your SuperGrok weekly limit you have used — overall and by product (Chat, Grok Build, API, and others when present) — alongside OpenCode and Cursor usage. Sign in once per provider; the app polls authenticated endpoints and keeps a local history for the daily chart.

## Features

| Area | Details |
|------|---------|
| **Menu bar** | Compact status: Grok icon, used %, optional filling pill, optional Chat / Build / API chips |
| **Dropdown** | Weekly used / remaining, segmented bar, category breakdown, daily bars, reset time |
| **Daily use** | Billing-period chart (e.g. Thu→Wed, `100/7` daily cap); whole week flips on reset; day-over-day deltas from local history |
| **Auth** | WKWebView sign-in; session cookies in Application Support |
| **Polling** | Faster refresh while the menu is open; backoff on errors; sleep / wake aware |
| **History** | SwiftData snapshots, charts window, CSV / JSON export |
| **Alerts** | Optional threshold notifications |
| **Preferences** | Menu bar toggles, poll intervals, visible products, launch at login |
| **Agent app** | No Dock icon by default (`LSUIElement`) |

## Requirements

- macOS 14 Sonoma or later
- [Xcode 15+](https://developer.apple.com/xcode/) (full app; Command Line Tools alone are not enough)
- A SuperGrok / Grok account

## Getting started

### 1. Clone and open

```bash
git clone https://github.com/faulknerpearce/token_monitor.git
cd token_monitor
open TokenMon.xcodeproj
```

Select the **TokenMon** scheme → **My Mac** → Run (⌘R). The app appears in the menu bar (no Dock icon).

### 2. Sign in

1. Click the menu bar item → **Sign In…**
2. Complete login on `accounts.x.ai` / grok.com in the sign-in window
3. If capture does not happen automatically, click **I'm signed in — Capture Session**
4. Usage appears after the first successful refresh

## Build from the command line

Point `xcode-select` at Xcode once (if needed):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -runFirstLaunch
```

Use the Makefile (preferred):

```bash
make help
```

All targets are listed below (`make help` also shows your detected signing identities).

### All Makefile targets

| Target | Description |
|--------|-------------|
| `make help` / `make tasks` | List all targets and detected signing identities |
| `make build` | Build the **Debug** `.app` (ad-hoc signed) |
| `make run` | Build Debug and launch the app in the menu bar |
| `make install` | Build **Release** and install into `/Applications` (default; override with `INSTALL_DIR=…`) |
| `make uninstall` | Remove the app from `/Applications` |
| `make release` | Full release into `dist/`: signed `.app` + `.pkg` + `.zip` |
| `make pkg` | Build only the installer `.pkg` into `dist/` |
| `make archive` | Create an `.xcarchive` (Xcode Organizer-compatible) |
| `make notarize` | Notarize the `dist/` app via `notarytool` profile |
| `make test` | Run the full Xcode unit test suite |
| `make test-core` | Run the CLT-only parser/builder tests (no app host) |
| `make lint` | **SwiftLint strict gate** — every warning is an error; must be clean before handoff/PR |
| `make lint-fix` | Auto-correct autocorrectable SwiftLint violations, then enforce the strict gate |
| `make format` | **SwiftFormat gate** — fails on formatting drift (config: `.swiftformat`) |
| `make format-fix` | Auto-format all Swift sources |
| `make secrets` | **gitleaks secret scan** of the working tree — must be clean before handoff/PR |
| `make project` | Regenerate `TokenMon.xcodeproj` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) |
| `make icon` | Regenerate the app icon asset catalog |
| `make check` | Verify the Xcode toolchain (`xcode-select`, versions) |
| `make open` | Open the project in Xcode |
| `make clean` | Remove `build/` and local DerivedData |
| `make distclean` | Remove `build/` **and** `dist/` |

### Signing & distribution

`make release` auto-detects **Developer ID Application** / **Installer** certs from your keychain (any team). Without them it falls back to ad-hoc signing and an unsigned `.pkg`. Optional notarization: `make release NOTARY=1` (see [Docs/NOTARIZATION.md](Docs/NOTARIZATION.md)).

### Regenerating the project

After adding or removing source files: `make project` (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen)). Regenerate the app icon with `make icon`.

## Testing & linting

```bash
make test        # full Xcode unit test suite
make test-core   # CLT-only parsers/builders (no app host)
make lint        # SwiftLint strict gate (must pass before handoff/PR)
make lint-fix    # auto-fix issues, then re-run the strict gate
make format      # SwiftFormat drift gate
make secrets     # gitleaks secret scan
```

`make lint` runs `swiftlint lint --strict`, so **every warning is treated as an error**. Configuration lives in `.swiftlint.yml`. Keep it green before opening a PR or handing off work.

## Project layout

```
TokenMon/
  App/           Entry point, AppDelegate
  Features/
    Grok/        Grok auth, usage, history, and alerts
    OpenCode/    OpenCode auth, console/local usage, and panel
    Cursor/      Cursor auth, dashboard usage, and panel
    Overview/    Multi-provider rings and hourly chart
    Provider/    Provider identity, switching, and logos
    Shared/      Cookie capture, sign-in shell, poll helpers
    MenuBar/     Label renderer, dropdown, daily chart
    Settings/    Preferences, UserDefaults
  Resources/     Info.plist, entitlements, assets
Docs/            Architecture, auth/endpoints, notarization
Scripts/         Icon generator, core tests, notarize
TokenMonTests/  XCTest suite
Tests/Manual/    Optional CLT-only subset (see Scripts/run_core_tests.sh)
```

## Privacy

- Session cookies and optional bearer tokens are stored as **user-only** files under Application Support (not Keychain — avoids access-dialog loops on ad-hoc debug builds).
- The app is **not sandboxed**; the store path is:
  `~/Library/Application Support/TokenMon/` (files `auth_*.dat`, mode `0600`)
- Network access is limited to authenticated Grok/xAI, OpenCode, and Cursor hosts for usage and auth.
- History stays on this Mac (SwiftData). No third-party telemetry.

## Documentation

| Doc | Contents |
|-----|----------|
| [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) | Module map and data flow |
| [Docs/AUTH_AND_ENDPOINTS.md](Docs/AUTH_AND_ENDPOINTS.md) | Auth model, endpoints, daily-use limitations |
| [Docs/NOTARIZATION.md](Docs/NOTARIZATION.md) | Developer ID signing and notarization |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to develop and open PRs |
| [SECURITY.md](SECURITY.md) | How to report vulnerabilities |

## Distribution

For a signed, notarized release build, see [Docs/NOTARIZATION.md](Docs/NOTARIZATION.md) and `Scripts/notarize.sh`.

## Notes on daily use

Grok’s billing API exposes **cumulative weekly** usage, not a public per-day series. The daily chart is always **exactly seven days** of the active billing period (e.g. Thu→Wed). When the pool resets, the whole window rolls to the next period — never two Thursdays and never a split bar. Until local day-to-day history exists, bars stay empty. After the app has polled across multiple days, bars use day-over-day deltas within the same billing period. Each bar is scaled to a daily share of the pool (`100 / 7`).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and pull requests are welcome.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

This project is licensed under the [MIT License](LICENSE).
