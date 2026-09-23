@testable import TokenMon
import XCTest

final class ProductCatalogTests: XCTestCase {
    private func product(_ id: String, _ pct: Double) -> ProductUsage {
        ProductUsage(id: id, displayName: ProductCatalog.displayName(for: id), percentOfPool: pct)
    }

    func testFilteredKeepsVisibleAboveThreshold() {
        let products = [
            product("chat", 50),
            product("build", 30),
            product("api", 2)
        ]
        let result = ProductCatalog.filtered(
            products,
            visible: ["chat", "build", "api"],
            threshold: 5
        )
        XCTAssertEqual(result.map(\.id), ["chat", "build"])
    }

    func testFilteredExcludesHiddenProducts() {
        let products = [product("chat", 50), product("api", 10)]
        let result = ProductCatalog.filtered(products, visible: ["chat"], threshold: 0)
        XCTAssertEqual(result.map(\.id), ["chat"])
    }

    func testFilteredOrdersByDisplayOrder() {
        let products = [product("other", 30), product("chat", 40), product("build", 20)]
        let result = ProductCatalog.filtered(products, visible: ["other", "chat", "build"], threshold: 0)
        XCTAssertEqual(result.map(\.id), ["chat", "build", "other"])
    }

    func testFilteredEmptyWhenNoneAboveThreshold() {
        let products = [product("chat", 3), product("api", 1)]
        let result = ProductCatalog.filtered(products, visible: ["chat", "api"], threshold: 5)
        XCTAssertTrue(result.isEmpty)
    }

    /// A breakdown-less snapshot arrives as a synthesized "other" slice carrying
    /// the full used%; the panel must show it so the bar is not empty.
    func testPanelProductsKeepsSynthesizedOtherSlice() {
        let synthesized = UsageClient.synthesizeProducts(usedPercent: 64)
        let result = ProductCatalog.panelProducts(synthesized, visible: Set(ProductCatalog.knownIDs))
        XCTAssertEqual(result.map(\.id), ["other"])
        XCTAssertEqual(result.first?.percentOfPool, 64)
    }

    /// The panel keeps any non-zero product but, like the menu bar, drops a
    /// zero-value one so a breakdown-less snapshot does not paint four 0% rows.
    func testPanelProductsDropsZeroValueProducts() {
        let products = [product("chat", 0), product("build", 40)]
        let result = ProductCatalog.panelProducts(products, visible: ["chat", "build"])
        XCTAssertEqual(result.map(\.id), ["build"])
    }

    /// Hidden products stay hidden in the panel.
    func testPanelProductsRespectsVisibility() {
        let products = [product("chat", 40), product("api", 20)]
        let result = ProductCatalog.panelProducts(products, visible: ["chat"])
        XCTAssertEqual(result.map(\.id), ["chat"])
    }
}
