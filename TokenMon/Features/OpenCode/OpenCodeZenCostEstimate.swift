import Foundation

/// Token-based USD value for OpenCode models when the local DB records `$0`.
///
/// The OpenCode plan providers bill at different published rates, so the lookup
/// is provider-aware:
/// - `opencode-go` uses the official OpenCode **Go** price list
///   (`https://opencode.ai/docs/go/`, per 1M tokens). DeepSeek models bill at
///   peak/off-peak rates; the off-peak (lower) rate is used here because the
///   recorded cost wins whenever a row is actually billed.
/// - `opencode` (Zen) uses the official OpenCode **Zen** pay-as-you-go price list
///   (`https://opencode.ai/docs/zen/`, per 1M tokens).
/// - Free Zen aliases (`-free` / `-contributor`) resolve to their paid base model
///   within the provider's table first, then to the shared catalogue.
///
/// The shared catalogue (`fallbackRates`) is the OpenRouter-sourced list used for
/// free-model paid-equivalents that have no plan entry and for OpenRouter's own
/// `$0` rows (`estimate(modelID:)`). Recorded cost always wins over any estimate.
enum OpenCodeZenCostEstimate {
    /// Date `goRates` and `zenRates` were checked against the published Go and
    /// Zen price pages (base context tier, off-peak DeepSeek).
    static let ratesVerifiedOn = "2026-10-10"

    /// Rates per 1M tokens (input, output, cacheRead, cacheWrite).
    struct Rates {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheWrite: Double
    }

