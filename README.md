# TokenMon

<p align="center">
  <img src="Docs/tokenmon-logo.png" alt="TokenMon" width="280">
</p>

A native macOS menu bar app for tracking your AI provider usage — **SuperGrok**, **Grokbot**, **OpenCode**, **Cursor**, **Claude**, **ChatGPT** and **OpenRouter** — in real time.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://github.com/faulknerpearce/token_monitor)
[![Swift](https://img.shields.io/badge/Swift-5.10-orange)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/faulknerpearce/token_monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/faulknerpearce/token_monitor/actions/workflows/ci.yml)

> **Unofficial.** TokenMon is not affiliated with, endorsed by, or supported by any of the tracked providers (xAI, Anysphere/Cursor, OpenCode, Anthropic, OpenAI, or OpenRouter). It uses authenticated provider surfaces that may change without notice.

## Overview

TokenMon sits in the macOS menu bar and shows how much of your allowance you have used on each connected AI provider — overall and, where the provider exposes it, broken down by product or time window. Switch between providers from one dropdown, or use the **Overview** tab to see every connected provider side by side. Sign in once per provider; the app polls authenticated endpoints and keeps a local history for the daily chart.

Adding a provider is a registry entry away: `ProviderRegistry` wires each `MonitorProvider` to its poller, and every provider implements the same auth / polling / snapshot contract.

## Supported providers

| Provider | Usage pools surfaced | Daily Budget chart |
|----------|----------------------|--------------------|
| **SuperGrok** | Rolling weekly pool ending at the provider's reset instant; per-product breakdown (Chat, Build, API, Imagine, …) | Billing-period week (`100/7` per day) |
| **Grokbot** | Weekly Bot allowance, anchored to the plan's own reset instant | Weekly window |
| **Claude** | 5-hour session + weekly (7-day) pool | Weekly window |
| **ChatGPT (Codex)** | 5-hour primary + weekly secondary pool | — |
| **Cursor** | Monthly billing cycle (usage-summary %) | Last 7 days of the billing cycle |
| **OpenCode Go** | 5-hour + weekly + monthly limits (console); local estimate when signed out | Weekly + subscription-month sections |
| **OpenRouter** | Account credits (management key) or per-key spending cap with provider-declared reset window | — |

Every window is anchored to the provider's own reset metadata (`resetsAt`, billing-cycle dates, or declared reset period). TokenMon never substitutes a calendar-derived guess when a provider payload is incomplete — the affected section simply waits for the next complete refresh.

## Features

| Area | Details |
|------|---------|
| **Menu bar** | Compact status: provider icon, used %, optional filling usage bar |
| **Dropdown** | Per-provider panel: used / remaining, segmented bar, category or window breakdown, daily chart, reset time |
| **Overview tab** | All connected providers at a glance with hourly multi-provider chart |
| **Daily Budget** | Per-pool daily charts (weekly windows, subscription months) paced against the provider's own consumed % |
| **Auth** | WKWebView sign-in per provider; session cookies in Application Support |
| **Polling** | Faster refresh while the menu is open; backoff on errors; sleep / wake aware |
| **History** | SwiftData snapshots, charts window, CSV / JSON export |
| **Alerts** | Optional threshold notifications |
| **Preferences** | Menu bar toggles, poll intervals, visible products, launch at login |
| **Agent app** | No Dock icon by default (`LSUIElement`) |

## Requirements

- macOS 14 Sonoma or later
- [Xcode 15+](https://developer.apple.com/xcode/) (full app; Command Line Tools alone are not enough)
- A signed-in account for at least one supported provider

## Getting started

### 1. Clone and open

```bash
git clone https://github.com/faulknerpearce/token_monitor.git
cd token_monitor
open TokenMon.xcodeproj
```

Select the **TokenMon** scheme → **My Mac** → Run (⌘R). The app appears in the menu bar (no Dock icon).

### 2. Sign in to your providers

1. Click the menu bar item and pick a provider from the switcher (or start on **Overview**)
2. Click **Sign In…** and complete the login on that provider's official sign-in page
3. If capture does not happen automatically, click **I'm signed in — Capture Session**
4. Usage appears after the first successful refresh — repeat for any other providers you want to track

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
    Grokbot/     Grokbot weekly allowance and panel (borrows the Cursor session)
    OpenCode/    OpenCode auth, console/local usage, and panel
    Cursor/      Cursor auth, dashboard usage, and panel
    Claude/      Claude auth, weekly usage, and panel
    ChatGPT/     ChatGPT/Codex usage pools and panel
    OpenRouter/  OpenRouter key/credits usage and panel
    Overview/    Multi-provider rings and hourly chart
    Provider/    Provider identity, registry, switching, and logos
    Shared/      Cookie capture, sign-in shell, Daily Budget kernel, poll helpers
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
- Network access is limited to authenticated hosts of the connected providers (grok.com/x.ai, opencode.ai, cursor.com, claude.ai, chatgpt.com, openrouter.ai) for usage and auth.
- History stays on this Mac (SwiftData). No third-party telemetry.

## Documentation

| Doc | Contents |
|-----|----------|
| [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) | Module map and data flow |
| [Docs/AUTH_AND_ENDPOINTS.md](Docs/AUTH_AND_ENDPOINTS.md) | Auth model, endpoints, usage-window limitations |
| [Docs/NOTARIZATION.md](Docs/NOTARIZATION.md) | Developer ID signing and notarization |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to develop and open PRs |
| [SECURITY.md](SECURITY.md) | How to report vulnerabilities |

## Distribution

For a signed, notarized release build, see [Docs/NOTARIZATION.md](Docs/NOTARIZATION.md) and `Scripts/notarize.sh`.

## Notes on usage windows

Each provider defines its own consumption pool: a rolling week anchored to a reset instant (SuperGrok, Grokbot), a weekly window plus 5-hour session (Claude, ChatGPT), a monthly billing cycle (Cursor), stacked 5-hour/weekly/monthly limits (OpenCode Go), or credits and key caps with a declared reset period (OpenRouter). Daily Budget charts always pace against the same pool the provider reports — the bars are shaped by local history while the consumed % comes straight from the provider snapshot.

TokenMon never invents a usage period. If a payload arrives without the reset metadata that defines the current pool, the affected chart or pace caption is withheld until the next complete refresh rather than substituting a calendar-derived guess. Where providers expose multiple pools (e.g. OpenCode's weekly and monthly limits), each gets its own Daily Budget section paced to its matching pool.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and pull requests are welcome.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

This project is licensed under the [MIT License](LICENSE).
