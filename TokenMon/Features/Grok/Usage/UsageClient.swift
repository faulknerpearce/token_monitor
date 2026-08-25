import Foundation
import os

/// Fetches SuperGrok weekly usage via authenticated grok.com / CLI endpoints.
struct UsageClient: Sendable {
    private let logger = Logger(category: "UsageClient")

    /// Primary gRPC-web billing endpoint used by grok.com Settings → Usage.
    static let billingEndpoint = URL(
        string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
    )!

    /// CLI billing JSON fallback (when bearer from `grok login` is available).
    static let cliBillingEndpoint = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing"
    )!

    /// Candidate REST paths probed for product breakdown JSON.
    static let restCandidates: [URL] = [
        URL(string: "https://grok.com/rest/subscriptions")!,
        URL(string: "https://grok.com/rest/user")!,
        URL(string: "https://grok.com/rest/billing/usage")!,
        URL(string: "https://grok.com/rest/usage")!
    ]

    var cookieHeader: String?
    var bearerToken: String?
    var accountEmail: String?
    var session: URLSession = .shared

    func fetchUsage() async throws -> WeeklyUsageSnapshot {
        if cookieHeader == nil && bearerToken == nil {
            throw UsageClientError.notSignedIn
        }

        var lastError: Error?

        // 1) Prefer REST JSON that may include product breakdown.
        // Do not swallow unauthorized — re-auth must surface immediately.
        do {
            if let rest = try await fetchRESTBreakdown() {
                return rest
            }
        } catch let error as UsageClientError where error == .unauthorized {
            throw error
        } catch {
            lastError = error
            logger.warning("REST usage probe failed: \(error.localizedDescription, privacy: .public)")
        }

        // 2) grok.com gRPC-web billing (overall %).
        do {
            return try await fetchGRPCWebBilling()
        } catch let error as UsageClientError where error == .unauthorized {
            throw error
        } catch {
            lastError = error
            logger.warning("gRPC-web billing failed: \(error.localizedDescription, privacy: .public)")
        }

        // 3) CLI billing JSON with bearer.
        if bearerToken != nil {
            do {
                return try await fetchCLIBilling()
            } catch {
                lastError = error
                logger.warning("CLI billing failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let lastError {
            throw lastError
        }
        throw UsageClientError.emptyResponse
    }

    // MARK: - REST

    private func fetchRESTBreakdown() async throws -> WeeklyUsageSnapshot? {
        for url in Self.restCandidates {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            applyAuth(to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
            request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw UsageClientError.unauthorized
            }
            guard http.statusCode == 200, !data.isEmpty else { continue }
            if let snapshot = UsageResponseParser.parseJSON(data, accountEmail: accountEmail) {
                logger.info("Parsed usage from \(url.path, privacy: .public)")
                return snapshot
            }
        }
        return nil
    }

    // MARK: - gRPC-web

    private func fetchGRPCWebBilling() async throws -> WeeklyUsageSnapshot {
        var request = URLRequest(url: Self.billingEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        // Empty gRPC-web frame (5-byte header + empty message).
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        applyAuth(to: &request)
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.network("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageClientError.unauthorized
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw UsageClientError.httpStatus(http.statusCode, body)
        }

        try GRPCWebParser.validateTrailers(data)
        let parsed = try GRPCWebParser.parseUsage(data)
        let used = parsed.usedPercent ?? 0
        let products = parsed.products.isEmpty
            ? Self.synthesizeProducts(usedPercent: used)
            : parsed.products
        let productLog = products.map { "\($0.id):\(String(format: "%.1f", $0.percentOfPool))%" }.joined(separator: ", ")
        logger.info("gRPC parsed products: \(productLog, privacy: .public)")
        #if DEBUG
        if !parsed.dailySeries.isEmpty {
            logger.info("gRPC daily series rows: \(parsed.dailySeries.count, privacy: .public)")
        }
        logger.debug("gRPC field dump:\n\(GRPCWebParser.debugFieldDump(data), privacy: .public)")
        #endif
        return WeeklyUsageSnapshot(
            usedPercent: used,
            remainingPercent: max(0, 100 - used),
            resetsAt: parsed.resetsAt,
            products: products,
            accountEmail: accountEmail,
            dailySeries: parsed.dailySeries
        )
    }

    // MARK: - CLI JSON

    private func fetchCLIBilling() async throws -> WeeklyUsageSnapshot {
        var request = URLRequest(url: Self.cliBillingEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.network("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageClientError.unauthorized
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw UsageClientError.httpStatus(http.statusCode, body)
        }

        if let snapshot = UsageResponseParser.parseCLIBilling(data, accountEmail: accountEmail) {
            return snapshot
        }
        throw UsageClientError.decodingFailed("CLI billing JSON shape unrecognized")
    }

    private func applyAuth(to request: inout URLRequest) {
        if let bearerToken, !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
    }

    /// When product breakdown is unavailable, keep a neutral "other" slice — never label as Build.
    static func synthesizeProducts(usedPercent: Double) -> [ProductUsage] {
        guard usedPercent > 0.05 else { return [] }
        return [
            ProductUsage(
                id: "other",
                displayName: "Other",
                percentOfPool: usedPercent,
                colorToken: .other
            )
        ]
    }
}

// MARK: - JSON parsing

enum UsageResponseParser {
    static func parseJSON(_ data: Data, accountEmail: String?) -> WeeklyUsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parseAny(obj, accountEmail: accountEmail)
    }

    static func parseCLIBilling(_ data: Data, accountEmail: String?) -> WeeklyUsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Shape: { monthlyLimit: {val}, usage: { totalUsed: {val} }, billingCycle: { billingPeriodEnd } }
        // or nested under "config"
        let config = (root["config"] as? [String: Any]) ?? root
        let limit = numberValue(config["monthlyLimit"]) ?? numberValue(nested(config, "monthlyLimit", "val"))
        let used = numberValue(nested(config, "usage", "totalUsed", "val"))
            ?? numberValue(config["used"])
            ?? numberValue(nested(config, "usage", "includedUsed", "val"))
        let end = stringValue(nested(config, "billingCycle", "billingPeriodEnd"))
            ?? stringValue(config["billingPeriodEnd"])

        guard let limit, limit > 0, let used else { return nil }
        let usedPercent = Percent.clamp((used / limit) * 100)
        let resetsAt = end.flatMap { ISO8601DateFormatter.parseFlexible($0) }
        return WeeklyUsageSnapshot(
            usedPercent: usedPercent,
            remainingPercent: max(0, 100 - usedPercent),
            resetsAt: resetsAt,
            products: UsageClient.synthesizeProducts(usedPercent: usedPercent),
            accountEmail: accountEmail
        )
    }

    private static let wrapperKeys = ["usage", "data", "subscription", "billing", "credits", "result"]

    private static func parseAny(_ obj: Any, accountEmail: String?) -> WeeklyUsageSnapshot? {
        guard let dict = obj as? [String: Any] else { return nil }

        // Nested common wrappers
        for key in wrapperKeys {
            if let nested = dict[key], let snap = parseAny(nested, accountEmail: accountEmail) {
                return snap
            }
        }

        let used = firstDouble(dict, keys: [
            "usedPercent", "usagePercent", "credit_usage_percent", "percentUsed",
            "used_percent", "usage_percent", "percent"
        ])
        let remaining = firstDouble(dict, keys: [
            "remainingPercent", "remaining_percent", "percentRemaining"
        ])

        var products: [ProductUsage] = []
        if let breakdown = dict["products"] as? [[String: Any]]
            ?? dict["breakdown"] as? [[String: Any]]
            ?? dict["productBreakdown"] as? [[String: Any]] {
            products = breakdown.compactMap { item in
                let id = stringValue(item["id"])
                    ?? stringValue(item["key"])
                    ?? stringValue(item["name"])
                    ?? "other"
                let name = stringValue(item["displayName"])
                    ?? stringValue(item["name"])
                    ?? stringValue(item["label"])
                    ?? ProductCatalog.displayName(for: id)
                let pct = firstDouble(item, keys: ["percentOfPool", "percent", "usagePercent", "value"]) ?? 0
                return ProductUsage(id: id.lowercased(), displayName: name, percentOfPool: pct)
            }
        } else if let map = dict["byProduct"] as? [String: Any] ?? dict["productUsage"] as? [String: Any] {
            products = map.compactMap { key, value in
                let pct: Double
                if let n = value as? Double { pct = n } else if let n = value as? Int { pct = Double(n) } else if let nested = value as? [String: Any] {
                    pct = firstDouble(nested, keys: ["percent", "value", "usagePercent"]) ?? 0
                } else { return nil }
                return ProductUsage(
                    id: key.lowercased(),
                    displayName: ProductCatalog.displayName(for: key),
                    percentOfPool: pct
                )
            }
        }

        let resetsString = firstString(dict, keys: [
            "resetsAt", "resetAt", "reset_at", "billingPeriodEnd", "periodEnd", "nextReset"
        ])
        let resetsAt = resetsString.flatMap { ISO8601DateFormatter.parseFlexible($0) }

        let credits = firstDecimal(dict, keys: [
            "extraCredits", "extraCreditsBalance", "onDemandBalance", "creditsBalance"
        ])

        // Accept if we have used% or products that sum to used.
        let inferredUsed: Double? = {
            if let used { return used }
            let sum = products.reduce(0) { $0 + $1.percentOfPool }
            return sum > 0 ? sum : nil
        }()

        guard let inferredUsed else { return nil }
        let rem = remaining ?? max(0, 100 - inferredUsed)
        let finalProducts = products.isEmpty
            ? UsageClient.synthesizeProducts(usedPercent: inferredUsed)
            : products

        return WeeklyUsageSnapshot(
            usedPercent: inferredUsed,
            remainingPercent: rem,
            resetsAt: resetsAt,
            products: finalProducts,
            extraCreditsBalance: credits,
            accountEmail: accountEmail ?? stringValue(dict["email"])
        )
    }

    private static func firstDouble(_ dict: [String: Any], keys: [String]) -> Double? {
        JSON.firstDouble(dict, keys: keys)
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        JSON.firstString(dict, keys: keys)
    }

    private static func firstDecimal(_ dict: [String: Any], keys: [String]) -> Decimal? {
        JSON.firstDecimal(dict, keys: keys)
    }

    private static func numberValue(_ any: Any?) -> Double? {
        JSON.number(any)
    }

    private static func stringValue(_ any: Any?) -> String? {
        JSON.string(any)
    }

    private static func nested(_ dict: [String: Any], _ keys: String...) -> Any? {
        JSON.nested(dict, keys)
    }
}

// MARK: - gRPC-web protobuf scan (adapted from community billing parsers)

extension Data {
    /// Shared with unit/manual tests that decode raw protobuf samples.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = chars.startIndex
        while i < chars.endIndex {
            let next = chars.index(i, offsetBy: 2)
            guard let byte = UInt8(String(chars[i..<next]), radix: 16) else { return nil }
            data.append(byte)
            i = next
        }
        self = data
    }
}

