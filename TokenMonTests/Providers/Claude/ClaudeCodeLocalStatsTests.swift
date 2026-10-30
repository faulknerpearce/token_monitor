@testable import TokenMon
import XCTest

final class ClaudeCodeLocalStatsTests: XCTestCase {
    private func line(
        id: String,
        request: String,
        at timestamp: String,
        model: String = "claude-opus-4-1",
        input: Int = 10,
        output: Int = 20,
        cacheRead: Int = 300,
        cacheWrite: Int = 40,
        cacheWrite1h: Int? = nil
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": cacheWrite
        ]
        if let cacheWrite1h {
            usage["cache_creation"] = [
                "ephemeral_1h_input_tokens": cacheWrite1h,
                "ephemeral_5m_input_tokens": cacheWrite - cacheWrite1h
            ]
        }
        let object: [String: Any] = [
            "type": "assistant",
            "timestamp": timestamp,
            "requestId": request,
            "message": [
                "id": id,
                "model": model,
                "usage": usage
            ]
        ]
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private let userLine = #"{"type":"user","timestamp":"2026-10-10T12:00:00.000Z","message":{"role":"user","content":"hi"}}"#

    func testParsesAssistantUsageAndSkipsOtherLines() {
        let jsonl = [
            userLine,
            line(id: "msg_1", request: "req_1", at: "2026-10-10T12:00:01.000Z"),
            line(id: "msg_s", request: "req_s", at: "2026-10-10T12:00:02.000Z", model: "<synthetic>"),
            "not json"
        ].joined(separator: "\n")
        let entries = ClaudeCodeLocalStats.parse(jsonl: Data(jsonl.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.inputTokens, 10)
        XCTAssertEqual(entries.first?.outputTokens, 20)
        XCTAssertEqual(entries.first?.cacheReadTokens, 300)
        XCTAssertEqual(entries.first?.cacheWrite5mTokens, 40)
        XCTAssertEqual(entries.first?.cacheWrite1hTokens, 0)
        XCTAssertEqual(entries.first?.dedupeKey, "msg_1:req_1")
    }

    func testParsesASliceOfALargerBuffer() {
        let prefix = Data("{\"type\":\"user\"}\n".utf8)
        let jsonl = [
            line(id: "msg_1", request: "req_1", at: "2026-10-10T12:00:01.000Z"),
            line(id: "msg_2", request: "req_2", at: "2026-10-10T12:00:02.000Z")
        ].joined(separator: "\n")
        let buffer = prefix + Data(jsonl.utf8)
        let slice = buffer[prefix.count...]
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(ClaudeCodeLocalStats.parse(jsonl: slice).map(\.dedupeKey), ["msg_1:req_1", "msg_2:req_2"])
    }

    func testParsesTimestampsWithAndWithoutFractionalSeconds() throws {
        let jsonl = [
            line(id: "msg_1", request: "req_1", at: "2026-10-10T12:00:01.500Z"),
            line(id: "msg_2", request: "req_2", at: "2026-10-10T12:00:01Z")
        ].joined(separator: "\n")
        let dates = ClaudeCodeLocalStats.parse(jsonl: Data(jsonl.utf8)).map(\.date)
        XCTAssertEqual(dates.count, 2)
        XCTAssertEqual(dates[0].timeIntervalSince(dates[1]), 0.5, accuracy: 0.001)
    }

    func testSplitsCacheWritesByLifetime() {
        let jsonl = line(id: "m", request: "r", at: "2026-10-10T12:00:00Z", cacheWrite: 100, cacheWrite1h: 70)
        let entry = ClaudeCodeLocalStats.parse(jsonl: Data(jsonl.utf8)).first
        XCTAssertEqual(entry?.cacheWrite5mTokens, 30)
        XCTAssertEqual(entry?.cacheWrite1hTokens, 70)
    }

    func testOneHourCacheWritesNeverExceedTheTotal() {
        let jsonl = line(id: "m", request: "r", at: "2026-10-10T12:00:00Z", cacheWrite: 10, cacheWrite1h: 50)
        let entry = ClaudeCodeLocalStats.parse(jsonl: Data(jsonl.utf8)).first
        XCTAssertEqual(entry?.cacheWrite5mTokens, 0)
        XCTAssertEqual(entry?.cacheWrite1hTokens, 10)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    func testDailyTokensDedupeAndGroupByDayAndModel() {
        let jsonl = [
            // Streamed response written twice (one line per content block).
            line(id: "msg_1", request: "req_1", at: "2026-10-10T12:00:01Z"),
            line(id: "msg_1", request: "req_1", at: "2026-10-10T12:00:02Z"),
            line(id: "msg_2", request: "req_2", at: "2026-10-10T13:00:00Z", input: 1, output: 2, cacheRead: 3, cacheWrite: 4),
            line(id: "msg_3", request: "req_3", at: "2026-10-10T14:00:00Z", model: "claude-sonnet-5-5"),
            line(id: "msg_4", request: "req_4", at: "2026-10-11T09:00:00Z")
        ].joined(separator: "\n")
        let entries = ClaudeCodeLocalStats.parse(jsonl: Data(jsonl.utf8))

        let days = ClaudeCodeLocalStats.dailyTokens(entries: entries, calendar: utcCalendar)
        XCTAssertEqual(Set(days.keys), ["2026-10-10", "2026-10-11"])
        let opus = days["2026-10-10"]?["claude-opus-4-1"]
        XCTAssertEqual(opus?.responseCount, 2)
        XCTAssertEqual(opus?.inputTokens, 11)
        XCTAssertEqual(opus?.outputTokens, 22)
        XCTAssertEqual(opus?.totalTokens, 380)
        XCTAssertEqual(days["2026-10-10"]?["claude-sonnet-5-5"]?.responseCount, 1)
        XCTAssertEqual(days["2026-10-11"]?["claude-opus-4-1"]?.totalTokens, 370)
    }

    func testDailyTokensUseTheCalendarsLocalDay() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? tokyo.timeZone
        let jsonl = line(id: "m", request: "r", at: "2026-10-10T20:00:00Z")
        let days = ClaudeCodeLocalStats.dailyTokens(
            entries: ClaudeCodeLocalStats.parse(jsonl: Data(jsonl.utf8)),
            calendar: tokyo
        )
        XCTAssertEqual(Array(days.keys), ["2026-10-11"])
    }

    func testScanReadsNestedTranscripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("projects/-Users-me-app", isDirectory: true)
        let subagents = project.appendingPathComponent("session/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(line(id: "a", request: "r1", at: "2026-10-10T12:00:00Z").utf8)
            .write(to: project.appendingPathComponent("session.jsonl"))
        try Data(line(id: "b", request: "r2", at: "2026-10-10T12:05:00Z").utf8)
            .write(to: subagents.appendingPathComponent("agent.jsonl"))

        let days = try XCTUnwrap(ClaudeCodeLocalStats.scanDailyTokens(
            directories: [root.appendingPathComponent("projects")],
            calendar: utcCalendar,
            cache: ClaudeCodeFileCache()
        ))
        XCTAssertEqual(days["2026-10-10"]?["claude-opus-4-1"]?.responseCount, 2)
    }

    /// A repeat scan picks up appended lines, leaves a partly written line for
    /// later, and drops the entries of a file that was removed or rewritten.
    func testRepeatScansFollowAppendsRewritesAndRemovals() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = projects.appendingPathComponent("session.jsonl")
        let other = projects.appendingPathComponent("other.jsonl")
        let cache = ClaudeCodeFileCache()
        func responses() throws -> Int? {
            let days = try XCTUnwrap(ClaudeCodeLocalStats.scanDailyTokens(
                directories: [projects],
                calendar: utcCalendar,
                cache: cache
            ))
            return days["2026-10-10"]?["claude-opus-4-1"]?.responseCount
        }

        let first = line(id: "a", request: "r1", at: "2026-10-10T12:00:00Z")
        let second = line(id: "b", request: "r2", at: "2026-10-10T12:05:00Z")
        try Data((first + "\n").utf8).write(to: session)
        try Data((line(id: "c", request: "r3", at: "2026-10-10T12:06:00Z") + "\n").utf8).write(to: other)
        XCTAssertEqual(try responses(), 2)

        // A partly written line is not read yet.
        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.prefix(20).utf8))
        XCTAssertEqual(try responses(), 2)

        // Once the line is finished, only the appended bytes are read.
        try handle.write(contentsOf: Data((second.dropFirst(20) + "\n").utf8))
        try handle.close()
        XCTAssertEqual(try responses(), 3)

        // A rewritten (shorter) file is parsed again and its old entries dropped.
        try Data((first + "\n").utf8).write(to: session)
        XCTAssertEqual(try responses(), 2)

        try FileManager.default.removeItem(at: other)
        XCTAssertEqual(try responses(), 1)
    }

    func testScanIsNilWithoutClaudeCode() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/projects")
        XCTAssertNil(ClaudeCodeLocalStats.scanDailyTokens(directories: [missing], cache: ClaudeCodeFileCache()))
    }

    func testProjectsDirectoriesHonorsConfigDir() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(
            ClaudeCodeLocalStats.projectsDirectories(environment: [:], home: home).map(\.path),
            ["/Users/me/.config/claude/projects", "/Users/me/.claude/projects"]
        )
        XCTAssertEqual(
            ClaudeCodeLocalStats.projectsDirectories(environment: ["CLAUDE_CONFIG_DIR": "/a, /b"], home: home).map(\.path),
            ["/a/projects", "/b/projects"]
        )
    }
}
