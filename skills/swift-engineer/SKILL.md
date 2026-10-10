---
name: swift-engineer
description: "Implementation and review guidance for native macOS Swift / SwiftUI code — writing new modules, implementing API clients and parsers, designing data models and enums, handling errors and async/await concurrency, AppKit drawing, reviewing Swift code for correctness, performance, and idiomatic patterns, and performing disciplined performance reviews (hot-path audits, allocation/COW/cache footprint, main-actor hop reduction, JSON/Codable parsing, SQLite access) inspired by Abseil Performance Hints. Use proactively whenever Swift code in this workspace is being written or modified, including enums, Codable models, @MainActor concurrency, SwiftUI views, NSStatusItem/AppKit menu-bar rendering, XCTest suites, or performance review."
tags: [swift, swiftui, appkit, macos, performance, micro-optimization, code-review, cache, allocations, cow, codable, json, sqlite, instruments, hot-path, main-actor, abseil, enum, error-handling, testing]
triggers: [swift, add a provider, endpoint handler, refactor, review swift, typed enum, model a domain, menu bar segment, panel, codable struct, performance review, micro-optimize, hot path, allocation profile, cache miss, speed up swift, reduce allocations, instruments, time profiler, cow, copy-on-write, codable slow, JSONDecoder slow, DateFormatter slow, NumberFormatter slow, SQLite slow, main actor hop, flat profile, SwiftUI lag, menu bar render, N+1]
---

# Swift Engineer

## Overview

Senior native macOS Swift engineering: design types first, let the compiler be the primary correctness tool, and treat every type and function as a contract. Default to value semantics and immutability; reserve `class`, mutation, and force-unwrapping for where they are earned.

This skill encodes the conventions of the `token_monitor` workspace (SwiftUI menu bar app, macOS 14+, Swift 5.10, XcodeGen project), including its performance review discipline.

## Core Philosophy

**Value semantics and immutability are the default. Mutation is the last resort.**

- Prefer `struct` over `class`; model state as immutable values and derive new ones rather than mutating in place.
- Prefer `let` over `var`. When mutation is unavoidable, contain it to the smallest possible scope and document why.
- Prefer returning new values over modifying existing ones.
- Swift's copy-on-write value types make copy-based updates cheap; use them freely.

**Strongly-typed domains eliminate entire classes of bugs.**

- Never use raw `String` constants as function parameters, control values, discriminators, or config keys.
- Model every domain concept with an `enum` (or small `RawRepresentable` type) that encodes valid states at compile time.
- Make enums ergonomically convertible to/from strings for interoperability (JSON, `UserDefaults`, URLs, CLI IDs) via `String` raw values and synthesized `Codable`.
- Eliminates "stringly-typed" logic, prevents invalid inputs at compile time, enables exhaustive `switch` (which the compiler checks as cases are added), and makes interfaces self-documenting.

**Simplicity and composability over cleverness.**

- Always favor **composition over inheritance**. Prefer protocols, generics, and plain function/method composition to subclassing; reserve `class` inheritance for genuinely shared behavior and state (e.g. a base view model) that composition cannot express as cleanly.
- Write short, focused functions and views that do one thing well (typically under 30 lines).
- Compose small pieces into larger behaviors rather than writing monoliths.
- Prefer explicit over implicit — avoid protocol-extension magic or macro cleverness unless it genuinely reduces code and improves clarity.
- If a function needs a comment to explain what it does, break it into smaller, well-named parts.

## Documentation Standards

Every public struct, enum, method, and non-obvious behavior MUST have documentation:

```swift
/// Represents the lifecycle state of an order in the fulfillment pipeline.
///
/// Each case encodes a valid state transition target. Invalid transitions
/// are prevented at compile time by the type system.
///
/// - Note: Wire values are stable; do not reorder existing cases.
enum OrderStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case confirmed
    case shipped
    case delivered
    case cancelled

    /// Human-readable, user-visible name.
    var displayName: String {
        switch self {
        case .pending: return "Pending"
        case .confirmed: return "Confirmed"
        case .shipped: return "Shipped"
        case .delivered: return "Delivered"
        case .cancelled: return "Cancelled"
        }
    }
}
```

- Document the **why**, not just the **what**.
- Use standard doc-comment sections: `- Parameters:`, `- Returns:`, `- Throws:`, `- Precondition:`, `- Note:`, `- Warning:`.
- For `async` APIs, document cancellation behavior.
- Document error conditions and edge cases; prefer throwing APIs over `fatalError`/`try!`.
- SwiftUI view bodies generally do not need docs; models, services, parsers, and shared utilities do.

## Enum Design

1. **Always conform to**: `String, Codable, CaseIterable, Hashable, Sendable` at minimum. Most are synthesized with zero code.
2. Use `String` raw values for wire/`UserDefaults`/network interop; avoid integer raw values unless the external protocol demands them.
3. Implement a computed `displayName` (or `CustomStringConvertible.description`) for user-facing output — never store display strings as raw values.
4. For parsing from strings, rely on `init?(rawValue:)` returning `nil` on unknown input; introduce a typed parse error only when the caller must distinguish failure reasons.
5. Never `switch` on raw strings — switch on enum cases so the compiler flags unhandled cases as the enum grows.
6. Keep the raw values stable once serialized anywhere (UserDefaults keys, JSON, files). Renaming a case = a migration decision.

## Error Handling

- Define a typed `enum XError: Error, LocalizedError, CustomStringConvertible` per domain — never throw raw `String` or build `NSError` ad hoc.
- Prefer throwing functions (`func f() throws -> T`) over `Result` plumbing; use `Result` when failure is a stored outcome rather than control flow.
- Propagate with `try` / `try await`; do not catch-and-rethrow that strips context.
- Reserve `!` (force unwrap), `try!`, and `fatalError` for provable invariants; use `precondition` with a message otherwise.
- Use `guard let` / `guard case` for early exits, `as?` over `as!`, and `try?` only when the error is deliberately discardable.
- In async/polling code, honor `Task.isCancelled` and handle `CancellationError` (see `PollingLoop`).

## Testing Standards

**Project convention: tests live in `TokenMonTests/`, never in `TokenMon/` source.**