enum GRPCWebParser {
    struct Parsed {
        var usedPercent: Double?
        var resetsAt: Date?
        var products: [ProductUsage]
        /// Per-day rows if present in the protobuf (currently unused by known samples).
        var dailySeries: [DailyUsageSnapshot] = []
    }

    /// Product-type enums in GetGrokCreditsConfig field-7 sub-messages.
    /// Verified against a live SuperGrok response + grok.com Settings → Usage
    /// (Build 30%, Chat 21%, Imagine 12%, Other 1%):
    ///   enum 2 → 30%, 4 → 21%, 5 → 12%, 3 → 1%.
    /// Earlier maps that labeled 3=Imagine / 5=Voice caused Imagine↔Voice swaps.
    private static let productEnumMap: [UInt64: (id: String, name: String)] = [
        1: ("api", "API"),
        2: ("build", "Grok Build"),
        3: ("other", "Other"),
        4: ("chat", "Chat"),
        5: ("imagine", "Imagine"),
        6: ("voice", "Voice")
    ]

    static func parseUsage(_ data: Data, now: Date = Date()) throws -> Parsed {
        var payloads = dataFrames(from: data)
        if payloads.isEmpty, looksLikeProtobuf(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { throw UsageClientError.emptyResponse }

        var fixed32: [(path: [UInt64], value: Float, order: Int)] = []
        var varints: [(path: [UInt64], value: UInt64)] = []
        var order = 0
        for payload in payloads {
            let scan = scanProtobuf(payload, depth: 0, path: [], order: order)
            fixed32.append(contentsOf: scan.fixed32)
            varints.append(contentsOf: scan.varints)
            order = scan.order
        }

        // Total used % lives at protobuf path [1, 1] (fixed32).
        let percent = fixed32
            .first(where: { $0.path == [1, 1] && $0.value.isFinite && $0.value >= 0 && $0.value <= 100 })
            .map { Double($0.value) }
            ?? fixed32
            .filter { $0.path.last == 1 && $0.path.count <= 2 && $0.value.isFinite && $0.value >= 0 && $0.value <= 100 }
            .min { lhs, rhs in
                lhs.path.count == rhs.path.count ? lhs.order < rhs.order : lhs.path.count < rhs.path.count
            }
            .map { Double($0.value) }

        let products = parseProductsFromPayloads(payloads)
        let dailySeries = extractDailySeries(varints: varints, fixed32: fixed32, calendar: .current, now: now)

        let resetCandidates = varints.compactMap { field -> (path: [UInt64], date: Date)? in
            guard field.value >= 1_700_000_000, field.value <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(field.value)))
        }
        // Canonical reset field [1,5,1] is kept even when already past — a lagging
        // payload must not lose the period anchor. `billingPeriodWeekBounds` rolls
        // the window when now >= resetsAt. Non-canonical candidates stay future-only
        // so unrelated old timestamps never invent an anchor.
        let canonical = resetCandidates.filter { $0.path == [1, 5, 1] }.map(\.date).min()
        let future = resetCandidates.filter { $0.date > now }
        let reset = canonical ?? future.map(\.date).min()

