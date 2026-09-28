# TokenMon Dead & Redundant Code Audit

- **Date:** 2026-09-17
- **Branch:** `master` (working tree dirty: 6 files from the OpenCode console-auth fix)
- **Scope:** Sweep — whole `TokenMon/` tree, focused on dead and redundant code
- **Method:** declaration/reference scan over 102 Swift sources (app + tests), duplicated-body
  scan, `swiftlint --strict` + `swiftformat --lint` (both clean), `make test-core` (pass).
- **Relationship to prior reports:** does not re-audit `TOKENMON_AUDIT.md` (auth/security/budget
  sweep). Findings below are limited to dead or redundant code.

## Resolution (2026-09-17)

All findings addressed or explicitly accepted; re-scan reports **0 unused declarations**.

| Finding | Resolution |
|---------|------------|
| Cursor pace dead feature (Medium) | Removed `CursorPace`, `CursorPoolUsage.pace`, the three `compute` calls, and the pace tests. |
| `isChatGPTDomain` / `isClaudeDomain` | Deleted (policies keep their inline `Domain.matches` closures). |
| `isOpenCodeDomain` | Deleted with its test; `Domain.matches` remains covered by `UsageParsingTests:711-719`. |
| `CursorUsageClient.modelIdentifier(from:)` | Deleted. |
| `TokenMonApp.menuBar` | Converted from an unread `@StateObject` to a documented retained `let`. |
| `paceCaption` duplicated | Extracted to `DailyBudget.paceCaption(_:)`; both charts call it. |
| Provider accent colors (5 places) | Consolidated into `ProviderAccent` (`Shared/ColorPalette.swift`); menu bar, rings, `ModelPalette.orange`, and the Grok chat segment now reference it. Also fixes a real drift: the menu-bar OpenCode composite used `0.90,0.45,0.20` while the selected-provider bar used `1.0,0.55,0.0`. |
| `clearSnapshot` duplicated (Claude/Grokbot) | **Accepted** — deduping needs a shared base or loosening `private(set)` to a settable protocol requirement; not worth the indirection for two 6-line copies. |
| Remaining color literals (`ModelPalette.sRGB` fallback entries, `OpenCodePanelView` DeepSeek logo) | Out of scope — these are a seed palette / a model brand color, not TokenMon provider accents. |

Re-run: `swiftlint --strict` 0 violations, `swiftformat --lint` clean, **376 tests** pass (2 dead tests removed), `make test-core` passes.

## Summary

The tree is in good shape — no commented-out code, no `TODO`/`FIXME`, and no fully orphaned
files. The sweep found one dead *feature* (Cursor pace is computed and tested but never
rendered), four unused declarations, and three duplication clusters. Nothing here is a
correctness or security risk; these are maintainability items.

## Findings

| Severity | Location | Finding | Suggestion |
|----------|----------|---------|------------|
| Medium | `TokenMon/Features/Cursor/CursorModels.swift:14-64`, `TokenMon/Features/Cursor/CursorUsageClient.swift:174,183,193` | The Cursor pace feature is dead *output*: `CursorPace` is computed for every pool and stored on `CursorPoolUsage.pace`, but no view reads it (`CursorPanelView` has no pace/reserve/deficit/forecast UI — `grep` finds `.pace` only in the client). `forecastLabel` (`:38`) has zero references anywhere. Tests (`CursorUsageClientTests:120-124`) assert `paceLabel`/`willLastUntilReset`, giving false confidence that the feature is live. | Either render the pace (restore the intended UI) or delete `CursorPace`, `CursorPoolUsage.pace`, its three `compute` calls, and the accompanying tests. Do not leave it computed-only. |
| Low | `TokenMon/Features/ChatGPT/ChatGPTAuthSession.swift:60` | `isChatGPTDomain(_:)` is declared and never referenced (app or tests); the policy uses an inline `isDomain` closure instead. | Remove, or switch the policy closure to call it (as OpenCode's docs imply). |
| Low | `TokenMon/Features/Claude/ClaudeAuthSession.swift:45` | `isClaudeDomain(_:)` is declared and never referenced (app or tests). | Remove, or wire the policy closure through it. |
| Low | `TokenMon/Features/OpenCode/OpenCodeAuthSession.swift:68` | `isOpenCodeDomain(_:)` is referenced only by tests (`OpenCodeConsoleClientTests:88-91`); no app code calls it. | Remove it and its test, or use it in the policy so it is genuinely exercised. |
| Low | `TokenMon/Features/Cursor/CursorUsageClient.swift:441` | `private static func modelIdentifier(from:)` has no callers (leftover from an events/cost path). | Delete. |
| Low | `TokenMon/App/TokenMonApp.swift:9` | `@StateObject private var menuBar` is assigned via `_menuBar` but never read anywhere; `MenuBarController` self-registers its `NSStatusItem`, so the property exists only for retention. | Either read it (e.g. in a scene) or replace the `@StateObject` with a retained `let` to make the intent explicit. |
| Low | `TokenMon/Features/MenuBar/DailyUsageChartView.swift:88`, `TokenMon/Features/Shared/DailyBudgetBarsView.swift:173` | `paceCaption(_:)` is **byte-identical** (669 chars, verified by `diff`) in two files. Any wording/logic change must be made twice; they will drift. | Extract one shared `DailyBudget.paceCaption(_:)` (pure function) and call it from both surfaces. |
| Low | `TokenMon/Features/Claude/ClaudeUsagePoller.swift:54`, `TokenMon/Features/Grokbot/GrokbotUsagePoller.swift:63` | `clearSnapshot()` bodies are identical (149 chars). | Optional: hoist a shared `ProviderUsagePoller` default or a small helper. Low value — two copies, unlikely to drift much. |
| Low | `MenuBarStatusRenderer.swift:288,622`; `Grok/Usage/UsageModels.swift:32`; `Overview/ConcentricUsageRingView.swift:10`; `OpenCode/OpenCodeModels.swift:385,387,391,395`; `OpenCode/OpenCodePanelView.swift:257` | Provider accent/segment colors are hardcoded in five places, including a comment in `MenuBarStatusRenderer.providerAccent` that admits the values "mirror `ConcentricUsageRingView`". Duplicate literals for Grok navy (`0.11,0.38,0.82`), OpenCode orange (`0.90,0.45,0.20`), and purple (`0.58,0.44,0.86`). | Consolidate to one palette (e.g. `ProductColor.sRGB` / `ModelPalette`) and reference it everywhere; a recolor currently requires five edits. |

## Checklist (verified)

- No `TODO`/`FIXME`/`XXX`/`HACK` in `TokenMon/`.
- No commented-out code blocks (the two `// let …` / `// lets …` hits are prose comments).
- No unreferenced top-level types or files (all declared types have ≥1 reference).
- `swiftlint --strict`: 0 violations. `swiftformat --lint`: 0 files need formatting.
- Full suite: 378 tests pass; CLT core suite (`make test-core`) passes.

## Stale build artifacts

Machine-wide check found a single build present — no stale copies:

- `/Applications/TokenMon.app` — 1.6.1 (build 13), the only installed copy.
- No repo `build/`, `dist/`, `.build`, `.pkg`, `.zip`, or `.xcarchive`.
- No `~/Library/Developer/Xcode/DerivedData/*TokenMon*`, no Xcode `Archives`, no `ModelMonitor.app`, no Trash copies.

## Residual risk / not reviewed

- Runtime-only behavior (network, WebKit capture) not exercised here.
- Non-velocity duplication (larger structural similarity, e.g. per-provider panel scaffolding)
  was not diffed beyond function-body hashing; a deeper clone-detection pass could surface more.
