# TokenMon codebase and CI review

**Date:** 2026-08-20  
**Scope:** Full tree under `token_monitor/` (source, tests, Makefile, GitHub Actions). Not a git-diff review.  
**Stance:** Strict. Parser coverage is real; runtime, auth, persistence, and CI gates are not.

---

## Verdict

TokenMon is a competent multi-provider macOS menu-bar app that has already extracted a useful shared layer (`ProviderAuthSession`, `ProviderSignInSheet`, `PollingLoop`, `AuthenticatedRequest`, `FileBackedStringStore`). That extraction is **incomplete**, several production paths have **no tests**, and CI **looks** like a gate while leaving the highest-risk code unguarded.

The DailyUsageBuilder XCTest suite and OpenCode SQLite aggregation tests are the high bar. Almost everything that actually runs in the menu bar — pollers, session invalidation, SwiftData history, threshold alerts, settings clamps, WebKit capture, menu-bar bitmap rendering — can regress with a green CI.

**Do not treat `make test-core` as a regression gate.** CONTRIBUTING and the PR template still present it as the default check. It duplicates a handful of happy-path parser asserts and **does not run** the DailyUsageBuilder reset/rebase cases.

---

## Size snapshot

| | Count |
|---|---|
| Production Swift files | 69 |
| Production Swift lines | ~10,064 |
| Test Swift files | 14 (13 XCTest + 1 CLT harness) |
| Test Swift lines | ~2,581 |
| XCTest `test*` methods | ~121 |
| GitHub workflows | 1 (`ci.yml`) |

Largest production files: `OpenCodeLocalStats.swift` (773), `UsageClient.swift` (728), `DailyUsageBuilder.swift` (709), `CursorUsageClient.swift` (641). Largest test file: `UsageParsingTests.swift` (977) — a kitchen-sink file the lint config was loosened to accommodate.

---

## What is actually in good shape

- Shared auth/sign-in/poll **skeleton** is the right shape. Provider wrappers are mostly policy (hosts, cookie names, start URLs).
- Grok REST **does not swallow 401/403** (`UsageClient.swift` ~39–45, 91–93). Matches `Docs/ARCHITECTURE.md`.
- App Support directory is `0700`, cookie files **intend** `0600`, and `ModelMonitor` → `TokenMon` migration refuses to clobber an existing folder (`AppSupport.swift` 37–41; tests exist).
- OpenCode local DB opens `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` via `getpwuid` so a sandbox home is not required.
- gRPC product pairing inside field-7 submessages, with a live-fixture enum map (Imagine vs Voice), is characterized by tests.
- `extractDailySeries` is **intentionally empty** after false positives (`UsageClient.swift` 468–480) — that is documented discipline, not a stub left by accident.
- `BackoffTimer`, `JSON` coercion, domain lookalike rejection, and App Support migration have real unit tests.
- Agent lifecycle (`LSUIElement`, dock reveal only for windows) is consistent.

---

## Findings

Severity: **P0** ship-blocker / security, **P1** correctness or session integrity, **P2** real defect or missing gate, **P3** hygiene / debt.

### P1 — `markSessionInvalid` does not clear WebKit or `HTTPCookieStorage`

`ProviderAuthSession.markSessionInvalid` (`ProviderAuthSession.swift` 67–76) deletes `auth_*session.dat` but does **not** run the cookie cleanup that `signOut()` does (124–137). Sign-in and capture both use `WKWebsiteDataStore.default()`.

After a 401, “Sign in again” can auto-capture the **same expired cookies**. Grok capture `maxAttempts` is 1 (`AuthSessionService.swift` 39), so the user gets one failed capture.

**Fix:** One `clearBrowserState()` used by both `signOut` and `markSessionInvalid`. Prefer a per-provider `WKWebsiteDataStore`.

### P1 — Session cookies are plaintext files in an unsandboxed app

