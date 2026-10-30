# Architecture

## Overview

TokenMon is an agent-style macOS app (`LSUIElement` + a custom `NSStatusItem`, not `MenuBarExtra`) with provider-specific services for Grok, OpenCode, Cursor, Claude, ChatGPT, OpenRouter, and Grokbot, plus an Overview aggregate. The shared shell owns provider selection, menu-bar presentation, settings, and lifecycle; each provider owns its authentication and usage implementation.

```
┌─────────────────────────────────────────────────────────┐
│ NSStatusItem label  →  MenuBarPanel (borderless NSPanel)│
│ Preferences Window  →  charts / export / settings       │
└───────────────┬─────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────┐
│ Provider selection → per-provider services              │
│   Grok · OpenCode · Cursor · Claude · ChatGPT ·         │
│   OpenRouter · Grokbot   (+ Overview aggregate)         │
│      │                                                  │
│      ▼                                                  │
│ One poller per provider (ProviderUsagePoller)           │
│ Auth / history · console / local · dashboard cookies    │
│      │                                                  │
│      └────────── shared MenuBar / Settings ─────────────┘
└─────────────────────────────────────────────────────────┘
```

## Modules

The source tree is layered. `Core` builds without any UI framework (a SwiftLint rule enforces it); `Platform` uses macOS services; `UI`, `Providers` and `Features` build on both.