- One `XCTestCase` file per unit under test, grouped by feature folder: `TokenMonTests/Grok/`, `TokenMonTests/OpenCode/`, `TokenMonTests/Cursor/`.
- Import with `@testable import TokenMon`. Keep internals `internal` — `@testable` reaches them from the test bundle, so you do NOT need to widen visibility to `public` for tests.
- NEVER add `#if DEBUG` test-only code or inline test modules to source files; production modules stay free of test-only imports and behavior.
- Use descriptive test names: `testWorkspaceIDFromURL`, `testExportCSVNeutralizesFormulaInjection`, `testOrderStatusRejectsInvalidInput` — not `test1`.
- Test happy paths and error cases; test edge cases and boundary conditions.
- For enums: always test `rawValue` roundtripping and invalid-input rejection (`XCTAssertNil(OrderStatus(rawValue: "nonexistent"))`).
- Use `XCTAssertEqual(_:_:accuracy:)` for floating point — never exact equality.
- Pure parsers/builders that need no app host go in `Tests/Manual/CoreTestsMain.swift` and run via `Scripts/run_core_tests.sh` (`make test-core`).
- Keep tests hermetic: use fixture JSON/text/hex (see the gRPC hex fixture in `Tests/Manual/CoreTestsMain.swift`), never live endpoints. If a test must touch a live surface, gate it behind an environment flag and skip by default so the suite stays hermetic.
- Never touch real user state: inject a temporary directory instead of `~/Library/Application Support/TokenMon` or `~/Library/Caches`, a throwaway `UserDefaults(suiteName:)` instead of `.standard`, `InMemoryCredentialStore` / a fake `KeychainBackend` instead of the Keychain, and a stubbed transport instead of the network.

## Performance & Micro-Optimizations

The engineer's in-the-moment awareness so code is born fast instead of fixed later. For deep audits — Instruments work, severity-graded findings, and the full lens-by-lens method — go to **Performance Review (Deep Audits)** below.

**Think about performance while writing, then measure.** A 12% easily-obtained gain is never marginal in quality software — but unmeasured "this looks slow" off a cold path is noise. Know which code is hot: per-poll, per-render, per-row, per-request — everything else is once-at-launch.

### Defaults that make code fast by construction

- **Value semantics + `let`** (the core philosophy) means COW sharing is harmless: nobody mutates shared storage. This is the highest-leverage perf property of this codebase.
- **Lean parsing by default.** Read only the fields you need. When the server shape is unstable, a manual scan (`data.range(of:)`, index math, brace-scan) beats `JSONDecoder`/`JSONSerialization` on hot paths — `GRPCWebParser` is the pattern. Stable shapes and cold paths may use `Codable`.
- **Bulk over per-item.** One connection/transaction/statement batch, one prepared statement reused, one `Dictionary(grouping:)`, one `reduce(into:)`.
- **Reuse expensive things as `static let`:** `DateFormatter`, `NSRegularExpression`, `NumberFormatter`, rank maps. Constructing a `DateFormatter` per call is the classic hidden tax.
- **Never allocate per row/render/poll** what could be hoisted out: fonts, colors, `[NSAttributedString.Key: Any]`, parse buffers.

### Micro-tricks worth knowing (full lens list in Deep Audits)

- `Array.reserveCapacity` / `Dictionary(minimumCapacity:)` when counts are known.
- `Set`/`Dictionary` membership over `array.contains`; `firstIndex(of:)` inside a sort comparator → precompute a `[String: Int]` rank.
- `String(Int)` / interpolation, never `String(format:)` on hot paths.
- `Data.withUnsafeBytes` + pointer math over `[UInt8](data)` in parse loops.
- `Substring` slices retain the whole parent `String` — copy when a slice outlives its source.
- `autoreleasepool { }` around big AppKit/Foundation loops.
- `os.Logger` interpolation is evaluated eagerly — gate expensive string builds behind a level check or `#if DEBUG`.
- Main actor is precious: parse/aggregate/DB off the UI thread, publish one coalesced delta (`AppModel.forwardChanges`).
- **Cache rule:** an `NSCache` key must encode EVERY input that changes the output — including the appearance — or a stale bitmap is served after a theme flip (`MenuBarStatusRenderer._cache`).

### Project hot paths (token_monitor)

- **Menu bar render** — `MenuBarStatusRenderer` (NSCache-bounded; keep the key complete, keep colors resolved against the live appearance).
- **Polling** — `PollingLoop`, one per provider: a full-interval sleep between refreshes (no ticking timer), parked with no timer while `interval()` returns nil, re-armed by `wake()`; failures back off 30 s → 10 min with ±10% jitter and honour `Retry-After`.
- **OpenCode SQLite reads** — `OpenCodeLocalStats` (one read-only connection per scan, `json_extract` in SQL so rows arrive as plain columns, `busy_timeout`, re-read only when the database changes).
- **Grok payload parsing** — `GRPCWebParser` (manual protobuf scan) and `UsageResponseParser` (multi-shape `JSONSerialization`); don't "upgrade" them to a framework.

**Workflow hook (quality gate):** before claiming done, also sanity-check the hot paths above for the smells in the Deep Audits quick checklist — no Instruments run required for the obvious ones (formatter-per-call, per-row full-JSON, `[UInt8]` copies, eager log strings).

## Performance Review (Deep Audits)

Disciplined performance review of Swift/macOS code through the lens of Jeff Dean
& Sanjay Ghemawat's **Performance Hints** (Abseil, 2025 —
https://abseil.io/fast/hints.html), translated to idiomatic Swift, SwiftUI, and
AppKit.

**Scope:** menu bar apps, CLI tools, and libraries — CPU, memory, COW behavior,
allocations, cache, locks, async/actor hops, and API shape. Not distributed
systems or ML hardware tuning.

**Core principle (Knuth, full quote):** forget about small efficiencies ~97% of
the time — *but do not pass up the critical 3%*. A 12% easily-obtained gain is
never marginal in quality software. Prefer the faster alternative when it does
not significantly hurt readability.

**Evidence before claims.** Every finding cites `file:line`, states whether the
code is on a **hot path**, and proposes one concrete fix. Unmeasured
"this looks slow" off a cold path is Minor at most.

### When to engage this review mode

- User asks for performance review, micro-optimizations, or "make it faster"
- Instruments shows a hotspot, an allocation spike, or a flat profile after low-hanging fruit
- Designing APIs (types, parsers, models) that will be called from many call sites
- Pre-merge audit of hot poll/render/parse/encode paths
- Investigating high RSS, retain churn, main-actor stalls, or laggy SwiftUI updates

