import Foundation

/// Serializes usage snapshots to CSV or JSON for export.
enum ExportService {
    /// Supported export file format.
    enum Format {
        case csv
        case json
    }

    /// Encodes `snapshots` as CSV or pretty-printed JSON.
    static func export(_ snapshots: [WeeklyUsageSnapshot], format: Format) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = snapshots.map { ExportRow(from: $0) }
            return try encoder.encode(payload)
        case .csv:
            var lines = ["fetchedAt,usedPercent,remainingPercent,resetsAt,products,extraCredits,accountEmail"]
            let iso = ISO8601DateFormatter()
            for snap in snapshots {
                let products = snap.products
                    .map { "\($0.id):\($0.percentOfPool)" }
                    .joined(separator: "|")
                let resets = snap.resetsAt.map { iso.string(from: $0) } ?? ""
                let credits = snap.extraCreditsBalance.map { "\($0)" } ?? ""
                let email = snap.accountEmail ?? ""
                lines.append([
                    iso.string(from: snap.fetchedAt),
                    String(format: "%.2f", snap.usedPercent),
                    String(format: "%.2f", snap.remainingPercent),
                    csvEscape(resets),
                    csvEscape(products),
                    csvEscape(credits),
                    csvEscape(email)
                ].joined(separator: ","))
            }
            return Data(lines.joined(separator: "\n").utf8)
        }
    }

    /// Escapes one CSV cell. A cell whose first character is `=`, `+`, `-`, `@`,
    /// tab or carriage return is prefixed with `'` so spreadsheets do not run it
    /// as a formula. A cell containing a comma, quote, line feed or carriage
    /// return is quoted, with inner quotes doubled.
    static func csvEscape(_ value: String) -> String {
        let sanitized: String
        if let first = value.unicodeScalars.first, formulaTriggers.contains(first) {
            sanitized = "'" + value
        } else {
            sanitized = value
        }
        if sanitized.unicodeScalars.contains(where: { quoteTriggers.contains($0) }) {
            return "\"\(sanitized.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return sanitized
    }

    private static let formulaTriggers = Set("=+-@\t\r".unicodeScalars)
    private static let quoteTriggers = Set(",\"\n\r".unicodeScalars)

    private struct ExportRow: Encodable {
        var fetchedAt: Date
        var usedPercent: Double
        var remainingPercent: Double
        var resetsAt: Date?
        var products: [ProductUsage]
        var extraCreditsBalance: Decimal?
        var accountEmail: String?

        init(from snap: WeeklyUsageSnapshot) {
            fetchedAt = snap.fetchedAt
            usedPercent = snap.usedPercent
            remainingPercent = snap.remainingPercent
            resetsAt = snap.resetsAt
            products = snap.products
            extraCreditsBalance = snap.extraCreditsBalance
            accountEmail = snap.accountEmail
        }
    }
}
