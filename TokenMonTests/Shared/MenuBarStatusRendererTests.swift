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
        grokbot: GrokbotSnapshot? = nil,
        showGrokbotBar: Bool = false,
        isGrokSignedIn: Bool = false,
        providerOrder: [MonitorProvider] = MonitorProvider.usageProviders
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
            grokbotSnapshot: grokbot,
            isGrokSignedIn: isGrokSignedIn,
            showGrokBar: true,
            showGrokCategories: true,
            showOpenCodeBar: true,
            showCursorBar: true,
            showClaudeBar: true,
            showGrokbotBar: showGrokbotBar,
            providerOrder: providerOrder,
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
        // The track stays visible at 0% usage, so the bar slot is still drawn.
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

    func testCompositeModeGrokbotBarWidensLabel() {
        let without = render(provider: .grok, showSelectedProvider: false, showGrokbotBar: false).size
        let withBar = render(
            provider: .grok,
            showSelectedProvider: false,
            grokbot: GrokbotSnapshot.preview,
            showGrokbotBar: true
        ).size
        XCTAssertGreaterThan(withBar.width, without.width)
        XCTAssertEqual(withBar.height, without.height)
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

    // MARK: - Provider hit regions

    /// Composite layout exposes one non-overlapping region per visible provider
    /// segment, in provider order, so a bar click maps back to its provider.
    func testCompositeRegionsFollowProviderOrder() {
        let status = renderStatus(provider: .grok, showSelectedProvider: false, showGrokbotBar: true)
        XCTAssertEqual(
            status.regions.map(\.provider),
            [.grok, .cursor, .opencode, .claude, .grokbot]
        )
        for (index, region) in status.regions.enumerated() {
            XCTAssertLessThanOrEqual(region.minX, region.maxX)
            if index > 0 {
                XCTAssertLessThanOrEqual(status.regions[index - 1].maxX, region.minX)
            }
            let mid = (region.minX + region.maxX) / 2
            XCTAssertEqual(
                MenuBarStatusRenderer.provider(atX: mid, in: status.regions),
                region.provider
            )
        }
        let last = status.regions.last!
        XCTAssertNil(MenuBarStatusRenderer.provider(atX: last.maxX + 50, in: status.regions))
        XCTAssertNil(MenuBarStatusRenderer.provider(atX: -5, in: status.regions))
    }

    /// The single-provider label is one region covering the whole bar.
    func testSelectedProviderModeHasSingleRegion() {
        let status = renderStatus(
            provider: .claude,
            showSelectedProvider: true,
            claude: makeClaudeSnapshot()
        )
        XCTAssertEqual(status.regions.map(\.provider), [.claude])
        XCTAssertEqual(status.regions.first?.minX, 0)
        XCTAssertEqual(
            status.regions.first?.maxX ?? 0,
            status.image.size.width,
            accuracy: 0.001
        )
    }

    /// A disabled provider must not leave a frozen segment in the composite.
    func testCompositeOmitsDisabledProviderRegion() {
        let enabled = renderStatus(
            provider: .grok,
            showSelectedProvider: false,
            claude: makeClaudeSnapshot()
        )
        XCTAssertTrue(enabled.regions.map(\.provider).contains(.claude))

        let disabled = renderStatus(
            provider: .grok,
            showSelectedProvider: false,
            claude: makeClaudeSnapshot(),
            enabledProviders: Set(MonitorProvider.usageProviders).subtracting([.claude])
        )
        XCTAssertFalse(disabled.regions.map(\.provider).contains(.claude))
    }

    private func renderStatus(
        provider: MonitorProvider,
        showSelectedProvider: Bool,
        claude: ClaudeSnapshot? = nil,
        grokbot: GrokbotSnapshot? = nil,
        showGrokbotBar: Bool = false,
        enabledProviders: Set<MonitorProvider> = Set(MonitorProvider.usageProviders)
    ) -> MenuBarStatusRenderer.RenderedStatus {
        MenuBarStatusRenderer.render(
            selectedProvider: provider,
            showSelectedProvider: showSelectedProvider,
            snapshot: nil,
            openCodeSnapshot: nil,
            cursorSnapshot: nil,
            claudeSnapshot: claude,
            chatGPTSnapshot: nil,
            openRouterSnapshot: nil,
            grokbotSnapshot: grokbot,
            isGrokSignedIn: false,
            showGrokBar: true,
            showGrokCategories: true,
            showOpenCodeBar: true,
            showCursorBar: true,
            showClaudeBar: true,
            showGrokbotBar: showGrokbotBar,
            providerOrder: MonitorProvider.usageProviders,
            visibleProductIDs: Set(ProductCatalog.knownIDs),
            enabledProviders: enabledProviders
        )
    }
}