**Do not** micro-optimize test-only code beyond asymptotic complexity, or
one-shot scripts. Do not sacrifice correctness or introduce dual mechanisms.

**Correctness bugs often *are* the performance story.** A feature that "never
fires" (always-false flag, wrong comparison order, stale cached appearance) looks
like lag or missing work. Diagnose with live state before rewriting loops.

### Philosophy (from Abseil → Swift)

1. **Think about performance while writing**, not only after profiles go flat. Flat profiles mean cost is smeared everywhere — hard to start.
2. **Library/model code is high leverage.** Callers often cannot fix your internals. Choose good defaults (value types, `struct`, lean Codable, bulk APIs) with low local complexity.
3. **Estimate before implementing.** Back-of-envelope with known costs; discard alternatives that cannot win.
4. **Measure before claiming.** Instruments for systems; XCTest `measure`/`swift-benchmark` for micro; Allocations for the allocator.
5. **Many 1% wins compound.** Twenty small clean improvements beat one heroic rewrite — needs stable benches.
6. **Deep modules.** Keep public interfaces narrow so layout/alloc changes stay inside encapsulation boundaries.
7. **Don't pay for what you don't use.** Thread-safety, generality, stats, `@MainActor` isolation, and logging on hot paths have real costs.

#### Rough cost table (order-of-magnitude, modern x86/ARM)

| Operation | ~Cost |
|---|---|
| L1 reference | 0.5 ns |
| L2 reference | 3 ns |
| Branch mispredict | 5 ns |
| Uncontended lock/unlock (`os_unfair_lock`) | 15 ns |
| Main memory reference | 50 ns |
| Compress 1KB (Snappy-class) | 1 µs |
| SSD 4KB read | 20 µs |
| Same-DC network RTT | 50 µs |
| 1MB sequential DRAM | 64 µs |
| 1MB over 100Gbps net | 100 µs |
| Disk seek | 5 ms |
| Transcontinental RTT | 150 ms |

Track *your* higher-level costs too: one SQLite point read, one HTTP hop, one
`JSONSerialization` parse of a typical payload, one `DateFormatter.string`,
one `NSImage` render. Without numbers you cannot estimate.

**Worked example (Abseil method, Swift framing):** aggregating 100k message rows
from SQLite, each needing `String(cString:)` → `.data(using: .utf8)` →
`JSONSerialization` → key lookups. That's ~4 allocations + a full JSON tree per
row just to read 3 fields. Floor estimate: 100k × (JSON parse ≈ 1–5 µs) ≈
0.1–0.5 s plus GC/autorelease pressure. A lean manual scan that reads only the 3
fields (`data.range(of:)` + offset math) cuts both the parse and the allocation
count; if per-row cost is the dominant term in the profile, that fix is the one
to make *before* touching the SQL.

### Review method

1. **Scope.** Whole target, module, hot function, or diff? Hot path vs init/setup?
2. **Classify code**
   - Test-only → asymptotics + test runtime only
   - App-specific → is it per-poll / per-render / per-item?
   - Library / multi-caller → apply techniques aggressively when cheap
3. **Estimate** dominant ops (allocs, COW copies, retains, syscalls, locks, actor hops, branches, bytes).
4. **Measure** when tradeoffs are non-obvious (Instruments; XCTest measure; `os_signpost` around candidates; `MetricKit` for field data).
5. **Apply lenses below** in order: algorithmic → memory representation → allocations → avoid work → compiler help → code size → concurrency → serialization → containers → SQLite → polling/network ordering.
6. **Report** with severity, evidence, estimated impact class, one fix.
7. **Gate claims** with a profile delta when Important+.

#### Severity (performance-specific)

- **Critical** — pathological complexity on a production path (O(n²) per poll), unbounded memory growth (retaining a giant `String`/`Data`/`Substring`, an ever-growing cache), lock or main-actor held across network I/O, allocator thrash that stalls the UI.
- **Important** — measurable hot-path waste: needless alloc/copy per poll or render, `DateFormatter`/`NSRegularExpression` created per call, full `[UInt8]` copies of `Data` in a parse loop, per-row full-JSON parsing when 3 fields are needed, `firstIndex(of:)` inside a sort comparator, missing `reserveCapacity`, eager string building in disabled logging, needless `@MainActor` hops, N+1 SQLite opens.
- **Minor** — cold-path micro-opts, style-level `clone`/copy cleanup, layout polish with tiny footprint, speculative caching. Batch only with approval.

#### Impact classes (for findings)

- **Structural / algorithmic** — often 2–10×+
- **Representation / cache / COW** — often 10–50% system-wide when data is large
- **Allocation reduction** — often 10–30% on alloc-heavy paths
- **Avoided work / fast path** — highly variable; can be huge
- **Lock / actor-hop reduction** — main-thread stalls and multi-core wins
- **Death by 1000 cuts** — many 1% changes after profile is flat

### Lens 1 — Algorithmic improvements

Highest leverage. Prefer these over micro-opts.

Checklist:
- [ ] Wrong asymptotics? (nested loops, repeated full scans, sort when hash works)
- [ ] Linear `contains`/`firstIndex` on an array → `Set`/`Dictionary` membership
- [ ] `firstIndex(of:)` **inside a sort comparator** → precompute a rank dictionary
- [ ] `Dictionary` keyed lookups when `Set` suffices
- [ ] Ordered map used only for equality lookups → `Dictionary`
- [ ] Grouping/reindexing done with nested loops → `Dictionary(grouping:)`
- [ ] Build a `[String: V]` by inserting in a loop → `Dictionary(uniqueKeysWithValues:)` or `init(_:uniquingKeysWith:)`

Swift notes:
- `Dictionary(grouping:)` is the one-liner for "bucket an array by a key" (e.g. bucket usage rows by hour/day instead of `if byHour[h] == nil`).
- `Set`/`Dictionary` membership over `array.contains` on any hot look-up loop.
- `reduce(into:)` over `reduce` when building a collection — no intermediate.
- `sorted(by:)` with a comparator that calls `array.firstIndex(of:)` per comparison is O(k² log k): build `let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })` and compare ranks. (`ProductCatalog.sortForDisplay` and `DailyUsageBuilder.finalize` sort with `firstIndex(of:)` over ≤ 6 products; see Performance field notes.)
- For sorted lookups on moderate N, `partition(by:)` / `partitioningIndex(where:)` (or a small `binarySearch` extension) on a sorted `Array` often beats `Dictionary` on cache behavior.
- `remove(at:)` is O(n); for front-removal use `ArraySlice`/`Deque` (swift-collections) or index math.
- Swift's `sort()` is in-place and stable; prefer it to building a new array via `sorted()` when the original can be consumed.

