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

| Area | Responsibility |
|------|----------------|
| `App/` | `TokenMonApp` (SwiftUI `Window` scenes, `AppModel` service graph), `AppDelegate` activation policy and launch housekeeping |
| `Grok/` | Grok auth, usage client/parser/poller, history, and alerts |
| `Grokbot/` | Grokbot weekly allowance client/poller and panel. Owns no session: Grok Bot is a Cursor-backed product (`com.anysphere.sand`), so it borrows `CursorAuthSession` and its sign-in window |
| `OpenCode/` | OpenCode auth, console/local usage, models, and panel |
| `Cursor/` | Cursor auth, dashboard usage client/poller, and panel |
| `Claude/` | Claude auth, usage client/poller, and panel |
| `ChatGPT/` | ChatGPT/Codex auth, usage client/poller, and panel |
| `OpenRouter/` | OpenRouter bearer-key auth, usage client/poller, and panel |
| `Overview/` | Multi-provider hourly chart and shared provider accent colors |
| `Provider/` | Provider identity, switching, and logos |
| `Shared/` | Provider-neutral infrastructure: `ProviderAuthSession`, WebKit cookie bridge/capture, credential stores (Keychain + files), `ProviderURLSession` / `AuthenticatedRequest`, sign-in sheet shell, `PollingLoop`, delta stores, daily-budget math, formatters |
| `MenuBar/` | `MenuBarController` (`NSStatusItem` + `MenuBarPanel`), status-item bitmap renderer, panel, segmented bar, category rows |
| `Settings/` | UserDefaults-backed preferences, launch-at-login |
| `Update/` | GitHub release check, verified in-place install (`UpdateChecker`, `ReleaseFeed`, `AppInstaller`) |

## Data flow

1. On launch, `AppModel` constructs one instance of each provider service and injects its dependencies.
2. Each provider poller runs a `PollingLoop`: it refreshes once at start, then sleeps the full interval its provider returns (the active interval while the menu-bar panel is open, the idle interval otherwise). A provider that is not needed (hidden, disabled, signed out) returns no interval and its loop parks with no timer until `AppModel` calls `wake()` (menu opened, settings changed). Failed refreshes back off exponentially (30 s → 10 min, ±10% jitter), and a 429's `Retry-After` is honoured. `SystemWakeGate` pauses every loop across system sleep and resumes them once `NWPathMonitor` reports the network is back.
3. Grok usage calls the grok.com gRPC-web billing endpoint first and probes REST JSON candidates only when billing fails for a reason other than a rejected session. OpenCode prefers official console usage and falls back to estimates from the local `opencode.db`. Cursor uses cookie-authenticated dashboard endpoints (`/api/usage-summary` and filtered usage events). Endpoint details: `AUTH_AND_ENDPOINTS.md`.
4. Grok snapshots update the UI and append to SwiftData (deduped).
5. The dropdown **Daily use** chart shows the active billing period's **7 days** (e.g. Thu→Wed). Before `resetsAt` the window ends the day before the reset; on the reset day itself, before the reset instant, the reset day is added as an eighth bar because the running period still owns it. Once `now >= resetsAt` (or the API advances `resetsAt`), the whole window rolls to the new period starting on the reset day. Each day scales to `100/7` of the weekly pool. Bars come from **local day-over-day history**; a server `dailySeries` is used only when local samples cannot paint bars. A caption shows when the pool resets.
6. `ThresholdNotifier` fires once per threshold crossing per Grok billing period. It re-arms when usage drops 5+ points below the notified threshold or when `resetsAt` moves to a later period.
7. **Early provider resets.** Providers sometimes reset every user's pool mid-cycle (a free or manual reset). `DailyQuotaDeltaStore.record(…window:)` classifies each sample with `QuotaWindowTransition` using only the provider's own metadata: a *rollover* (old reset instant passed, new one advanced ≥ half a period) or an *early reset* (old reset instant still ahead, used % dropped ≥ `Percent.resetDropFloor`, and the period start or reset instant moved). Either way the baseline restarts at 0 so the first new-window sample is credited whole and only the entries on/after the new window's start day are dropped — earlier days stay as history. After an early reset the weekly bars open on the new window start (`windowStart`) and lead with the preserved days of the cut-short window, dimmed (`DailyBudgetDay.isPriorWindow`); pace/elapsed days ignore them. Wired for Grokbot, Claude (weekly pool) and Cursor (billing cycle). SuperGrok already keeps one SwiftData snapshot per day and re-anchors from `resetsAt`, so it needs no store; OpenCode (bars come from the local DB and console window), ChatGPT and OpenRouter have no delta store and are unchanged.