- `TokenMon.entitlements` is an empty dict: **no App Sandbox, no Keychain**.
- Cookies and Grok bearer files live at `~/Library/Application Support/TokenMon/auth_*.dat` (mode `0600` attempted **after** `Data.write`, both `try?` — chmod failure leaves umask perms, often `644`).
- README still claims the sandbox container path (`README.md` 142–144). That path is **false** for this binary.
- README also claims network is limited to Grok/xAI and OpenCode. **Cursor `cursor.com` is polled**; Info.plist has no ATS allowlist.

This is a documented debug-UX tradeoff (Keychain dialogs on ad-hoc builds). It is still a session-theft surface for any process of the same user. Signed/notarized builds should use Keychain (or `SecAccessControl`). README must describe the real path.

### P1 — Shared default WebKit cookie jar

All three providers share `WKWebsiteDataStore.default()`. Grok capture includes **all** cookies for `grok.com` / `x.ai` / `x.com` / `twitter.com` when any auth-ish cookie exists (`includeAllDomainCookiesWhenSessionFound: true`). X/Twitter sessions can land in `auth_session.dat`.

### P1 — XCTest host launches the full app

`project.yml` 51–52:

```
TEST_HOST: "$(BUILT_PRODUCTS_DIR)/TokenMon.app/Contents/MacOS/TokenMon"
BUNDLE_LOADER: "$(TEST_HOST)"
```

`TokenMonApp` `@main` constructs `AppModel` (`TokenMonApp.swift` 91–122), which **starts every poller**, opens SwiftData, requests notification permission, and writes Application Support. Tests are not hermetic. They can flake, prompt, or poll live hosts depending on leftover cookies on the CI/local Mac.

**Fix:** Extract `AppModel` construction from `@main`, or add a process-launch flag / `XCTestConfigurationFilePath` guard that skips `providers.startAll()` and notification auth under test.

---

### P2 — SwiftData `recent` IDs desync on the second same-day sample

`HistoryStore.append` (`HistoryStore.swift` 108–172):

1. Disk row keeps the original `id`.
2. `apply(_:)` does **not** copy `snapshot.id`.
3. `upsertRecent(snapshot, replacingID: existing.id)` stores a **new** UUID in `recent`.
4. The next same-day poll cannot find `existing.id` in `recent` and **prepends**.

Early-out only skips samples with `< 0.05%` change **and** `< 60s`. A long session inflates `recent` (capped at 200) and can evict older days that `DailyUsageBuilder` reads from `history.recent`. Disk `allSnapshots()` stays correct because same-day extras are deleted.

There are **zero** `HistoryStore` tests despite `init(inMemory: true)` existing for exactly this.

**Fix:** Upsert `recent` by calendar day, or keep `existing.id` on the in-memory snapshot. Flush on terminate (`scheduleFlush` can drop the last 400ms on quit).

### P2 — Grok poller wipes session state every idle tick while signed out

`UsagePoller.refreshNow` (`UsagePoller.swift` 70–84):

```swift
guard auth.isSignedIn, !auth.needsSignIn else {
    lastError = UsageClientError.notSignedIn.localizedDescription
    if !auth.isSignedIn {
        auth.markSessionInvalid()
    }
    return
}
```

Unlike Cursor/OpenCode (`needsCursorPolling` / `needsOpenCodePolling`), Grok **always** polls. Signed-out, every interval calls `markSessionInvalid()`. Combined with P1, this fights an in-progress WebKit login.

**Fix:** Do not `markSessionInvalid` when already unsigned. Add `needsGrokPolling` (bar, Grok/Overview tab, or signed-in).

### P2 — `PollingLoop` does not react to `menuIsOpen`

Interval is sampled **after** sleep (`PollingLoop.swift` 32–43). Opening the menu (active 15–60s) does not cancel an idle sleep (up to 3600s). `onAppear` does a one-shot refresh; the loop stays on the old delay.

### P2 — HTTP layer is only half-shared

Cursor uses `AuthenticatedRequest`. Grok still has `UsageClient.applyAuth` + manual status codes (`UsageClient.swift` 79–193). OpenCode uses raw `URLSession.shared` and scrapes SolidStart JS.

