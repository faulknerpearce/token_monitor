import Foundation
import os
import SwiftData

/// Reads Grok history saved by earlier versions in a SwiftData store, so
/// `GrokHistoryStore` can carry it into its JSON file once. The SwiftData
/// file is left in place.
enum GrokHistoryImport {
    private static let logger = Logger(category: "GrokHistoryStore")

    /// Every snapshot in the SwiftData store at `url`, oldest first; nil when
    /// there is no store there or it cannot be read.
    @MainActor
    static func snapshots(at url: URL) -> [WeeklyUsageSnapshot]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let container = try ModelContainer(
                for: UsageSnapshotRecord.self,
                configurations: ModelConfiguration(url: url)
            )
            let records = try ModelContext(container).fetch(FetchDescriptor<UsageSnapshotRecord>(
                sortBy: [SortDescriptor(\.fetchedAt, order: .forward)]
            ))
            return records.map { $0.toSnapshot() }
        } catch {
            logger.error("SwiftData history import failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// SwiftData row for one daily `WeeklyUsageSnapshot`, as earlier versions
/// saved it.
@Model
final class UsageSnapshotRecord {
    @Attribute(.unique) var id: UUID
    var fetchedAt: Date
    var usedPercent: Double
    var remainingPercent: Double
    var resetsAt: Date?
    var productsJSON: Data
    /// Stored as Double for SwiftData schema stability; domain model uses Decimal.
    /// The conversion is lossy (a display-only balance), so `4.10` may read
    /// back as `4.0999…`.
    var extraCredits: Double?
    var accountEmail: String?

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
    private static let logger = Logger(category: "History")

    init(from snapshot: WeeklyUsageSnapshot) {
        self.id = snapshot.id
        self.fetchedAt = snapshot.fetchedAt
        self.usedPercent = snapshot.usedPercent
        self.remainingPercent = snapshot.remainingPercent
        self.resetsAt = snapshot.resetsAt
        if let data = try? Self.encoder.encode(snapshot.products) {
            self.productsJSON = data
        } else {
            Self.logger.error("Failed to encode products for snapshot \(snapshot.id)")
            self.productsJSON = Data()
        }
        self.extraCredits = snapshot.extraCreditsBalance.map { NSDecimalNumber(decimal: $0).doubleValue }
        self.accountEmail = snapshot.accountEmail
    }

    func apply(_ snapshot: WeeklyUsageSnapshot) {
        fetchedAt = snapshot.fetchedAt
        usedPercent = snapshot.usedPercent
        remainingPercent = snapshot.remainingPercent
        resetsAt = snapshot.resetsAt
        if let data = try? Self.encoder.encode(snapshot.products) {
            productsJSON = data
        } else {
            Self.logger.error("Failed to encode products on apply for \(snapshot.id)")
        }
        extraCredits = snapshot.extraCreditsBalance.map { NSDecimalNumber(decimal: $0).doubleValue }
        accountEmail = snapshot.accountEmail
    }

    func toSnapshot() -> WeeklyUsageSnapshot {
        let products: [ProductUsage]
        if let decoded = try? Self.decoder.decode([ProductUsage].self, from: productsJSON) {
            products = decoded
        } else {
            Self.logger.error("Failed to decode productsJSON for record \(self.id)")
            products = []
        }
        return WeeklyUsageSnapshot(
            id: id,
            fetchedAt: fetchedAt,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetsAt: resetsAt,
            products: products,
            extraCreditsBalance: extraCredits.map { Decimal($0) },
            accountEmail: accountEmail
        )
    }
}
