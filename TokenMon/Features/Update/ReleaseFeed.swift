import Foundation

/// A published release newer than the running build.
struct AvailableRelease: Equatable, Sendable {
    var version: AppVersion
    var pageURL: URL
    var publishedAt: Date?

    static func == (lhs: AvailableRelease, rhs: AvailableRelease) -> Bool {
        lhs.version.description == rhs.version.description && lhs.pageURL == rhs.pageURL
    }
}

/// Reads the project's latest GitHub release and decides whether it is newer
/// than the running app.
///
/// Only public release metadata is fetched — no token, no user data, and
/// nothing is downloaded or installed. The user is pointed at the release page
/// and updates by hand.
enum ReleaseFeed {
    static let owner = "faulknerpearce"
    static let repository = "token_monitor"

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    }

    /// Parses the `releases/latest` payload, returning the release only when it
    /// is strictly newer than `current`.
    ///
    /// Drafts and pre-releases are ignored: a menu-bar app should not nudge
    /// people onto an unfinished build.
    static func newerRelease(
        in data: Data,
        than current: AppVersion
    ) throws -> AvailableRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateCheckError.badResponse("Unexpected release payload")
        }
        if JSON.firstBool(root, keys: ["draft"]) || JSON.firstBool(root, keys: ["prerelease"]) {
            return nil
        }
        guard let tag = JSON.firstString(root, keys: ["tag_name", "name"]),
              let version = AppVersion(tag)
        else {
            throw UpdateCheckError.badResponse("Release carries no usable version tag")
        }
        guard version > current, !version.isPrerelease else { return nil }

        let page = JSON.firstString(root, keys: ["html_url"])
            .flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(owner)/\(repository)/releases/latest")!

        return AvailableRelease(
            version: version,
            pageURL: page,
            publishedAt: JSON.firstString(root, keys: ["published_at"])
                .flatMap(ISO8601DateFormatter.parseFlexible)
        )
    }
}

enum UpdateCheckError: LocalizedError, Equatable {
    case badResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(message): return "Update check failed: \(message)"
        case let .network(message): return "Update check failed: \(message)"
        }
    }
}