`AuthenticatedRequest.perform` always uses `URLSession.shared` (line 50) — not injectable, **untested**. Grok’s `UsageClient.session` *is* injectable and unused by tests.

### P2 — Grok bearer / CLI billing is load-only

Nothing in app sources **writes** `token`. `usesBearerToken: true` only deletes a leftover file. CLI `~/.grok/auth.json` import is gone; `cli-chat-proxy.grok.com` is dead unless a user plants `auth_token.dat`. Docs still mention bearer capture (`Docs/AUTH_AND_ENDPOINTS.md`).

### P2 — Shared `ISO8601DateFormatter` used off the main actor

`ISO8601.swift` 6–20: static `Formatter` subclasses. `UsageClient` and `CursorUsageClient` are `Sendable` and parse after `await URLSession`. Formatters are not thread-safe. Grok and Cursor pollers run concurrently.

### P2 — Work computed and never shown

| Item | Evidence |
|------|----------|
| `OpenCodeUsagePoller.weekHeatmap` | Written in the poller; **no other Swift file reads it** |
| `CursorUsageClient.mostUsedModel` | Paged from up to 40×500 events; panel never displays it |
| `AppSettings.filteredProducts` | Defined, **never called**. Grok panel hardcodes `chat/build/imagine/voice` |
| `CursorPoolBar` | Unused; panel uses `SlimUsageTrack` |
| `HistoryStore` `import SQLite3` | Unused |
| `GRPCWebParser.extractDailySeries` | Always `[]` (intentional; keep or delete the dead helper) |

### P2 — Category preferences do not affect the Grok dropdown

`GrokPanelView` hardcodes product IDs. `visibleProductIDs` only affects menu-bar chips. Preferences UI implies otherwise.

### P2 — Overview title still says “Token Monitor”

`OverviewPanelView.swift` 33. Bundle ID `com.modelmonitor.app` is **intentional** (prefs survive rename — `ARCHITECTURE.md` 64). The visible title is not.

### P2 — OpenCode / Cursor have no 429 backoff

Architecture gives Grok `BackoffTimer` (30s → 10m). Cursor pages `/api/dashboard/get-filtered-usage-events` with no backoff. A 429 storm is untested and unthrottled.

### P2 — Threshold alerts are Grok-only

`ThresholdNotifier` copy is “Weekly SuperGrok usage…”. OpenCode/Cursor over-quota has no notification. No tests for enable flag, hysteresis (`usedPercent < last - 5`), or duplicate suppression.

### P2 — Privacy manifest incomplete

`PrivacyInfo.xcprivacy` declares UserDefaults + file timestamps. The app posts local notifications (`ThresholdNotifier`) with no corresponding privacy entry.

---

### P3 — Lint is `--strict` in name only

`.swiftlint.yml` raises the ceilings so current files stay green:

| Rule | This repo | Typical default |
|------|-----------|-----------------|
| `file_length` error | 1100 | ~400 |
| `type_body_length` error | 1000 | ~250 |
| `function_body_length` error | 300 | ~40 |
| `cyclomatic_complexity` error | 32 | ~10 |
| `function_parameter_count` error | 14 | ~5 |

Comments in the file admit the intent: freeze debt until a later refactor. `--strict` turns those warnings into errors, so **the warning numbers are the real gate**. `force_unwrapping` is off. `UsageParsingTests.swift` is 977 lines — the file the comment names as the reason `file_length` was raised.

### P3 — SwiftFormat config disables the useful rules

`.swiftformat` disables indent, `spaceAroundOperators`, wrapping, **and `noForceUnwrapInTests`**. The format job will not catch the issues the project skill cares about. It is a green-at-all-costs baseline.

### P3 — Logger subsystem hardcoded ~10 times

`"com.modelmonitor.app"` is copied into pollers, clients, history, alerts, auth. Should be `Bundle.main.bundleIdentifier` or one `enum AppLog`.

