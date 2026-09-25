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

    private let cookieHeader: String
    private let logger = Logger(category: "OpenCodeConsole")

    init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }

    // MARK: - Public

    /// Returns the snapshot and the org id (`wrk_…`) that produced it, so the
    /// caller can persist the id.
    func fetchGoUsageSnapshot(knownOrgID: String? = nil) async throws -> (OpenCodeSnapshot, String) {
        let orgID = try await resolveOrgID(preferred: knownOrgID)
        do {
            let meters = try await fetchGoMeters(orgID: orgID)
            return (Self.snapshot(from: meters, now: Date()), orgID)
        } catch OpenCodeConsoleError.orgForbidden {
            // The stored org id was rejected. Re-resolve from the account's own
            // workspace list and retry once; only 401 / a login redirect (raised
            // by the unscoped requests) means the session itself is expired.
            let freshOrg = try await resolveOrgID(preferred: nil)
            guard freshOrg != orgID else {
                throw ProviderError.badResponse(
                    .openCode,
                    "The OpenCode console denied access to this workspace."
                )
            }
            let meters = try await fetchGoMeters(orgID: freshOrg)
            return (Self.snapshot(from: meters, now: Date()), freshOrg)
        }
    }

    /// The console org id. Prefers the stored id; otherwise lists `/console/api/orgs`.
    func resolveOrgID(preferred: String? = nil) async throws -> String {
        if let preferred, preferred.hasPrefix("wrk_") { return preferred }
        let orgs = try await Self.parseOrgs(try get("/console/api/orgs"))
        guard let first = orgs.first else {
            throw ProviderError.badResponse(.openCode, "No OpenCode workspace on this account.")
        }
        return first
    }

    /// Account email from the console session. Best-effort — the console session
    /// may not be bound yet on the first capture.
    func fetchAccountEmail() async -> String? {
        let data = try? await get("/console/auth/session")
        return data.flatMap(Self.parseSessionEmail)
    }

    // MARK: - Requests

    private func fetchGoMeters(orgID: String) async throws -> OpenCodeGoMeters {
        let meters = try await Self.parseGoMeters(try get("/console/api/go/status", orgID: orgID))
        guard meters.hasAny else {
            throw ProviderError.badResponse(
                .openCode,
                "No Go subscription on this account (or another member holds the Go seat)."
            )
        }
        return meters
    }

    private func get(_ path: String, orgID: String? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL else {
            throw ProviderError.network(.openCode, "malformed path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if let orgID { request.setValue(orgID, forHTTPHeaderField: "x-org-id") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network(.openCode, "invalid response")
        }
        // An expired console session redirects to the login page (URLSession
        // follows it) rather than returning 401.
        if let final = http.url, Self.isLoginRedirect(final) {
            throw ProviderError.unauthorized(.openCode)
        }
        // A 403 on an org-scoped request is a rejected workspace, not an expired
        // session — let the caller re-resolve and retry. A 403 without an org id
        // is the session being refused outright.
        if http.statusCode == 403, orgID != nil {
            throw OpenCodeConsoleError.orgForbidden
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.unauthorized(.openCode)
        }
        guard http.statusCode < 400 else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw ProviderError.badResponse(.openCode, "HTTP \(http.statusCode): \(body)")
        }
        return data
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
