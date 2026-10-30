import Foundation
import os

extension ProviderError {
    private static let logger = Logger(category: "GrokUsageClient")

    /// Body-free error: the raw response body is logged privately (truncated) for
    /// diagnostics, and the user-facing message, which is logged at
    /// `privacy: .public` and rendered in the panel, carries only the status code.
    static func grokHTTPStatus(_ code: Int, body: String) -> ProviderError {
        if !body.isEmpty {
            logger.debug("Grok HTTP \(code) body: \(String(body.prefix(400)), privacy: .private)")
        }
        let message = "Usage request failed (HTTP \(code))."
        return .custom(message: message, usage: .badResponse(message))
    }

    /// Maps a usage-response decoding failure to a user-facing `ProviderError`.
    static func grokDecoding(_ detail: String) -> ProviderError {
        let message = "Could not parse usage response: \(detail)"
        return .custom(message: message, usage: .badResponse(message))
    }

    static var grokEmptyResponse: ProviderError {
        let message = "Empty usage response from Grok."
        return .custom(message: message, usage: .badResponse(message))
    }
}

/// Fetches SuperGrok weekly usage via authenticated grok.com endpoints.
///
/// The gRPC-web billing endpoint behind grok.com Settings → Usage is the
/// source of truth and is called first. The REST paths are guesses, probed
/// only when that call fails for a reason other than a rejected session; only
/// the billing endpoint decides whether the session is valid.
struct GrokUsageClient: Sendable {
    private let logger = Logger(category: "GrokUsageClient")

    /// Primary gRPC-web billing endpoint used by grok.com Settings → Usage.
    static let billingEndpoint = URL(staticString: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")

    /// Candidate REST paths probed for product breakdown JSON.
    static let restCandidates: [URL] = [
        URL(staticString: "https://grok.com/rest/subscriptions"),
        URL(staticString: "https://grok.com/rest/user"),
        URL(staticString: "https://grok.com/rest/billing/usage"),
        URL(staticString: "https://grok.com/rest/usage")
    ]

    var cookieHeader: String?
    var accountEmail: String?
    var session: URLSession = ProviderURLSession.shared

    /// Fetches usage from gRPC-web billing, falling back to the REST probes
    /// when billing fails transiently.
    ///
    /// - Throws: `.unauthorized` only when the billing endpoint rejects the
    ///   session; otherwise the billing error when no probe yields usage.
    func fetchUsage() async throws -> WeeklyUsageSnapshot {
        if cookieHeader == nil {
            throw ProviderError.notSignedIn(.grok)
        }
        do {
            return try await fetchGRPCWebBilling()
        } catch let error as ProviderError where error.usageError == .unauthorized {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.warning("gRPC-web billing failed: \(error.localizedDescription, privacy: .public)")
            if let rest = await fetchRESTBreakdown() {
                return rest
            }
            throw error
        }
    }

    // MARK: - REST

    /// First REST probe that returns parseable usage, or `nil`. Every failure,
    /// including 401/403, only moves on to the next path.
    private func fetchRESTBreakdown() async -> WeeklyUsageSnapshot? {
        for url in Self.restCandidates where !Task.isCancelled {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            applyAuth(to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
            request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
            request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

            guard let result = try? await session.data(for: request),
                  let http = result.1 as? HTTPURLResponse,
                  http.statusCode == 200, !result.0.isEmpty else { continue }
            if let snapshot = GrokUsageResponseParser.parseJSON(result.0, accountEmail: accountEmail) {
                logger.info("Parsed usage from \(url.path, privacy: .public)")
                return snapshot
            }
        }
        return nil
    }

    // MARK: - gRPC-web

    private func fetchGRPCWebBilling() async throws -> WeeklyUsageSnapshot {
        var request = URLRequest(url: Self.billingEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        // Empty gRPC-web frame (5-byte header + empty message).
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        applyAuth(to: &request)
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await AuthenticatedRequest.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network(.grok, "Invalid response")
        }
        if ProviderHTTP.isBotChallenge(http, data: data) {
            let message = ProviderHTTP.botChallengeMessage(status: http.statusCode)
            throw ProviderError.custom(message: message, usage: .badResponse(message))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.unauthorized(.grok)
        }
        guard http.statusCode == 200 else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw ProviderError.grokHTTPStatus(http.statusCode, body: body)
        }

        // A trailers-only reply carries `grpc-status` in the HTTP headers.
        try GRPCWebParser.validateHeaders(http)
        try GRPCWebParser.validateTrailers(data)
        let parsed = try GRPCWebParser.parseUsage(data)
        let used = parsed.usedPercent
        let products = parsed.products.isEmpty
            ? Self.synthesizeProducts(usedPercent: used)
            : parsed.products
        let productLog = products.map { "\($0.id):\(String(format: "%.1f", $0.percentOfPool))%" }.joined(separator: ", ")
        logger.info("gRPC parsed products: \(productLog, privacy: .public)")
        #if DEBUG
        logger.debug("gRPC field dump:\n\(GRPCWebParser.debugFieldDump(data), privacy: .public)")
        #endif
        return WeeklyUsageSnapshot(
            usedPercent: used,
            remainingPercent: max(0, 100 - used),
            resetsAt: parsed.resetsAt,
            products: products,
            accountEmail: accountEmail
        )
    }

    private func applyAuth(to request: inout URLRequest) {
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
    }

    /// Without a product breakdown, attributes the pool to a neutral "other" slice.
    static func synthesizeProducts(usedPercent: Double) -> [ProductUsage] {
        guard usedPercent > 0.05 else { return [] }
        return [
            ProductUsage(
                id: "other",
                displayName: "Other",
                percentOfPool: usedPercent,
                colorToken: .other
            )
        ]
    }
}
