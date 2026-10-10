# Auth and endpoints

TokenMon reads usage from seven providers. None of them publishes a stable consumer API for the numbers the app shows, so six of them use the same authenticated surfaces their own web dashboards use, with defensive decoding. OpenRouter uses its documented REST API with an API key.

| Provider | Credential | Sent as | Endpoints |
|----------|------------|---------|-----------|
| Grok (SuperGrok) | grok.com session cookies | `Cookie` | `grok.com` gRPC-web billing, then REST probes |
| Grokbot | Cursor session cookie (shared with Cursor) | `Cookie` | `cursor.com/api/dashboard/get-sand-usage-status` |
| Cursor | Cursor session cookie | `Cookie` | `cursor.com/api/usage-summary`, `/api/auth/me`, `/api/dashboard/get-filtered-usage-events` |
| OpenCode | OpenCode console cookies | `Cookie` + `x-org-id` | `opencode.ai/console/...`; plus the local `opencode.db` |
| Claude | claude.ai session cookies | `Cookie` | `claude.ai/api/organizations/{org}/usage` |
| ChatGPT | chatgpt.com session cookie, exchanged for an access token | `Cookie`, then `Authorization: Bearer` | `chatgpt.com/api/auth/session`, `/backend-api/wham/usage` |
| OpenRouter | API key (`sk-or-…`) | `Authorization: Bearer` | `openrouter.ai/api/v1/key`, `/credits`, `/activity` |

## Shared mechanics

### Sign-in and cookie capture

Every cookie-based provider signs in inside an embedded `WKWebView` (`ProviderSignInSheet` / `SignInBrowserView`). Each provider's session (`ProviderAuthSession` subclass) owns its own `WKWebsiteDataStore.nonPersistent()`, so a sign-in page only ever sees that provider's cookies and nothing is written to the default WebKit store.

When the flow returns to the provider's own page, `WebKitCookieCapture` reads that isolated store and keeps only cookies whose domain matches the provider's hosts (`Domain.matches`: exact host or a dot-suffix, never a substring). It then narrows them to the provider's **essential cookie allowlist**, and capture succeeds only once the preferred session cookie is among them. A stored header is narrowed again on every read (`ProviderAuthSession.pruneCookieHeader`), so a jar saved before an allowlist existed loses its extra cookies.

| Provider | Hosts the session belongs to | Essential cookies |
|----------|------------------------------|-------------------|
| Grok | `grok.com`, `x.ai` | `sso`, `sso-rw` |
| Cursor (and Grokbot) | `cursor.com`, `cursor.sh`, `authenticator.cursor.sh` | `WorkosCursorSessionToken` |
| OpenCode | `opencode.ai`, `auth.opencode.ai` | `auth`, `provider`, `__Host-console_session` |
| Claude | `claude.ai`, `www.claude.ai`, `api.claude.ai` | `sessionKey`, `lastActiveOrg` |
| ChatGPT | `chatgpt.com`, `www.chatgpt.com`, `auth.openai.com`, `api.openai.com` | the `__Secure-next-auth.session-token` family (including chunks `.0`, `.1`, …) |

Hosts that only take part in sign-in, such as `x.com` / `accounts.x.ai` for Grok or GitHub / Google for Cursor, are allowed to load in the sign-in view but their cookies are never captured. An email shown for the account comes from the provider's API or a plausible email-shaped cookie value; nothing else is inferred.

ChatGPT's session cookie rolls: `/api/auth/session` returns a renewed `Set-Cookie`, which `applyRefreshedCookies` folds back into the stored header (only for essential cookies; a renewed chunk replaces the whole chunk family).

### Requests

Provider requests go through `ProviderURLSession.shared` (`AuthenticatedRequest.swift`): an ephemeral session with no cookie jar (`httpCookieStorage = nil`, `httpShouldSetCookies = false`) and no URL cache. The stored credential is sent in an explicit `Cookie` or `Authorization` header, a provider's `Set-Cookie` never lands in a shared jar, and authenticated JSON is never written to disk. Requests carry `Accept: application/json` and `User-Agent: TokenMon/<version>`, plus the `Referer` / `Origin` the provider's own page would send.