### P3 — User-Agent / version drift

`UsageClient` sends `TokenMon/1.0`; `MARKETING_VERSION` is `1.1.0`. OpenCode console header still uses `server-fn:grok-monitor`.

### P3 — `ExportOptions.plist` is gitignored

`.gitignore` line 26 is bare `ExportOptions.plist`, so `Scripts/ExportOptions.plist` is **not tracked**. Release/notarize docs can drift from what a clone actually has.

### P3 — README vs Makefile vs CI

README “All Makefile targets” omits `format`, `format-fix`, `secrets` even though CI runs format + gitleaks. README Features table is still SuperGrok-centric while the app ships Cursor + OpenCode + Overview.

### P3 — Force unwraps on static URLs

Accepted for compile-time literals (`https://grok.com/...`). `ProviderHourlyUsage.swift` `precondition` on 24-length arrays will crash if a poller ships a short array — untested.

---

## Redundancies

**Already shared (keep):** auth session base, sign-in sheet chrome, poll loop, `UsageError`, Cursor HTTP helper, JSON coercion, `SlimUsageTrack` / `PanelCard` / `DailyBudgetBarsView`.

**Still duplicated:**

| Concern | Grok | OpenCode | Cursor |
|---------|------|----------|--------|
| Poller | `UsagePoller` (sleep + backoff + history) | `OpenCodeUsagePoller` | `CursorUsagePoller` |
| HTTP 401 / headers | `applyAuth` + manual status | raw `URLSession` | `AuthenticatedRequest` |
| Sign-in `Window` scene | three near-identical blocks in `TokenMonApp` | same | same |
| Panel signed-out / error chrome | copy-paste across three panel views | | |
| Domain helpers | `isGrokDomain` | `isOpenCodeDomain` | `isCursorDomain` (all wrap `Domain.matches`) |

`ProviderRegistry` only **starts** pollers. `AppModel` still constructs three auths, three pollers, and `forwardChanges` by name.

`CoreTestsMain.swift` duplicates XCTest fixtures (same JSON, same gRPC hex, same CSV/JSON export asserts). Two suites, one of them a false sense of coverage.

---

## Test review (strict)

### Coverage map (condensed)

| Area | Quality |
|------|---------|
| `UsageResponseParser` / `GRPCWebParser` | Partial→strong on live hex; **no** `nil` on garbage JSON |
| `DailyUsageBuilder` | **Strong in XCTest**; thin in `test-core` (not a substitute) |
| `OpenCodeLocalStats` | Strongest file in the repo; missing corrupt schema / busy lock |
| `CursorUsageClient` parse/hours | Partial; empty `{}` → 0% untested; `parseSummary` never asserted to throw |
| `OpenCodeConsoleClient` | Thin discovery + one JS fixture; missing windows / `mine:false` untested |
| `AuthenticatedRequest` | Headers + status map only; `perform` never executed |
| `ProviderAuthSession` | Start / email / invalid; **no** cookie save, sign-out extra keys, capture |
| `BackoffTimer` | Geometric doubling + cap; no `initial > maximum` |
| `AppSupport` | Migration OK; `testDefaultUsesExpectedSubdirectory` hits **real** Application Support |
| `HistoryStore` | **None** (`inMemory:` unused) |
| `UsagePoller` / Cursor / OpenCode pollers | **None** |
| `ThresholdNotifier` | **None** |
| `GrokHourlyActivityStore` | **None** (injectable `store:` unused) |
| `AppSettings` | **None** (clamps, `needs*Polling`, `filteredProducts`) |
| `PollingLoop` | **None** (closures are injectable) |
| `MenuBarStatusRenderer` | **None** (project skill names this as a production footgun) |
| `DailyBudget` | **None** |
| `WebKitCookieCapture` | **None** |
| `AppModel` / `AppDelegate` | **None** |

### Tautological tests (do not count as regression coverage)

