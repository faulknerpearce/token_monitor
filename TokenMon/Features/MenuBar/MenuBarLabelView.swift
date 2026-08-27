import AppKit
import SwiftUI

struct MenuBarLabelView: View {
    let selectedProvider: MonitorProvider
    let showSelectedProvider: Bool
    let snapshot: WeeklyUsageSnapshot?
    let openCodeSnapshot: OpenCodeSnapshot?
    let cursorSnapshot: CursorSnapshot?
    let claudeSnapshot: ClaudeSnapshot?
    let chatGPTSnapshot: ChatGPTSnapshot?
    let openRouterSnapshot: OpenRouterSnapshot?
    let grokbotSnapshot: GrokbotSnapshot?
    let isGrokSignedIn: Bool
    let showGrokBar: Bool
    let showGrokCategories: Bool
    let showOpenCodeBar: Bool
    let showCursorBar: Bool
    let showClaudeBar: Bool
    let showGrokbotBar: Bool
    let providerOrder: [MonitorProvider]
    let visibleProductIDs: Set<String>

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let image = MenuBarStatusRenderer.image(
            selectedProvider: selectedProvider,
            showSelectedProvider: showSelectedProvider,
            snapshot: snapshot,
            openCodeSnapshot: openCodeSnapshot,
            cursorSnapshot: cursorSnapshot,
            claudeSnapshot: claudeSnapshot,
            chatGPTSnapshot: chatGPTSnapshot,
            openRouterSnapshot: openRouterSnapshot,
            grokbotSnapshot: grokbotSnapshot,
            isGrokSignedIn: isGrokSignedIn,
            showGrokBar: showGrokBar,
            showGrokCategories: showGrokCategories,
            showOpenCodeBar: showOpenCodeBar,
            showCursorBar: showCursorBar,
            showClaudeBar: showClaudeBar,
            showGrokbotBar: showGrokbotBar,
            providerOrder: providerOrder,
            visibleProductIDs: visibleProductIDs
        )
        Image(nsImage: image)
            .renderingMode(.original)
            .frame(width: image.size.width, height: image.size.height)
            .transaction { $0.animation = nil }
            .animation(nil, value: colorScheme)
    }
}
