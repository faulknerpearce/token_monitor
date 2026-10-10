@testable import TokenMon
import XCTest

final class ChatGPTAccessTokenCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let usageBody = Data(#"{"rate_limit": {"primary_window": {"used_percent": 12}}}"#.utf8)

    func testTokenIsReusedUntilRenewDeadline() async throws {
        let calls = ExchangeCounter()
        let cache = ChatGPTAccessTokenCache()
        let token = Self.jwt(expiresAt: now.addingTimeInterval(3600))
        let client = makeClient(cache: cache, calls: calls, token: token) { _ in self.usageBody }

        _ = try await client.fetchUsage(now: now)
        _ = try await client.fetchUsage(now: now.addingTimeInterval(60))
        var sessions = await calls.sessions
        XCTAssertEqual(sessions, 1)

        _ = try await client.fetchUsage(now: now.addingTimeInterval(ChatGPTAccessTokenCache.sessionRenewInterval + 1))
        sessions = await calls.sessions
        XCTAssertEqual(sessions, 2)
        let usages = await calls.usages
        XCTAssertEqual(usages, 3)
    }

    func testSessionCookiesAreReturnedOnlyWithAnExchange() async throws {
        let cache = ChatGPTAccessTokenCache()
        let client = makeClient(cache: cache, calls: ExchangeCounter(), token: Self.jwt(expiresAt: now.addingTimeInterval(3600))) { _ in
            self.usageBody
        }
        let first = try await client.fetchUsage(now: now)
        XCTAssertEqual(first.setCookieHeaders, ["session=renewed"])
        let second = try await client.fetchUsage(now: now.addingTimeInterval(60))
        XCTAssertEqual(second.setCookieHeaders, [])
    }

    func testRejectedCachedTokenIsReexchangedOnce() async throws {
        let calls = ExchangeCounter()
        let cache = ChatGPTAccessTokenCache()
        let token = Self.jwt(expiresAt: now.addingTimeInterval(3600))
        let rejectSecond = RejectFlag()
        let client = makeClient(cache: cache, calls: calls, token: token) { usageIndex in
            if usageIndex == 2, await rejectSecond.take() { throw ProviderError.unauthorized(.chatGPT) }
            return self.usageBody
        }
        _ = try await client.fetchUsage(now: now)
        let fetch = try await client.fetchUsage(now: now.addingTimeInterval(60))
        XCTAssertEqual(fetch.response.primary?.usedPercent ?? -1, 12, accuracy: 0.001)
        let sessions = await calls.sessions
        XCTAssertEqual(sessions, 2)
    }

    func testValidUntilHonoursTokenExpiryAndRenewInterval() {
        let shortLived = Self.jwt(expiresAt: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(
            ChatGPTAccessTokenCache.validUntil(accessToken: shortLived, now: now),
            now.addingTimeInterval(10 * 60 - ChatGPTAccessTokenCache.expiryMargin)
        )
        let longLived = Self.jwt(expiresAt: now.addingTimeInterval(86400))
        XCTAssertEqual(
            ChatGPTAccessTokenCache.validUntil(accessToken: longLived, now: now),
            now.addingTimeInterval(ChatGPTAccessTokenCache.sessionRenewInterval)
        )
        XCTAssertEqual(
            ChatGPTAccessTokenCache.validUntil(accessToken: "opaque", now: now),
            now.addingTimeInterval(ChatGPTAccessTokenCache.unknownExpiryLifetime)
        )
    }

    func testCacheIsScopedToKey() {
        let cache = ChatGPTAccessTokenCache()
        cache.store("tok", forKey: "1", validUntil: now.addingTimeInterval(60))
        XCTAssertEqual(cache.token(forKey: "1", now: now), "tok")
        XCTAssertNil(cache.token(forKey: "2", now: now))
        XCTAssertNil(cache.token(forKey: "1", now: now.addingTimeInterval(61)))
    }

    /// The poller builds a client per poll from the stored header, which holds
    /// the cookie renewed by the previous exchange; the token is still reused.
    func testTokenIsReusedAfterCookieRenewal() async throws {
        let calls = ExchangeCounter()
        let cache = ChatGPTAccessTokenCache()
        let token = Self.jwt(expiresAt: now.addingTimeInterval(3600))
        let first = makeClient(cache: cache, calls: calls, token: token, cookieHeader: "session=old") { _ in self.usageBody }
        let fetch = try await first.fetchUsage(now: now)
        XCTAssertEqual(fetch.setCookieHeaders, ["session=renewed"])

        let second = makeClient(cache: cache, calls: calls, token: token, cookieHeader: "session=renewed") { _ in self.usageBody }
        _ = try await second.fetchUsage(now: now.addingTimeInterval(60))

        let sessions = await calls.sessions
        XCTAssertEqual(sessions, 1)
    }

    func testWindowLabelsDeriveFromWindowSeconds() {
        func label(_ seconds: Int?) -> String {
            ChatGPTUsageWindow(usedPercent: 0, resetsAt: nil, windowSeconds: seconds).label(fallback: "Fallback")
        }
        XCTAssertEqual(label(18000), "5-Hour Window")
        XCTAssertEqual(label(3600), "1-Hour Window")
        XCTAssertEqual(label(86400), "Daily")
        XCTAssertEqual(label(604_800), "Weekly")
        XCTAssertEqual(label(30 * 86400), "30-Day Window")
        XCTAssertEqual(label(5400), "Fallback")
        XCTAssertEqual(label(nil), "Fallback")
    }

    // MARK: - Helpers

    private func makeClient(
        cache: ChatGPTAccessTokenCache,
        calls: ExchangeCounter,
        token: String,
        cookieHeader: String = "session=old",
        usage: @escaping @Sendable (Int) async throws -> Data
    ) -> ChatGPTUsageClient {
        let transport = ChatGPTUsageClient.Transport(
            session: { _ in
                await calls.noteSession()
                return (Data(#"{"accessToken": "\#(token)"}"#.utf8), ["session=renewed"])
            },
            usage: { _, _, _ in
                let index = await calls.noteUsage()
                return try await (usage(index), [])
            }
        )
        return ChatGPTUsageClient(cookieHeader: cookieHeader, tokenCache: cache, tokenCacheKey: "1", transport: transport)
    }

    private static func jwt(expiresAt: Date) -> String {
        let payload = #"{"exp": \#(Int(expiresAt.timeIntervalSince1970))}"#
        let encoded = Data(payload.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "h.\(encoded).s"
    }
}

private actor ExchangeCounter {
    private(set) var sessions = 0
    private(set) var usages = 0

    func noteSession() {
        sessions += 1
    }

    func noteUsage() -> Int {
        usages += 1
        return usages
    }
}

private actor RejectFlag {
    private var armed = true

    func take() -> Bool {
        defer { armed = false }
        return armed
    }
}
