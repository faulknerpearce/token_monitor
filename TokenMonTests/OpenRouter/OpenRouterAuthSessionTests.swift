@testable import TokenMon
import XCTest

@MainActor
final class OpenRouterAuthSessionTests: XCTestCase {
    private func makeSession() -> (OpenRouterAuthSession, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (OpenRouterAuthSession(directory: dir), dir)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func testStartsSignedOut() {
        let (auth, dir) = makeSession()
        defer { cleanup(dir) }
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertNil(auth.apiKey())
    }

    func testSaveRejectsNonOpenRouterKey() {
        let (auth, dir) = makeSession()
        defer { cleanup(dir) }
        XCTAssertFalse(auth.saveAPIKey("not-a-key"))
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNotNil(auth.lastAuthError)

        XCTAssertTrue(auth.saveAPIKey("  sk-or-v1-abc123  \n"))
        XCTAssertEqual(auth.apiKey(), "sk-or-v1-abc123")
        XCTAssertTrue(auth.isSignedIn)
        XCTAssertFalse(auth.needsSignIn)
    }

    func testSavePersistsAcrossInstances() {
        let (auth, dir) = makeSession()
        defer { cleanup(dir) }
        auth.saveAPIKey("sk-or-v1-persisted")

        let reloaded = OpenRouterAuthSession(directory: dir)
        reloaded.refreshFromDisk()
        XCTAssertEqual(reloaded.apiKey(), "sk-or-v1-persisted")
        XCTAssertTrue(reloaded.isSignedIn)
    }

    func testSignOutClearsKey() {
        let (auth, dir) = makeSession()
        defer { cleanup(dir) }
        auth.saveAPIKey("sk-or-v1-abc")
        auth.signOut()
        XCTAssertNil(auth.apiKey())
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.needsSignIn)
    }

    func testMarkSessionInvalidKeepsKeyButPromptsReauth() {
        let (auth, dir) = makeSession()
        defer { cleanup(dir) }
        auth.saveAPIKey("sk-or-v1-abc")
        auth.markSessionInvalid(reason: "401")
        XCTAssertEqual(auth.apiKey(), "sk-or-v1-abc")
        XCTAssertTrue(auth.needsSignIn)
        XCTAssertNotNil(auth.lastAuthError)
    }

    /// A rejected key must not be considered current, so the poller stops probing
    /// until a new key is saved (audit: OpenRouter invalidation contract).
    func testRejectedKeyIsNotCurrentUntilReplaced() {
        let (auth, dir) = makeSession()
        defer { cleanup(dir) }
        auth.saveAPIKey("sk-or-v1-abc")
        let generation = auth.sessionGeneration
        XCTAssertTrue(auth.isCurrent(generation))

        auth.markSessionInvalid(reason: "401")
        XCTAssertFalse(auth.isCurrent(generation))
        // The key stays on disk for the replace-key field, but polls must stop.
        XCTAssertEqual(auth.apiKey(), "sk-or-v1-abc")

        XCTAssertTrue(auth.saveAPIKey("sk-or-v1-new"))
        XCTAssertTrue(auth.isCurrent(auth.sessionGeneration))
        XCTAssertFalse(auth.isCurrent(generation))
    }
}
