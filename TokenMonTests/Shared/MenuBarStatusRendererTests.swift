@testable import TokenMon
import XCTest

/// Menu bar label rendering: the selected-provider mode must keep one fixed
/// geometry across providers and data states so the dropdown anchor never
/// shifts on the x axis.
@MainActor
final class MenuBarStatusRendererTests: XCTestCase {
    private func render(
        provider: MonitorProvider,
        showSelectedProvider: Bool,
        snapshot: WeeklyUsageSnapshot? = nil,
        openCode: OpenCodeSnapshot? = nil,
        cursor: CursorSnapshot? = nil,
        claude: ClaudeSnapshot? = nil,
        chatGPT: ChatGPTSnapshot? = nil,
        openRouter: OpenRouterSnapshot? = nil,
        isGrokSignedIn: Bool = false
    ) -> NSImage {
        MenuBarStatusRenderer.image(
            selectedProvider: provider,
            showSelectedProvider: showSelectedProvider,
            snapshot: snapshot,
            openCodeSnapshot: openCode,
            cursorSnapshot: cursor,
            claudeSnapshot: claude,
            chatGPTSnapshot: chatGPT,
            openRouterSnapshot: openRouter,
            isGrokSignedIn: isGrokSignedIn,
            showGrokBar: true,
            showGrokCategories: true,
            showOpenCodeBar: true,
            showCursorBar: true,
            showClaudeBar: true,
            visibleProductIDs: Set(ProductCatalog.knownIDs)
        )
    }

    func testSelectedProviderLabelHasFixedWidthAcrossProviders() {
        let sizes = MonitorProvider.allCases.map {
            render(provider: $0, showSelectedProvider: true).size
        }
        XCTAssertEqual(Set(sizes.map(ObservableSize.init)).count, 1)
    }

    func testSelectedProviderLabelMatchesOverviewSwitchGeometry() {
        let overview = render(provider: .overview, showSelectedProvider: true).size
        let provider = render(provider: .openrouter, showSelectedProvider: true).size
        XCTAssertEqual(overview.width, provider.width)
        XCTAssertEqual(overview.height, provider.height)
    }

    func testSelectedProviderLabelHasFixedWidthWithAndWithoutData() {
        let empty = render(provider: .grok, showSelectedProvider: true).size
        let withData = render(provider: .claude, showSelectedProvider: true, claude: makeClaudeSnapshot()).size
        XCTAssertEqual(empty.width, withData.width)
        XCTAssertEqual(empty.height, withData.height)
    }

    func testCompositeModeRendersVisibleTrackAtZeroUsage() {
        // Regression: the bar graph used to vanish when usage hit 0 (e.g. right
        // after a weekly reset) because the fill was dropped and the track was
        // painted at 0.14 alpha. The track must stay visible so the bar slot is
        // always drawn, even at an empty (0%) fill.
        let zeroSnap = WeeklyUsageSnapshot(usedPercent: 0, remainingPercent: 100)
        let fullSnap = WeeklyUsageSnapshot(usedPercent: 9, remainingPercent: 91)
        let zero = render(
            provider: .grok,
            showSelectedProvider: false,
            snapshot: zeroSnap,
            isGrokSignedIn: true
        )
        let full = render(
            provider: .grok,
            showSelectedProvider: false,
            snapshot: fullSnap,
            isGrokSignedIn: true
        )
        XCTAssertEqual(zero.size.width, full.size.width)
        XCTAssertGreaterThan(hasNonTransparentPixels(zero), 0)
    }

    func testCompositeModeIgnoresSelectedProvider() {
        let grok = render(provider: .grok, showSelectedProvider: false).size
        let openRouter = render(provider: .openrouter, showSelectedProvider: false).size
        XCTAssertEqual(grok.width, openRouter.width)
    }

    private struct ObservableSize: Hashable {
        let width: CGFloat
        let height: CGFloat

        init(_ size: CGSize) {
            width = size.width
            height = size.height
        }
    }

    private func hasNonTransparentPixels(_ image: NSImage) -> Int {
        guard let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else { return 0 }
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 {
                count += 1
            }
        }
        return count
    }

    private func makeClaudeSnapshot() -> ClaudeSnapshot {
        ClaudeSnapshot(
            fetchedAt: Date(),
            fiveHour: ClaudeUsageWindow(usedPercent: 42, resetsAt: nil),
            sevenDay: nil,
            accountEmail: nil
        )
    }
}
