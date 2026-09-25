import Foundation

/// Fetches the weekly Grok Bot allowance from the cookie-authenticated Cursor
/// dashboard.
///
/// Grok Bot is a Cursor-backed product (app bundle `com.anysphere.sand`), and
/// "Sand" is the wire-protocol name. `aiserver.v1.GetSandUsageStatusResponse`
/// is reached through the dashboard's REST wrapper and carries the weekly pool:
///
///   POST https://cursor.com/api/dashboard/get-sand-usage-status   (body `{}`)
///
///   current_period_start           → periodStart
///   next_reset_timestamp_utc       → resetsAt      (anchor for every window)
///   usage_percent                  → usedPercent
///   included_limit_zero            ┐
///   has_non_zero_included_limit    ┘ → hasIncludedAllowance
///   included_usage_super_grok_plan ┐
///   grok_plan_label                ┘ → entitlement
///
/// One endpoint covers both purchase channels: when the allowance is bundled
/// with a SuperGrok subscription, the SuperGrok plan fields are populated and
/// the rest of the payload is identical.
struct GrokbotUsageClient: Sendable {
    static let baseURL = URL(string: "https://cursor.com")!
    static let usageStatusPath = "/api/dashboard/get-sand-usage-status"

    private let cookieHeader: String
    private let accountEmail: String?

    init(cookieHeader: String, accountEmail: String? = nil) {
        self.cookieHeader = cookieHeader
        self.accountEmail = accountEmail
    }

    /// Posts to the usage-status endpoint and parses the allowance snapshot.
    func fetchSnapshot(now: Date = Date()) async throws -> GrokbotSnapshot {
        let data = try await post(path: Self.usageStatusPath, json: [:])
        return try Self.parseUsageStatus(data: data, accountEmail: accountEmail, fetchedAt: now)
    }

    // MARK: - Parsing

    /// Parses the usage-status payload, reading missing `usage_percent` as 0% when allowance fields exist.
    static func parseUsageStatus(
        data: Data,
        accountEmail: String?,
        fetchedAt: Date
    ) throws -> GrokbotSnapshot {
        // An expired session redirects to WorkOS and lands on an HTML page, so a
        // non-JSON body here means "signed out", not "malformed".
        let root = try ProviderHTTP.jsonObject(data, context: .grokbot)
        if let error = JSON.string(root["error"]), ProviderHTTP.isUnauthorizedMessage(error) {
            throw ProviderError.unauthorized(.grokbot)
        }

        // protobuf-es emits camelCase over JSON; accept the proto field names too
        // so a transport switch does not silently blank the panel.
        //
        // proto3 JSON omits default-valued fields, so a period with no Bot usage
        // arrives without `usage_percent` — that is 0%, not "no access". Only a
        // payload with no allowance fields at all means no Bot entitlement.
        let percent: Double
        if let reported = JSON.firstDouble(root, keys: ["usagePercent", "usage_percent"]) {
            percent = reported
        } else if hasAllowanceFields(root) {
            percent = 0
        } else {
            let message = "No Grok Bot allowance on this account. Grokbot needs a Cursor or SuperGrok plan that includes it."
            throw ProviderError.custom(message: message, usage: .badResponse(message))
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

    /// Timestamps arrive as RFC-3339 strings, or as `{seconds, nanos}` when the
    /// wrapper passes the protobuf `Timestamp` through unconverted.
    private static func date(_ root: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let string = JSON.string(root[key]), let parsed = ISO8601DateFormatter.parseFlexible(string) {
                return parsed
            }
            if let dict = root[key] as? [String: Any],
               let seconds = JSON.number(dict["seconds"]), seconds > 0 {
                // An unset protobuf Timestamp arrives as {seconds: 0}; treat it
                // as missing rather than anchoring the window to 1970.
                return Date(timeIntervalSince1970: seconds + (JSON.number(dict["nanos"]) ?? 0) / 1_000_000_000)
            }
        }
        return nil
    }

    // MARK: - HTTP

    private func post(path: String, json: [String: Any]) async throws -> Data {
        try await ProviderHTTP.post(
            path,
            baseURL: Self.baseURL,
            context: .grokbot,
            json: json,
            cookieHeader: cookieHeader,
            referer: "https://cursor.com/bot",
            origin: "https://cursor.com"
        )
    }
}