## Auth sessions and storage

Each cookie provider has a `ProviderAuthSession` subclass: `AuthSessionService` (Grok), `CursorAuthSession` (also used by Grokbot), `OpenCodeAuthSession`, `ClaudeAuthSession`, and `ChatGPTAuthSession`. `OpenRouterAuthSession` stores a pasted API key instead of cookies. Each session signs in through its own non-persistent `WKWebsiteDataStore`, keeps only an allowlist of essential cookies, and invalidates itself after three consecutive rejections (`authFailureThreshold`). A `sessionGeneration` counter lets pollers drop responses that finish after a sign-out or account switch.

Credentials are stored through `SecretRoutingCredentialStore`:

- Secrets (each provider's `session` cookie header, OpenRouter's `key`) are generic-password items in the login Keychain, service `com.modelmonitor.app.credentials`, account `<prefix><key>`, this device only.
- Account email, account identity, and OpenCode's workspace id are mode `0600` files in `~/Library/Application Support/TokenMon/` (`<prefix><key>.dat`).
- A secret still in a legacy `.dat` file is moved into the Keychain once it has been written and read back; if the Keychain write fails the file is kept and used.

A first launch after the rename moves `Application Support/ModelMonitor/` onto `TokenMon/` when the new folder does not already exist. At launch `LegacyCacheCleanup` removes, once, the `URLCache` files in `~/Library/Caches/com.modelmonitor.app/` and the shared cookie jar `com.modelmonitor.app.binarycookies`, which `URLSession.shared` kept for provider requests in older builds.

Provider requests use `ProviderURLSession.shared`, an ephemeral session with no cookie jar and no URL cache; credentials travel only in explicit `Cookie` / `Authorization` headers. Details: `AUTH_AND_ENDPOINTS.md`.

## Percent semantics

- **Menu bar** shows **used** percent (e.g. 38%).
- **Dropdown** shows both used and remaining (e.g. `38% used · 62% remaining`) plus a billing-period daily use chart.

## Build source of truth

`project.yml` (XcodeGen) is the only project definition. Run `make project` after adding or moving files and commit the regenerated project; CI fails on drift. There is no Swift Package Manager app target — use `TokenMon.xcodeproj`. The bundle identifier stays `com.modelmonitor.app` so existing installs keep their preferences.

## Shared provider patterns

- **Auth capture** — `WebKitCookieCapture` + a per-provider `ProviderAuthConfig` (hosts, preferred session cookie, essential-cookie allowlist, sign-out hosts).
- **Sign-in UI** — `ProviderSignInSheet` + `ProviderSignInWebView`; thin provider wrappers supply the start URL, identity hosts, and return-page rules.
- **Requests** — `ProviderHTTP` / `AuthenticatedRequest` build the headers and map responses to `UsageError`.
- **Polling** — one `PollingLoop` per provider. Each sleeps the full remaining interval and parks (no timer) while its provider is not needed; `AppModel` wakes the loops on menu open and on polling-relevant setting changes, and `SystemWakeGate` pauses them across system sleep until the network is back.
- **UI updates** — child `objectWillChange` events are forwarded into `AppModel` through one throttled publisher, so a burst of changes produces one re-render.

## Error handling

- Bot-protection challenge (`cf-mitigated` header, or a 403 with an HTML body) → transient error; never counts against the session.
- `401/403` (or a login redirect / `not_authenticated` payload) → `recordAuthFailure`; the third consecutive rejection calls `markSessionInvalid` and the panel prompts re-auth. Grok's REST probes never decide session validity.
- `429` → `UsageError.rateLimited` carrying `Retry-After`, which the loop honours.
- Any failed refresh → exponential backoff in `PollingLoop` for every provider (30s → 10m cap, ±10% jitter on every wait).
- Decode failures are logged and reported as bad responses rather than crashing.
