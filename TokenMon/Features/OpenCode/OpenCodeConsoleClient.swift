import Foundation
import os

/// Console `/console/api/go/status` meters for the 5-hour, week, and month windows.
struct OpenCodeGoMeters: Equatable {
    /// One console access meter (`limitMicroCents`/`usedMicroCents` with reset).
    struct Meter: Equatable {
        var limitUSD: Double?
        var usedUSD: Double
        var resetsAt: Date?
    }

    var fiveHour: Meter?
    var week: Meter?
    var month: Meter?
    /// Subscription period end — the month window's reset when it has none.
    var monthResetsAt: Date?

    var hasAny: Bool { fiveHour != nil || week != nil || month != nil }
}

/// A 403 on an org-scoped console request: the workspace id was rejected
/// (membership change, or a stale id from a previous account). Distinct from an
/// expired session so the caller can re-resolve the org instead of signing out.
enum OpenCodeConsoleError: Error {
    case orgForbidden
}

/// Fetches OpenCode Go usage from the console API.
///
/// The console moved off the legacy `_server` (`lite.subscription`) server
/// function, which now answers every call with a `302` to `/console/login`.
/// Usage is served by the console's own session instead:
///
/// ```
/// GET https://opencode.ai/console/api/go/status
/// Cookie: __Host-console_session=…; auth=…
/// x-org-id: wrk_…
/// ```
///
/// Response carries the account's subscription access meters:
/// `access.meters.{fiveHour,week,month}` with `limitMicroCents`/`usedMicroCents`.
struct OpenCodeConsoleClient: Sendable {
    static let baseURL = URL(string: "https://opencode.ai")!

    /// Network seam: GET a console path, optionally scoped to an org id.
    typealias Get = @Sendable (_ path: String, _ orgID: String?) async throws -> Data

    private let getData: Get

    init(cookieHeader: String) {
        self.init { path, orgID in
            try await Self.liveGet(path, orgID: orgID, cookieHeader: cookieHeader)
        }
    }

    /// Injects the transport (tests supply canned console responses).
    init(get: @escaping Get) {
        getData = get
    }

    // MARK: - Public

    /// Returns the snapshot and the org id (`wrk_…`) that produced it, so the
    /// caller can persist the id.
    ///
    /// Tries `knownOrgID` first, then every other workspace on the account, and
    /// returns the first one that holds a Go seat. A workspace that rejects the
    /// request (403) or has no Go meters is skipped; only 401 or a login
    /// redirect means the session itself is expired.
    func fetchGoUsageSnapshot(knownOrgID: String? = nil) async throws -> (OpenCodeSnapshot, String) {
        let preferred = knownOrgID.flatMap { $0.hasPrefix("wrk_") ? $0 : nil }
        var tried = 0
        var forbidden = 0
        func attempt(_ org: String) async throws -> OpenCodeGoMeters? {
            tried += 1
            switch try await seatedMeters(orgID: org) {
            case let .seated(meters): return meters
            case .forbidden: forbidden += 1
            case .noSeat: break
            }
            return nil
        }
        if let preferred, let meters = try await attempt(preferred) {
            return (Self.snapshot(from: meters, now: Date()), preferred)
        }
        for org in try await listOrgs() where org != preferred {
            if let meters = try await attempt(org) {
                return (Self.snapshot(from: meters, now: Date()), org)
            }
        }
        guard tried > 0 else {
            throw ProviderError.badResponse(.openCode, "No OpenCode workspace on this account.")
        }
        throw ProviderError.badResponse(
            .openCode,
            forbidden == tried
                ? "The OpenCode console denied access to this workspace."
                : "No Go subscription on this account (or another member holds the Go seat)."
        )
    }

    /// The console org id. Prefers `preferred` (for example the id in the
    /// sign-in redirect); otherwise the first workspace listed by `/console/api/orgs`.
    func resolveOrgID(preferred: String? = nil) async throws -> String {
        if let preferred, preferred.hasPrefix("wrk_") { return preferred }
        guard let first = try await listOrgs().first else {
            throw ProviderError.badResponse(.openCode, "No OpenCode workspace on this account.")
        }
        return first
    }

    /// Account email from the console session. Best-effort — the console session
    /// may not be bound yet on the first capture.
    func fetchAccountEmail() async -> String? {
        let data = try? await getData("/console/auth/session", nil)
        return data.flatMap(Self.parseSessionEmail)
    }

    // MARK: - Requests

    /// Go status for one workspace.
    private enum SeatResult {
        case seated(OpenCodeGoMeters)
        case noSeat
        case forbidden
    }

    private func seatedMeters(orgID: String) async throws -> SeatResult {
        do {
            let meters = try await Self.parseGoMeters(getData("/console/api/go/status", orgID))
            return meters.hasAny ? .seated(meters) : .noSeat
        } catch OpenCodeConsoleError.orgForbidden {
            return .forbidden
        }
    }

    private func listOrgs() async throws -> [String] {
        try await Self.parseOrgs(getData("/console/api/orgs", nil))
    }

    private static let log = Logger(category: "OpenCodeConsole")