Older builds sent provider requests through `URLSession.shared`, which can leave responses in `~/Library/Caches/com.modelmonitor.app/Cache.db` and `fsCachedData/`, and provider cookies in the shared jar `com.modelmonitor.app.binarycookies` (under `~/Library/HTTPStorages/` or `~/Library/Cookies/`). At launch `LegacyCacheCleanup` clears `URLCache.shared` and `HTTPCookieStorage.shared` and deletes exactly those files, once each.

Response mapping (`AuthenticatedRequest.responseError`, `ProviderHTTP`):

| Response | Result |
|----------|--------|
| Bot-protection challenge: any status with a `cf-mitigated` header, or a 403 with an HTML body | Transient error ("blocked by a bot-protection check… Retrying."); never counts against the session |
| 401 / 403 | `.unauthorized` (Grokbot: a non-challenge 403 means the account has no Bot access, a transient error) |
| Other non-2xx | `.badResponse("HTTP <status>")`; the body is never shown, and is logged only privately |
| Transport failure | `.network` |

Some providers signal an expired session without a 401: Grokbot and OpenCode are redirected to a login page (followed by `URLSession`, so the client checks the final URL or the non-JSON body), and some payloads carry `error: not_authenticated`. Each client maps these to `.unauthorized` too.

### Session invalidation: three strikes

A single rejection can be a token-exchange hiccup or an edge challenge, and invalidating deletes the stored credential, so it takes **three consecutive** `.unauthorized` / `.notSignedIn` results on the live session (`ProviderAuthSession.authFailureThreshold = 3`) before a session is invalidated. Any successful request resets the count (`recordAuthSuccess`). The rule applies to every provider, including OpenRouter's API key and Grokbot (which counts against the shared Cursor session).

On the third strike `markSessionInvalid` clears the stored credential and the provider's browser cookies so "Sign in again" cannot recapture the same expired session. Usage history is kept, and the account identity survives so a re-login to the same account continues it. An explicit **Sign Out** also clears the account identity and fires `accountReset`, which drops that account's stored history.

Every poll captures the session's `sessionGeneration` before its request and checks it afterwards (`isCurrent(_:)`), so a response that arrives after a sign-out or account switch is discarded and cannot count as a strike against the new session.

### Credential storage

Secrets live in the login Keychain; identifiers that cannot authenticate stay in files.

- **Keychain** (`KeychainVault`, viewed per provider through `KeychainCredentialStore`): one generic-password item, service `com.modelmonitor.app.credentials`, account `vault`, holding a JSON object keyed by `<prefix><key>` (for example `chatgpt_auth_session`, `openrouter_auth_key`); accessible after first unlock, this device only, never synced. Secrets are each cookie provider's `session` header and OpenRouter's `key`. A single item means a new build triggers one access prompt, not one per provider. The vault is read once and cached, so polling does not touch the Keychain every tick. If the user refuses the read, every secret reads as missing and the vault is never written for the rest of the process. Secrets stored as separate per-account items under the same service are copied into the vault the first time their account is read; the separate item is deleted when the Keychain allows it, and each account is checked only once.
- **Files** (`~/Library/Application Support/TokenMon/`, folder `0700`, files `0600`): the account email and identity, and OpenCode's workspace id, as `<prefix><key>.dat`.
- **Migration** (`SecretRoutingCredentialStore`): a secret still held in a legacy `.dat` file is copied into the Keychain, read back to verify it, and only then deleted from disk. If the Keychain write fails, the file stays authoritative, so a Keychain problem never signs the user out.

Release builds are ad-hoc signed, so macOS ties Keychain access to the exact binary. After each update macOS asks once whether the new build may read the TokenMon item; choosing **Always Allow** stops the prompt until the next update.

The XCTest host uses `InMemoryCredentialStore` and never reads, migrates, or writes real credentials.

## Grok (SuperGrok weekly pool)

Sign-in starts at `https://accounts.x.ai/sign-in?redirect=https://grok.com/?_s=usage`; capture runs once the flow returns to `grok.com`.

