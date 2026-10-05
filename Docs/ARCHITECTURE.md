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
| `App/` | `MenuBarController` (`NSStatusItem` + `MenuBarPanel`), SwiftUI `Window` scenes, `AppDelegate` activation policy |
| `Grok/` | Grok auth, usage client/parser/poller, history, and alerts |
| `Grokbot/` | Grokbot weekly allowance client/poller and panel. Owns no session: Grok Bot is a Cursor-backed product (`com.anysphere.sand`), so it borrows `CursorAuthSession` and its sign-in window |
| `OpenCode/` | OpenCode auth, console/local usage, models, and panel |
| `Cursor/` | Cursor auth, dashboard usage client/poller, and panel |
| `Claude/` | Claude auth, usage client/poller, and panel |
| `ChatGPT/` | ChatGPT/Codex auth, usage client/poller, and panel |
| `OpenRouter/` | OpenRouter bearer-key auth, usage client/poller, and panel |
| `Overview/` | Multi-provider hourly chart and shared provider accent colors |
| `Provider/` | Provider identity, switching, and logos |
| `Shared/` | Provider-neutral infrastructure: WebKit cookie bridge/capture, sign-in sheet shell, poll interval, formatters |
| `MenuBar/` | Status-item bitmap renderer, panel, segmented bar, category rows |
| `Settings/` | UserDefaults-backed preferences, launch-at-login |

## Data flow

1. On launch, `AppModel` constructs one instance of each provider service and injects its dependencies.
2. Each provider poller starts a loop: active interval while the menu is open, idle interval otherwise; Grok also pauses across sleep/wake.
3. Grok usage tries REST JSON candidates, then grok.com gRPC-web billing, then CLI billing JSON. OpenCode prefers official console usage and falls back to local database estimates. Cursor uses cookie-authenticated dashboard endpoints (`/api/usage-summary` and filtered usage events).
4. Grok snapshots update the UI and append to SwiftData (deduped).
5. The dropdown **Daily use** chart is always **7 days** of the active billing period (e.g. Thu→Wed). Before `resetsAt`, the window ends the day before reset; once `now >= resetsAt` (or the API advances `resetsAt`), the whole window rolls to the new period starting that Thursday — never two Thursdays. Each day scales to `100/7` of the weekly pool. Prefer **local day-over-day history**; use server `dailySeries` only when local samples cannot paint bars. A caption shows when the pool resets.
6. `ThresholdNotifier` fires once per threshold crossing.
7. **Early provider resets.** Providers sometimes reset every user's pool mid-cycle (a free or manual reset). `DailyQuotaDeltaStore.record(…window:)` classifies each sample with `QuotaWindowTransition` using only the provider's own metadata: a *rollover* (old reset instant passed, new one advanced ≥ half a period) or an *early reset* (old reset instant still ahead, used % dropped ≥ `Percent.resetDropFloor`, and the period start or reset instant moved). Either way the baseline restarts at 0 so the first new-window sample is credited whole and only the entries on/after the new window's start day are dropped — earlier days stay as history. After an early reset the weekly bars open on the new window start (`windowStart`) and lead with the preserved days of the cut-short window, dimmed (`DailyBudgetDay.isPriorWindow`); pace/elapsed days ignore them. Wired for Grokbot, Claude (weekly pool) and Cursor (billing cycle). SuperGrok already keeps one SwiftData snapshot per day and re-anchors from `resetsAt`, so it needs no store; OpenCode (bars come from the local DB and console window), ChatGPT and OpenRouter have no delta store and are unchanged.

## Auth storage

Session cookies and optional bearer tokens are stored as mode `0600` files under:

`~/Library/Application Support/TokenMon/{auth_*,opencode_auth_*,cursor_auth_*}.dat`

A first launch after the rename moves `Application Support/ModelMonitor/` onto `TokenMon/` when the new folder does not already exist.

Keychain is intentionally avoided: unsigned/debug builds repeatedly prompt “wants to access the keychain.”

## Percent semantics

- **Menu bar** shows **used** percent (e.g. 38%).
- **Dropdown** shows both used and remaining (e.g. `38% used · 62% remaining`) plus a billing-period daily use chart.

## Build source of truth

`project.yml` (XcodeGen) is the only project definition. Run `xcodegen generate` after adding or moving files. There is no Swift Package Manager app target — use `TokenMon.xcodeproj`. The bundle identifier stays `com.modelmonitor.app` so existing installs keep their preferences.

## Shared provider patterns

- **Auth capture** — `WebKitCookieCapture` + per-provider domain/session policy (`AuthSessionService`, `OpenCodeAuthSession`, `CursorAuthSession`).
- **Sign-in UI** — `ProviderSignInSheet` + `ProviderSignInWebView`; thin provider wrappers supply URLs and return-page rules.
- **Polling** — `PollingLoop` + `PollInterval.seconds(menuIsOpen:settings:)`. Grok alone adds sleep/wake and error backoff.

## Error handling

- `401/403` → provider `markSessionInvalid` + panel prompts re-auth (Grok REST probes must not swallow unauthorized)
- `429/5xx` / network → exponential backoff on Grok (30s → 10m cap)
- Decode failures are logged and recorded with empty products rather than crashing
