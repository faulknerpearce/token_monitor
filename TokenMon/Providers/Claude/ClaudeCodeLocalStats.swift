import Foundation

/// Token counts for one model, summed over some set of responses.
///
/// Cache writes are split by cache lifetime because the two are priced
/// differently (see ``ClaudeAPIPricing``).
struct ClaudeModelTokens: Codable, Hashable, Sendable {
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    /// Prompt tokens served from the prompt cache (`cache_read_input_tokens`).
    var cacheReadTokens: Int64 = 0
    /// Prompt tokens written to the 5-minute prompt cache.
    var cacheWrite5mTokens: Int64 = 0
    /// Prompt tokens written to the 1-hour prompt cache.
    var cacheWrite1hTokens: Int64 = 0
    /// Distinct assistant responses counted.
    var responseCount: Int = 0

    var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWrite5mTokens: lhs.cacheWrite5mTokens + rhs.cacheWrite5mTokens,
            cacheWrite1hTokens: lhs.cacheWrite1hTokens + rhs.cacheWrite1hTokens,
            responseCount: lhs.responseCount + rhs.responseCount
        )
    }

    /// The larger of each count in `self` and `other`.
    func fieldwiseMax(_ other: Self) -> Self {
        Self(
            inputTokens: max(inputTokens, other.inputTokens),
            outputTokens: max(outputTokens, other.outputTokens),
            cacheReadTokens: max(cacheReadTokens, other.cacheReadTokens),
            cacheWrite5mTokens: max(cacheWrite5mTokens, other.cacheWrite5mTokens),
            cacheWrite1hTokens: max(cacheWrite1hTokens, other.cacheWrite1hTokens),
            responseCount: max(responseCount, other.responseCount)
        )
    }
}

/// Reads per-response token usage from Claude Code's local JSONL transcripts
/// (`~/.claude/projects/**/*.jsonl`, or `~/.config/claude/projects`).
///
/// claude.ai's usage endpoint reports only window percentages, so this is the
/// token source for the Claude panel. It covers Claude Code on this Mac (CLI,
/// IDE extensions, and the desktop app's Code tab), not claude.ai chat.
enum ClaudeCodeLocalStats {
    /// One assistant response's usage.
    struct Entry: Hashable, Sendable {
        var date: Date
        var model: String
        var inputTokens: Int64
        var outputTokens: Int64
        var cacheReadTokens: Int64
        var cacheWrite5mTokens: Int64
        var cacheWrite1hTokens: Int64
        /// `message.id:requestId`; Claude Code writes one line per content
        /// block of a streamed response, each repeating the same usage, and
        /// resumed sessions copy earlier lines, so entries sharing a key are
        /// counted once.
        var dedupeKey: String?
    }

    /// Shared cache of parsed transcript files.
    static let fileCache = ClaudeCodeFileCache()

