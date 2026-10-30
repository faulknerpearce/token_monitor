import Foundation

/// Scans gRPC-web frames for the usage percent, reset instant, and product slices.
enum GRPCWebParser {
    /// Decoded usage percent, reset instant, and product slices from one payload.
    struct Parsed {
        var usedPercent: Double
        var resetsAt: Date?
        var products: [ProductUsage]
    }

    /// Product-type enums in GetGrokCreditsConfig field-7 sub-messages.
    /// Verified against a live SuperGrok response + grok.com Settings → Usage
    /// (Build 30%, Chat 21%, Imagine 12%, Other 1%):
    ///   enum 2 → 30%, 4 → 21%, 5 → 12%, 3 → 1%.
    private static let productEnumMap: [UInt64: (id: String, name: String)] = [
        1: ("api", "API"),
        2: ("build", "Grok Build"),
        3: ("other", "Other"),
        4: ("chat", "Chat"),
        5: ("imagine", "Imagine"),
        6: ("voice", "Voice")
    ]

    /// Scans gRPC-web `data` for the `[1, 1]` usage percent and reset candidates.
    static func parseUsage(_ data: Data, now: Date = Date()) throws -> Parsed {
        var payloads = dataFrames(from: data)
        if payloads.isEmpty, looksLikeProtobuf(data) {
            payloads = [data]
        }
        guard !payloads.isEmpty else { throw ProviderError.grokEmptyResponse }

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

        let resetCandidates = varints.compactMap { field -> (path: [UInt64], date: Date)? in
            guard field.value >= 1_700_000_000, field.value <= 2_100_000_000 else { return nil }
            return (field.path, Date(timeIntervalSince1970: TimeInterval(field.value)))
        }
        // Canonical reset field [1,5,1] is kept even when already past, so a lagging
        // payload keeps the period anchor. `billingPeriodWeekBounds` rolls the window
        // when now >= resetsAt. Non-canonical candidates count only when in the
        // future, so unrelated old timestamps are ignored.
        let canonical = resetCandidates.filter { $0.path == [1, 5, 1] }.map(\.date).min()
        let future = resetCandidates.filter { $0.date > now }
        let reset = canonical ?? future.map(\.date).min()

        let hasPeriod = varints.contains {
            $0.path.starts(with: [1, 5]) || ($0.path == [1, 8, 1] && ($0.value == 1 || $0.value == 2))
        }
        let used = percent ?? ((reset != nil && hasPeriod && fixed32.isEmpty) ? 0 : nil)
        guard let used else { throw ProviderError.grokDecoding("gRPC usage percent missing") }
        return Parsed(usedPercent: used, resetsAt: reset, products: products)
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

    /// Scans raw protobuf bytes recursively for field‑7 sub‑messages (products),
    /// pairing field 1 (enum) with field 2 (percent) inside each entry, at any depth.
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

    /// Recursively walks `bytes[start..<end]`, treating the body of every
    /// length‑delimited field 7 as a product sub‑message.
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
                      len <= UInt64(end - index),
                      let intLen = Int(exactly: len) else { return products }
                let subStart = index
                let subEnd = index + intLen
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
                      nl <= UInt64(end - index),
                      let intNl = Int(exactly: nl) else { return nil }
                index += intNl
            default:
                // Unknown wire type: abandons this product.
                return nil
            }
        }

        guard let enumValue, let percent, percent > 0.05, percent <= 100 else { return nil }
        let meta = productEnumMap[enumValue]
            ?? ("product-\(enumValue)", "Product \(enumValue)")
        return ProductUsage(id: meta.id, displayName: meta.name, percentOfPool: percent)
    }

    /// Throws `.unauthorized` on gRPC auth trailers, else maps `grpc-status` to an error.
    static func validateTrailers(_ data: Data) throws {
        let fields = trailerFields(from: data)
        try validateStatus(fields["grpc-status"], message: fields["grpc-message"])
    }

    /// Applies `validateTrailers` rules to a `grpc-status` sent in the HTTP
    /// headers, as a trailers-only reply (e.g. UNAUTHENTICATED with an empty
    /// body) does.
    static func validateHeaders(_ response: HTTPURLResponse) throws {
        let message = response.value(forHTTPHeaderField: "grpc-message")
        try validateStatus(
            response.value(forHTTPHeaderField: "grpc-status"),
            message: message?.removingPercentEncoding ?? message
        )
    }

    /// Throws `.unauthorized` for status 16 (UNAUTHENTICATED) or an
    /// "unauthenticated" message, a body-free error for any other non-zero
    /// status, and nothing for a missing or zero status.
    private static func validateStatus(_ raw: String?, message: String?) throws {
        guard let raw, let status = Int(raw.trimmingCharacters(in: .whitespaces)), status != 0 else { return }
        let message = message ?? ""
        if status == 16 || message.lowercased().contains("unauthenticated") {
            throw ProviderError.unauthorized(.grok)
        }
        throw ProviderError.grokHTTPStatus(status, body: message)
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
