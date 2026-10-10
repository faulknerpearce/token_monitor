import Foundation

/// A file attached to a GitHub release.
struct ReleaseAsset: Equatable, Sendable {
    var name: String
    var url: URL
    /// Lowercase hex SHA-256 from the asset's `digest` field (`sha256:<hex>`),
    /// or `nil` when GitHub reported none.
    var sha256: String?
}

/// A published release newer than the running build.
struct AvailableRelease: Equatable, Sendable {
    var version: AppVersion
    var pageURL: URL
    /// Zip of `TokenMon.app` attached to the release, when one was published.
    var archive: ReleaseAsset?
    /// Installer package attached to the release, offered when this copy of
    /// the app cannot replace itself.
    var installerPackage: ReleaseAsset?
    var publishedAt: Date?

    var archiveURL: URL? { archive?.url }

    static func == (lhs: AvailableRelease, rhs: AvailableRelease) -> Bool {
        lhs.version.description == rhs.version.description && lhs.pageURL == rhs.pageURL
    }
}

/// Reads the project's latest GitHub release and decides whether it is newer
/// than the running app.
///
/// Fetches public release metadata. A newer release's `TokenMon-*.zip` can be
/// installed in place once its SHA-256 matches the asset digest; without that
/// asset the user is sent to the installer package or the release page.
enum ReleaseFeed {
    static let owner = "faulknerpearce"
    static let repository = "token_monitor"

    /// Hosts GitHub redirects release-asset downloads to.
    static let assetCDNHosts: Set<String> = [
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com"
    ]

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

        let assets = releaseAssets(in: root)
        return AvailableRelease(
            version: version,
            pageURL: page,
            archive: preferredAsset(in: assets, withExtension: "zip"),
            installerPackage: preferredAsset(in: assets, withExtension: "pkg"),
            publishedAt: JSON.firstString(root, keys: ["published_at"])
                .flatMap(ISO8601DateFormatter.parseFlexible)
        )
    }

    /// Asset to install with the given extension. Prefers `TokenMon-*` names
    /// and skips debug-symbol archives (`*-dSYM.zip`).
    static func preferredAsset(in assets: [ReleaseAsset], withExtension pathExtension: String) -> ReleaseAsset? {
        let matching = assets.filter {
            let name = $0.name.lowercased()
            return name.hasSuffix(".\(pathExtension)") && !name.contains("dsym")
        }
        return matching.first { $0.name.lowercased().hasPrefix("tokenmon") } ?? matching.first
    }

    /// Assets whose download URL is one of this repository's release
    /// downloads. Others are dropped so a release payload cannot point the
    /// download at an unrelated site.
    static func releaseAssets(in root: [String: Any]) -> [ReleaseAsset] {
        guard let assets = root["assets"] as? [[String: Any]] else { return [] }
        return assets.compactMap { asset in
            guard let name = JSON.firstString(asset, keys: ["name"]),
                  let raw = JSON.firstString(asset, keys: ["browser_download_url"]),
                  let url = URL(string: raw),
                  isRepositoryReleaseDownload(url)
            else { return nil }
            return ReleaseAsset(name: name, url: url, sha256: sha256(fromDigest: asset["digest"] as? String))
        }
    }

    /// Hex SHA-256 from a GitHub asset digest (`sha256:<64 hex>`), lowercased.
    static func sha256(fromDigest digest: String?) -> String? {
        guard let digest else { return nil }
        let parts = digest.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        let hex = parts[1].lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// True for `https://github.com/<owner>/<repository>/releases/download/<tag>/<file>`.
    static func isRepositoryReleaseDownload(_ url: URL) -> Bool {
        guard isPlainHTTPS(url), url.host?.lowercased() == "github.com" else { return false }
        let components = url.pathComponents
        guard components.count == 7,
              !components.contains(".."), !components.contains(".")
        else { return false }
        return components[1].lowercased() == owner.lowercased()
            && components[2].lowercased() == repository.lowercased()
            && components[3] == "releases"
            && components[4] == "download"
    }

    /// True for this repository's release downloads and the GitHub CDN hosts
    /// those downloads redirect to.
    static func isTrustedDownload(_ url: URL) -> Bool {
        if isRepositoryReleaseDownload(url) { return true }
        guard isPlainHTTPS(url), let host = url.host?.lowercased() else { return false }
        return assetCDNHosts.contains(host)
    }

    /// `https` on the default port with no embedded credentials.
    private static func isPlainHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }
}

/// Network and malformed-payload failures from the release check.
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
