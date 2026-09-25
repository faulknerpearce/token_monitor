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

    /// Paid-equivalent rates per 1M tokens (input, output, cacheRead, cacheWrite),
    /// taken from OpenRouter's public catalogue
    /// (`https://openrouter.ai/api/v1/models`) for every model it lists. Free Zen
    /// models record `$0`, so these rates give their included usage a value.
    private static let ratesByModelID: [String: Rates] = [
        // Free Zen models: paid-equivalent value, not an OpenCode charge.
        "big-pickle": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "deepseek-v4-flash-free": Rates(input: 0.04872, output: 0.09744, cacheRead: 0.009744, cacheWrite: 0),
        "mimo-v2.5-free": Rates(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0),
        "mimo-v2.6-flash-free": Rates(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0),
        "laguna-s-2.1-free": Rates(input: 0.09, output: 0.18, cacheRead: 0.009, cacheWrite: 0),
        "ling-3.0-flash-free": Rates(input: 0.021, output: 0.063, cacheRead: 0.0042, cacheWrite: 0),
        "north-mini-code-free": Rates(input: 0.20, output: 0.80, cacheRead: 0.02, cacheWrite: 0),
        "nemotron-3-ultra-free": Rates(input: 0.60, output: 2.40, cacheRead: 0.12, cacheWrite: 0),
        "nemotron-3.5-lightning-free": Rates(input: 0.07, output: 0.20, cacheRead: 0.04, cacheWrite: 0),
        "hy3-free": Rates(input: 0.132, output: 0.528, cacheRead: 0.033, cacheWrite: 0),
        // OpenCode Zen catalogue.
        "minimax-m2.5": Rates(input: 0.27, output: 1.08, cacheRead: 0.027, cacheWrite: 0),
        "minimax-m2.7": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "deepseek-v4.1-flash": Rates(input: 0.15, output: 0.60, cacheRead: 0.003, cacheWrite: 0),
        "deepseek-v4-flash": Rates(input: 0.04872, output: 0.09744, cacheRead: 0.009744, cacheWrite: 0),
        "deepseek-v4-pro": Rates(input: 0.783, output: 1.566, cacheRead: 0.06525, cacheWrite: 0),
        "minimax-m3": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "mimo-v2.5": Rates(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0),
        "mimo-v2.5-pro": Rates(input: 0.435, output: 0.87, cacheRead: 0.0036, cacheWrite: 0),
        "mimo-v2.6-pro": Rates(input: 0.435, output: 0.87, cacheRead: 0.0036, cacheWrite: 0),
        "glm-5": Rates(input: 0.60, output: 1.92, cacheRead: 0.12, cacheWrite: 0),
        "glm-5.1": Rates(input: 0.9646, output: 3.0316, cacheRead: 0.17914, cacheWrite: 0),
        "glm-5.2": Rates(input: 0.6496, output: 2.0416, cacheRead: 0.12064, cacheWrite: 0),
        "glm-5.3-flash": Rates(input: 0.045, output: 0.14, cacheRead: 0.01, cacheWrite: 0),
        "kimi-k2.5": Rates(input: 0.45, output: 2.25, cacheRead: 0.07, cacheWrite: 0),
        "kimi-k2.6": Rates(input: 0.95, output: 4.00, cacheRead: 0.16, cacheWrite: 0),
        "kimi-k2.7-code": Rates(input: 0.6562, output: 3.30, cacheRead: 0.18, cacheWrite: 0),
        "kimi-k3": Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 0),
        "qwen3.5-plus": Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25),
        "qwen3.6-plus": Rates(input: 0.325, output: 1.95, cacheRead: 0, cacheWrite: 0.40625),
        "qwen3.7-plus": Rates(input: 0.32, output: 1.28, cacheRead: 0.064, cacheWrite: 0.40),
        "qwen3.7-max": Rates(input: 1.475, output: 4.425, cacheRead: 0.295, cacheWrite: 1.84375),
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
        "gemini-3.5-flash": Rates(input: 1.50, output: 9.00, cacheRead: 0.15, cacheWrite: 0.083333),
        "gemini-3.5-flash-lite": Rates(input: 0.30, output: 2.50, cacheRead: 0.03, cacheWrite: 0.083333),
        "gemini-3.6-flash": Rates(input: 0.75, output: 3.75, cacheRead: 0.075, cacheWrite: 0.041667),
        "grok-4.5": Rates(input: 2.00, output: 6.00, cacheRead: 0.30, cacheWrite: 0),
        "grok-build-0.1": Rates(input: 1.00, output: 2.00, cacheRead: 0.20, cacheWrite: 0),
        "gpt-5": Rates(input: 1.25, output: 10.00, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5.1": Rates(input: 1.25, output: 10.00, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5.1-codex": Rates(input: 1.25, output: 10.00, cacheRead: 0.13, cacheWrite: 0),
        "gpt-5.1-codex-max": Rates(input: 1.25, output: 10.00, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5.1-codex-mini": Rates(input: 0.25, output: 2.00, cacheRead: 0.03, cacheWrite: 0),
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
        "muse-spark-1.3-contributor-free": Rates(input: 0.10, output: 0.20, cacheRead: 0.002, cacheWrite: 0),
        "muse-spark-1.2-contributor-free": Rates(input: 0.10, output: 0.20, cacheRead: 0.002, cacheWrite: 0),
        "muse-spark-1.2-contributor": Rates(input: 0.10, output: 0.20, cacheRead: 0.002, cacheWrite: 0),
        "muse-spark": Rates(input: 1.25, output: 4.25, cacheRead: 0.15, cacheWrite: 0)
    ]

    /// Rates for a model id, resolving Zen's `-free` / `-contributor` billing
    /// aliases to their base model. Free Zen models record `$0`, so without a
    /// base rate their included usage estimates to zero and never shows a value
    /// (e.g. `muse-spark-1.2-contributor-free` → `muse-spark-1.2-contributor`).
    private static func rates(for modelID: String) -> Rates? {
        var base = modelID.lowercased()
        if let rates = ratesByModelID[base] { return rates }
        for suffix in ["-free", "-contributor"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            if let rates = ratesByModelID[base] { return rates }
        }
        return nil
    }

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

    /// Token-based USD value for `modelID` from per-1M rates; `0` when unknown.
    static func estimate(
        modelID: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) -> Double {
        guard let rates = rates(for: modelID) else { return 0 }
        let perMillion = 1_000_000.0
        return rates.input * Double(inputTokens) / perMillion
            + rates.output * Double(outputTokens) / perMillion
            + rates.cacheRead * Double(cacheReadTokens) / perMillion
            + rates.cacheWrite * Double(cacheWriteTokens) / perMillion
    }
}
