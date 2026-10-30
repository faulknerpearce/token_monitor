import Foundation

/// Claude API list prices, used to value Claude Code usage at API rates.
///
/// A subscription is billed at a flat plan price, so these values say what the
/// same tokens would cost through the API, not what was charged. Prompt-cache
/// writes cost a multiple of the input rate that depends on the cache lifetime:
/// 1.25× for the 5-minute cache and 2× for the 1-hour cache.
enum ClaudeAPIPricing {
    /// Date the rates were checked against Anthropic's published prices.
    static let ratesVerifiedOn = "2026-10-06"

    /// USD per 1M tokens.
    struct Rates: Hashable, Sendable {
        var input: Double
        var output: Double
        var cacheRead: Double

        /// 5-minute cache writes: 1.25× input.
        var cacheWrite5m: Double { input * 1.25 }
        /// 1-hour cache writes: 2× input.
        var cacheWrite1h: Double { input * 2 }
    }

    /// Rates by model id, without any `-YYYYMMDD` snapshot suffix.
    ///
    /// Claude Haiku 5.5 uses its rate for prompts up to 100K tokens for every
    /// prompt length.
    private static let rates: [String: Rates] = [
        "claude-fable-5-1": Rates(input: 10, output: 50, cacheRead: 0.25),
        "claude-fable-5": Rates(input: 10, output: 50, cacheRead: 1),
        "claude-opus-5-5": Rates(input: 4, output: 20, cacheRead: 0.20),
        "claude-opus-5": Rates(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-8": Rates(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-7": Rates(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-6": Rates(input: 5, output: 25, cacheRead: 0.50),
        "claude-sonnet-5-5": Rates(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-5": Rates(input: 2, output: 10, cacheRead: 0.20),
        "claude-sonnet-4-6": Rates(input: 3, output: 15, cacheRead: 0.30),
        "claude-haiku-5-5": Rates(input: 0.10, output: 0.50, cacheRead: 0.01),
        "claude-haiku-4-5": Rates(input: 1, output: 5, cacheRead: 0.10)
    ]

    /// Rates for `modelID`, or `nil` for a model with no listed price.
    static func rates(for modelID: String) -> Rates? {
        rates[baseModelID(modelID)]
    }

    /// API-rate value of `tokens` on `modelID`, or `nil` when the model has no
    /// listed price.
    static func cost(of tokens: ClaudeModelTokens, modelID: String) -> Double? {
        guard let rates = rates(for: modelID) else { return nil }
        let parts: [(Int64, Double)] = [
            (tokens.inputTokens, rates.input),
            (tokens.outputTokens, rates.output),
            (tokens.cacheReadTokens, rates.cacheRead),
            (tokens.cacheWrite5mTokens, rates.cacheWrite5m),
            (tokens.cacheWrite1hTokens, rates.cacheWrite1h)
        ]
        let perMillion = parts.reduce(0.0) { sum, part in sum + Double(part.0) * part.1 }
        return perMillion / 1_000_000
    }

    /// `modelID` without a trailing `-YYYYMMDD` snapshot date.
    static func baseModelID(_ modelID: String) -> String {
        let lower = modelID.lowercased()
        guard let dash = lower.lastIndex(of: "-") else { return lower }
        let tail = lower[lower.index(after: dash)...]
        guard tail.count == 8, tail.allSatisfy(\.isASCIIDigit) else { return lower }
        return String(lower[..<dash])
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
