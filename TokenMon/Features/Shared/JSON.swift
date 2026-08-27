import Foundation

/// Shared helpers for extracting values from `[String: Any]` JSON trees.
///
/// These were duplicated between the Grok, Cursor, and OpenCode clients; hoisting
/// them here keeps numeric coercion, key-order fallback, and nested traversal
/// consistent across every provider.
enum JSON {
    /// Coerces a decoded JSON value to `Double`, descending into `["val": …]` /
    /// `["value": …]` wrappers the server emits around scalar fields.
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        case let dict as [String: Any]: return number(dict["val"]) ?? number(dict["value"])
        default: return nil
        }
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
            if let value = number(dict[key]) { return Decimal(value) }
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