    private static func liveGet(_ path: String, orgID: String?, cookieHeader: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ProviderError.network(.openCode, "malformed path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if let orgID { request.setValue(orgID, forHTTPHeaderField: "x-org-id") }

        let (data, response) = try await ProviderURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network(.openCode, "invalid response")
        }
        try check(http, data: data, orgID: orgID)
        return data
    }

    /// Maps a console response onto the client's errors.
    ///
    /// An expired console session redirects to the login page (URLSession
    /// follows it) rather than returning 401. A 403 on an org-scoped request is
    /// a rejected workspace, not an expired session, so the caller can try
    /// another; a 403 without an org id is the session being refused outright.
    /// Error bodies are logged privately and never shown to the user.
    static func check(_ http: HTTPURLResponse, data: Data, orgID: String?) throws {
        if ProviderHTTP.isBotChallenge(http, data: data) {
            throw ProviderError.badResponse(.openCode, ProviderHTTP.botChallengeMessage(status: http.statusCode))
        }
        if let final = http.url, Self.isLoginRedirect(final) {
            throw ProviderError.unauthorized(.openCode)
        }
        if http.statusCode == 403, orgID != nil {
            throw OpenCodeConsoleError.orgForbidden
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.unauthorized(.openCode)
        }
        guard http.statusCode < 400 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            log.error("OpenCode console HTTP \(http.statusCode, privacy: .public): \(body, privacy: .private)")
            throw ProviderError.badResponse(.openCode, "HTTP \(http.statusCode)")
        }
    }

    // MARK: - Session expiry

    /// Console login endpoints an expired session redirects to.
    private static let loginRedirectMarkers = ["/console/login", "/auth/authorize", "/auth/login"]

    /// True when a console URL is the login page an expired cookie redirects to.
    static func isLoginRedirect(_ url: URL) -> Bool {
        loginRedirectMarkers.contains { url.path.contains($0) }
    }

    // MARK: - URLs

    /// `wrk_…` id from a console (`/console/wrk_…`) or workspace (`/workspace/wrk_…`) URL.
    static func workspaceID(from url: URL) -> String? {
        for part in url.path.split(separator: "/") where part.hasPrefix("wrk_") {
            return String(part)
        }
        return nil
    }

    // MARK: - Parsing

    /// Parses `access.meters` from Go status; returns empty meters when absent.
    static func parseGoMeters(_ data: Data) throws -> OpenCodeGoMeters {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse(.openCode, "Unrecognized Go status response.")
        }
        guard let access = root["access"] as? [String: Any],
              let meters = access["meters"] as? [String: Any]
        else {
            return OpenCodeGoMeters()
        }
        return OpenCodeGoMeters(
            fiveHour: meter(meters["fiveHour"]),
            week: meter(meters["week"]),
            month: meter(meters["month"]),
            monthResetsAt: (access["endsAt"] as? String).flatMap(ISO8601DateFormatter.parseFlexible)
        )
    }

    /// Org ids from `/console/api/orgs`.
    static func parseOrgs(_ data: Data) throws -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ProviderError.badResponse(.openCode, "Could not read OpenCode workspaces.")
        }
        return rows.compactMap { $0["id"] as? String }.filter { $0.hasPrefix("wrk_") }
    }

    /// Email from `/console/auth/session`.
    static func parseSessionEmail(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = root["user"] as? [String: Any]
        else { return nil }
        return user["email"] as? String
    }

    /// Builds the usage snapshot from the console meters.
    static func snapshot(from meters: OpenCodeGoMeters, now: Date) -> OpenCodeSnapshot {
        OpenCodeSnapshot(
            fetchedAt: now,
            windows: [
                window(kind: .rolling5h, meter: meters.fiveHour),
                window(kind: .weekly, meter: meters.week),
                window(kind: .monthly, meter: meters.month, fallbackResetsAt: meters.monthResetsAt)
            ].compactMap { $0 },
            models: [],
            isEstimated: false
        )
    }

    /// One-day meter → window. Missing meters are omitted so the panel shows
    /// only the windows the account actually has.
    private static func window(
        kind: OpenCodeWindowKind,
        meter: OpenCodeGoMeters.Meter?,
        fallbackResetsAt: Date? = nil
    ) -> OpenCodeWindowUsage? {
        guard let meter else { return nil }
        return OpenCodeWindowUsage(
            kind: kind,
            usedUSD: meter.usedUSD,
            limitUSD: meter.limitUSD ?? kind.defaultLimitUSD,
            resetsAt: meter.resetsAt ?? fallbackResetsAt,
            sessionCount: 0
        )
    }

    private static func meter(_ any: Any?) -> OpenCodeGoMeters.Meter? {
        guard let dict = any as? [String: Any] else { return nil }
        return OpenCodeGoMeters.Meter(
            limitUSD: usd(dict["limitMicroCents"]),
            usedUSD: usd(dict["usedMicroCents"]) ?? 0,
            resetsAt: (dict["resetsAt"] as? String).flatMap(ISO8601DateFormatter.parseFlexible)
        )
    }

    /// Microcents → USD (`$1 = 100_000_000` microcents).
    static func usd(_ any: Any?) -> Double? {
        let raw: Double?
        if let string = any as? String {
            raw = Double(string)
        } else if let number = any as? NSNumber {
            raw = number.doubleValue
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        return raw / 100_000_000
    }
}
