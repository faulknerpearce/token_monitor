@testable import TokenMon
import XCTest

final class UsageErrorTests: XCTestCase {
    func testLocalizedDescriptions() {
        XCTAssertFalse(UsageError.notSignedIn.localizedDescription.isEmpty)
        XCTAssertFalse(UsageError.unauthorized.localizedDescription.isEmpty)
        XCTAssertFalse(UsageError.network("timeout").localizedDescription.isEmpty)
        XCTAssertFalse(UsageError.badResponse("boom").localizedDescription.isEmpty)
    }

    func testEquality() {
        XCTAssertEqual(UsageError.unauthorized, .unauthorized)
        XCTAssertEqual(UsageError.network("x"), .network("x"))
        XCTAssertNotEqual(UsageError.network("x"), .network("y"))
        XCTAssertEqual(UsageError.badResponse("m"), .badResponse("m"))
    }

    func testClientMappingsToCommonAuthCases() {
        XCTAssertEqual(ProviderError.unauthorized(.cursor).usageError, .unauthorized)
        XCTAssertEqual(ProviderError.notSignedIn(.cursor).usageError, .notSignedIn)

        XCTAssertEqual(ProviderError.unauthorized(.openCode).usageError, .unauthorized)
        XCTAssertEqual(ProviderError.notSignedIn(.openCode).usageError, .notSignedIn)

        XCTAssertEqual(ProviderError.unauthorized(.grok).usageError, .unauthorized)
        XCTAssertEqual(ProviderError.notSignedIn(.grok).usageError, .notSignedIn)
    }
}
