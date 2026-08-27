# Auth and endpoints

Grok does not publish a stable public consumer API for the Weekly SuperGrok pool. This app uses the same authenticated surfaces the web Settings → Usage experience relies on, with defensive decoding.

## Authentication

### Primary: WKWebView session cookies

1. User signs in inside an embedded `WKWebView` pointed at `https://grok.com/?_s=usage`.
2. After navigation returns to `grok.com`, cookies are read from `WKWebsiteDataStore.default().httpCookieStore`.
3. Cookies scoped to `grok.com` / `x.ai` / `x.com` are serialized into a `Cookie` header and stored under Application Support (`~/Library/Application Support/TokenMon/auth_session.dat`, mode `0600`).

`ASWebAuthenticationSession` is **not** used because its cookies live in the system jar and are not readable by the app. Keychain is also avoided to prevent access-dialog loops in unsigned debug builds.

Optional bearer tokens captured during WebKit sign-in (or saved under Application Support) are sent as `Authorization: Bearer …` when present. The app no longer imports `~/.grok/auth.json` from the Grok CLI.

## Endpoints (ordered)

| Order | Method | URL | Notes |
|------:|--------|-----|-------|
| 1 | GET | `https://grok.com/rest/subscriptions` | Prefer JSON with product breakdown |
| 1 | GET | `https://grok.com/rest/user` | Alternate identity/usage payload |
| 1 | GET | `https://grok.com/rest/billing/usage` | Candidate usage JSON |
| 1 | GET | `https://grok.com/rest/usage` | Candidate usage JSON |
| 2 | POST | `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` | gRPC-web+proto; empty frame body; yields used % + reset + product mix |
| 3 | GET | `https://cli-chat-proxy.grok.com/v1/billing` | CLI JSON; needs bearer |

## Grokbot (Grok Bot)

Grok Bot is an xAI product but a **Cursor-backed** one: the desktop app bundle is
`com.anysphere.sand`, its onboarding lives at `cursor.com/bot/onboarding`, and it
talks to `api2.cursor.sh` / `api3.cursor.sh`. "Sand" is the name the wire protocol
still uses. TokenMon therefore reuses `CursorAuthSession` (the
`WorkosCursorSessionToken` cookie) rather than owning a second store.

| Method | URL | Notes |
|--------|-----|-------|
| POST | `https://cursor.com/api/dashboard/get-sand-usage-status` | Body `{}`; REST wrapper over `aiserver.v1.GetSandUsageStatusResponse` |

Response fields consumed (protobuf-es emits camelCase over JSON; the parser also
accepts the proto names):

| Field | Use |
|-------|-----|
| `usage_percent` | Weekly used % |
| `next_reset_timestamp_utc` | Reset instant — the anchor for every window |
| `current_period_start` | Period start; with the reset it yields the real period length |
| `included_limit_zero`, `has_non_zero_included_limit` | Whether the plan includes an allowance at all |
| `included_usage_super_grok_plan`, `grok_plan_label` | Which subscription funds the allowance |

**One endpoint covers both purchase channels.** Grokbot is sold through Cursor
*and* through SuperGrok; when a SuperGrok plan pays for it, the plan fields are
populated and the rest of the payload is identical. There is no separate
per-channel endpoint, so no source resolution is needed.

**Signed-out behaviour:** an expired session returns `307` to
`api.workos.com/user_management/authorize`. `URLSession` follows it and lands on
an HTML page, so the client treats any non-JSON body as `unauthorized` rather
than a decode failure.

**Usage window:** `next_reset_timestamp_utc` is the only anchor. When it is
absent the snapshot carries `resetsAt == nil` and the panel withholds both the
weekly caption and the Daily Budget bars — no calendar-derived substitute.

### Daily use — status

**No confirmed public daily series endpoint.**

Probed (2026-07-11) with a live session:

| Endpoint | Result |
|----------|--------|
| `GetGrokCreditsConfig` | Cumulative weekly `%` + product mix + period start/end only |
| `GetGrokUsageInfo` / `GetGrokBuildBillingHistory` | HTTP 200, **empty body** (even with period params) |
| `GetUsage` / `GetDailyUsage` / REST `/usage/daily` | Empty or 404 |

Observed CreditsConfig paths: `[1,1]` used%, `[1,4]` period start, `[1,5]` reset, `[1,7]` product sub-messages (enum field 1 + percent field 2).

Product mix must be paired **inside each field-7 sub-message**. Flat-zipping all enums with all percents misassigns usage when a product (e.g. Voice at 0%) omits its percent field — later slices shift onto the earlier enum.

Product-type enums (field 1 inside each field-7 message):

| Enum | Product | Evidence |
|-----:|---------|----------|
| 1 | API | Inferred (sequential; not in 2026-07-28 capture) |
| 2 | Grok Build | Live 2026-07-28 (30%) |
| 3 | Other | Live 2026-07-28 (1%) |
| 4 | Chat | Live 2026-07-28 (21%) |
| 5 | Imagine | Live 2026-07-28 (12%) |
| 6 | Voice | Inferred (sequential; 0% omitted from capture) |

(Do not map 3→Imagine or 5→Voice — that swaps Imagine with Voice/Other.)

Until a real daily RPC is found, the dropdown chart:

1. Shows the **billing period** week (seven days starting at the previous reset’s calendar day, e.g. Thu→Wed)
2. Prefers local history day-over-day deltas; uses `WeeklyUsageSnapshot.dailySeries` only when local samples cannot paint bars
3. Else uses **deltas between successive local sample days** in the same billing period (SwiftData end-of-day snapshots)
4. On period rollover, advances the whole week window — never splits two periods into one bar
5. Bars stay empty until two same-period sample days exist; after a calendar day rollover, yesterday keeps its end-of-day total and today shows only new usage since then
6. Past weeks (chevron left) anchor to that week’s period `resetsAt` from local samples — not the live period — so last week’s bars remain after the weekly reset

If xAI exposes a new daily API, document and test the endpoint in this file before adding it to the Grok usage client. The production app does not probe speculative endpoints.


### gRPC-web request shape

```
POST /grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
Content-Type: application/grpc-web+proto
x-grpc-web: 1
Origin: https://grok.com
Referer: https://grok.com/?_s=usage
Cookie: <session>
Authorization: Bearer <optional>

Body: 00 00 00 00 00   # empty gRPC-web data frame
```

Response is scanned for float32 usage percent fields and unix reset timestamps (community-proven approach used by tools such as CodexBar).

### Expected JSON fields (defensive)

```json
{
  "usedPercent": 35,
  "remainingPercent": 65,
  "resetsAt": "2026-07-16T20:25:00Z",
  "products": [
    { "id": "build", "displayName": "Grok Build", "percentOfPool": 25 },
    { "id": "api", "displayName": "API", "percentOfPool": 9 },
    { "id": "chat", "displayName": "Chat", "percentOfPool": 1 }
  ],
  "extraCredits": 0
}
```

Also accepted:

- Nested wrappers (`usage`, `data`, `billing`, …)
- `byProduct` / `productUsage` maps
- CLI shape: `monthlyLimit.val`, `usage.totalUsed.val`, `billingCycle.billingPeriodEnd`

When only an overall percent is available, the UI synthesizes a single **Other** segment so the segmented bar still renders.