| Order | Method | URL | Notes |
|------:|--------|-----|-------|
| 1 | POST | `https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` | gRPC-web+proto, empty frame body. Source of truth: used %, period start, reset, product mix |
| 2 | GET | `https://grok.com/rest/subscriptions` | Probed only when billing fails for a reason other than a rejected session |
| 2 | GET | `https://grok.com/rest/user` | Same |
| 2 | GET | `https://grok.com/rest/billing/usage` | Same |
| 2 | GET | `https://grok.com/rest/usage` | Same |

Only the billing endpoint decides whether the session is valid: a 401/403 from it is `.unauthorized`; every REST probe failure, including 401/403, just moves on to the next path. A gRPC status in the HTTP headers (trailers-only reply) or in the trailer frame is checked before parsing.

### gRPC-web request shape

```
POST /grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
Content-Type: application/grpc-web+proto
x-grpc-web: 1
x-user-agent: connect-es/2.1.1
Origin: https://grok.com
Referer: https://grok.com/?_s=usage
Cookie: sso=…; sso-rw=…

Body: 00 00 00 00 00   # empty gRPC-web data frame
```

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

### Daily use

No daily-series endpoint has been found. Probed (2026-07-11) with a live session:

| Endpoint | Result |
|----------|--------|
| `GetGrokCreditsConfig` | Cumulative weekly `%` + product mix + period start/end only |
| `GetGrokUsageInfo` / `GetGrokBuildBillingHistory` | HTTP 200, **empty body** (even with period params) |
| `GetUsage` / `GetDailyUsage` / REST `/usage/daily` | Empty or 404 |

The daily chart is therefore built from local samples (`DailyUsageBuilder`):

1. It shows the **billing-period** week: seven days starting at the previous reset's calendar day (for example Thu→Wed). On the reset day itself, before the reset instant, the running period still owns today, so the reset day appears as an eighth bar.
2. Bars are deltas between successive local end-of-day samples in the same billing period. They stay empty until two same-period sample days exist.
3. A period rollover advances the whole window; two periods never share a bar.
4. Past weeks (chevron left) anchor to that week's own reset from local samples, so last week's bars remain after the weekly reset.
5. A server daily series (`WeeklyUsageSnapshot.dailySeries`) is used only when local samples cannot paint bars.

If xAI exposes a daily API, document and test it here before adding it to `UsageClient`. The app does not probe speculative endpoints.

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

When only an overall percent is available, the UI synthesizes a single **Other** segment so the segmented bar still renders.

## Grokbot (Grok Bot)

Grok Bot is an xAI product but a **Cursor-backed** one: the desktop app bundle is `com.anysphere.sand`, its onboarding lives at `cursor.com/bot/onboarding`, and it talks to `api2.cursor.sh` / `api3.cursor.sh`. "Sand" is the name the wire protocol uses. TokenMon reuses `CursorAuthSession` (the `WorkosCursorSessionToken` cookie) rather than owning a second store, and Grokbot rejections count toward the Cursor session's three strikes.

| Method | URL | Notes |
|--------|-----|-------|
| POST | `https://cursor.com/api/dashboard/get-sand-usage-status` | Body `{}`, `Referer: https://cursor.com/bot`, `Origin: https://cursor.com`; REST wrapper over `aiserver.v1.GetSandUsageStatusResponse` |

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

**Early resets:** the provider may reset everyone mid-cycle. It shows up as
`current_period_start` jumping forward to a date before the previous
`next_reset_timestamp_utc`, together with a used-% drop of at least
`Percent.resetDropFloor`. Detection uses only those two fields (never the
calendar); see `QuotaWindowTransition` and the data-flow notes in
`ARCHITECTURE.md`. A payload whose reset instant stays put while the period
start moves still anchors the bars to the new start, over 7 bars.

## Cursor

Sign-in starts at `https://cursor.com/dashboard/usage` (WorkOS, with GitHub / Google as identity hosts).

| Method | URL | Notes |
|--------|-----|-------|
| GET | `https://cursor.com/api/usage-summary` | Plan pools (Total, Auto, API), on-demand spend, billing cycle start and end |
| GET | `https://cursor.com/api/auth/me` | Account email; best-effort |
| POST | `https://cursor.com/api/dashboard/get-filtered-usage-events` | JSON `{startDate, endDate, page, pageSize}` (epoch ms as strings), `Origin: https://cursor.com`. Paged once per billing-cycle window and cached between polls; feeds the hourly and daily breakdowns |