- `ColorPaletteTests.testSRGBComponentsRoundTrip` — reads stored properties.
- `FormatTests.testResetDateMatchesNaiveFormatterAndLowercasesMeridian` — **reimplements** production then compares.
- `UsageErrorTests.testLocalizedDescriptions` — `isEmpty == false`.
- `OpenCodeStatsTests.testWindowLabelsAndLimits` — string literals == string literals.
- `testOverviewHourlyRelativeStackKeepsSmallProvidersVisible` — recomputes `heightFraction` locally, `_ = hour`, **never calls** `relativeStackWeight`.

### Dual-suite drift

`Tests/Manual/CoreTestsMain.swift` + `Scripts/run_core_tests.sh`:

- Compiles `DailyUsageBuilder.swift` and `UsageClient.swift` **just to run ~12 asserts**.
- Does **not** include Cursor/OpenCode.
- Does **not** include DailyUsageBuilder reset/rebase/previous-week cases.
- Same gRPC hex as `testGRPCProductBreakdown` — live enum-map regression (`testGRPCLiveCreditsConfigEnumMap`) is XCTest-only.

CONTRIBUTING.md 32–36 and `.github/PULL_REQUEST_TEMPLATE.md` 7–8 tell contributors to run core tests first. A green core suite can ship a broken billing-week chart.

### Skill violations

`skills/swift-engineer/SKILL.md` requires one XCTestCase file per unit under `TokenMonTests/<Feature>/`. Reality: `SharedHelpersTests` is stuffed into `UsageParsingTests.swift` 936–977; DailyUsageBuilder tests live in the same 977-line file.

---

## CI review (strict)

File: `.github/workflows/ci.yml`. Jobs today: SwiftLint, SwiftFormat, gitleaks-action, `make test-core`, `xcodebuild test` + Codecov.

### What CI actually proves

| Job | Proves | Does not prove |
|-----|--------|----------------|
| lint | Files are under the **loosened** SwiftLint ceilings | Complexity/length of the files the comments name |
| format | Current `.swiftformat` (with useful rules disabled) | Indent, operator spacing, force-unwraps in tests |
| secrets | `gitleaks-action` `detect` on a **shallow** clone | Same command as `make secrets` (`gitleaks dir .`) |
| core-tests | CLT parser happy paths | DailyUsageBuilder regressions, Cursor, OpenCode, pollers |
| build-and-test | XCTest on a **regenerated** xcodeproj | Committed `TokenMon.xcodeproj` matches `project.yml` |
| coverage upload | Best-effort | Anything (`fail_ci_if_error: false`; `*.xcresult` is a bundle, not lcov) |

### Concrete CI defects

1. **No `workflow_dispatch`.** Cannot re-run the gate without a dummy commit.
2. **No `schedule`.** No nightly fixture replay.
3. **No `permissions:`** block. No `timeout-minutes`.
4. **Actions unpinned** (`actions/checkout@v4`, `codecov/codecov-action@v4`, `gitleaks/gitleaks-action@v2`).
5. **`brew install` unpinned** every run (SwiftLint, SwiftFormat, XcodeGen). Tool defaults change; CI can go red or silently loosen vs local.
6. **Lint/format burn macos-26 minutes** for CLI tools that do not need Xcode 26.
7. **gitleaks-action vs Makefile mismatch.** CI uses git `detect` on `fetch-depth: 1`. Local uses `gitleaks dir .`. Step is named “Install gitleaks” but it **runs** the scan. Org repos may need `GITLEAKS_LICENSE`. No `.gitleaks.toml`.
8. **Coverage theater.** `files: build/DerivedData/Logs/Test/*.xcresult`, `fail_ci_if_error: false`, no `codecov.yml` thresholds, scheme has no `codeCoverageTargets`.
9. **xcodegen is not a drift gate.** CI always `make project` then tests the regenerated tree. A stale committed `TokenMon.xcodeproj` never fails CI — the exact footgun in skill lesson #5.
10. **`make test` and CI `xcodebuild` diverge.** Makefile does not pass `-enableCodeCoverage YES`.
11. **No Release configuration build.** `ENABLE_TESTABILITY` is Debug-only; availability / optimizer issues can ship.
12. **No golden fixture directory.** gRPC hex and OpenCode JS live as inline strings in two files that can drift.