    /// Candidate `projects` directories: each `CLAUDE_CONFIG_DIR` entry
    /// (comma-separated) when set, else `~/.config/claude` and `~/.claude`.
    static func projectsDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = AppSupport.realHomeDirectory
    ) -> [URL] {
        if let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces),
           !configured.isEmpty {
            return configured.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { path in
                    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                        .appendingPathComponent("projects", isDirectory: true)
                }
        }
        return [
            home.appendingPathComponent(".config/claude/projects", isDirectory: true),
            home.appendingPathComponent(".claude/projects", isDirectory: true)
        ]
    }

    /// Token counts per local day and model across every transcript, or `nil`
    /// when no Claude Code `projects` directory exists on this Mac.
    ///
    /// `cache` keeps every transcript's parsed entries and the running totals,
    /// so a repeat scan parses only the bytes appended since the last one.
    static func scanDailyTokens(
        directories: [URL] = projectsDirectories(),
        calendar: Calendar = .autoupdatingCurrent,
        cache: ClaudeCodeFileCache = fileCache
    ) -> ClaudeDailyTokens? {
        let fm = FileManager.default
        let existing = directories.filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        guard !existing.isEmpty else { return nil }
        for directory in existing {
            cache.update(directory: directory)
        }
        return cache.dailyTokens(calendar: calendar)
    }

    private static let usageMarker = Array("\"usage\"".utf8)

    /// Parses every assistant-usage line in a JSONL transcript.
    ///
    /// Transcripts reach gigabytes, and most lines (user turns, tool results)
    /// carry no usage, so lines are found with `memchr` / `memmem` over the raw
    /// bytes and only lines naming `"usage"` are decoded.
    static func parse(jsonl data: Data) -> [Entry] {
        let decoder = JSONDecoder()
        return usageLineRanges(in: data).compactMap { parseLine(data[$0], decoder: decoder) }
    }

    /// Parses the complete lines of `data`: every newline-terminated line,
    /// plus a final unterminated line when it is whole JSON.
    ///
    /// - Returns: The entries, and the number of bytes those lines span; a
    ///   final line still being written is left for a later read.
    static func parseCompleteLines(_ data: Data) -> (entries: [Entry], consumed: Int) {
        let tailStart = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
        let tail = data[tailStart...]
        let end = tail.isEmpty || (try? JSONSerialization.jsonObject(with: tail)) == nil ? tailStart : data.endIndex
        return (parse(jsonl: data[data.startIndex..<end]), end - data.startIndex)
    }

    /// Index ranges, in `data`'s indices, of the lines that contain `"usage"`.
    static func usageLineRanges(in data: Data) -> [Range<Data.Index>] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Range<Data.Index>] in
            guard let base = raw.baseAddress else { return [] }
            var ranges: [Range<Data.Index>] = []
            var lineStart = 0
            while lineStart < raw.count {
                let remaining = raw.count - lineStart
                let lineEnd = memchr(base + lineStart, 0x0A, remaining)
                    .map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                if memmem(base + lineStart, lineEnd - lineStart, usageMarker, usageMarker.count) != nil {
                    ranges.append((data.startIndex + lineStart)..<(data.startIndex + lineEnd))
                }
                lineStart = lineEnd + 1
            }
            return ranges
        }
    }

    /// One transcript line → its usage entry, or `nil` for any other line.
    static func parseLine(_ line: Data, decoder: JSONDecoder = JSONDecoder()) -> Entry? {
        guard let root = try? decoder.decode(TranscriptLine.self, from: line),
              root.type == "assistant",
              let message = root.message,
              let usage = message.usage,
              let timestamp = root.timestamp,
              let date = ISO8601DateFormatter.parseFlexible(timestamp)
        else { return nil }

        let model = message.model ?? "unknown"
        // Claude Code's locally generated placeholder replies carry zero usage.
        guard model != "<synthetic>" else { return nil }

        var dedupeKey: String?
        if let messageID = message.id, let requestID = root.requestId {
            dedupeKey = "\(messageID):\(requestID)"
        }

        // `cache_creation` splits the writes by cache lifetime; without it,
        // every write is a 5-minute write.
        let cacheWrite = count(usage.cacheWriteTokens)
        let cacheWrite1h = min(cacheWrite, count(usage.cacheCreation?.oneHourTokens))

        return Entry(
            date: date,
            model: model,
            inputTokens: count(usage.inputTokens),
            outputTokens: count(usage.outputTokens),
            cacheReadTokens: count(usage.cacheReadTokens),
            cacheWrite5mTokens: cacheWrite - cacheWrite1h,
            cacheWrite1hTokens: cacheWrite1h,
            dedupeKey: dedupeKey
        )
    }

    /// A non-negative token count, or 0 for a missing or invalid value.
    private static func count(_ value: Double?) -> Int64 {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return Int64(min(value, Double(Int64.max)))
    }

    /// Token counts per ``DayKey`` and model, counting each response once.
    /// A response belongs to the local day its timestamp falls on in `calendar`.
    static func dailyTokens(entries: [Entry], calendar: Calendar) -> ClaudeDailyTokens {
        var tally = ClaudeDailyTokenTally(calendar: calendar)
        for entry in entries {
            tally.add(entry)
        }
        return tally.days
    }
}

/// Running per-day, per-model Claude Code totals that count each response
/// once (see ``ClaudeCodeLocalStats/Entry/dedupeKey``).
struct ClaudeDailyTokenTally {
    let calendar: Calendar
    private(set) var days: ClaudeDailyTokens = [:]
    private var seen = Set<String>()
    /// The day of the last entry added; transcripts are in time order, so
    /// most entries fall on the same day as the one before.
    private var currentDay: (start: Date, end: Date, key: String)?

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    mutating func add(_ entry: ClaudeCodeLocalStats.Entry) {
        if let key = entry.dedupeKey, !seen.insert(key).inserted { return }
        let counts = ClaudeModelTokens(
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheWrite5mTokens: entry.cacheWrite5mTokens,
            cacheWrite1hTokens: entry.cacheWrite1hTokens,
            responseCount: 1
        )
        let day = dayKey(for: entry.date)
        let current = days[day]?[entry.model] ?? ClaudeModelTokens()
        days[day, default: [:]][entry.model] = current + counts
    }

    private mutating func dayKey(for date: Date) -> String {
        if let currentDay, date >= currentDay.start, date < currentDay.end {
            return currentDay.key
        }
        let key = DayKey.key(for: date, calendar: calendar)
        if let interval = calendar.dateInterval(of: .day, for: date) {
            currentDay = (interval.start, interval.end, key)
        }
        return key
    }
}

/// The fields of a Claude Code transcript line that usage needs; the decoder
/// skips every other field.
private struct TranscriptLine: Decodable {
    var type: String?
    var timestamp: String?
    var requestId: String?
    var message: TranscriptMessage?
}