The billing cycle comes from the usage summary; when only one bound is known, `DailyBudget.subscriptionMonth` infers the other by one calendar month, anchored to the known day.

## OpenCode

OpenCode has two sources.

**Console (official Go usage).** Sign-in starts at `https://opencode.ai/console/login`. The `wrk_…` workspace id in the post-sign-in URL is stored (file, not Keychain) and preferred.

| Method | URL | Notes |
|--------|-----|-------|
| GET | `https://opencode.ai/console/api/go/status` | Header `x-org-id: wrk_…`. `access.meters.{fiveHour,week,month}` with `limitMicroCents` / `usedMicroCents` and resets |
| GET | `https://opencode.ai/console/api/orgs` | Workspaces on the account; searched in turn for the one that holds a Go seat |
| GET | `https://opencode.ai/console/auth/session` | Account email; best-effort |

An expired console session redirects to `/console/login` (or `/auth/authorize`, `/auth/login`) instead of returning 401; the client checks the final URL and maps it to `.unauthorized`. A 403 on an org-scoped request means that workspace was refused, so the client tries the next workspace instead of counting a strike. When the console session expires the panel keeps showing the local estimate.

**Local database.** TokenMon reads `~/.local/share/opencode/opencode.db` (the real home directory, resolved with `getpwuid_r`) **read-only** with SQLite, to estimate model costs and hourly / daily activity. The file never leaves the Mac, and the database is re-read only when it changes.

## Claude

Sign-in starts at `https://claude.ai/new`.

| Method | URL | Notes |
|--------|-----|-------|
| GET | `https://claude.ai/api/organizations/{org}/usage` | `{org}` is the `lastActiveOrg` cookie value; `Referer: https://claude.ai/`. Five-hour and weekly pools (`five_hour`, `seven_day`, or the `limits` list) with `utilization` and `resets_at` |

`lastActiveOrg` also identifies the account, so a capture for a different org fires `accountReset`.

## ChatGPT

Sign-in starts at `https://chatgpt.com/`.

| Order | Method | URL | Notes |
|------:|--------|-----|-------|
| 1 | GET | `https://chatgpt.com/api/auth/session` | Cookie only. Returns the web `accessToken` and renews the rolling session cookie |
| 2 | GET | `https://chatgpt.com/backend-api/wham/usage` | Cookie + `Authorization: Bearer <accessToken>` + `ChatGPT-Account-Id` (from the token's `https://api.openai.com/auth` claim) |

The access token is cached in memory (`ChatGPTAccessTokenCache`) until five minutes before its JWT `exp`, and never longer than 30 minutes, so the session exchange still runs regularly and keeps the cookie fresh. A rejection clears the cached token. A sign-in page returned instead of the session JSON is reported as a bad response.

## OpenRouter

No browser sign-in: the user pastes an API key (`sk-or-v1-…`) in Settings. It is stored in the Keychain vault as `openrouter_auth_key`.

| Method | URL | Notes |
|--------|-----|-------|
| GET | `https://openrouter.ai/api/v1/key` | Key limit, usage, and reset; required |
| GET | `https://openrouter.ai/api/v1/credits` | Account credits; management keys only, so a failure degrades quietly |
| GET | `https://openrouter.ai/api/v1/activity` | Daily activity; management keys only, so a failure degrades quietly |

All three send `Authorization: Bearer <key>`. A rejected key follows the same three-strike rule.

## Update checks

Not a provider, but the app's only other network traffic (Settings → Check for updates; every 6 hours when automatic checks are on):

| Method | URL | Notes |
|--------|-----|-------|
| GET | `https://api.github.com/repos/<owner>/<repo>/releases/latest` | Unauthenticated |
| GET | `https://github.com/<owner>/<repo>/releases/download/…` | Release zip / pkg; redirects are allowed only to `objects.githubusercontent.com` and `release-assets.githubusercontent.com` |

See `NOTARIZATION.md` for how a download is verified before it is installed.
