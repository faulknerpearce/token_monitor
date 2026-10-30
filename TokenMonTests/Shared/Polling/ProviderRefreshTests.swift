import os
@testable import TokenMon
import XCTest

/// The shared refresh steps: stale results are dropped, a rejected session
/// counts toward the streak, other failures do not, and cancellation is skipped.
@MainActor
final class ProviderRefreshTests: XCTestCase {
    private let logger = Logger(category: "ProviderRefreshTests")

    private final class FakeAuth: PollingAuthSession {
        var sessionGeneration = 0
        var isLive = true
        var failures: [String] = []
        var successes = 0

        func isCurrent(_ generation: Int) -> Bool {
            isLive && generation == sessionGeneration
        }

        func recordAuthFailure(reason: String) -> Bool {
            failures.append(reason)
            return false
        }

        func recordAuthSuccess() {
            successes += 1
        }
    }

    private func run(
        _ auth: FakeAuth,
        fetch: () async throws -> Int,
        published: inout [Int],
        rejected: inout Int,
        errors: inout [String]
    ) async -> PollOutcome {
        var values: [Int] = []
        var rejections = 0
        var reported: [String] = []
        let outcome = await ProviderRefresh.run(
            auth: auth,
            logger: logger,
            label: "Test",
            fetch: fetch,
            publish: { value in
                values.append(value)
                return .success
            },
            onRejected: { rejections += 1 },
            reportError: { reported.append($0) }
        )
        published += values
        rejected += rejections
        errors += reported
        return outcome
    }

    func testSuccessPublishesAndResetsTheStreak() async {
        let auth = FakeAuth()
        var published: [Int] = []
        var rejected = 0
        var errors: [String] = []
        let outcome = await run(auth, fetch: { 7 }, published: &published, rejected: &rejected, errors: &errors)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(published, [7])
        XCTAssertEqual(auth.successes, 1)
        XCTAssertTrue(errors.isEmpty)
    }

    func testResultForAStaleGenerationIsDropped() async {
        let auth = FakeAuth()
        var published: [Int] = []
        var rejected = 0
        var errors: [String] = []
        let outcome = await run(auth, fetch: {
            auth.sessionGeneration += 1
            return 7
        }, published: &published, rejected: &rejected, errors: &errors)
        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(auth.successes, 0)
    }

    func testRejectedSessionCountsTowardTheStreak() async {
        let auth = FakeAuth()
        var published: [Int] = []
        var rejected = 0
        var errors: [String] = []
        let outcome = await run(auth, fetch: { throw ProviderError.unauthorized(.claude) },
                                published: &published, rejected: &rejected, errors: &errors)
        XCTAssertEqual(outcome, .failure(retryAfter: nil))
        XCTAssertEqual(rejected, 1)
        XCTAssertEqual(auth.failures.count, 1)
        XCTAssertEqual(errors.count, 1)
    }

    func testOtherFailuresDoNotCountAgainstTheSession() async {
        let auth = FakeAuth()
        var published: [Int] = []
        var rejected = 0
        var errors: [String] = []
        let outcome = await run(auth, fetch: { throw URLError(.notConnectedToInternet) },
                                published: &published, rejected: &rejected, errors: &errors)
        XCTAssertEqual(outcome, .failure(retryAfter: nil))
        XCTAssertEqual(rejected, 0)
        XCTAssertTrue(auth.failures.isEmpty)
        XCTAssertEqual(errors.count, 1)
    }

    func testFailureForAStaleGenerationIsIgnored() async {
        let auth = FakeAuth()
        var published: [Int] = []
        var rejected = 0
        var errors: [String] = []
        let outcome = await run(auth, fetch: {
            auth.sessionGeneration += 1
            throw ProviderError.unauthorized(.claude)
        }, published: &published, rejected: &rejected, errors: &errors)
        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(auth.failures.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    func testCancellationIsSkipped() async {
        let auth = FakeAuth()
        var published: [Int] = []
        var rejected = 0
        var errors: [String] = []
        let outcome = await run(auth, fetch: { throw CancellationError() },
                                published: &published, rejected: &rejected, errors: &errors)
        XCTAssertEqual(outcome, .skipped)
        XCTAssertTrue(errors.isEmpty)
    }
}
