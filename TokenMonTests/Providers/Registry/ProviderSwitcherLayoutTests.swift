import AppKit
import SwiftUI
@testable import TokenMon
import XCTest

/// The tab grid's outer border lines up with a panel card's edges at the panel
/// content width, for every provider count and display scale.
@MainActor
final class ProviderSwitcherLayoutTests: XCTestCase {
    private let width: CGFloat = MenuBarPanelView.panelWidth - 24

    func testRowsPadTheLastRowToFullWidth() {
        let all: [MonitorProvider] = [.overview] + MonitorProvider.usageProviders
        for count in 1...all.count {
            let rows = ProviderSwitcherView.rows(for: Array(all.prefix(count)))
            XCTAssertTrue(rows.allSatisfy { $0.count == ProviderSwitcherView.maxPerRow })
            XCTAssertEqual(rows.joined().compactMap { $0 }, Array(all.prefix(count)))
        }
    }

    func testGridEdgesMatchCardEdgesForEveryProviderCount() throws {
        let all: [MonitorProvider] = [.overview] + MonitorProvider.usageProviders
        for scale in [1.0, 2.0] {
            let card = try inkExtent(of: PanelCard { Text("x") }.frame(width: width), scale: scale)
            for count in 1...all.count {
                let grid = try inkExtent(
                    of: ProviderSwitcherView(providers: Array(all.prefix(count)), selection: .constant(.overview))
                        .frame(width: width),
                    scale: scale
                )
                XCTAssertEqual(grid.minX, card.minX, accuracy: 0.01, "left edge, \(count) tabs @\(scale)x")
                XCTAssertEqual(grid.maxX, card.maxX, accuracy: 0.01, "right edge, \(count) tabs @\(scale)x")
            }
        }
    }

    /// Leftmost and rightmost drawn x, in points relative to the view's frame.
    private func inkExtent(of view: some View, scale: CGFloat) throws -> (minX: CGFloat, maxX: CGFloat) {
        let margin: CGFloat = 8
        let renderer = ImageRenderer(content: view.padding(margin).environment(\.colorScheme, .light))
        renderer.scale = scale
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        var minPixel = Int.max
        var maxPixel = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let alpha = rep.colorAt(x: x, y: y)?.alphaComponent, alpha > 0.02 else { continue }
                minPixel = min(minPixel, x)
                maxPixel = max(maxPixel, x + 1)
            }
        }
        XCTAssertLessThan(minPixel, maxPixel, "nothing drawn")
        return (CGFloat(minPixel) / scale - margin, CGFloat(maxPixel) / scale - margin)
    }
}
