import Foundation

/// A published release newer than the running build.
struct AvailableRelease: Equatable, Sendable {
    var version: AppVersion
    var pageURL: URL
    /// Zip of `TokenMon.app` attached to the release, when one was published.
    var archiveURL: URL?
    var publishedAt: Date?

    static func == (lhs: AvailableRelease, rhs: AvailableRelease) -> Bool {
        lhs.version.description == rhs.version.description && lhs.pageURL == rhs.pageURL
    }
}

/// Reads the project's latest GitHub release and decides whether it is newer
/// than the running app.
///
/// Fetches public release metadata. A newer release's `TokenMon-*.zip` can be
/// installed in place; without that asset the user is sent to the release page.
enum ReleaseFeed {
    static let owner = "faulknerpearce"
    static let repository = "token_monitor"

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    }

    /// Parses the `releases/latest` payload, returning the release only when it
    /// is strictly newer than `current`.
    ///
    /// Drafts and pre-releases are ignored.
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
            archiveURL: archiveURL(in: root),
            publishedAt: JSON.firstString(root, keys: ["published_at"])
                .flatMap(ISO8601DateFormatter.parseFlexible)
        )
    }

    /// Zip asset to install. Prefers `TokenMon-*.zip`. Ignores other hosts so a
    /// release payload cannot point the download at an unrelated site.
    static func archiveURL(in root: [String: Any]) -> URL? {
        guard let assets = root["assets"] as? [[String: Any]] else { return nil }
        let zips: [(name: String, url: URL)] = assets.compactMap { asset in
            guard let name = JSON.firstString(asset, keys: ["name"]),
                  name.lowercased().hasSuffix(".zip"),
                  let raw = JSON.firstString(asset, keys: ["browser_download_url"]),
                  let url = URL(string: raw),
                  isTrustedDownload(url)
            else { return nil }
            return (name, url)
        }
        let preferred = zips.first { $0.name.lowercased().hasPrefix("tokenmon") }
        return (preferred ?? zips.first)?.url
    }

    static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        if host == "github.com" { return true }
        return host == "objects.githubusercontent.com"
            || host == "release-assets.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
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
