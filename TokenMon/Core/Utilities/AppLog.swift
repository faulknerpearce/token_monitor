import Foundation
import os

/// Single source of truth for logging subsystem and User-Agent identity.
enum AppLog {
    static let subsystem = "com.modelmonitor.app"
}

/// Bundle-derived identity (`TokenMon/<version>`) sent as the API `User-Agent`.
enum AppIdentity {
    /// e.g. "TokenMon/1.2.1" — version tracks MARKETING_VERSION automatically.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return "TokenMon/\(version)"
    }
}

extension Logger {
    init(category: String) {
        self.init(subsystem: AppLog.subsystem, category: category)
    }
}
