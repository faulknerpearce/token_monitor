import Foundation

/// Token-based USD value for OpenCode models when the local DB records `$0`.
/// Paid-equivalent rates match the official OpenCode Zen pricing table, per 1M
/// tokens, so free Zen models show the value of the included usage.
enum OpenCodeZenCostEstimate {
    /// Rates per 1M tokens (input, output, cacheRead, cacheWrite).
    private struct Rates {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    /// Official OpenCode Zen pricing and paid-equivalent rates for free models.
    private static let ratesByModelID: [String: Rates] = [
        // Free Zen models: paid-equivalent value, not an OpenCode charge.
        "big-pickle": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "deepseek-v4-flash-free": Rates(input: 0.14, output: 0.28, cacheRead: 0.028, cacheWrite: 0),
        "mimo-v2.5-free": Rates(input: 0.20, output: 0.80, cacheRead: 0.02, cacheWrite: 0),
        "laguna-s-2.1-free": Rates(input: 0.20, output: 0.80, cacheRead: 0.02, cacheWrite: 0),
        "ling-3.0-flash-free": Rates(input: 0.14, output: 0.28, cacheRead: 0.028, cacheWrite: 0),
        "north-mini-code-free": Rates(input: 0.20, output: 0.80, cacheRead: 0.02, cacheWrite: 0),
        "nemotron-3-ultra-free": Rates(input: 0.20, output: 0.80, cacheRead: 0.02, cacheWrite: 0),
        // OpenCode Zen catalogue.
        "minimax-m2.5": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "minimax-m2.7": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "deepseek-v4-flash": Rates(input: 0.14, output: 0.28, cacheRead: 0.028, cacheWrite: 0),
        "deepseek-v4-pro": Rates(input: 1.74, output: 3.48, cacheRead: 0.145, cacheWrite: 0),
        "minimax-m3": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "glm-5": Rates(input: 1.00, output: 3.20, cacheRead: 0.20, cacheWrite: 0),
        "glm-5.1": Rates(input: 1.40, output: 4.40, cacheRead: 0.26, cacheWrite: 0),
        "glm-5.2": Rates(input: 1.40, output: 4.40, cacheRead: 0.26, cacheWrite: 0),
        "kimi-k2.5": Rates(input: 0.60, output: 3.00, cacheRead: 0.10, cacheWrite: 0),
        "kimi-k2.6": Rates(input: 0.95, output: 4.00, cacheRead: 0.16, cacheWrite: 0),
        "kimi-k2.7-code": Rates(input: 0.95, output: 4.00, cacheRead: 0.19, cacheWrite: 0),
        "kimi-k3": Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 0),
        "qwen3.5-plus": Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25),
        "qwen3.6-plus": Rates(input: 0.50, output: 3.00, cacheRead: 0.05, cacheWrite: 0.625),
        "qwen3.7-plus": Rates(input: 0.40, output: 1.60, cacheRead: 0.04, cacheWrite: 0.50),
        "qwen3.7-max": Rates(input: 2.50, output: 7.50, cacheRead: 0.50, cacheWrite: 3.125),
        "claude-fable-5": Rates(input: 10.00, output: 50.00, cacheRead: 1.00, cacheWrite: 12.50),
        "claude-opus-4-5": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-6": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-7": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-8": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-5": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-sonnet-4-5": Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75),
        "claude-sonnet-4-6": Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75),
        "claude-sonnet-5": Rates(input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50),
        "claude-haiku-4-5": Rates(input: 1.00, output: 5.00, cacheRead: 0.10, cacheWrite: 1.25),
        "gemini-3-flash": Rates(input: 0.50, output: 3.00, cacheRead: 0.05, cacheWrite: 0),
        "gemini-3.1-pro": Rates(input: 2.00, output: 12.00, cacheRead: 0.20, cacheWrite: 0),
        "gemini-3.5-flash": Rates(input: 1.50, output: 9.00, cacheRead: 0.15, cacheWrite: 0),
        "gemini-3.5-flash-lite": Rates(input: 0.30, output: 2.50, cacheRead: 0.03, cacheWrite: 0),
        "gemini-3.6-flash": Rates(input: 1.50, output: 7.50, cacheRead: 0.15, cacheWrite: 0),
        "grok-4.5": Rates(input: 2.00, output: 6.00, cacheRead: 0.30, cacheWrite: 0),
        "grok-build-0.1": Rates(input: 1.00, output: 2.00, cacheRead: 0.20, cacheWrite: 0),
        "gpt-5": Rates(input: 1.07, output: 8.50, cacheRead: 0.107, cacheWrite: 0),
        "gpt-5.1": Rates(input: 1.07, output: 8.50, cacheRead: 0.107, cacheWrite: 0),
        "gpt-5.1-codex": Rates(input: 1.07, output: 8.50, cacheRead: 0.107, cacheWrite: 0),
        "gpt-5.1-codex-max": Rates(input: 1.25, output: 10.00, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5.1-codex-mini": Rates(input: 0.25, output: 2.00, cacheRead: 0.025, cacheWrite: 0),
        "gpt-5.2": Rates(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.2-codex": Rates(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.3-codex": Rates(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.3-codex-spark": Rates(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.4": Rates(input: 2.50, output: 15.00, cacheRead: 0.25, cacheWrite: 0),
        "gpt-5.4-mini": Rates(input: 0.75, output: 4.50, cacheRead: 0.075, cacheWrite: 0),
        "gpt-5.4-nano": Rates(input: 0.20, output: 1.25, cacheRead: 0.02, cacheWrite: 0),
        "gpt-5.5": Rates(input: 5.00, output: 30.00, cacheRead: 0.50, cacheWrite: 0),
        "gpt-5.6-luna": Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25),
        // Muse Spark (Muse Park) — Go secondary model, add value estimate when cost==0.
        "muse-spark-1.2-contributor": Rates(input: 0.40, output: 1.60, cacheRead: 0.04, cacheWrite: 0.50),
        "muse-spark": Rates(input: 0.40, output: 1.60, cacheRead: 0.04, cacheWrite: 0.50)
    ]

    static func isPlanProvider(_ providerID: String) -> Bool {
        providerID.lowercased() == "opencode" || providerID.lowercased() == "opencode-go"
    }

    /// Prefer recorded cost; otherwise calculate value from the official model rate.
    static func billableCostUSD(
        providerID: String,
        modelID: String,
        recordedCostUSD: Double,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) -> (cost: Double, isEstimated: Bool) {
        if recordedCostUSD > 0 {
            return (recordedCostUSD, false)
        }
        guard isPlanProvider(providerID) else {
            return (0, false)
        }
        let tokens = inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        guard tokens > 0 else {
            return (0, false)
        }
        let value = estimate(
            modelID: modelID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
        // Any token-derived value is an estimate (recorded cost was zero), so it
        // must carry the `~` prefix. A free model with no rate entry estimates to
        // 0 and stays unmarked.
        return (value, value > 0)
    }

    static func estimate(
        modelID: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) -> Double {
        guard let rates = ratesByModelID[modelID.lowercased()] else { return 0 }
        let perMillion = 1_000_000.0
        return rates.input * Double(inputTokens) / perMillion
            + rates.output * Double(outputTokens) / perMillion
            + rates.cacheRead * Double(cacheReadTokens) / perMillion
            + rates.cacheWrite * Double(cacheWriteTokens) / perMillion
    }
}
