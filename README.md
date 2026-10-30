# TokenMon

<p align="center">
  <img src="Docs/tokenmon-logo.png" alt="TokenMon" width="280">
</p>

TokenMon is a native macOS menu bar app that shows how much of your AI usage allowances you have used, across the coding assistants, chat subscriptions and model APIs you connect, in real time.

[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://github.com/faulknerpearce/token_monitor)
[![Swift](https://img.shields.io/badge/Swift-5.10-orange)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/faulknerpearce/token_monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/faulknerpearce/token_monitor/actions/workflows/ci.yml)

## Overview

Every AI service meters usage its own way: rolling session windows, weekly pools, monthly billing cycles, credit balances, spending caps. TokenMon reads each connected service's own figures and shows them side by side, so you can see at a glance how much headroom you have and when each pool resets.

The menu bar shows a compact used percentage (and optional usage bar) per provider. The dropdown has one tab per provider, with its pools, product or model breakdown and a daily chart, plus an **Overview** tab that puts every connected provider on one hourly chart. Sign in once per provider; TokenMon polls that provider's authenticated endpoints, reads local usage logs where a tool keeps them, and keeps a local history for the daily charts.

Providers plug into one contract (session, usage client, poller, panel), so support for another assistant or model API is added in one folder plus a registry entry; see [Adding a provider](#adding-a-provider).

## Supported providers

| Provider | Usage pools surfaced | Daily Budget chart |
|----------|----------------------|--------------------|
| **ChatGPT (Codex)** | 5-hour primary + weekly secondary pool | — |
| **Claude** | 5-hour session + weekly (7-day) pool; Claude Code tokens and API-rate spend for this month and all time, by model, read from local logs (shown signed in or not) | Weekly window |
| **Cursor** | Monthly billing cycle (usage-summary %) | Last 7 days of the billing cycle |
| **Grokbot** | Weekly Bot allowance, anchored to the plan's own reset instant | Weekly window |
| **OpenCode Go** | 5-hour + weekly + monthly limits (console); local estimate when signed out | Weekly + subscription-month sections |
| **OpenRouter** | Account credits (management key) or per-key spending cap with provider-declared reset window | — |
| **SuperGrok** | Rolling weekly pool ending at the provider's reset instant; per-product breakdown (Chat, Build, API, Imagine, …) | Billing-period week (`100/7` per day) |

Every window is anchored to the provider's own reset metadata (`resetsAt`, billing-cycle dates, or declared reset period). When a payload lacks that metadata, the affected section waits for the next complete refresh.

## Features

| Area | Details |
|------|---------|
| **Menu bar** | Compact status: provider icon, used %, optional filling usage bar per provider; click a provider's bar to open its tab |
| **Dropdown** | Per-provider panel headed by its usage pool (hourly, weekly, monthly or mixed), with used / remaining, breakdown by product, window or model, a daily chart and the reset time |
| **Overview tab** | Every connected provider on one hourly chart; arrows step back through the last 30 days |
| **Daily Budget** | Per-pool daily charts (weekly windows, subscription months) paced against the provider's own consumed % |
| **Auth** | Guided sign-in per provider in an isolated web view that closes itself once you're signed in; API-key providers connect in Settings. Credentials are kept in the macOS Keychain. Signing out keeps the local history for when the same account signs back in |
| **Polling** | Faster refresh while the menu is open, slower when idle; providers that are hidden and unwatched do not poll; failed refreshes back off and retry |
| **History** | Daily usage kept on this Mac for the charts; SuperGrok snapshots export as CSV or JSON |
| **Alerts** | Optional notification when a provider's usage crosses a threshold; choose the threshold and which providers it watches in Settings › General (off by default) |
| **Settings** | Four tabs: General (launch at login, updates, refresh intervals, alerts), Providers (tab order and menu bar graphs), Accounts (sign-in for each provider), and Data (product categories, export) |
| **Updates** | Optional check for new GitHub releases; verified in-place install (see [Docs/NOTARIZATION.md](Docs/NOTARIZATION.md#in-app-updates)) |
| **Agent app** | No Dock icon by default (`LSUIElement`) |

## Requirements

- macOS 14 Sonoma or later
- [Xcode 16+](https://developer.apple.com/xcode/) (Swift 5.10 language mode; the full app — Command Line Tools alone are not enough)
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
2. Choose **Sign In…** and complete the login on that provider's own page
3. The window finishes on its own once you're back on the provider page, shows **"Signed in as …"**, and closes. If it lingers, choose **Finish Sign-In**; use **Back** or **Close popup** to leave an OAuth popup.
4. Usage appears after the first refresh — repeat for any other providers you want to track

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
| `make release` | Full release into `dist/`: `.app` + `.pkg` + `.zip` + dSYM zip (Developer ID signed when a certificate is available, ad-hoc otherwise) |
| `make pkg` | Build only the installer `.pkg` into `dist/` |
| `make archive` | Create an `.xcarchive` (Xcode Organizer-compatible) |
| `make export` | Export a Developer ID `.app` from the archive into `build/export` |
| `make notarize` | Notarize the `dist/` app via `notarytool` profile |
| `make test` | Run the full Xcode unit test suite |
| `make test-core` | Run the CLT-only parser/builder tests (no app host) |
| `make lint` | **SwiftLint strict gate** — every warning is an error; must be clean before a PR |
| `make lint-fix` | Auto-correct autocorrectable SwiftLint violations, then enforce the strict gate |
| `make format` | **SwiftFormat gate** — fails on formatting drift (config: `.swiftformat`) |
| `make format-fix` | Auto-format all Swift sources |
| `make secrets` | **gitleaks secret scan** of the working tree **and** full git history — must be clean before a PR |
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
make lint        # SwiftLint strict gate (must pass before a PR)
make lint-fix    # auto-fix issues, then re-run the strict gate
make format      # SwiftFormat drift gate
make secrets     # gitleaks secret scan (working tree + full history)
```

`make lint` runs `swiftlint lint --strict`, so **every warning is treated as an error**. Configuration lives in `.swiftlint.yml`. Keep it green before opening a PR.

## Project layout

```
TokenMon/
  App/           Entry point, AppModel service graph, AppDelegate
  Core/          Networking, polling, storage, usage maths, utilities (no UI frameworks)
  Platform/      Auth sessions and Keychain storage, sleep/wake, alerts
  UI/            Shared components, menu bar, sign-in window
  Providers/     One folder per provider, plus the provider registry
  Features/      Overview, Settings, Update
  Resources/     Info.plist, entitlements, assets
Docs/            Architecture, auth/endpoints, notarization
Scripts/         Icon generator, core tests, notarize, coverage conversion
TokenMonTests/   XCTest suite, mirroring the TokenMon folders
Tests/Manual/    Optional CLT-only subset (see Scripts/run_core_tests.sh)
```

## Adding a provider

Each provider lives in `TokenMon/Providers/<Name>/` and implements the same pieces:

1. **Session**: a `ProviderAuthSession` subclass (cookie sign-in) with its `ProviderSignInProviding.signInConfig`, or a key-based session like OpenRouter's.
2. **Client and models**: fetches and parses the provider's usage into a snapshot.
3. **Poller**: a `ProviderUsagePoller` that runs its fetch through `ProviderRefresh.run` and reports its headline percentage, reset instant and account for the menu bar and alerts.
4. **Panel**: the dropdown tab.

Then add a `MonitorProvider` case (name, accent colour, whether it has a menu-bar graph), one `ProviderRegistry` entry in `AppModel`, its panel in `MenuBarPanelView` and its card in the Overview. Tests go in `TokenMonTests/Providers/<Name>/`. Architecture details: [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md).

## Privacy

- **Credentials** (session cookies and API keys) are stored in the **macOS login Keychain** (one item: service `com.modelmonitor.app.credentials`, account `vault`; this device only, never synced). Account emails and workspace ids stay in user-only files (mode `0600`) under `~/Library/Application Support/TokenMon/`. Credentials still stored as files in that folder are moved into the Keychain at launch.
- **Keychain prompts after updates.** Release builds are ad-hoc signed, so after each update macOS asks once whether the new TokenMon may read its Keychain item. Choose **Always Allow** to keep it from asking again until the next update.
- **Network access** is limited to:
  - each connected provider's own hosts, for usage and sign-in (listed per provider in [Docs/AUTH_AND_ENDPOINTS.md](Docs/AUTH_AND_ENDPOINTS.md)), plus the identity pages a provider's sign-in redirects to;
  - GitHub, for update checks and downloads: `api.github.com`, `github.com`, and its release-asset hosts `objects.githubusercontent.com` / `release-assets.githubusercontent.com`. Turn off automatic checks in Settings to stop these.
- **Local files read**, always read-only, where a provider's tool keeps usage on this Mac:

  | Provider | File | Used for |
  |----------|------|----------|
  | OpenCode | `~/.local/share/opencode/opencode.db` | Cost and activity estimates |
  | Claude | Claude Code's session logs (`~/.claude/projects`, `~/.config/claude/projects`, or each `CLAUDE_CONFIG_DIR`) | Token counts; daily per-model totals are saved under Application Support so all-time totals outlast Claude Code's log cleanup |

- **Local history** (daily usage, the Overview chart's days, SuperGrok snapshots) is saved as files under `~/Library/Application Support/TokenMon/`. It never leaves the Mac. No third-party telemetry.
- Provider responses are never cached to disk, and provider cookies never enter a shared cookie jar.
- The app is **not sandboxed** (needed to read local usage logs and databases).

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

Each provider defines its own consumption pool: a rolling session window, a weekly pool, a monthly billing cycle, stacked limits, or credits with a spending cap. The [Supported providers](#supported-providers) table lists what each one exposes. Daily Budget charts always pace against the same pool the provider reports: the bars are shaped by local history while the consumed % comes straight from the provider snapshot.

If a payload arrives without the reset metadata that defines the current pool, the affected chart or pace caption is withheld until the next complete refresh. Where a provider exposes several pools, each gets its own Daily Budget section paced to its matching pool.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and pull requests are welcome.

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

This project is licensed under the [MIT License](LICENSE).
