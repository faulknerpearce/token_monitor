import Foundation
import os

/// Fetches authoritative OpenCode Go usage from the console SolidStart server functions.
///
/// Protocol:
/// ```
/// GET https://opencode.ai/_server?id=<hash>&args=["wrk_…"]
/// Cookie: auth=…; provider=…
/// X-Server-Id: <hash>
/// ```
/// Response is `text/javascript` seroval (not JSON), e.g.:
/// `…rollingUsage$R[2]={status:"ok",resetInSec:18000,usagePercent:0},weeklyUsage$R[3]={…usagePercent:88}…`
struct OpenCodeConsoleClient: Sendable {
    static let baseURL = URL(string: "https://opencode.ai")!

    /// Fallback server-fn id when live discovery fails.
    static let fallbackLiteSubscriptionID =
        "c7389bd0e731f80f49593e5ee53835475f4e28594dd6bd83eb229bab753498cd"

    private let cookieHeader: String
    private let logger = Logger(category: "OpenCodeConsole")

    init(cookieHeader: String) {
        self.cookieHeader = cookieHeader
    }

    // MARK: - Public

    /// Returns the snapshot and the workspace id that produced it (caller should persist the id).
    func fetchGoUsageSnapshot(knownWorkspaceID: String? = nil) async throws -> (OpenCodeSnapshot, String) {
        let serverID = try await resolveLiteSubscriptionServerID()

        if let known = knownWorkspaceID, known.hasPrefix("wrk_") {
            do {
                let payload = try await fetchValidatedPayload(serverID: serverID, workspaceID: known)
                return (makeSnapshot(from: payload), known)
            } catch let error as ProviderError {
                switch error {
                case .unauthorized, .notSignedIn:
                    throw error
                default:
                    logger.warning(
                        "Known workspace failed (\(error.localizedDescription, privacy: .public)); resolving fresh id"
                    )
                }
            } catch {
                logger.warning(
                    "Known workspace failed (\(error.localizedDescription, privacy: .public)); resolving fresh id"
                )
            }
            let fresh = try await resolveWorkspaceID()
            let payload = try await fetchValidatedPayload(serverID: serverID, workspaceID: fresh)
            return (makeSnapshot(from: payload), fresh)
        }

        let workspaceID = try await resolveWorkspaceID()
        let payload = try await fetchValidatedPayload(serverID: serverID, workspaceID: workspaceID)
        return (makeSnapshot(from: payload), workspaceID)
    }

    private func fetchValidatedPayload(serverID: String, workspaceID: String) async throws -> LitePayload {
        let payload = try await callLiteSubscription(serverID: serverID, workspaceID: workspaceID)
        guard payload.mine || payload.hasUsage else {
            throw ProviderError.badResponse(
                .openCode,
                "No Go subscription on this account (or another member holds the Go seat)."
            )
        }
        return payload
    }

    private func makeSnapshot(from payload: LitePayload) -> OpenCodeSnapshot {
        OpenCodeSnapshot(
            fetchedAt: Date(),
            windows: [
                windowUsage(kind: .rolling5h, from: payload.rolling),
                windowUsage(kind: .weekly, from: payload.weekly),
                windowUsage(kind: .monthly, from: payload.monthly)
            ],
            models: [],
            modelsWindowLabel: "All models this week",
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalSessions: 0,
            isEstimated: false
        )
    }

    /// Follows `/auth` → `/workspace/{id}` using the session cookie.
    func resolveWorkspaceID() async throws -> String {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("auth"))
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network(.openCode, "invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.unauthorized(.openCode)
        }

        if let final = http.url, let id = Self.workspaceID(from: final) {
            return id
        }

        if let body = String(data: data, encoding: .utf8),
           let match = body.range(of: #"wrk_[A-Za-z0-9]+"#, options: String.CompareOptions.regularExpression) {
            return String(body[match])
        }