        let hasPeriod = varints.contains {
            $0.path.starts(with: [1, 5]) || ($0.path == [1, 8, 1] && ($0.value == 1 || $0.value == 2))
        }
        let used = percent ?? ((reset != nil && hasPeriod && fixed32.isEmpty) ? 0 : nil)
        guard let used else { throw UsageClientError.decodingFailed("gRPC usage percent missing") }
        return Parsed(usedPercent: used, resetsAt: reset, products: products, dailySeries: dailySeries)
    }

    /// Debug dump of all scanned protobuf fields (for discovering daily series paths).
    static func debugFieldDump(_ data: Data) -> String {
        var payloads = dataFrames(from: data)
        if payloads.isEmpty, looksLikeProtobuf(data) {
            payloads = [data]
        }
        var lines: [String] = []
        var order = 0
        for (i, payload) in payloads.enumerated() {
            let scan = scanProtobuf(payload, depth: 0, path: [], order: order)
            order = scan.order
            lines.append("frame[\(i)] bytes=\(payload.count)")
            for fixed32 in scan.fixed32 {
                let path = fixed32.path.map(String.init).joined(separator: ".")
                lines.append("  f32 \(path) = \(fixed32.value)")
            }
            for varint in scan.varints {
                let path = varint.path.map(String.init).joined(separator: ".")
                if varint.value >= 1_700_000_000, varint.value <= 2_100_000_000 {
                    let date = Date(timeIntervalSince1970: TimeInterval(varint.value))
                    lines.append("  vi  \(path) = \(varint.value) // \(date)")
                } else {
                    lines.append("  vi  \(path) = \(varint.value)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Reserved for a confirmed server daily series path.
    ///
    /// The previous heuristic (pairing near-midnight unix varints with nearby fixed32
    /// percents) false-positived on live GetGrokCreditsConfig payloads and could
    /// override local day-over-day history in `DailyUsageBuilder`. Keep empty until
    /// xAI documents a stable daily field path.
    private static func extractDailySeries(
        varints _: [(path: [UInt64], value: UInt64)],
        fixed32 _: [(path: [UInt64], value: Float, order: Int)],
        calendar _: Calendar,
        now _: Date
    ) -> [DailyUsageSnapshot] {
        []
    }

    /// Scans raw protobuf bytes recursively for field‑7 sub‑messages (products),
    /// pairing field 1 (enum) with field 2 (percent) inside each entry.
    /// Works at any nesting depth so it doesn’t matter whether products live
    /// inside an outer wrapper or at the top level.
    private static func parseProductsFromPayloads(_ payloads: [Data]) -> [ProductUsage] {
        var seen: [String: ProductUsage] = [:]
        for payload in payloads {
            for product in scanForField7Products(bytes: [UInt8](payload), start: 0, end: payload.count) {
                let key = product.id.lowercased()
                if var existing = seen[key] {
                    existing.percentOfPool += product.percentOfPool
                    seen[key] = existing
                } else {
                    seen[key] = product
                }
            }
        }
        return ProductCatalog.sortForDisplay(Array(seen.values))
    }

    /// Recursively walk `bytes[start..<end]`.  Every time we hit a length‑delimited
    /// field whose number is 7, treat its body as a product sub‑message.
    private static func scanForField7Products(bytes: [UInt8], start: Int, end: Int) -> [ProductUsage] {
        var products: [ProductUsage] = []
        var index = start
        while index < end {
            guard let key = readVarint(bytes, index: &index), key != 0 else { break }
            let fieldNumber = key >> 3
            let wireType = key & 0x07

            switch wireType {
            case 0:
                _ = readVarint(bytes, index: &index)
            case 1:
                guard index + 8 <= end else { return products }
                index += 8
            case 2:
                guard let len = readVarint(bytes, index: &index),
                      index + Int(len) <= end else { return products }
                let subStart = index
                let subEnd = index + Int(len)
                if fieldNumber == 7 {
                    if let product = parseProductSubMessage(bytes: bytes, start: subStart, end: subEnd) {
                        products.append(product)
                    }
                } else {
                    // Recurse into any other length‑delimited field.
                    products.append(contentsOf: scanForField7Products(bytes: bytes, start: subStart, end: subEnd))
                }
                index = subEnd
            case 5:
                guard index + 4 <= end else { return products }
                index += 4
            default:
                return products
            }
        }
        return products
    }

    private static func parseProductSubMessage(bytes: [UInt8], start: Int, end: Int) -> ProductUsage? {
        var index = start
        var enumValue: UInt64?
        var percent: Double?

        while index < end {
            guard let sk = readVarint(bytes, index: &index), sk != 0 else { return nil }
            let sfn = sk >> 3
            let swt = sk & 0x07

            switch swt {
            case 0:
                guard let value = readVarint(bytes, index: &index) else { return nil }
                if sfn == 1 { enumValue = value }
            case 1:
                // fixed64 — skip
                guard index + 8 <= end else { return nil }
                index += 8
            case 5:
                guard index + 4 <= end else { return nil }
                if sfn == 2 {
                    let bits = UInt32(bytes[index])
                        | (UInt32(bytes[index + 1]) << 8)
                        | (UInt32(bytes[index + 2]) << 16)
                        | (UInt32(bytes[index + 3]) << 24)
                    percent = Double(Float(bitPattern: bits))
                }
                index += 4
            case 2:
                guard let nl = readVarint(bytes, index: &index),
                      index + Int(nl) <= end else { return nil }
                index += Int(nl)
            default:
                // Unknown wire type — abort this product rather than spin.
                return nil
            }
        }

        guard let enumValue, let percent, percent > 0.05, percent <= 100 else { return nil }
        let meta = productEnumMap[enumValue]
            ?? ("product-\(enumValue)", "Product \(enumValue)")
        return ProductUsage(id: meta.id, displayName: meta.name, percentOfPool: percent)
    }

    static func validateTrailers(_ data: Data) throws {
        let fields = trailerFields(from: data)
        guard let raw = fields["grpc-status"], let status = Int(raw), status != 0 else { return }
        let message = fields["grpc-message"] ?? ""
        if status == 16 || message.lowercased().contains("unauthenticated") {
            throw UsageClientError.unauthorized
        }
        throw UsageClientError.httpStatus(status, message)
    }

    private static func dataFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var frames: [Data] = []
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { return [] }
            if flags & 0x80 == 0 {
                frames.append(Data(bytes[start..<end]))
            }
            index = end
        }
        return frames
    }

    private static func trailerFields(from data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var fields: [String: String] = [:]
        var index = 0
        while index + 5 <= bytes.count {
            let flags = bytes[index]
            let length = (Int(bytes[index + 1]) << 24)
                | (Int(bytes[index + 2]) << 16)
                | (Int(bytes[index + 3]) << 8)
                | Int(bytes[index + 4])
            let start = index + 5
            let end = start + length
            guard length >= 0, end <= bytes.count else { break }
            if flags & 0x80 != 0, let text = String(data: Data(bytes[start..<end]), encoding: .utf8) {
                for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                    guard let sep = line.firstIndex(of: ":") else { continue }
                    let key = line[..<sep].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let value = line[line.index(after: sep)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .removingPercentEncoding ?? ""
                    fields[key] = value
                }
            }
            index = end
        }
        return fields
    }

    private static func looksLikeProtobuf(_ data: Data) -> Bool {
        guard let first = data.first else { return false }
        let fieldNumber = first >> 3
        let wireType = first & 0x07
        return fieldNumber > 0 && (wireType == 0 || wireType == 1 || wireType == 2 || wireType == 5)
    }

    private static func scanProtobuf(
        _ data: Data,
        depth: Int,
        path: [UInt64],
        order: Int
    ) -> (fixed32: [(path: [UInt64], value: Float, order: Int)],
          varints: [(path: [UInt64], value: UInt64)],
          order: Int) {
        let bytes = [UInt8](data)
        var fixed32: [(path: [UInt64], value: Float, order: Int)] = []
        var varints: [(path: [UInt64], value: UInt64)] = []
        var index = 0
        var nextOrder = order

        while index < bytes.count {
            guard let key = readVarint(bytes, index: &index), key != 0 else {
                return (fixed32, varints, nextOrder)
            }
            let fieldNumber = key >> 3
            let wireType = key & 0x07
            let fieldPath = path + [fieldNumber]

            switch wireType {
            case 0:
                if let value = readVarint(bytes, index: &index) {
                    varints.append((fieldPath, value))
                } else {
                    return (fixed32, varints, nextOrder)
                }
            case 1:
                guard index + 8 <= bytes.count else { return (fixed32, varints, nextOrder) }
                index += 8
            case 2:
                guard let length = readVarint(bytes, index: &index),
                      length <= UInt64(bytes.count - index)
                else {
                    return (fixed32, varints, nextOrder)
                }
                let start = index
                let end = index + Int(length)
                if depth < 4 {
                    let nested = scanProtobuf(Data(bytes[start..<end]), depth: depth + 1, path: fieldPath, order: nextOrder)
                    fixed32.append(contentsOf: nested.fixed32)
                    varints.append(contentsOf: nested.varints)
                    nextOrder = nested.order
                }
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return (fixed32, varints, nextOrder) }
                let bits = UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24)
                fixed32.append((fieldPath, Float(bitPattern: bits), nextOrder))
                nextOrder += 1
                index += 4
            default:
                return (fixed32, varints, nextOrder)
            }
        }
        return (fixed32, varints, nextOrder)
    }

    private static func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}