`macos-26` as of this review is a valid hosted image and matches local Xcode 26.x. Pin a **specific** `Xcode_26.x.app` anyway; image defaults move.

---

## Recommended GitHub workflows

Split cheap Linux/macOS-15 jobs from Xcode jobs. Pin tool versions. Fail closed.

### `ci.yml` — `push` (`main`/`master`) + `pull_request` + `workflow_dispatch`

```yaml
permissions:
  contents: read
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

| Job | Runner | Must fail if |
|-----|--------|----------------|
| **lint** | `macos-15` (or Linux + released SwiftLint) | `swiftlint lint --strict` nonzero. Pin formula version. Cache bottle. |
| **format** | same | `swiftformat . --lint` nonzero. Pin binary to the version that matches `.swiftformat`. Re-enable `noForceUnwrapInTests` for `TokenMonTests/` + `Tests/`. |
| **secrets** | `ubuntu-latest` | `gitleaks dir . --no-banner` (same as Makefile) after `fetch-depth: 0`. Optional second step: `gitleaks detect --log-opts=--all`. Add `.gitleaks.toml` allowlisting only checked-in hex fixtures. |
| **xcodegen-drift** | `macos-15` | After `make project`, `git diff --exit-code TokenMon.xcodeproj`. Committed project **is** the generated project. |
| **core-tests** | macos + **pinned** Xcode | `make test-core` nonzero, or stdout missing `ALL TESTS PASSED`. Either shrink the compile list to types the asserts use, or grow asserts to cover DailyUsageBuilder rebase/reset. |
| **unit-tests** | `macos-26` + `xcode-select` a **named** Xcode | Any XCTest failure. Convert coverage with `xcrun xccov view --report --json` (not raw `.xcresult`). Codecov `fail_ci_if_error: true`. Until poller tests exist, project coverage informational; **patch** threshold on non-View Swift under `TokenMon/Features/`. |
| **build-release** (main only) | macos-26 | `xcodebuild -configuration Release` ad-hoc missing `.app`. |

Do **not** regenerate the project inside `unit-tests` without the drift job. Prefer `make test` flags over a second copy of `xcodebuild` in YAML.

### `nightly.yml` — `cron: "0 7 * * *"` + `workflow_dispatch`

- Replay **checked-in** fixtures: gRPC hex, Cursor summary JSON, OpenCode lite JS.
- `make test` + `make test-core`.
- Fail on fixture hash change without a PR (optional `git` check of `TokenMonTests/Fixtures/`).

### What “extensive” means here (priority order)

CI volume without new tests is theater. Add tests **then** raise thresholds.

1. `HistoryStoreTests` (`inMemory: true`) — same-day replace, 0.05%/60s skip, ID stability, 200-cap, `clear`.
2. `GrokHourlyActivityStoreTests` — temp store, noise floor, day rollover, week-reset drop.
3. `ThresholdNotifierTests` — extract `shouldNotify(...)` so UNUserNotificationCenter is not required.
4. `PollingLoopTests` — first refresh, `interval() == nil` exits, `stop` cancels.
5. `AppSettingsTests` — inject `UserDefaults(suiteName:)`; clamps; `needs*Polling`.
6. `ProviderAuthSessionTests` extend — cookie save → `refreshFromDisk`; extra keys; bearer clear.
7. `WebKitCookieCaptureTests` — `extractEmail`, preferred cookie vs auth-ish.
8. Poller tests with `URLProtocol` / injected clients — 401, Cursor 4s TTL, OpenCode console→local fallback.
9. `MenuBarStatusRendererTests` — unsigned label, bar width, cache key includes appearance.
10. `DailyBudgetTests` — `last7` at period start, over-budget.
11. Parser **error** cases — garbage JSON `nil`/throw; `fillFraction(0.05)==0`.
12. Split `UsageParsingTests.swift` into `DailyUsageBuilderTests`, `GRPCWebParserTests`, `ExportServiceTests`, `PercentTests`, `DomainTests`, `FileBackedStringStoreTests`.
13. `TokenMonTests/Fixtures/` — both XCTest and `CoreTestsMain` load the same files.

Until items 1–8 exist, CI is a **parser linter with a coverage upload that is allowed to fail**.

---

## Misconfiguration checklist

| Item | Status |
|------|--------|
| Bundle ID `com.modelmonitor.app` | Intentional (prefs). Do not “fix” without a migration. |
| Visible title “Token Monitor” | Stale. Should be TokenMon. |
| Entitlements empty | Intentional for OpenCode DB + debug Keychain UX. **Inconsistent with README sandbox claim.** |
| ATS | Default HTTPS; no host lock. Cursor + Google/GitHub OAuth omitted from privacy copy. |
| Hardened runtime | YES in `project.yml` and pbxproj. Aligned. |
| XcodeGen vs pbxproj sources | Aligned at review time; **CI does not enforce it.** |
| Privacy manifest | UserDefaults + file timestamps; notifications undeclared. |
| `.gitignore` `ExportOptions.plist` | Ignores `Scripts/ExportOptions.plist`. |
| Logger / User-Agent | Still `com.modelmonitor` / `TokenMon/1.0`. |

---

## Suggested fix order

1. Session integrity: clear WebKit on `markSessionInvalid`; stop calling it every Grok poll while unsigned.
2. `HistoryStore` ID upsert + tests (`inMemory:`).
3. Stop lying in README (sandbox path, network hosts, SuperGrok-only overview).
4. CI: xcodegen drift job, pin tools, `gitleaks dir` with `fetch-depth: 0`, coverage that can fail, `workflow_dispatch`.
5. Split god-file tests; add poller/auth/settings/renderer tests; then **tighten** SwiftLint ceilings instead of documenting them as a future stage forever.
6. Route Grok/OpenCode JSON HTTP through `AuthenticatedRequest` with an injectable `URLSession`.
7. Delete or use: heatmap, `mostUsedModel` paging, `filteredProducts`, dead `import SQLite3`, CLI bearer path.

---

## Out of scope / not claimed

- This review did not re-run `make test` / `make lint` on this machine as part of the write-up.
- Bundle ID retention is a product decision, not drift.
- No source files were modified. This document is the deliverable.

## Follow-up

Implementation of the CI jobs and the missing test files is a separate change. Start with HistoryStore + session invalidation; those are the two defects most likely to show up as “usage chart went empty” / “sign-in does nothing after 401.”

---

## Implementation status

**Branch:** `feat/codebase-review-fixes` (9 commits, 43 files, +1,435/−174)
**Verified:** 159 XCTests passing (was 121) · `make test-core` · `make lint` · `make format` · `make secrets` all green.

### P1 findings

| Finding | Status |
|---------|--------|
| `markSessionInvalid` does not clear WebKit / `HTTPCookieStorage` | **Fixed** — shared `clearBrowserState()` used by both `signOut()` and `markSessionInvalid()` |
| Session cookies plaintext in unsandboxed app | **Partially** — README now states the real path and mode; Keychain migration still open (documented debug-UX tradeoff) |
| Shared default WebKit cookie jar | **Fixed** — per-provider non-persistent `WKWebsiteDataStore`; legacy default-jar cookies cleaned on sign-out/invalid |
| XCTest host launches the full app | **Fixed** — `XCTestConfigurationFilePath` guard skips `startAll()` + notification prompts; in-memory history under test |

### P2 findings

| Finding | Status |
|---------|--------|
| SwiftData `recent` IDs desync on second same-day sample | **Fixed** — day-based upsert; regression-tested. `flush()` wired to `willTerminate` |
| Grok poller wipes session state every idle tick while signed out | **Fixed** — no-op removed; `needsGrokPolling` gating added (`MonitorProvider.pollsGrok`) |
| `PollingLoop` does not react to `menuIsOpen` | **Fixed** — interval re-evaluated every 250ms during sleep; shrink honored immediately |
| HTTP layer only half-shared | **Deferred** — Grok/OpenCode not yet routed through injectable `AuthenticatedRequest` |
| Grok bearer / CLI billing load-only | **Open** — left as-is (functional path, low risk) |
| Shared `ISO8601DateFormatter` off the main actor | **Deferred** |
| Work computed and never shown | **Fixed** — deleted: `weekHeatmap`, `mostUsedModel` (+ helper/test), `filteredProducts`, `CursorPoolBar`, dead `import SQLite3`. `extractDailySeries` kept (documented discipline) |
| Category preferences do not affect Grok dropdown | **Deferred** |
| Overview title “Token Monitor” | **Fixed** → “TokenMon” |
| OpenCode / Cursor have no 429 backoff | **Deferred** |
| Threshold alerts Grok-only | **Partial** — pure `shouldNotify()` extracted + tested; multi-provider alerts deferred |
| Privacy manifest missing notifications entry | **Skipped deliberately** — local notifications are not an Apple required-reason API category |

### P3 findings

| Finding | Status |
|---------|--------|
| Lint `--strict` in name only | **Open by design** — ceilings unchanged until remaining suites land (per review’s own ordering) |
| SwiftFormat disables useful rules | **Open by design** — green baseline kept for now |
| Logger subsystem hardcoded ~10× | **Fixed** — `AppLog.subsystem` + `Logger(category:)` convenience |
| User-Agent / version drift | **Fixed** — `AppIdentity.userAgent` = `TokenMon/<MARKETING_VERSION>`. `X-Server-Instance` header left untouched (functional risk) |
| `ExportOptions.plist` gitignored | **Fixed** — root-anchored ignore rule; `Scripts/ExportOptions.plist` tracked |
| README vs Makefile vs CI | **Fixed** — targets documented, multi-provider copy, truthful privacy/network claims |
| Force unwraps on static URLs / 24-length preconditions | **Open** |

### CI defects

| # | Defect | Status |
|---|--------|--------|
| 1 | No `workflow_dispatch` | **Fixed** |
| 2 | No nightly schedule | **Deferred** (`nightly.yml` not created) |
| 3 | No `permissions:` / `timeout-minutes` | **Fixed** |
| 4 | Actions unpinned | **Partial** — tool binaries pinned to exact versions via release artifacts; actions still referenced by tag |
| 5 | `brew install` unpinned | **Fixed** — brew eliminated from CI |
| 6 | Lint/format burn macos-26 minutes | **Fixed** — moved to macos-15 |
| 7 | gitleaks-action vs Makefile mismatch | **Fixed** — `gitleaks dir .` on `fetch-depth: 0` + `detect --all` + `.gitleaks.toml` |
| 8 | Coverage theater | **Fixed** — `xccov` conversion, `fail_ci_if_error: true`, `codecov.yml` thresholds (patch 50%, project informational) |
| 9 | xcodegen not a drift gate | **Fixed** — dedicated job, `git diff --exit-code` |
| 10 | `make test` vs CI divergence | **Fixed** — `-enableCodeCoverage YES` in Makefile |
| 11 | No Release build | **Fixed** — `build-release` job on master with dist artifacts |
| 12 | No golden fixture directory | **Deferred** |

### Test expansion (review priority list)

Done: **1** HistoryStoreTests · **3** ThresholdNotifierTests · **4** PollingLoopTests · **5** AppSettingsTests (+ defaults injection) · **7** WebKitCookieCaptureTests (`extractEmail`) · **10** DailyBudgetTests.

Deferred: **2** GrokHourlyActivityStoreTests · **6** ProviderAuthSessionTests extension · **8** poller URLProtocol tests · **9** MenuBarStatusRendererTests · **11** parser error cases · **12** splitting `UsageParsingTests.swift` · **13** shared fixtures directory.