        let message = "Could not find an OpenCode workspace. Sign in at opencode.ai, then try again."
        throw ProviderError.custom(message: message, usage: .badResponse(message))
    }

    // MARK: - Server function discovery

    func resolveLiteSubscriptionServerID() async throws -> String {
        if let cached = Self.cachedServerID, !cached.isEmpty {
            return cached
        }
        do {
            let entryPath = try await discoverEntryClientPath()
            let entry = try await fetchText(path: entryPath)
            guard let goChunk = Self.goRouteChunkName(fromEntryClient: entry) else {
                logger.warning("go route chunk not found; using fallback server id")
                return Self.fallbackLiteSubscriptionID
            }
            let chunkPath = goChunk.hasPrefix("/") ? goChunk : "/_build/assets/\(goChunk)"
            let chunk = try await fetchText(path: chunkPath)
            if let id = Self.liteSubscriptionServerID(fromChunkJS: chunk) {
                Self.cachedServerID = id
                logger.info("Discovered lite.subscription server id")
                return id
            }
        } catch {
            logger.error("Server id discovery failed: \(error.localizedDescription, privacy: .public)")
        }
        return Self.fallbackLiteSubscriptionID
    }

    private static let cachedServerIDLock = NSLock()
    private static var _cachedServerID: String?

    private static var cachedServerID: String? {
        get {
            cachedServerIDLock.lock(); defer { cachedServerIDLock.unlock() }
            return _cachedServerID
        }
        set {
            cachedServerIDLock.lock(); defer { cachedServerIDLock.unlock() }
            _cachedServerID = newValue
        }
    }

    private func discoverEntryClientPath() async throws -> String {
        let html = try await fetchText(path: "/")
        if let range = html.range(
            of: #"/_build/assets/entry-client-[A-Za-z0-9_-]+\.js"#,
            options: String.CompareOptions.regularExpression
        ) {
            return String(html[range])
        }
        let message = "Could not resolve OpenCode console usage endpoint (site may have updated)."
        throw ProviderError.custom(message: message, usage: .badResponse(message))
    }

    /// Bundle lists the go route module import *before* the path string; match on `go/index.tsx`.
    private static let goRouteChunkRegex = try? NSRegularExpression(
        pattern: #"workspace/\[id\]/go/index\.tsx[\s\S]{0,500}?(index-[A-Za-z0-9_-]+\.js)"#
    )

    static func goRouteChunkName(fromEntryClient entry: String) -> String? {
        guard let regex = Self.goRouteChunkRegex else { return nil }
        let range = NSRange(entry.startIndex..<entry.endIndex, in: entry)
        guard let match = regex.firstMatch(in: entry, range: range),
              match.numberOfRanges >= 2,
              let fileRange = Range(match.range(at: 1), in: entry)
        else { return nil }
        return String(entry[fileRange])
    }

    private static let liteSubscriptionRegex = try? NSRegularExpression(
        pattern: #"queryLiteSubscription_query\s*=\s*createServerReference\("([a-f0-9]+)"\)"#
    )

    static func liteSubscriptionServerID(fromChunkJS js: String) -> String? {
        guard let regex = Self.liteSubscriptionRegex else { return nil }
        let range = NSRange(js.startIndex..<js.endIndex, in: js)
        guard let match = regex.firstMatch(in: js, range: range),
              match.numberOfRanges >= 2,
              let idRange = Range(match.range(at: 1), in: js)
        else { return nil }
        return String(js[idRange])
    }

    static func workspaceID(from url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard let idx = parts.firstIndex(of: "workspace"), parts.index(after: idx) < parts.endIndex else {
            return nil
        }
        let candidate = String(parts[parts.index(after: idx)])
        return candidate.hasPrefix("wrk_") ? candidate : nil
    }

    // MARK: - HTTP

    private struct LitePayload {
        var mine: Bool
        var rolling: WindowFields
        var weekly: WindowFields
        var monthly: WindowFields

        var hasUsage: Bool {
            rolling.usagePercent > 0 || weekly.usagePercent > 0 || monthly.usagePercent > 0
        }
    }

    private struct WindowFields {
        var usagePercent: Double
        var resetInSec: TimeInterval
    }

    private func callLiteSubscription(serverID: String, workspaceID: String) async throws -> LitePayload {
        // Console accepts GET with a plain JSON args array.
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("_server"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: serverID),
            URLQueryItem(name: "args", value: String(data: try JSONSerialization.data(withJSONObject: [workspaceID]), encoding: .utf8))
        ]
        guard let url = components.url else {
            throw ProviderError.network(.openCode, "bad server url")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(serverID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:grok-monitor", forHTTPHeaderField: "X-Server-Instance")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network(.openCode, "invalid response")
        }

        let body = String(data: data, encoding: .utf8) ?? ""

        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.unauthorized(.openCode)
        }
        if let loc = http.value(forHTTPHeaderField: "Location"), loc.contains("auth") {
            throw ProviderError.unauthorized(.openCode)
        }
        if body.contains("/auth/authorize") && body.contains("location") {
            throw ProviderError.unauthorized(.openCode)
        }
        if http.statusCode >= 400 {
            if http.statusCode == 404 || body.contains("Cannot find") {
                Self.cachedServerID = nil
            }
            throw ProviderError.badResponse(.openCode, "HTTP \(http.statusCode): \(body.prefix(200))")
        }
        if let xerr = http.value(forHTTPHeaderField: "X-Error"), !xerr.isEmpty {
            if xerr.lowercased().contains("auth") || xerr.lowercased().contains("account") {
                // Account-without-workspace usually means bad args.
            }
            throw ProviderError.badResponse(.openCode, xerr)
        }
        if body.contains("actor of type") && body.contains("workspace") {
            throw ProviderError.badResponse(
                .openCode,
                "Console could not bind workspace (session or workspace id issue)."
            )
        }

        return try Self.parseLitePayload(body)
    }

    /// Parses SolidStart seroval `text/javascript` payload into usage percents (for tests + client).
    static func parseLiteSubscriptionJS(_ body: String) throws -> (
        mine: Bool,
        rolling: (Double, TimeInterval),
        weekly: (Double, TimeInterval),
        monthly: (Double, TimeInterval)
    ) {
        let payload = try parseLitePayload(body)
        return (
            payload.mine,
            (payload.rolling.usagePercent, payload.rolling.resetInSec),
            (payload.weekly.usagePercent, payload.weekly.resetInSec),
            (payload.monthly.usagePercent, payload.monthly.resetInSec)
        )
    }

    private static func parseLitePayload(_ body: String) throws -> LitePayload {
        let mine: Bool
        if body.contains("mine:!0") || body.contains("mine:true") {
            mine = true
        } else if body.contains("mine:!1") || body.contains("mine:false") {
            mine = false
        } else {
            mine = body.contains("rollingUsage")
        }

        guard
            let rolling = windowFields(named: "rollingUsage", in: body),
            let weekly = windowFields(named: "weeklyUsage", in: body),
            let monthly = windowFields(named: "monthlyUsage", in: body)
        else {
            throw ProviderError.badResponse(.openCode, "could not parse usage windows from console response")
        }

        return LitePayload(mine: mine, rolling: rolling, weekly: weekly, monthly: monthly)
    }

    private static func windowFields(named name: String, in body: String) -> WindowFields? {
        // Example: rollingUsage$R[2]={status:"ok",resetInSec:18000,usagePercent:0}
        // Scan from the key name to the matching `}`.
        guard let keyRange = body.range(of: name) else { return nil }
        let afterKey = body[keyRange.upperBound...]
        guard let braceOpen = afterKey.firstIndex(of: "{") else { return nil }
        let afterBrace = afterKey[afterKey.index(after: braceOpen)...]
        guard let braceClose = afterBrace.firstIndex(of: "}") else { return nil }
        let inner = String(afterBrace[..<braceClose])

        let percent = firstNumber(after: "usagePercent:", in: inner) ?? 0
        let reset = firstNumber(after: "resetInSec:", in: inner) ?? 0
        return WindowFields(usagePercent: percent, resetInSec: reset)
    }

    private static func firstNumber(after marker: String, in text: String) -> Double? {
        guard let range = text.range(of: marker) else { return nil }
        var rest = text[range.upperBound...]
        // Skip insignificant whitespace/quotes before the value so
        // `"usagePercent": 0.5` parses the same as `usagePercent:0.5`.
        rest = rest.drop { $0 == " " || $0 == "\"" || $0 == "\t" }
        // A literal null/undefined is not a number — do not walk past it into
        // the next field's numeric value.
        if rest.hasPrefix("null") || rest.hasPrefix("undefined") { return nil }

        var digits = ""
        for ch in rest {
            if ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E" {
                digits.append(ch)
            } else if !digits.isEmpty {
                break
            } else {
                // First meaningful character is not numeric: give up.
                return nil
            }
        }
        return Double(digits)
    }

    private func fetchText(path: String) async throws -> String {
        let url: URL
        if path.hasPrefix("http") {
            guard let absolute = URL(string: path) else {
                throw ProviderError.network(.openCode, "malformed URL: \(path)")
            }
            url = absolute
        } else {
            guard let relative = URL(string: path, relativeTo: Self.baseURL) else {
                throw ProviderError.network(.openCode, "malformed path: \(path)")
            }
            url = relative.absoluteURL
        }
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ProviderError.network(.openCode, "HTTP \(http.statusCode) for \(path)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.network(.openCode, "non-utf8 body for \(path)")
        }
        return text
    }

    private func windowUsage(kind: OpenCodeWindowKind, from fields: WindowFields) -> OpenCodeWindowUsage {
        let limit = kind.defaultLimitUSD
        let percent = max(0, min(100, fields.usagePercent))
        let usedUSD = percent / 100.0 * limit
        let resetsAt: Date? = fields.resetInSec > 0 ? Date().addingTimeInterval(fields.resetInSec) : nil
        return OpenCodeWindowUsage(
            kind: kind,
            usedUSD: usedUSD,
            limitUSD: limit,
            resetsAt: resetsAt,
            sessionCount: 0
        )
    }
}
