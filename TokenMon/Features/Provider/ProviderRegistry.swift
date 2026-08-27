import Foundation

/// Model-layer registry mapping each `MonitorProvider` to its live poller.
///
/// App wiring (start all pollers, forward child changes) iterates this
/// registry instead of hardcoding each provider, so adding a provider (e.g.
/// OpenRouter) means adding one registry entry.
@MainActor
struct ProviderRegistry {
    private let pollers: [MonitorProvider: any ProviderUsagePoller]

    init(
        grok: UsagePoller,
        openCode: OpenCodeUsagePoller,
        cursor: CursorUsagePoller,
        claude: ClaudeUsagePoller,
        chatGPT: ChatGPTUsagePoller,
        openRouter: OpenRouterUsagePoller,
        grokbot: GrokbotUsagePoller
    ) {
        self.pollers = [
            .grok: grok,
            .opencode: openCode,
            .cursor: cursor,
            .claude: claude,
            .chatgpt: chatGPT,
            .openrouter: openRouter,
            .grokbot: grokbot
        ]
    }

    var all: [(provider: MonitorProvider, poller: any ProviderUsagePoller)] {
        MonitorProvider.allCases.compactMap { provider in
            guard let poller = pollers[provider] else { return nil }
            return (provider, poller)
        }
    }

    func startAll() {
        for (_, poller) in all { poller.start() }
    }
}