private struct TranscriptMessage: Decodable {
    var id: String?
    var model: String?
    var usage: TranscriptUsage?
}

private struct TranscriptUsage: Decodable {
    var inputTokens: Double?
    var outputTokens: Double?
    var cacheReadTokens: Double?
    var cacheWriteTokens: Double?
    var cacheCreation: TranscriptCacheCreation?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadTokens = "cache_read_input_tokens"
        case cacheWriteTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
    }
}

/// `cache_creation`: cache writes split by cache lifetime.
private struct TranscriptCacheCreation: Decodable {
    var oneHourTokens: Double?

    enum CodingKeys: String, CodingKey {
        case oneHourTokens = "ephemeral_1h_input_tokens"
    }
}

/// Parsed transcript files keyed by path, plus the running totals over them.
///
/// Transcripts are append-only, so a file that grew is read from where the
/// last read stopped; a file that shrank or was replaced, or whose last read
/// did not stop after a newline, is parsed again in full. Totals take only
/// the new entries, and are rebuilt from every file's entries when entries
/// were dropped (a file removed or parsed again).
final class ClaudeCodeFileCache: @unchecked Sendable {
    private struct Item {
        /// The scanned folder the file was found under.
        var root: String
        var modified: Date
        var size: Int
        var fileID: UInt64?
        /// Bytes parsed so far: every complete line.
        var parsedBytes: Int
        var entries: [ClaudeCodeLocalStats.Entry]
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var tally: ClaudeDailyTokenTally?
    /// Entries added since `tally` was last brought up to date.
    private var pending: [ClaudeCodeLocalStats.Entry] = []
    private var needsRebuild = false

    /// Brings the cached entries up to date with every `.jsonl` file under
    /// `directory`, and drops files there that no longer exist.
    func update(directory: URL) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .fileIdentifierKey]
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return }

        var seenPaths = Set<String>()
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            seenPaths.insert(url.path)
            refresh(
                url: url,
                root: directory.path,
                modified: modified,
                size: values.fileSize ?? 0,
                fileID: values.fileIdentifier
            )
        }
        prune(keeping: seenPaths, under: directory.path)
    }

    /// Totals per day and model over every cached file.
    func dailyTokens(calendar: Calendar) -> ClaudeDailyTokens {
        lock.lock()
        defer { lock.unlock() }
        if needsRebuild || tally?.calendar != calendar {
            var rebuilt = ClaudeDailyTokenTally(calendar: calendar)
            for path in items.keys.sorted() {
                for entry in items[path]?.entries ?? [] {
                    rebuilt.add(entry)
                }
            }
            tally = rebuilt
            needsRebuild = false
        } else if var current = tally {
            for entry in pending {
                current.add(entry)
            }
            tally = current
        }
        pending = []
        return tally?.days ?? [:]
    }

    private func refresh(url: URL, root: String, modified: Date, size: Int, fileID: UInt64?) {
        lock.lock()
        let cached = items[url.path]
        lock.unlock()
        if let cached, cached.modified == modified, cached.size == size, cached.fileID == fileID {
            return
        }
        if let cached, cached.fileID == fileID, cached.parsedBytes > 0, size >= cached.parsedBytes,
           let appended = Self.readAppended(url: url, from: cached.parsedBytes) {
            let (entries, consumed) = ClaudeCodeLocalStats.parseCompleteLines(appended)
            lock.lock()
            items[url.path] = Item(
                root: root,
                modified: modified,
                size: size,
                fileID: fileID,
                parsedBytes: cached.parsedBytes + consumed,
                entries: cached.entries + entries
            )
            pending += entries
            lock.unlock()
            return
        }
        let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        let (entries, consumed) = ClaudeCodeLocalStats.parseCompleteLines(data)
        lock.lock()
        items[url.path] = Item(
            root: root,
            modified: modified,
            size: size,
            fileID: fileID,
            parsedBytes: consumed,
            entries: entries
        )
        if cached == nil {
            pending += entries
        } else {
            needsRebuild = true
        }
        lock.unlock()
    }

    /// The bytes after `offset`, or nil when the byte before `offset` is not
    /// the newline the last read ended on (the file was rewritten).
    private static func readAppended(url: URL, from offset: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset - 1))) != nil,
              let data = try? handle.readToEnd() ?? Data(),
              data.first == 0x0A
        else { return nil }
        return data.dropFirst()
    }

    /// Drops cached files found under the `root` folder that the last walk
    /// did not find (deleted since).
    private func prune(keeping paths: Set<String>, under root: String) {
        lock.lock()
        defer { lock.unlock() }
        let kept = items.filter { $0.value.root != root || paths.contains($0.key) }
        if kept.count != items.count {
            items = kept
            needsRebuild = true
        }
    }
}
