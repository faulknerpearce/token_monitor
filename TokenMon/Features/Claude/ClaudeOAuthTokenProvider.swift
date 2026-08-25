import Foundation

/// Reads the Claude Code OAuth access token from the same locations the CLI
/// itself uses: env → `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`)
/// → macOS Keychain `Claude Code-credentials`.
///
/// The JSON shape is `{ "claudeAiOauth": { "accessToken": "...",
/// "refreshToken": "...", "expiresAt": 1712800000000 } }`.
/// The Keychain entry (macOS) holds that same JSON as its generic password.
enum ClaudeOAuthTokenProvider {
    /// Returns a non-expired access token if one can be found, otherwise `nil`.
    static func accessToken() -> String? {
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let token = tokenFromCredentialsFile(), !isExpired(token: token) { return token.accessToken }
        if let token = tokenFromKeychain(), !isExpired(token: token) { return token.accessToken }
        // Fallback: file token may exist but be expired — still return it so the
        // caller can try and get a 401 to surface re-auth guidance; the poller
        // treats 401 as session-expired.
        if let token = tokenFromCredentialsFile() { return token.accessToken }
        if let token = tokenFromKeychain() { return token.accessToken }
        return nil
    }

    private struct Token: Sendable {
        var accessToken: String
        var expiresAt: Date?
    }

    private static func isExpired(token: Token) -> Bool {
        guard let exp = token.expiresAt else { return false }
        // 60s buffer as the reference implementation uses.
        return Date() >= exp.addingTimeInterval(-60)
    }

    // MARK: - File

    private static func credentialsFileURL() -> URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Prefer the real home (not the app sandbox container) — `homeDirectoryForCurrentUser`
        // already does the right thing on macOS, but `~/.claude` is the CLI's path.
        let realHome: String
        if let pw = getpwuid(getuid()), let cStr = pw.pointee.pw_dir {
            realHome = String(cString: cStr)
        } else {
            realHome = home
        }
        return URL(fileURLWithPath: realHome).appendingPathComponent(".claude/.credentials.json")
    }

    private static func tokenFromCredentialsFile() -> Token? {
        let url = credentialsFileURL()
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parseToken(from: root)
    }

    // MARK: - Keychain (macOS)

    private static func tokenFromKeychain() -> Token? {
        // Use the `security` CLI as the simplest cross-process Keychain read that
        // matches how community tools do it. The Security framework's
        // `SecItemCopyMatching` would require entitlements the app avoids in
        // ad-hoc debug builds.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !json.isEmpty,
                let jData = json.data(using: .utf8),
                let root = try? JSONSerialization.jsonObject(with: jData) as? [String: Any]
            else { return nil }
            return parseToken(from: root)
        } catch {
            return nil
        }
    }

    private static func parseToken(from root: [String: Any]) -> Token? {
        // Shape: { "claudeAiOauth": { "accessToken": "…", "expiresAt": 123… } }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        var expires: Date?
        if let raw = oauth["expiresAt"] as? Double {
            expires = dateFromExpiresAt(raw)
        } else if let raw = oauth["expiresAt"] as? Int {
            expires = dateFromExpiresAt(Double(raw))
        } else if let rawStr = oauth["expiresAt"] as? String, let raw = Double(rawStr) {
            expires = dateFromExpiresAt(raw)
        }
        return Token(accessToken: access, expiresAt: expires)
    }

    /// Claude Code writes epoch **milliseconds** (≥ 1e11). Older tooling
    /// sometimes wrote seconds — detect the unit rather than always ÷1000.
    private static func dateFromExpiresAt(_ raw: Double) -> Date {
        if raw >= 1e11 {
            return Date(timeIntervalSince1970: raw / 1000)
        }
        return Date(timeIntervalSince1970: raw)
    }
}