    /// Official OpenCode **Go** rates per 1M tokens (`opencode.ai/docs/go`).
    /// Only the models Go exposes, using off-peak DeepSeek rates and the base
    /// (≤ 256K / ≤ 272K token) tiers.
    private static let goRates: [String: Rates] = [
        "glm-5.3-flash": Rates(input: 0.15, output: 0.50, cacheRead: 0.03, cacheWrite: 0),
        "glm-5.3": Rates(input: 1.40, output: 4.40, cacheRead: 0.26, cacheWrite: 0),
        "glm-5.2": Rates(input: 1.40, output: 4.40, cacheRead: 0.26, cacheWrite: 0),
        "kimi-k3": Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 0),
        "kimi-k2.7-code": Rates(input: 0.95, output: 4.00, cacheRead: 0.19, cacheWrite: 0),
        "kimi-k2.6": Rates(input: 0.95, output: 4.00, cacheRead: 0.16, cacheWrite: 0),
        "longcat-2.0": Rates(input: 0.30, output: 1.20, cacheRead: 0.006, cacheWrite: 0),
        "mimo-v2.6-flash": Rates(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0),
        "mimo-v2.6-pro": Rates(input: 0.435, output: 0.87, cacheRead: 0.003625, cacheWrite: 0),
        "mimo-v2.5": Rates(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0),
        "mimo-v2.5-pro": Rates(input: 0.435, output: 0.87, cacheRead: 0.003625, cacheWrite: 0),
        "minimax-m3": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "minimax-m2.7": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0.375),
        "muse-spark-1.3-contributor": Rates(input: 0.10, output: 0.20, cacheRead: 0.002, cacheWrite: 0),
        "muse-spark-1.2-contributor": Rates(input: 0.10, output: 0.20, cacheRead: 0.002, cacheWrite: 0),
        "qwen3.8-max": Rates(input: 2.00, output: 6.00, cacheRead: 0.25, cacheWrite: 2.50),
        "qwen3.8-flash": Rates(input: 0.15, output: 0.47, cacheRead: 0.016, cacheWrite: 0.20),
        "qwen3.7-plus": Rates(input: 0.40, output: 1.60, cacheRead: 0.04, cacheWrite: 0.50),
        // DeepSeek off-peak (peak doubles input/output and cache read).
        "deepseek-v4.1-flash": Rates(input: 0.15, output: 0.60, cacheRead: 0.003, cacheWrite: 0),
        "deepseek-v4-pro": Rates(input: 0.66, output: 1.98, cacheRead: 0.022, cacheWrite: 0),
        "deepseek-v4-flash": Rates(input: 0.15, output: 0.60, cacheRead: 0.003, cacheWrite: 0),
        "deepseek-v4-flash-vision-exp": Rates(input: 0.15, output: 0.60, cacheRead: 0.003, cacheWrite: 0),
        "hy4-preview": Rates(input: 0.834, output: 2.501, cacheRead: 0.042, cacheWrite: 0),
        "hy3": Rates(input: 0.14, output: 0.58, cacheRead: 0.035, cacheWrite: 0),
        "space-bunny": Rates(input: 0.15, output: 0.60, cacheRead: 0.03, cacheWrite: 0),
        "grok-4.7": Rates(input: 2.00, output: 6.00, cacheRead: 0.50, cacheWrite: 0),
        "grok-4.6": Rates(input: 2.00, output: 6.00, cacheRead: 0.50, cacheWrite: 0),
        "gpt-6-luna": Rates(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
        "gpt-5.6-luna": Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25),
        "claude-haiku-5-5": Rates(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)
    ]

    /// Official OpenCode **Zen** pay-as-you-go rates per 1M tokens
    /// (`opencode.ai/docs/zen`). Uses the base context tier where a model prices
    /// higher beyond a token threshold.
    private static let zenRates: [String: Rates] = [
        "minimax-m3": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "minimax-m2.7": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "minimax-m2.5": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "glm-5.3-flash": Rates(input: 0.15, output: 0.50, cacheRead: 0.03, cacheWrite: 0),
        "glm-5.3": Rates(input: 1.40, output: 4.40, cacheRead: 0.26, cacheWrite: 0),
        "glm-5.2": Rates(input: 1.40, output: 4.40, cacheRead: 0.26, cacheWrite: 0),
        "glm-5.1": Rates(input: 1.40, output: 4.40, cacheRead: 0.26, cacheWrite: 0),
        "glm-5": Rates(input: 1.00, output: 3.20, cacheRead: 0.20, cacheWrite: 0),
        "kimi-k2.7-code": Rates(input: 0.95, output: 4.00, cacheRead: 0.19, cacheWrite: 0),
        "kimi-k3": Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 0),
        "kimi-k2.6": Rates(input: 0.95, output: 4.00, cacheRead: 0.16, cacheWrite: 0),
        "kimi-k2.5": Rates(input: 0.60, output: 3.00, cacheRead: 0.10, cacheWrite: 0),
        "qwen3.8-max": Rates(input: 2.00, output: 6.00, cacheRead: 0.25, cacheWrite: 2.50),
        "qwen3.8-flash": Rates(input: 0.15, output: 0.47, cacheRead: 0.016, cacheWrite: 0.20),
        "qwen3.7-max": Rates(input: 2.50, output: 7.50, cacheRead: 0.50, cacheWrite: 3.125),
        "qwen3.7-plus": Rates(input: 0.40, output: 1.60, cacheRead: 0.04, cacheWrite: 0.50),
        "qwen3.6-plus": Rates(input: 0.50, output: 3.00, cacheRead: 0.05, cacheWrite: 0.625),
        "qwen3.5-plus": Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25),
        "deepseek-v4.1-flash": Rates(input: 0.30, output: 1.20, cacheRead: 0.006, cacheWrite: 0),
        "deepseek-v4-pro": Rates(input: 1.74, output: 3.48, cacheRead: 0.145, cacheWrite: 0),
        "deepseek-v4-flash": Rates(input: 0.14, output: 0.28, cacheRead: 0.028, cacheWrite: 0),
        "deepseek-v4-flash-vision-exp": Rates(input: 0.14, output: 0.28, cacheRead: 0.028, cacheWrite: 0),
        "claude-fable-5-1": Rates(input: 10.00, output: 50.00, cacheRead: 0.25, cacheWrite: 12.50),
        "claude-fable-5": Rates(input: 10.00, output: 50.00, cacheRead: 1.00, cacheWrite: 12.50),
        "claude-opus-5-5": Rates(input: 4.00, output: 20.00, cacheRead: 0.20, cacheWrite: 5.00),
        "claude-opus-5": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-8": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-7": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-6": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-opus-4-5": Rates(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-sonnet-5-5": Rates(input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50),
        "claude-sonnet-5": Rates(input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50),
        "claude-haiku-5-5": Rates(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
        "claude-sonnet-4-6": Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75),
        "claude-sonnet-4-5": Rates(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75),
        "claude-haiku-4-5": Rates(input: 1.00, output: 5.00, cacheRead: 0.10, cacheWrite: 1.25),
        "gemini-3.8-flash": Rates(input: 1.50, output: 7.50, cacheRead: 0.15, cacheWrite: 0),
        "gemini-3.7-flash": Rates(input: 1.50, output: 7.50, cacheRead: 0.15, cacheWrite: 0),
        "gemini-3.6-flash": Rates(input: 1.50, output: 7.50, cacheRead: 0.15, cacheWrite: 0),
        "gemini-3.5-flash": Rates(input: 1.50, output: 9.00, cacheRead: 0.15, cacheWrite: 0),
        "gemini-3.5-flash-lite": Rates(input: 0.30, output: 2.50, cacheRead: 0.03, cacheWrite: 0),
        "gemini-3.1-pro": Rates(input: 2.00, output: 12.00, cacheRead: 0.20, cacheWrite: 0),
        "gemini-3-flash": Rates(input: 0.50, output: 3.00, cacheRead: 0.05, cacheWrite: 0),
        "grok-4.7": Rates(input: 2.00, output: 6.00, cacheRead: 0.50, cacheWrite: 0),
        "grok-4.6": Rates(input: 2.00, output: 6.00, cacheRead: 0.50, cacheWrite: 0),
        "grok-4.5": Rates(input: 2.00, output: 6.00, cacheRead: 0.30, cacheWrite: 0),
        "grok-build-0.1": Rates(input: 1.00, output: 2.00, cacheRead: 0.20, cacheWrite: 0),
        "muse-spark-1.3": Rates(input: 1.25, output: 4.25, cacheRead: 0.15, cacheWrite: 0),
        "muse-spark-1.2": Rates(input: 1.25, output: 4.25, cacheRead: 0.15, cacheWrite: 0),
        "gpt-6-astra": Rates(input: 10.00, output: 50.00, cacheRead: 1.00, cacheWrite: 12.50),
        "gpt-6-sol": Rates(input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50),
        "gpt-6.1-sol": Rates(input: 2.00, output: 10.00, cacheRead: 0.10, cacheWrite: 2.50),
        "gpt-6-luna": Rates(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
        "gpt-5.6-sol": Rates(input: 4.00, output: 20.00, cacheRead: 0.40, cacheWrite: 5.00),
        "gpt-5.6-terra": Rates(input: 2.00, output: 12.00, cacheRead: 0.20, cacheWrite: 2.50),
        "gpt-5.6-luna": Rates(input: 0.20, output: 1.20, cacheRead: 0.02, cacheWrite: 0.25),
        "gpt-5.5": Rates(input: 5.00, output: 30.00, cacheRead: 0.50, cacheWrite: 0),
        "gpt-5-codex": Rates(input: 1.07, output: 8.50, cacheRead: 0.107, cacheWrite: 0),
        "gpt-5.5-pro": Rates(input: 30.00, output: 180.00, cacheRead: 30.00, cacheWrite: 0),
        "gpt-5.4": Rates(input: 2.50, output: 15.00, cacheRead: 0.25, cacheWrite: 0),
        "gpt-5.4-pro": Rates(input: 30.00, output: 180.00, cacheRead: 30.00, cacheWrite: 0),
        "gpt-5.4-mini": Rates(input: 0.75, output: 4.50, cacheRead: 0.075, cacheWrite: 0),
        "gpt-5.4-nano": Rates(input: 0.20, output: 1.25, cacheRead: 0.02, cacheWrite: 0),
        "gpt-5.3-codex-spark": Rates(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.3-codex": Rates(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.2": Rates(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.2-codex": Rates(input: 1.75, output: 14.00, cacheRead: 0.175, cacheWrite: 0),
        "gpt-5.1": Rates(input: 1.07, output: 8.50, cacheRead: 0.107, cacheWrite: 0),
        "gpt-5.1-codex": Rates(input: 1.07, output: 8.50, cacheRead: 0.107, cacheWrite: 0),
        "gpt-5.1-codex-max": Rates(input: 1.25, output: 10.00, cacheRead: 0.125, cacheWrite: 0),
        "gpt-5.1-codex-mini": Rates(input: 0.25, output: 2.00, cacheRead: 0.025, cacheWrite: 0),
        "gpt-5": Rates(input: 1.07, output: 8.50, cacheRead: 0.107, cacheWrite: 0),
        "gpt-5-nano": Rates(input: 0.05, output: 0.40, cacheRead: 0.005, cacheWrite: 0)
    ]

    /// Shared catalogue rates per 1M tokens (input, output, cacheRead, cacheWrite),
    /// taken from OpenRouter's public catalogue (`https://openrouter.ai/api/v1/models`)
    /// for every model it lists. Free Zen models record `$0`, so these rates give
    /// their included usage a value. Also backs OpenRouter's own `$0` rows.
    private static let fallbackRates: [String: Rates] = [
        // Free Zen models: paid-equivalent value, not an OpenCode charge.
        "big-pickle": Rates(input: 0.30, output: 1.20, cacheRead: 0.06, cacheWrite: 0),
        "mimo-v2.5-free": Rates(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0),
        "mimo-v2.6-flash-free": Rates(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheWrite: 0),
        "laguna-s-2.1-free": Rates(input: 0.09, output: 0.18, cacheRead: 0.009, cacheWrite: 0),
        "ling-3.0-flash-free": Rates(input: 0.021, output: 0.063, cacheRead: 0.0042, cacheWrite: 0),
        "north-mini-code-free": Rates(input: 0.20, output: 0.80, cacheRead: 0.02, cacheWrite: 0),
        "nemotron-3-ultra-free": Rates(input: 0.50, output: 2.20, cacheRead: 0.10, cacheWrite: 0),
        "nemotron-3.5-lightning-free": Rates(input: 0.06, output: 0.16, cacheRead: 0.03, cacheWrite: 0),
        "hy3-free": Rates(input: 0.132, output: 0.528, cacheRead: 0.033, cacheWrite: 0),
        "space-bunny": Rates(input: 0.15, output: 0.60, cacheRead: 0.03, cacheWrite: 0),
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

    /// Provider-specific tables; `opencode` and `opencode-go` bill at different
    /// published rates, so each is checked before the shared catalogue.
    private static let ratesByProvider: [String: [String: Rates]] = [
        "opencode-go": goRates,
        "opencode": zenRates
    ]

    /// Candidate ids for a model, most specific first: the id itself, then it with
    /// one billing suffix (`-contributor`, then `-free`) stripped, repeatedly
    /// (e.g. `muse-spark-1.2-contributor-free` → `…-contributor` → `muse-spark-1.2`).
    private static func modelIDVariants(_ modelID: String) -> [String] {
        var result = [modelID.lowercased()]
        var current = result[0]
        while true {
            if current.hasSuffix("-contributor") {
                current = String(current.dropLast("-contributor".count))
            } else if current.hasSuffix("-free") {
                current = String(current.dropLast("-free".count))
            } else {
                break
            }
            result.append(current)
        }
        return result
    }

    private static func lookup(_ table: [String: Rates], variants: [String]) -> Rates? {
        for variant in variants {
            if let rates = table[variant] { return rates }
        }
        return nil
    }

    /// Rates for a provider/model, preferring the provider's published table and
    /// falling back to the shared catalogue for free-model paid-equivalents.
    /// Variants are tried most-specific first across both tables, so a stripped
    /// base rate never outranks a more specific free-model entry.
    static func rates(providerID: String, modelID: String) -> Rates? {
        let providerTable = ratesByProvider[providerID.lowercased()]
        for variant in modelIDVariants(modelID) {
            if let rates = providerTable?[variant] { return rates }
            if let rates = fallbackRates[variant] { return rates }
        }
        return nil
    }

    /// Shared-catalogue rates for a bare model id (used by OpenRouter's `$0` rows).
    static func catalogRates(modelID: String) -> Rates? {
        lookup(fallbackRates, variants: modelIDVariants(modelID))
    }

    static func isPlanProvider(_ providerID: String) -> Bool {
        providerID.lowercased() == "opencode" || providerID.lowercased() == "opencode-go"
    }

    /// Prefer recorded cost; otherwise calculate value from the published rate.
    /// `isUnpriced` marks a `$0` plan row with tokens whose model has no rate,
    /// so its usage carries no value.
    static func billableCostUSD(
        providerID: String,
        modelID: String,
        recordedCostUSD: Double,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) -> (cost: Double, isEstimated: Bool, isUnpriced: Bool) {
        if recordedCostUSD > 0 {
            return (recordedCostUSD, false, false)
        }
        guard isPlanProvider(providerID) else {
            return (0, false, false)
        }
        let tokens = inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        guard tokens > 0 else {
            return (0, false, false)
        }
        guard rates(providerID: providerID, modelID: modelID) != nil else {
            return (0, false, true)
        }
        let value = estimate(
            providerID: providerID,
            modelID: modelID,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
        // Any token-derived value is an estimate (recorded cost was zero), so it
        // carries the `~` prefix.
        return (value, value > 0, false)
    }

    /// Token-based USD value for a `providerID`/`modelID` from per-1M rates; `0` when unknown.
    static func estimate(
        providerID: String,
        modelID: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) -> Double {
        guard let rates = rates(providerID: providerID, modelID: modelID) else { return 0 }
        return value(rates: rates, inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
    }

    /// Token-based USD value from the shared catalogue only, for a bare model id
    /// (OpenRouter's `$0` fallback); `0` when unknown.
    static func estimate(
        modelID: String,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) -> Double {
        guard let rates = catalogRates(modelID: modelID) else { return 0 }
        return value(rates: rates, inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
    }

    private static func value(
        rates: Rates,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64,
        cacheWriteTokens: Int64
    ) -> Double {
        let perMillion = 1_000_000.0
        return rates.input * Double(inputTokens) / perMillion
            + rates.output * Double(outputTokens) / perMillion
            + rates.cacheRead * Double(cacheReadTokens) / perMillion
            + rates.cacheWrite * Double(cacheWriteTokens) / perMillion
    }
}
