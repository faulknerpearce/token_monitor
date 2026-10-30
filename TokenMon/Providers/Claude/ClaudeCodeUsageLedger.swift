import Foundation
import os

/// Claude Code token counts keyed by ``DayKey``, then by model id.
typealias ClaudeDailyTokens = [String: [String: ClaudeModelTokens]]

/// Saved per-day, per-model Claude Code token counts.
///
/// Claude Code deletes old transcripts (after 30 days by default), so totals
/// read only from the transcripts would shrink as days age out. Each scan is
/// merged into this record, keeping for every day and model the larger of each
/// saved and scanned count: a day's true counts only grow, so the larger value
/// is the more complete one, and days whose transcripts are gone keep their
/// saved counts.
///
/// Days are UTC calendar days (``dayCalendar``). A local day would shift when
/// the Mac's time zone changes, and the same responses would then be saved
/// under two days and counted twice.
final class ClaudeCodeUsageLedger: @unchecked Sendable {
    /// The calendar whose days key the saved counts: Gregorian in UTC.
    static let dayCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }()

    /// Saved format version. A file with another version is discarded and
    /// rebuilt from the transcripts.
    private static let payloadVersion = 2

    private struct Payload: Codable, Equatable {
        var version = ClaudeCodeUsageLedger.payloadVersion
        var days: ClaudeDailyTokens
    }

    private static let storageKey = "daily_tokens"
    private static let logger = Logger(category: "ClaudeCodeLedger")

    private let store: FileBackedStringStore
    private let lock = NSLock()
    /// Saved counts; `nil` until first read from disk.
    private var days: ClaudeDailyTokens?

    /// - Parameter store: Where the record is saved; tests pass a temporary directory.
    init(store: FileBackedStringStore = FileBackedStringStore(filenamePrefix: "claude_code_")) {
        self.store = store
    }

    /// Merges `scanned` into the saved counts, writes them when they changed,
    /// and returns the merged counts.
    func merge(_ scanned: ClaudeDailyTokens) -> ClaudeDailyTokens {
        lock.lock()
        defer { lock.unlock() }
        let saved = days ?? load()
        let merged = Self.merge(saved: saved, scanned: scanned)
        if merged != saved {
            save(merged)
        }
        days = merged
        return merged
    }

    /// For every day and model, the larger of each saved and scanned count.
    static func merge(saved: ClaudeDailyTokens, scanned: ClaudeDailyTokens) -> ClaudeDailyTokens {
        saved.merging(scanned) { savedModels, scannedModels in
            savedModels.merging(scannedModels) { $0.fieldwiseMax($1) }
        }
    }

    private func load() -> ClaudeDailyTokens {
        guard let text = store.value(forKey: Self.storageKey) else { return [:] }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(text.utf8))
            return payload.version == Self.payloadVersion ? payload.days : [:]
        } catch {
            Self.logger.error("Saved Claude Code usage is unreadable: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func save(_ days: ClaudeDailyTokens) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Payload(days: days)),
              let text = String(bytes: data, encoding: .utf8)
        else { return }
        store.set(text, forKey: Self.storageKey)
    }
}

/// One model's Claude Code usage over a period, valued at API rates.
struct ClaudeModelUsage: Identifiable, Hashable, Sendable {
    var modelID: String
    var tokens: ClaudeModelTokens
    /// API-rate value; 0 when the model has no listed price.
    var costUSD: Double
    /// True when the model has no listed price, so `costUSD` leaves it out.
    var isUnpriced: Bool
    /// This model's share of the period's value (of its tokens when nothing is
    /// priced), 0–100.
    var sharePercent: Double

    var id: String { modelID }
}

/// Token and API-rate value totals for one period.
struct ClaudeUsageTotals: Hashable, Sendable {
    var tokens: Int64 = 0
    var costUSD: Double = 0
    /// True when some usage has no listed price, so `costUSD` leaves it out.
    var hasUnpriced = false
}

/// Claude Code usage on this Mac for the panel: this calendar month, all
/// recorded days, and this month's per-model breakdown. With the ledger's UTC
/// days, the month turns over at midnight UTC.
struct ClaudeCodeUsageSummary: Hashable, Sendable {
    var month: ClaudeUsageTotals
    var allTime: ClaudeUsageTotals
    /// This month's models, highest value first.
    var monthModels: [ClaudeModelUsage]

    /// Summary of `days` for the calendar month containing `now` in `calendar`.
    static func make(days: ClaudeDailyTokens, now: Date, calendar: Calendar) -> Self {
        // `DayKey`s start with `yyyy-MM`, so a month's days share that prefix.
        let monthPrefix = String(DayKey.key(for: now, calendar: calendar).prefix(7))
        let monthDays = days.filter { $0.key.hasPrefix(monthPrefix) }
        return Self(
            month: totals(byModel(monthDays)),
            allTime: totals(byModel(days)),
            monthModels: ranked(byModel(monthDays))
        )
    }

    /// Token counts summed across days, per model.
    private static func byModel(_ days: ClaudeDailyTokens) -> [String: ClaudeModelTokens] {
        days.values.reduce(into: [:]) { result, models in
            for (model, counts) in models {
                result[model] = (result[model] ?? ClaudeModelTokens()) + counts
            }
        }
    }

    private static func totals(_ models: [String: ClaudeModelTokens]) -> ClaudeUsageTotals {
        models.reduce(into: ClaudeUsageTotals()) { result, element in
            result.tokens += element.value.totalTokens
            if let cost = ClaudeAPIPricing.cost(of: element.value, modelID: element.key) {
                result.costUSD += cost
            } else {
                result.hasUnpriced = true
            }
        }
    }

    private static func ranked(_ models: [String: ClaudeModelTokens]) -> [ClaudeModelUsage] {
        let rows = models
            .filter { $0.value.totalTokens > 0 }
            .map { model, counts in
                let cost = ClaudeAPIPricing.cost(of: counts, modelID: model)
                return ClaudeModelUsage(
                    modelID: model,
                    tokens: counts,
                    costUSD: cost ?? 0,
                    isUnpriced: cost == nil,
                    sharePercent: 0
                )
            }
        let totalCost = rows.reduce(0) { $0 + $1.costUSD }
        let totalTokens = rows.reduce(Int64(0)) { $0 + $1.tokens.totalTokens }
        return rows
            .map { row in
                var copy = row
                if totalCost > 0 {
                    copy.sharePercent = row.costUSD / totalCost * 100
                } else if totalTokens > 0 {
                    copy.sharePercent = Double(row.tokens.totalTokens) / Double(totalTokens) * 100
                }
                return copy
            }
            .sorted { lhs, rhs in
                if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
                if lhs.tokens.totalTokens != rhs.tokens.totalTokens {
                    return lhs.tokens.totalTokens > rhs.tokens.totalTokens
                }
                return lhs.modelID < rhs.modelID
            }
    }
}

/// Display names for Claude model ids (`claude-opus-5-5` → "Opus 5.5").
enum ClaudeModelName {
    static func display(_ modelID: String) -> String {
        var base = ClaudeAPIPricing.baseModelID(modelID)
        if base.hasPrefix("claude-") {
            base.removeFirst("claude-".count)
        }
        return OpenCodeModelName.display(base)
    }
}
