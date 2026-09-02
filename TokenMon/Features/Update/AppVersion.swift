import Foundation

/// A dotted release version (`1.4.2`), compared numerically rather than as a
/// string so `1.10.0` sorts above `1.9.0`.
///
/// Parsing is deliberately forgiving about the shapes GitHub tags take
/// (`v1.4.2`, `1.4`, `1.4.2-beta.1`) and deliberately strict about everything
/// else: an unparseable tag yields `nil`, and the caller then offers no update
/// rather than guessing.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]
    /// Pre-release suffix after `-`, e.g. `beta.1`. Absent on final releases.
    let prerelease: String?

    var description: String {
        let core = components.map(String.init).joined(separator: ".")
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    var isPrerelease: Bool { prerelease != nil }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("v") { text.removeFirst() }
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = String(parts[0])
        let suffix = parts.count > 1 ? String(parts[1]) : nil

        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }

        components = numbers.compactMap { $0 }
        prerelease = (suffix?.isEmpty == false) ? suffix : nil
    }

    /// The version of the running bundle, from `CFBundleShortVersionString`.
    static func current(bundle: Bundle = .main) -> AppVersion? {
        (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        // Same numbers: a pre-release precedes the final release of that number
        // (1.5.0-beta.1 < 1.5.0), matching semver.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return false
        case (.some, nil): return true
        case let (.some(left), .some(right)): return left < right
        }
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