| Folder | Responsibility |
|------|----------------|
| `App/` | `TokenMonApp` (the Settings window and one sign-in window group), `AppModel` (the service graph and the observation loops that react to it), `AppDelegate` (activation policy and launch housekeeping) |
| `Core/Networking/` | `ProviderHTTP` / `AuthenticatedRequest`, `ProviderURLSession`, `UsageError` / `ProviderError` mapping, `Domain` host matching, static URLs |
| `Core/Polling/` | `PollingLoop`, `BackoffTimer`, the `ProviderUsagePoller` protocol, `ProviderRefresh` (the fetch, stale-session and error steps every poller shares) |
| `Core/Storage/` | `AppSupport`, `FileBackedStringStore`, daily and hourly delta stores, `LegacyCacheCleanup` |
| `Core/Usage/` | Daily Budget and pace maths, `UsagePool`, `DayKey`, `Percent` |
| `Core/Utilities/` | `Format`, `JSON`, `ISO8601`, `AppLog`, `ObservationLoop` |
| `Platform/Auth/` | `ProviderAuthSession`, `KeychainVault` / credential stores, WebKit cookie bridge and capture |
| `Platform/` | `SystemWakeGate`, `ThresholdNotifier` |
| `UI/Components/` | Panel cards, typography, colour palette and provider accents, usage track, Daily Budget bars |
| `UI/MenuBar/` | `MenuBarController` (`NSStatusItem` + `MenuBarPanel`), status-image renderer, panel, segmented bar, category rows |
| `UI/SignIn/` | The shared sign-in sheet, embedded browser and sign-in / sign-out buttons |
| `Providers/<Name>/` | One folder per provider: session and sign-in config, usage client and parsers, poller, models, panel. Grokbot owns no session: it is a Cursor-backed product (`com.anysphere.sand`) and signs in with `CursorAuthSession` |
| `Providers/Registry/` | `MonitorProvider` (identity, menu-bar graph support, sign-in session), `ProviderRegistry`, logos, the switcher |
| `Features/Overview/` | Multi-provider hourly chart and its saved per-day history (30 days) |
| `Features/Settings/` | `AppSettings` (UserDefaults-backed, including each provider's poll interval) and the Settings window |
| `Features/Update/` | GitHub release check, verified in-place install (`UpdateChecker`, `ReleaseFeed`, `AppInstaller`) |

Tests in `TokenMonTests/` mirror these folders.

## Data flow

1. On launch, `AppModel` constructs one instance of each provider service, injects its dependencies, and records each provider's poller and session in `ProviderRegistry`. App wiring (polling, menu-open refresh, sign-in completion, usage alerts, the menu-bar image) iterates the registry.
2. Each provider poller runs a `PollingLoop`: it refreshes once at start, then sleeps the full interval its provider returns (the active interval while the menu-bar panel is open, the idle interval otherwise). A provider that is not needed (`AppSettings.needsPolling`: disabled, or neither its tab, its menu-bar graph nor the usage alert needs it) returns no interval and its loop parks with no timer until `AppModel` calls `wake()` (menu opened, settings changed). Failed refreshes back off exponentially (30 s → 10 min, ±10% jitter), and a 429's `Retry-After` is honoured. `SystemWakeGate` pauses every loop across system sleep and resumes them once `NWPathMonitor` reports the network is back.
3. Grok usage calls the grok.com gRPC-web billing endpoint first and probes REST JSON candidates only when billing fails for a reason other than a rejected session. OpenCode prefers official console usage and falls back to estimates from the local `opencode.db`. Cursor uses cookie-authenticated dashboard endpoints (`/api/usage-summary` and filtered usage events); events are read once into `CursorUsageEvent`, kept between polls, and each refresh pages only the events since the last fetch (less a 15-minute overlap), paging the whole window again every hour. Claude Code totals come from the local transcripts: each scan reads only the bytes appended since the last one and keeps running per-day totals, and the totals load on every Claude poll whether or not claude.ai is signed in. Endpoint details: `AUTH_AND_ENDPOINTS.md`.
4. Grok snapshots update the UI and append to `GrokHistoryStore` (one row per day and account), saved as JSON in `grok_history.dat`. A history saved by an earlier version in the SwiftData store `history.store` is imported into that file once.
5. The dropdown **Daily use** chart shows the active billing period's **7 days** (e.g. Thu→Wed). Before `resetsAt` the window ends the day before the reset; on the reset day itself, before the reset instant, the reset day is added as an eighth bar because the running period still owns it. Once `now >= resetsAt` (or the API advances `resetsAt`), the whole window rolls to the new period starting on the reset day. Each day scales to `100/7` of the weekly pool. Bars come from **local day-over-day history**. A caption shows when the pool resets.
6. `ThresholdNotifier` fires once per threshold crossing per provider, account and billing period. `AppModel` evaluates it whenever a provider's headline percentage (`ProviderUsagePoller.headlineUsedPercent`) or the alert settings change, for the providers the alert watches (`AppSettings.alertProviders`); those providers keep polling while the alert is on. It re-arms when usage drops 5+ points below the notified threshold or when `resetsAt` moves to a later period.
7. **Early provider resets.** Providers sometimes reset every user's pool mid-cycle (a free or manual reset). `DailyQuotaDeltaStore.record(…window:)` classifies each sample with `QuotaWindowTransition` using only the provider's own metadata: a *rollover* (old reset instant passed, new one advanced ≥ half a period) or an *early reset* (old reset instant still ahead, used % dropped ≥ `Percent.resetDropFloor`, and the period start or reset instant moved). Either way the baseline restarts at 0 so the first new-window sample is credited whole and only the entries on/after the new window's start day are dropped — earlier days stay as history. After an early reset the weekly bars open on the new window start (`windowStart`) and lead with the preserved days of the cut-short window, dimmed (`DailyBudgetDay.isPriorWindow`); pace/elapsed days ignore them. Grokbot, Claude (weekly pool), and Cursor (billing cycle) use this store. SuperGrok keeps one snapshot per day in `GrokHistoryStore` and re-anchors from `resetsAt`; OpenCode takes its bars from the local DB and console window; ChatGPT and OpenRouter have no Daily Budget chart.

## Auth sessions and storage

Each cookie provider has a `ProviderAuthSession` subclass: `GrokAuthSession` (Grok), `CursorAuthSession` (also used by Grokbot), `OpenCodeAuthSession`, `ClaudeAuthSession`, and `ChatGPTAuthSession`. `OpenRouterAuthSession` stores a pasted API key instead of cookies. Each session signs in through its own non-persistent `WKWebsiteDataStore`, keeps only an allowlist of essential cookies, and invalidates itself after three consecutive rejections (`authFailureThreshold`). A `sessionGeneration` counter lets pollers drop responses that finish after a sign-out or account switch. Sign-out fires `signedOut`, which drops the displayed snapshot; stored history and the account identity are kept, and `accountReset` clears a provider's stored history only when a different account signs in.

Credentials are stored through `SecretRoutingCredentialStore`:

- Secrets (each provider's `session` cookie header, OpenRouter's `key`) share one generic-password item in the login Keychain (`KeychainVault`: service `com.modelmonitor.app.credentials`, account `vault`, a JSON object keyed by `<prefix><key>`), this device only. Secrets held as separate per-account items under the same service are copied into the vault on first read.
- Account email, account identity, and OpenCode's workspace id are mode `0600` files in `~/Library/Application Support/TokenMon/` (`<prefix><key>.dat`).
- A secret still in a `.dat` file is moved into the Keychain once it has been written and read back; if the Keychain write fails the file is kept and used.

At launch, `Application Support/ModelMonitor/` is moved to `TokenMon/` when `TokenMon/` does not exist. At launch `LegacyCacheCleanup` removes, once, the `URLCache` files in `~/Library/Caches/com.modelmonitor.app/` and the shared cookie jar `com.modelmonitor.app.binarycookies` that `URLSession.shared` can hold for provider requests.

Provider requests use `ProviderURLSession.shared`, an ephemeral session with no cookie jar and no URL cache; credentials travel only in explicit `Cookie` / `Authorization` headers. Details: `AUTH_AND_ENDPOINTS.md`.

## Percent semantics

- **Menu bar** shows **used** percent (e.g. 38%).
- **Dropdown** shows both used and remaining (e.g. `38% used · 62% remaining`) plus a billing-period daily use chart.

## Build source of truth

`project.yml` (XcodeGen) is the only project definition. Run `make project` after adding or moving files and commit the regenerated project; CI fails on drift. Build through `TokenMon.xcodeproj`. The bundle identifier is `com.modelmonitor.app`.

## Shared provider patterns

- **Auth capture** — `WebKitCookieCapture` + a per-provider `ProviderAuthConfig` (hosts, preferred session cookie, essential-cookie allowlist, sign-out hosts).
- **Sign-in UI** — one window group keyed by provider shows `ProviderSignInSheet`; each session supplies its start URL, identity hosts, return-page rules and any post-capture step through `ProviderSignInProviding.signInConfig`.
- **Requests** — `ProviderHTTP` / `AuthenticatedRequest` build the headers and map responses to `UsageError`; `ProviderRefresh.run` applies the stale-session check and rejected-session handling for every poller.
- **Polling** — one `PollingLoop` per provider. Each sleeps the full remaining interval and parks (no timer) while its provider is not needed; `AppModel` wakes the loops on menu open and on polling-relevant setting changes, and `SystemWakeGate` pauses them across system sleep until the network is back.
- **UI updates** — pollers, sessions, settings and stores are `@Observable`, so a view re-renders only for the properties it reads. Non-view reactions (the status image, polling wake-ups, usage alerts, Overview history) run through `ObservationLoop`, which re-reads its inputs once per 100 ms burst of changes. The dropdown re-fits when its content height changes.

## Error handling

- Bot-protection challenge (`cf-mitigated` header, or a 403 with an HTML body) → transient error; never counts against the session.
- `401/403` (or a login redirect / `not_authenticated` payload) → `recordAuthFailure`; the third consecutive rejection calls `markSessionInvalid` and the panel prompts re-auth. Grok's REST probes never decide session validity.
- `429` → `UsageError.rateLimited` carrying `Retry-After`, which the loop honours.
- Any failed refresh → exponential backoff in `PollingLoop` for every provider (30s → 10m cap, ±10% jitter on every wait).
- Decode failures are logged and reported as bad responses rather than crashing.
