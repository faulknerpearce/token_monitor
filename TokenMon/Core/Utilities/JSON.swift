import Foundation

/// Shared helpers for extracting values from `[String: Any]` JSON trees,
/// keeping numeric coercion, key-order fallback, and nested traversal
/// consistent across providers.
enum JSON {
    /// Coerces a decoded JSON value to a finite `Double`, descending into
    /// `["val": …]` / `["value": …]` wrappers the server emits around scalar
    /// fields. Booleans, NaN and infinities are rejected.
    static func number(_ any: Any?) -> Double? {
        let value: Double?
        switch any {
        case let number as NSNumber:
            guard !isBoolean(number) else { return nil }
            value = number.doubleValue
        case let string as String:
            value = Double(string.trimmingCharacters(in: .whitespaces))
        case let dict as [String: Any]:
            return number(dict["val"]) ?? number(dict["value"])
        default:
            return nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    /// Coerces a decoded JSON value to `Decimal` without a `Double` round trip,
    /// so money values keep their written digits (`"19.99"` stays 19.99).
    /// Accepts numbers and numeric strings, descends into `val`/`value`
    /// wrappers, and rejects booleans, NaN and infinities.
    static func decimal(_ any: Any?) -> Decimal? {
        switch any {
        case let number as NSNumber:
            guard !isBoolean(number), number.doubleValue.isFinite else { return nil }
            return number.decimalValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard let parsed = Double(trimmed), parsed.isFinite else { return nil }
            return Decimal(string: trimmed, locale: posixLocale)
        case let dict as [String: Any]:
            return decimal(dict["val"]) ?? decimal(dict["value"])
        default:
            return nil
        }
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// True for `true`/`false`, which Foundation bridges to `NSNumber`.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Coerces a decoded JSON value to `String`.
    static func string(_ any: Any?) -> String? {
        any as? String
    }

    /// Walks nested dictionaries along `keys`, returning the value at the end or `nil`.
    static func nested(_ dict: [String: Any], _ keys: [String]) -> Any? {
        var current: Any? = dict
        for key in keys {
            guard let nestedDict = current as? [String: Any] else { return nil }
            current = nestedDict[key]
        }
        return current
    }

    /// Returns the first numeric value among `keys`, in order.
    static func firstDouble(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = number(dict[key]) { return value }
        }
        return nil
    }

    /// Returns the first string among `keys`, in order.
    static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = string(dict[key]) { return value }
        }
        return nil
    }

    /// Returns the first `Decimal` among `keys`, in order.
    static func firstDecimal(_ dict: [String: Any], keys: [String]) -> Decimal? {
        for key in keys {
            if let value = decimal(dict[key]) { return value }
        }
        return nil
    }

    /// Returns the first boolean among `keys`, in order. Numeric `0`/`1` is
    /// accepted because some protobuf-JSON encodings emit flags as numbers.
    static func firstBool(_ dict: [String: Any], keys: [String], fallback: Bool = false) -> Bool {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let value = number(dict[key]) { return value != 0 }
        }
        return fallback
    }
}
