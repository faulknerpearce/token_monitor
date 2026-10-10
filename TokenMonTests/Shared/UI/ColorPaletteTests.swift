import AppKit
@testable import TokenMon
import XCTest

final class ColorPaletteTests: XCTestCase {
    func testSRGBComponentsRoundTrip() {
        let srgb = SRGB(red: 0.5, green: 0.25, blue: 0.75, alpha: 0.4)
        XCTAssertEqual(srgb.red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(srgb.green, 0.25, accuracy: 0.0001)
        XCTAssertEqual(srgb.blue, 0.75, accuracy: 0.0001)
        XCTAssertEqual(srgb.alpha, 0.4, accuracy: 0.0001)
    }

    func testSRGBConversionHelpers() {
        let srgb = SRGB(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        let color = srgb.color
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        NSColor(color).usingColorSpace(.deviceRGB)?.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(Double(red), 0.25, accuracy: 0.001)
        XCTAssertEqual(Double(green), 0.5, accuracy: 0.001)
        XCTAssertEqual(Double(blue), 0.75, accuracy: 0.001)
    }

    func testProductColorSRGB() {
        XCTAssertEqual(ProductColor.build.sRGB.blue, 1.0, accuracy: 0.0001)
        XCTAssertEqual(ProductColor.chat.sRGB.red, 0.11, accuracy: 0.0001)
    }
}