### Lens 2 — Better memory representation (incl. COW)

Touch fewer cache lines; cut memory bus traffic (helps neighbors on the machine).

#### Value types & copy-on-write (COW)
- `struct` values are cheap to pass but **expensive to mutate when shared**: mutating a `var` that shares storage with other copies triggers a full copy. Keep shared immutable data in `let`, and when you must mutate a large shared buffer, prefer `withUnsafeMutableBufferPointer` or hoist it so it's owned once.
- `String`, `Array`, `Dictionary`, `Data` are COW. A `String` passed into 5 structs shares storage until someone mutates — good. But retaining a `Substring` of a huge string keeps the **entire parent** alive; copy with `String(substring)` when the slice outlives the parent (memory footgun).
- `ContiguousArray<T>` guarantees contiguous storage (slightly better than `Array` when bridging/pointer work dominates).
- Favor `let` + derived values (this repo's convention) — it makes COW a non-issue because nothing mutates shared storage.

#### Compact data structures
- Smaller integer types when the domain fits (`Int32`/`Int16`/`UInt8` vs `Int`).
- Swift enums without associated values are already small; with payloads, the enum takes the size of the largest payload + tag. `Box`/`indirect` large cold variants so the common enum stays small (`indirect enum` or a `final class` payload reference).
- Bit flags / a `UInt64` bitmask (or `[Bool]`) instead of `Set<SmallEnum>` when the domain is tiny and hot (e.g. a 6-product visibility mask).
- Dense `Array` indexed by small IDs instead of `[String: V]` when IDs are bounded — zero hashing, perfect locality.
- `Data`/`String` stored immutably is fine; avoid double storage (`String` + `Data` copies of the same payload).

#### Layout
- Struct field order affects size via padding; group same-size fields. Verify with `MemoryLayout<T>.size` in a test or LLDB.
- Store hot read-mostly fields together; keep hot mutable fields separate to reduce invalidation in multi-threaded contexts.
- Check actual sizes with `MemoryLayout` and `malloc_size`/Instruments Allocations — don't guess.

#### Indices instead of references
- In a graph of many small objects, arrays of structs + integer indices beat a web of `class` references: fewer allocations, better locality, no ARC traffic.
- ARC (`class`) has real cost: each reference increments/decrements retain counts. Hot loops over class instances pay this; value-type collections mostly don't.

### Lens 3 — Reduce allocations

Alloc cost = allocator time + init/drop + **cache footprint** (each alloc tends
toward a new cache line in long-running programs). On Apple platforms the
allocator is good, but allocations still cost.

Checklist:
- [ ] `Array.reserveCapacity(_:)` when the count is known — never grow one by one in a loop without reserving
- [ ] `Dictionary(minimumCapacity:)` to avoid rehash churn
- [ ] Prefer `append` + `reserveCapacity` over `+=` concatenation in loops
- [ ] Build strings with `joined(separator:)` / `reduce(into:)` — not `reduce("") { $0 + $1 }` (O(n²)) and not `String(format:)` in a loop
- [ ] Reuse formatters: `DateFormatter`, `NumberFormatter`, and regexes are **expensive to construct** — make them `static let` or a lock-guarded cache (see `Format.cachedFormatter`, `DailyUsageBuilder.makeDateFormatters`)
- [ ] Use `String(Int)` / interpolation, not `String(format: "%d", …)` — the latter bridges through `CVarArg`/`NSString`
- [ ] Replace `JSONSerialization` full-tree parses with `data.range(of:)` / `String` scanning when only a few fields are read
- [ ] Avoid `[UInt8](data)` copies in parse loops — use `data.withUnsafeBytes { … }` and pointer arithmetic instead
- [ ] `Data.subdata(in:)` copies; prefer slices/`withUnsafeBytes` on hot paths
- [ ] Hoist buffers and attribute dictionaries out of loops (fonts, colors, `[NSAttributedString.Key: Any]`)
- [ ] Wrap big AppKit/Foundation loops in `autoreleasepool { }` to bound autoreleased memory (NSString/NSDictionary churn)
- [ ] Bridge once at the edge: casting a Foundation collection to Swift (`as? NSArray` → `as [Any]`) per element in a loop is waste
- [ ] `NSRegularExpression` compiled in a function body → `static let`; better, `range(of:)`/`firstIndex(of:)`/`contains` when a regex isn't needed
- [ ] `NumberFormatter`/`DateFormatter` are **not thread-safe** to share; guard reuse with a lock/actor or use thread-local/`static let` where access is confined. `Date.FormatStyle` (macOS 12+) is value-type and safe to reuse.

Swift-specific smells (each is a finding when on a hot path):
- `DateFormatter()` created inside a `week()`/`render()`/`row()` function
- `NSRegularExpression(pattern:)` created per call
- `String(format: "%.1f", …)` on a hot log line
- `someArray.map { String($0) }.joined()` when a single pass suffices
- `JSONSerialization.jsonObject` per DB row just to read `id` + `cost`
- `String(cString:)` + `.data(using: .utf8)` + full JSON per row in a SQLite loop
- `products.map { … }.joined(separator:)` built eagerly even when the log level would discard it

### Lens 4 — Avoid unnecessary work

Often the biggest win: don't do it.

#### Fast paths for common cases
- Structure code so the common case is branch-predictable and allocation-free
- e.g. `guard` the cheap `menuIsOpen`/nil cases first, then do the expensive work
- Keep slow paths separate so they don't pollute I-cache

#### Precompute once
- Expensive properties, lookup tables, rank maps, static regexes, static formatters — `static let` (lazy, thread-safe in Swift).
- Examples in this repo: `ISO8601DateFormatter.flexible`, `productEnumMap`, `colorCache`.

#### Hoist from loops / renders
- Date formats, config flags, fonts, colors, attribute dictionaries, `ProductCatalog.displayOrder` lookups
- `MenuBarStatusRenderer._render` builds `usedAttrs`/`labelAttrs` every render — hoistable, though the NSCache already bounds cost

#### Defer
- Don't compute legend/heatmap/daily series until a consumer needs them
- Don't build debug field dumps outside `#if DEBUG` (`UsageClient` gates its `debugFieldDump` log this way)

#### Specialize
- Hot call site may not need full generality: `hasPrefix`/`range(of:)` over a regex; `Set` over `[String]`; manual parse over `JSONDecoder` when the shape is unstable (this repo's hand-rolled gRPC-web parser is the right call).

#### Cache
- Fingerprint/cache-keyed caches for expensive renders (see `MenuBarStatusRenderer._cache`). **The cache key must encode every input that changes the output — including the appearance and, for date formatters, the time zone** (Hard-Earned Lessons #2/#3).

#### Logging / stats on hot paths
- `os.Logger` interpolation is evaluated **eagerly** even when the level is filtered — don't build expensive strings for a line that won't be shown
- Gate with `logger.logLevel <= .info` or `#if DEBUG` before building
- Sample stats (1/N polls) instead of every event

### Lens 5 — Help the compiler

Only when profiles show pain — the Swift compiler is often already good. Inspect
with Instruments (Time Profiler) and, for critical functions, the generated
assembly/IR via `swiftc -emit-assembly` or the Xcode "Show Assembly" / Godbolt.

Techniques:
- Prefer **concrete types / generics** over existential `any P` on hot loops — existentials box and route through dynamic dispatch
- `some` for opaque return types; avoid `Any` casts in loops
- Avoid protocol `P` method calls in the hottest inner loop when monomorphization is possible (use generics)
- Keep hot kernels small and inlinable; `@inline(__always)` sparingly (helps tiny getters, hurts when code size explodes)
- `@_transparent` / `@usableFromInline` for internal hot helpers only
- Reserve `try!`/`!` for provable invariants (repo convention)
- Watch heavy `Codable` synthesized `init(from:)` on huge types — the compiler builds a lot; hand-written decoding can win when measured

#### Build flags (Xcode, system-wide, cheap)
- Release: `SWIFT_COMPILATION_MODE = wholemodule`, `SWIFT_OPTIMIZATION_LEVEL = -O` (default). `-Ounchecked` drops runtime checks — only where provably safe.
- `-Osize` when binary size/I-cache matters more than a few percent.
- PGO: Xcode "Profile Guided Optimization" (generate `.profdata` from a representative run, then enable Use Optimization Profile).
- Linker: `-dead_strip`, and `SWIFT_DEFAULT_ACTOR_ISOLATION`/concurrency checks are correctness, not speed.
- Remember **`make project` after any file add/move** — un-compiled files aren't "slow", they're absent (repo quality gate).

### Lens 6 — Code size (I-cache / compile time)

Large code → longer builds, fatter binaries, I-cache pressure, worse predictors.
Especially important for widely-used generics and `Codable`/`SwiftUI` bodies.

- Measure binary size via Xcode's size report or `size -m` / `dwarfdump`
- Watch heavy `Codable` derives and broad generic constraints pulled into hot modules
- SwiftUI: view-body splitting is for maintainability, not speed — don't over-split for "perf" (view identity is cheap)
- Avoid huge string literals / big `switch`-built attribute tables on hot paths when a `static let` dictionary is denser

### Lens 7 — Concurrency & synchronization (Swift Concurrency)

See also `@MainActor`/actor guidance above and the repo's `PollingLoop` + `AppModel.forwardChanges` patterns.

- **Main actor is precious.** Every `await` to a `@MainActor`-isolated function can hop. Do parsing, DB reads, and aggregation off the main actor; publish one coalesced snapshot to the UI (pollers fetch/parse off the view, and `AppModel.forwardChanges` coalesces).
- Don't hold a lock or a synchronous `@MainActor` call across network I/O.
- `withThrowingTaskGroup` / `TaskGroup` for batching independent I/O; avoid `Task {}` per item when a loop inside one task suffices (task spawn is not free; context switches are).
- Prefer `os_unfair_lock` (`OSAllocatedUnfairLock`, macOS 13+) over `NSLock` for perf-critical short critical sections; never across an `await`.
- Counters: `OSAllocatedUnfairLock<Int>` or a small value type; avoid `NSLock`/`Mutex`-style sync for a plain counter.
- `Sendable` structs are cheap to pass across concurrency domains; `@unchecked Sendable` on a `final class` only when you prove safety.
- Actor reentrancy means your state can change between `await`s — guard or snapshot; correctness first (a reentrancy bug reads as "lag").
- `URLSession` reuse: provider requests share `ProviderURLSession.shared` (ephemeral, no cookie jar, no cache) — one shared connection pool is correct. Don't create a `URLSession` per poll, and don't send provider requests through `URLSession.shared`, whose cookie jar and disk cache outlive sign-out.
- Coalesce `objectWillChange` churn (see `AppModel.forwardChanges`) — don't notify SwiftUI 20× per poll for 20 fields.

### Lens 8 — Serialization / parsing (JSON, gRPC-web, seroval)

Heavy schema frameworks are convenient and **expensive**. In Swift the tiers are:

1. **`Codable`/`JSONDecoder`** — cleanest, but slowest per byte; synthesized decoding builds dictionaries and does key lookup with overhead. Keep each `JSONDecoder` instance confined to one actor or thread. Use for cold/rarely-called decoding and for *stable* shapes.
2. **`JSONSerialization`** — faster for ad-hoc `[String: Any]` probing when the shape is unstable or multi-shaped (this repo's `UsageResponseParser` is a legitimate use — it must accept many server shapes).
3. **Manual scanning** — fastest. When the wire format is unstable but the fields you need are few, scan the bytes directly: `data.range(of:)` for ASCII keys + index math, `String` slicing, or a tiny state machine. The repo's `GRPCWebParser` (raw protobuf scan) is exactly right — keep that instinct, but cut the per-call `[UInt8](data)` copies (see Lens 3).

General rules:
- Re-encoding/decoding the same blob repeatedly is waste — decode once, keep the typed value.
- Avoid `JSONSerialization` of large blobs when you only need 3 fields; avoid `Codable` of the same.
- `Data` → `String` → `Data` round trips are pure waste; read the bytes once.
- Dates: `ISO8601DateFormatter` static instances (`ISO8601DateFormatter.flexible`); `Date.FormatStyle`/`.formatted()` for display formatting (thread-safe, modern). Avoid a fresh `DateFormatter` per value.

### Lens 9 — Swift container & idiom cheat sheet (Abseil → Swift)

#### Containers

| Abseil / C++ idea | Swift default | Faster / denser alternatives |
|---|---|---|
| `std::vector` | `Array` | `reserveCapacity`; `ContiguousArray`; slices |
| `absl::InlinedVector` | `Array` (already contiguous inline) | `ArraySlice`; small `[(K,V)]` linear scan |
| `std::unordered_map` | `Dictionary` | custom `Hasher` only if profiled; small `[(K,V)]` for N ≤ ~8 |
| `absl::flat_hash_map` | `Dictionary` (open addressing) | same; `minimumCapacity`; `Dictionary(grouping:)` |
| `std::map` | — | sorted `Array` + `partition(by:)`; `OrderedDictionary` (swift-collections) |
| bit sets | `Set<SmallEnum>` | `UInt64` bitmask / `[Bool]` for tiny domains |
| `std::deque` | — | `Deque` (swift-collections); index math on `Array` |
| arenas | — | `ContiguousArray` of structs + `Int` indices; `ManagedBuffer` |
| indices vs pointers | — | `Int` indices into arrays, not `class` graphs |

#### Strings & bytes

| Need | Reach for |
|---|---|
| Sliced view | `Substring` (retains parent — copy when it outlives the parent) |
| Byte scanning | `data.withUnsafeBytes` + pointers; `range(of:)` on `Data`/`String` |
| Number formatting | `String(Int)` / interpolation; never `String(format:)` hot |
| Conditional ownership | `String` (COW) is already cheap — don't add `Cow` machinery |
| Regex once | `static let` `NSRegularExpression`; or `hasPrefix`/`range(of:)` |

#### Sync & misc

| Abseil / C++ idea | Swift default | Alternative |
|---|---|---|
| `absl::Span` / `string_view` | `ArraySlice`, `UnsafeBufferPointer`, `Substring` | prefer views in APIs |
| `FunctionRef` | `@escaping () -> Void` | avoid `@Sendable () async` per item on hot loops |
| `CachePadded` | — | not exposed; reduce false sharing by layout design |
| faster mutex | `NSLock` | `os_unfair_lock` / `OSAllocatedUnfairLock` (macOS 13+) |
| stats counters | `NSLock`-guarded var | `OSAllocatedUnfairLock<Int>`, atomics |
| `StatusOr` tax | throwing `func` | on ultra-hot infallible paths, avoid forced `try?`/`Result` plumbing |
| allocator | system malloc | (mimalloc/jemalloc not available; trust the system allocator) |

API design (Abseil "API considerations"):
- **Bulk APIs** — batch encode/decode, batch DB reads, batch lookups; amortize locking and boundary costs.
- **View types** — accept `Substring`/`ArraySlice`/`UnsafeBufferPointer` rather than copying; accept `some Collection`/`Sequence` when appropriate.
- **Pre-allocated / precomputed args** — let callers pass formatters, buffers, scratch space they already have.
- **Thread-compatible vs thread-safe** — default to `Sendable` value types and confined mutable state (this repo's convention).

### Lens 10 — SQLite (this repo: `OpenCodeLocalStats`)

The repo reads the OpenCode SQLite DB (`~/.local/share/opencode/opencode.db`)
read-only via the C API (`SQLITE_OPEN_READONLY`). It is re-read when the file
changes, so a scan runs at most once per change rather than once per view.

Checklist:
- [ ] **`=` not `LIKE`** for exact keys — `LIKE` without wildcards still forces different plans
- [ ] **`EXPLAIN QUERY PLAN`** on every new/changed query against a realistic DB
- [ ] **Composite indexes match real predicates** — single-column indexes on `year`/`month`/`day` are often dead weight
- [ ] **Prepare statements once**, `reset` + re-bind in the loop
- [ ] **One transaction per batch** where you write (this repo is read-only — still, `PRAGMA query_only=ON` on readers)
- [ ] **`PRAGMA busy_timeout` on every connection** (`OpenCodeLocalStats` sets 2000 ms; the default of 0 fails with `database is locked` while a writer holds the lock)
- [ ] **WAL-friendly**: a read-only open is correct for readers concurrent with a writer — keep it
- [ ] **Avoid DISTINCT/GROUP BY when a bare filter returns one row/key**
- [ ] **N+1 point queries** → bulk `IN (...)` or a single ranged scan
- [ ] **One connection per fetch, not one per query** — open once and prepare each statement on it
- [ ] **Don't parse full JSON per row** — select the fields with `json_extract` in SQL (as `OpenCodeLocalStats` does) instead of `String(cString:)` + `JSONSerialization` per row
- [ ] Backup before schema changes; `ANALYZE` after schema changes

### Lens 11 — Polling loops & network work ordering

The repo is a poll-driven menu bar app. Cadence multiplies waste.

Checklist:
- [ ] **Order work cheapest → dearest**: settings/throttle/`isSignedIn` gates before network I/O; the `PollingLoop` checks `Task.isCancelled` — keep that
- [ ] **Fail fast on auth**: `401/403` → surface re-auth immediately, don't fall through 4 candidate endpoints (Grok's billing call does this for `.unauthorized`)
- [ ] **Candidate probing**: Grok calls the gRPC-web billing endpoint first and probes its 4 REST candidates (sequential, 15 s timeouts) only when billing fails transiently — keep the probes off the common path, and bound their total time if they ever move onto it
- [ ] **Don't pay N× external I/O over the whole queue when one poll advances one item**
- [ ] **Never poll hot against a throttling server** — a refresh returns `PollOutcome`; `.failure` grows the wait through `BackoffTimer` (30 s → 10 min) and a 429's `Retry-After` (`UsageError.rateLimited`) sets the earliest next refresh. Report `.failure` for real fetch errors and `.skipped` for cancellation or nothing-to-do, or the backoff never engages
- [ ] **Don't wake parked loops for nothing** — a provider that is not needed returns a nil interval (`PollInterval.seconds(menuIsOpen:settings:needed:)`) and its loop holds no timer; `AppModel` calls `wake()` only when an input to `interval()` changes (menu opened, polling settings edited)
- [ ] **Cache discovery results** — e.g. the OpenCode workspace id is stored after sign-in and tried first; don't re-resolve per poll what rarely changes
- [ ] **Logging**: per-item `logger.info` × N polls is disk + I-cache tax; summary once, `debug` for detail
- [ ] **Sleep/wake handling**: `SystemWakeGate` pauses every loop on system sleep and resumes them once `NWPathMonitor` reports a satisfied path (or after a fallback delay), so a wake does not fail every provider at once

### Review output format

```markdown
## Performance review: <scope>

### Summary
- Hot paths identified: ...
- Profile/bench evidence: ... (or "static review only")
- Top opportunities: ...

### Findings

#### [Critical|Important|Minor] <title>
- **Where:** `path/file.swift:LINE`
- **Evidence:** quote + why hot
- **Mechanism:** (alloc / COW / cache / algorithm / actor-hop / work-avoidance / …)
- **Impact class:** structural | representation | allocation | …
- **Fix:** minimal concrete change (code sketch OK)
- **Validate:** Instruments template / XCTest measure / reason estimate suffices

### Non-findings / accepted costs
- ... (generality, readability tradeoffs explicitly OK)

### Suggested bench plan
- ...
```

Push back on premature micro-opts that hurt clarity with no hot-path evidence.
Push back on "optimize everything" — prioritize the critical 3%.

### Quick hot-path checklist (print this mentally on every file)

1. Per-poll / per-render / per-row / per-request? If no → deprioritize.
2. **Structural first:** wrong SQL plan, N+1 SQL/HTTP, unbounded queue/retain, sequential candidate probing, missing auth fail-fast? Fix those before polish.
3. SQLite: `=` not `LIKE`? Composite index? One connection? Prepared statements? `busy_timeout`? `EXPLAIN QUERY PLAN` on realistic data? Full-JSON-per-row?
4. Any alloc/copy that could be a view, move, or reuse? `reserveCapacity`? `DateFormatter`/`NSRegularExpression`/`NumberFormatter` created per call? `[UInt8](data)` in a parse loop?
5. Any `Set`/`Dictionary` that could replace a linear scan, or a `firstIndex` inside a comparator that deserves a rank map?
6. Main actor: parsing/DB off the UI thread? Coalesced `objectWillChange`? Locks held over I/O or `await`? Task-per-item vs loop-in-task?
7. Rendering: NSCache key includes every input (appearance!)? Fonts/colors/attrs hoisted? `autoreleasepool` around big Foundation loops?
8. Logging/stats on the path — eager `String(format:)`/`map().joined()` in `os.Logger` calls? Per-item logs × N?
9. Correctness of the predicate that gates work (flags, comparisons, cached state) — live state inspection, not only CPU.
10. Measured or estimated before recommending Important+ changes?

## Project Notes (token_monitor)

- **macOS 14+ / Swift 5.10 / SwiftUI + AppKit.** App is `LSUIElement` (agent app, no Dock icon). The menu bar is a custom `NSStatusItem` owned by `MenuBarController`; its label is one AppKit-rendered bitmap (`MenuBarStatusRenderer`) and its dropdown is a borderless `MenuBarPanel` (`NSPanel`), **not** `MenuBarExtra`/`NSPopover`. The status item keeps `variableLength` and sizes to the bitmap.
- **`project.yml` (XcodeGen) is the only project definition.** After adding or moving source files, run `make project` (xcodegen generate); new files are NOT compiled otherwise.
- Build/test/run: `make build` (Debug), `make run`, `make release` (dist/), `make test` (full Xcode suite), `make test-core` (CLT-only parsers).
- **Menu bar content is drawn as an AppKit bitmap**, not SwiftUI (see `MenuBarStatusRenderer`): one `NSImage` composite of per-provider segments plus the hit regions for the same layout, so a status-item click maps back to its provider (`MenuBarController`).
- Menu bar labels are bitmaps: text must use system label colors resolved from the menu bar's *live* `effectiveAppearance`, and the image cache must be keyed by appearance and invalidated on `AppleInterfaceThemeChangedNotification`.
- App-wide services live on `AppModel` (`@MainActor` `ObservableObject`); child services forward `objectWillChange` into it so the status-item label refreshes (see `AppModel.forwardChanges`).
- Polling uses `PollingLoop`, one loop per provider:
  - It refreshes at start, then sleeps the full remaining interval (active interval while the panel is open, idle otherwise; `PollInterval`). There is no periodic tick.
  - `interval()` returning nil parks the loop with no timer; `wake()` re-evaluates it and re-arms from the last refresh, refreshing at once when overdue. `refreshNow()` restarts the wait from the manual refresh.
  - Each refresh returns a `PollOutcome`. Failures back off exponentially (`BackoffTimer`, 30 s → 10 min), a 429 `Retry-After` is honoured, and every wait carries ±10% jitter.
  - `SystemWakeGate` calls `pause()` on sleep and `resume()` once the network is back.
  - `AppModel` forwards child `objectWillChange` through one throttled publisher, so a poll that sets many fields triggers one re-render.
- Auth: `ProviderAuthSession` subclasses with per-provider `WebKitCookieCapture` policies (isolated non-persistent WebKit store, essential-cookie allowlist, three-strike invalidation). Secrets (session cookie headers, the OpenRouter key) live in the login Keychain via `SecretRoutingCredentialStore` / `KeychainCredentialStore`; email, account identity, and workspace id are mode-`0600` files under Application Support. Tests use `InMemoryCredentialStore` or a fake `KeychainBackend`. See `Docs/AUTH_AND_ENDPOINTS.md`.
- Percent semantics: menu bar shows used %; dropdown shows used + remaining; the Grok daily chart shows the 7 days of the active billing period (plus the reset day before its reset instant), deriving day-over-day deltas from local history.

## Workflow

1. Understand the requirement — ask clarifying questions if the domain is ambiguous.
2. Design types first — define enums, structs, and protocols before writing logic.
3. Implement with value semantics and composability — small functions/views, no unnecessary mutation.
4. Document everything — `///` comments with `- Parameters:`, `- Returns:`, `- Throws:` on public items.
5. Write tests — `TokenMonTests/<Feature>/<Type>Tests.swift` plus `Tests/Manual/CoreTestsMain.swift` for CLT-friendly parsers, covering happy paths, errors, and edge cases. Never add test-only modules to source.
6. Review for hot paths — once correct, optimize allocation patterns, COW/copy behavior, main-actor usage, and caching (see Performance & Micro-Optimizations, and Deep Audits for review hunts).
7. Self-review — before presenting code, verify: Are all types documented? Are there tests and are they hermetic? Is mutation minimized? Are strings eliminated in favor of enums? Are errors properly typed? Any hot-path smells (formatter-per-call, per-row full-JSON, `[UInt8]` copies, eager log strings)?
8. **Quality gate (MANDATORY before claiming done or asking to commit/deploy)** — the same checks CI runs. From the repo root:
   1. `make project` when files were added, moved, or removed, and commit the regenerated `TokenMon.xcodeproj` — CI fails when `make project` leaves `git diff` non-empty (project drift check). New core-test sources also go in `CORE_SOURCES` in `Scripts/run_core_tests.sh`.
   2. `make lint` — SwiftLint strict; every warning is an error.
   3. `make format` — SwiftFormat lint; no drift.
   4. `make secrets` — gitleaks over the working tree and history.
   5. `make build`, then `make test` and `make test-core`.

   Every step MUST pass. Do not hand off code that fails this gate.

## Review Focus

- Check type design before line-by-line logic.
- Check failure modes, boundary cases, and test coverage before micro-optimizations.
- Prefer a small refactor that improves type safety over a large stylistic rewrite.
- Confirm the quality gate (Workflow §8) passes before approving.
- For menu bar / rendering changes, verify BOTH light and dark appearances, including wallpaper-tinted menu bars.
- For performance questions, apply the Deep Audits review mode: severity-graded findings, `file:line` evidence, hot-path vs cold-path classification — rather than ad-hoc guesses.

## Typical Triggers

- "Add a new provider or endpoint handler."
- "Refactor this module to be more testable."
- "Review this Swift code for correctness and idiomatic patterns."
- "Introduce a typed enum or error model here."
- "Add a new menu bar segment or panel."
- "Model a new domain concept (usage, billing period, product) with a Codable struct/enum."
- "This feels slow / laggy / spins the CPU." (→ Deep Audits)

## Hard-Earned Lessons (token_monitor workspace)

Repo rules. These override generic best practices when they conflict.

1. **The menu bar is not SwiftUI.** It is an `NSStatusItem` whose label is one AppKit bitmap (`MenuBarStatusRenderer`) and whose dropdown is a borderless `MenuBarPanel`; a status-item click is hit-tested from the status image's x to a provider region, and the event's own location is unreliable for that (`MenuBarController` reads `NSEvent.mouseLocation`). Do not use `MenuBarExtra`/`NSPopover`.
2. **Never hardcode menu bar text color, and never cache an appearance value.** Resolve `NSColor.labelColor` against the status bar's *live* `effectiveAppearance` on every render; key cached images by the resolved appearance and clear the cache on `AppleInterfaceThemeChangedNotification`. Account for wallpaper-tinted menu bars, where the status bar appearance differs from the system theme.
3. **A cache key must encode every input that changes the output.** If it affects the pixels (appearance) or the text (time zone, locale), it is part of the key, or the cache is cleared when it changes.
4. **Credentials go in the Keychain through `SecretRoutingCredentialStore`, never in new files.** Only identifiers that cannot authenticate (email, account identity, workspace id) stay in `0600` files. A secret found in a `.dat` file moves into the Keychain only after a verified Keychain write.
5. **Provider requests use `ProviderURLSession.shared`.** It has no cookie jar and no cache; send the stored credential in an explicit header.
6. **`project.yml` is the only source of truth.** A Swift file added without `make project` never compiles, and CI rejects an uncommitted project diff.
7. **Menu bar labels only observe `AppModel`.** Forward each child's `objectWillChange` into `AppModel` (see `AppModel.forwardChanges`) or labels go stale.
8. **Parse failures degrade, never crash; one rejection is not an expiry.** Decode errors are logged and surfaced as bad responses. A 401/403 counts toward `ProviderAuthSession.authFailureThreshold` (three in a row) before the session is invalidated, and a bot-protection challenge never counts.
9. **Day keys and dates.** Bucket by `calendar.startOfDay(for:)` with the injected `Calendar`, never `Calendar.current` inside a function that takes one; month arithmetic counts each cycle from its anchor, not from the previous result.
10. **After surprising edit successes, re-read the file.** An edit that "shouldn't have matched" may have matched somewhere else. Surprise = signal.

### Performance field notes

Repo-specific patterns for the Deep Audits review mode. Prefer these over
generic "maybe reserveCapacity" advice when auditing this tree.

1. **Inspect live state first.** A label that looks laggy or frozen is more often a stale cached value or a wrong predicate than slow code.
2. **`[UInt8](data)` copies in the protobuf parse loop.** `GRPCWebParser` converts `Data` to `[UInt8]` in `dataFrames`, `trailerFields`, and `scanProtobuf`. For the small gRPC-web billing payload this is negligible, but the pattern is a trap on any larger payload. **Prefer `data.withUnsafeBytes` + pointer/index math** when a parser graduates from toy-size to hot-size.
3. **`firstIndex(of:)` inside sort comparators.** `ProductCatalog.sortForDisplay` and `DailyUsageBuilder.finalize` sort with a comparator calling `displayOrder.firstIndex(of:)` — O(k² log k) for k products. Tiny here (≤ 6 products), but **precompute a `[String: Int]` rank once** for any larger list.
4. **Eager string building in logging.** `UsageClient` builds `productLog` (`products.map { … }.joined(separator:)`) to pass to `logger.info`. `os.Logger` string interpolation is evaluated eagerly even when the level discards it — gate the build behind a level check or `#if DEBUG`.
5. **What not to optimize (accepted costs).** The menu bar render is NSCache-bounded by a full input key — that's the win. The gRPC-web payload is small (KBs); a protobuf framework would be a regression in size and complexity — the hand scan is right. Per-session work (OpenCode workspace discovery, sign-in capture) is not per-poll — cache the *result*, don't speed the path.

## Source attribution

Principles and structure adapted from:

> Jeffrey Dean & Sanjay Ghemawat, *Performance Hints*, 2025,
> https://abseil.io/fast/hints.html

Swift/macOS mappings, severity taxonomy, review workflow, and the performance
field notes are specific to this workspace. Add a field note when a measured
production win or footgun is confirmed (with numbers).
