import Foundation

/// Fetches the weekly Grok Bot allowance from the cookie-authenticated Cursor
/// dashboard.
///
/// Grok Bot is a Cursor-backed product (the desktop app bundle is
/// `com.anysphere.sand`), and "Sand" is the name the wire protocol still uses.
/// `aiserver.v1.GetSandUsageStatusResponse` is reached through the dashboard's
/// REST wrapper and carries the whole weekly pool:
///
///   POST https://cursor.com/api/dashboard/get-sand-usage-status   (body `{}`)
///
///   current_period_start           → periodStart
///   next_reset_timestamp_utc       → resetsAt      (the anchor for every window)
///   usage_percent                  → usedPercent
///   included_limit_zero            ┐
///   has_non_zero_included_limit    ┘ → hasIncludedAllowance
///   included_usage_super_grok_plan ┐
///   grok_plan_label                ┘ → entitlement
///
/// One endpoint covers both purchase channels: when the allowance is bundled
/// with a SuperGrok subscription rather than a Cursor one, the SuperGrok plan
/// fields are populated and the rest of the payload is identical.
struct GrokbotUsageClient: Sendable {
    static let baseURL = URL(string: "https://cursor.com")!
    static let usageStatusPath = "/api/dashboard/get-sand-usage-status"

    private let cookieHeader: String
    private let accountEmail: String?

    init(cookieHeader: String, accountEmail: String? = nil) {
        self.cookieHeader = cookieHeader
        self.accountEmail = accountEmail
    }

    func fetchSnapshot(now: Date = Date()) async throws -> GrokbotSnapshot {
        let data = try await post(path: Self.usageStatusPath, json: [:])
        return try Self.parseUsageStatus(data: data, accountEmail: accountEmail, fetchedAt: now)
    }

    // MARK: - Parsing

    static func parseUsageStatus(
        data: Data,
        accountEmail: String?,
        fetchedAt: Date
    ) throws -> GrokbotSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // An expired session redirects to WorkOS and lands on an HTML page,
            // so a non-JSON body here means "signed out", not "malformed".
            throw GrokbotUsageError.unauthorized
        }
        if let error = JSON.string(root["error"]), isUnauthorized(error) {
            throw GrokbotUsageError.unauthorized
        }

        // protobuf-es emits camelCase over JSON; accept the proto field names too
        // so a transport switch does not silently blank the panel.
        //
        // proto3 JSON omits default-valued fields, so a period with no Bot usage
        // yet arrives *without* `usage_percent` — that is 0%, not "no access".
        // Only a payload carrying no allowance fields at all means the account
        // has no Bot entitlement. Without this the section blanked exactly when
        // usage was empty, instead of drawing an empty track like every other
        // provider does at 0%.
        let percent: Double
        if let reported = JSON.firstDouble(root, keys: ["usagePercent", "usage_percent"]) {
            percent = reported
        } else if hasAllowanceFields(root) {
            percent = 0
        } else {
            throw GrokbotUsageError.noBotAccess(
                "No Grok Bot allowance on this account. Grokbot needs a Cursor or SuperGrok plan that includes it."
            )
        }

        let hasIncludedAllowance = !JSON.firstBool(root, keys: ["includedLimitZero", "included_limit_zero"])
            && JSON.firstBool(root, keys: ["hasNonZeroIncludedLimit", "has_non_zero_included_limit"], fallback: true)

        return GrokbotSnapshot(
            fetchedAt: fetchedAt,
            usedPercent: Percent.clamp(percent),
            periodStart: date(root, keys: ["currentPeriodStart", "current_period_start"]),
            resetsAt: date(root, keys: ["nextResetTimestampUtc", "next_reset_timestamp_utc"]),
            entitlement: entitlement(from: root),
            accountEmail: accountEmail,
            hasIncludedAllowance: hasIncludedAllowance
        )
    }

    /// Fields that only appear once the account actually has a Bot allowance.
    /// Their presence lets a missing `usage_percent` be read as 0% rather than
    /// as "no entitlement".
    private static func hasAllowanceFields(_ root: [String: Any]) -> Bool {
        let keys = [
            "currentPeriodStart", "current_period_start",
            "nextResetTimestampUtc", "next_reset_timestamp_utc",
            "includedLimitZero", "included_limit_zero",
            "hasNonZeroIncludedLimit", "has_non_zero_included_limit",
            "includedUsageSuperGrokPlan", "included_usage_super_grok_plan",
            "grokPlanLabel", "grok_plan_label"
        ]
        return keys.contains { root[$0] != nil }
    }

    /// SuperGrok-funded accounts report their plan; everything else is Cursor-funded.
    private static func entitlement(from root: [String: Any]) -> GrokbotEntitlement {
        let plan = JSON.firstString(root, keys: ["includedUsageSuperGrokPlan", "included_usage_super_grok_plan"])
        let label = JSON.firstString(root, keys: ["grokPlanLabel", "grok_plan_label"])
        guard let funded = plan?.trimmingCharacters(in: .whitespacesAndNewlines), !funded.isEmpty else {
            return .cursor
        }
        let display = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .superGrok(planLabel: (display?.isEmpty == false ? display : funded) ?? funded)
    }

    private static func isUnauthorized(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("not_authenticated") || lowered.contains("unauthor")
    }

    /// Timestamps arrive as RFC-3339 strings, or as `{seconds, nanos}` when the
    /// wrapper passes the protobuf `Timestamp` through unconverted.
    private static func date(_ root: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let string = JSON.string(root[key]), let parsed = ISO8601DateFormatter.parseFlexible(string) {
                return parsed
            }
            if let dict = root[key] as? [String: Any], let seconds = JSON.number(dict["seconds"]) {
                return Date(timeIntervalSince1970: seconds + (JSON.number(dict["nanos"]) ?? 0) / 1_000_000_000)
            }
        }
        return nil
    }

    // MARK: - HTTP

    private func post(path: String, json: [String: Any]) async throws -> Data {
        guard let resolved = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL else {
            throw GrokbotUsageError.badResponse("Invalid path \(path)")
        }
        var request = URLRequest(url: resolved)
        request.httpMethod = "POST"
        AuthenticatedRequest.applyHeaders(
            to: &request,
            cookieHeader: cookieHeader,
            bearerToken: nil,
            referer: "https://cursor.com/bot"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)

        return try await AuthenticatedRequest.perform(request) { usageError in
            switch usageError {
            case .notSignedIn: return GrokbotUsageError.notSignedIn
            case .unauthorized: return GrokbotUsageError.unauthorized
            case let .network(message): return GrokbotUsageError.network(message)
            case let .badResponse(message): return GrokbotUsageError.badResponse(message)
            }
        }
    }
}
