import Foundation

/// One agent session's share of the tokens spent in a quota window.
struct SessionShare: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let share: Double
    let weightedTokens: Double
}

/// Splits a quota window's spend across local sessions by reading the
/// agents' own transcripts. Estimates only: tokens are weighted roughly by
/// list price (cache reads are cheap, output is dear), which tracks how the
/// subscription limits are metered without claiming to match them exactly.
enum SessionAttribution {
    static let defaultClaudeRoot = Home.url(".claude/projects")
    static let defaultCodexRoot = Home.url(".codex/sessions")

    static func shares(
        providerID: String,
        since: Date,
        until: Date = .now,
        claudeRoot: URL = defaultClaudeRoot,
        codexRoot: URL = defaultCodexRoot
    ) -> [SessionShare] {
        let usages: [TranscriptCache.Usage]
        switch providerID {
        case "claude": usages = TranscriptCache.claude.scan(root: claudeRoot, since: since).usages
        case "codex": usages = TranscriptCache.codex.scan(root: codexRoot, since: since).usages
        default: return []
        }

        var totals: [String: (name: String, weight: Double)] = [:]
        // Claude Code writes one entry per content block, all with the same
        // message (and usage); a message is counted once.
        var seenMessages = Set<String>()
        for usage in usages where usage.timestamp >= since && usage.timestamp <= until {
            if let messageID = usage.messageID, !seenMessages.insert(messageID).inserted { continue }
            totals[usage.session, default: (usage.name, 0)].weight += usage.weight
            totals[usage.session]?.name = usage.name
        }
        let sum = totals.values.reduce(0) { $0 + $1.weight }
        guard sum > 0 else { return [] }

        // Disambiguate several sessions in the same project.
        var seen: [String: Int] = [:]
        return totals
            .sorted { $0.value.weight != $1.value.weight ? $0.value.weight > $1.value.weight : $0.key < $1.key }
            .map { id, value in
                seen[value.name, default: 0] += 1
                let count = seen[value.name]!
                return SessionShare(
                    id: id,
                    name: count > 1 ? "\(value.name) #\(count)" : value.name,
                    share: value.weight / sum,
                    weightedTokens: value.weight
                )
            }
    }

    /// The window attributed for a provider: its shortest one.
    static func attributionWindow(for provider: ProviderUsage) -> UsageWindow? {
        provider.windows
            .filter { $0.resetsAt != nil && $0.windowMinutes != nil && $0.scope == nil }
            .min { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
    }

    /// Codex usage straight from Codex's own logs: works offline and with an
    /// expired login, as long as Codex ran recently.
    static func codexLocalUsage(
        lookback: TimeInterval = 7 * 86_400,
        root: URL = defaultCodexRoot,
        now: Date = .now
    ) -> ProviderUsage? {
        guard let latest = TranscriptCache.codex.scan(root: root, since: now.addingTimeInterval(-lookback)).rateLimits
        else { return nil }
        // A window that already reset says nothing about now.
        let windows = latest.windows.filter { window in
            window.resetsAt.map { $0 >= now } ?? true
        }
        guard !windows.isEmpty else { return nil }
        var usage = ProviderUsage.make(id: "codex", account: tr("本地记录", "Local log"), windows: windows)
        usage.updatedAt = latest.at
        return usage
    }

    static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return tr("未知项目", "Unknown project") }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        if name == NSUserName() || cwd == NSHomeDirectory() { return tr("主目录", "Home folder") }
        return name.isEmpty ? tr("未知项目", "Unknown project") : name
    }
}

/// What each transcript file contributed, kept between refreshes so a scan
/// only parses the lines appended since the last one. Transcripts only ever
/// grow; a file that shrank or was replaced is read again from the start.
final class TranscriptCache: @unchecked Sendable {
    struct Usage: Sendable {
        let timestamp: Date
        let session: String
        let name: String
        let weight: Double
        let messageID: String?
    }

    /// A rate-limit snapshot Codex recorded in its log.
    struct RateLimits: Sendable {
        let at: Date
        let windows: [UsageWindow]
    }

    private struct FileState {
        var size: Int
        var modified: Date
        /// Bytes parsed so far, always at a line boundary.
        var offset: UInt64
        var usages: [Usage] = []
        var rateLimits: RateLimits?
        /// Codex names the session once, at the top of the file.
        var session: String?
        var name: String?
    }

    private enum Kind {
        case claude, codex
    }

    static let claude = TranscriptCache(kind: .claude)
    static let codex = TranscriptCache(kind: .codex)

    /// Files untouched for this long drop out of the cache; no quota window
    /// reaches back further.
    private static let retention: TimeInterval = 8 * 86_400

    private let kind: Kind
    private let lock = NSLock()
    private var files: [String: FileState] = [:]

    private init(kind: Kind) {
        self.kind = kind
    }

    /// Usages from every transcript modified since `since` (callers filter
    /// by timestamp), and the newest rate-limit snapshot among them.
    func scan(root: URL, since: Date) -> (usages: [Usage], rateLimits: RateLimits?) {
        lock.lock()
        defer { lock.unlock() }

        var usages: [Usage] = []
        var latest: RateLimits?
        for (url, size, modified) in Self.recentFiles(under: root, since: since) {
            let path = url.path
            var state = files[path] ?? FileState(size: 0, modified: .distantPast, offset: 0)
            if size < state.size || (size == state.size && modified != state.modified) {
                state = FileState(size: 0, modified: .distantPast, offset: 0)
            }
            if size != state.size || modified != state.modified {
                parse(url, into: &state)
                state.size = size
                state.modified = modified
                files[path] = state
            }
            usages += state.usages
            if let limits = state.rateLimits, limits.at > (latest?.at ?? .distantPast) {
                latest = limits
            }
        }

        let cutoff = Date.now.addingTimeInterval(-Self.retention)
        files = files.filter { $0.value.modified >= cutoff }
        return (usages, latest)
    }

    // MARK: Parsing

    private func parse(_ url: URL, into state: inout FileState) {
        let fallbackSession = url.deletingPathExtension().lastPathComponent
        let needle = kind == .claude ? "\"usage\"" : nil
        state.offset = Self.forEachLine(in: url, from: state.offset, containing: needle) { entry in
            switch kind {
            case .claude:
                if let usage = Self.claudeUsage(entry, fallbackSession: fallbackSession) {
                    state.usages.append(usage)
                }
            case .codex:
                Self.codexEntry(entry, fallbackSession: fallbackSession, into: &state)
            }
        }
    }

    private static func claudeUsage(_ entry: [String: Any], fallbackSession: String) -> Usage? {
        guard entry["type"] as? String == "assistant",
              let message = entry["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              // Only the Claude subscription: CC Switch can point Claude
              // Code at other providers' models, which don't count here.
              (message["model"] as? String)?.hasPrefix("claude") == true,
              let timestamp = (entry["timestamp"] as? String).flatMap(ISODate.parse) else { return nil }

        let weight = (Num.double(usage["input_tokens"]) ?? 0)
            + 1.25 * (Num.double(usage["cache_creation_input_tokens"]) ?? 0)
            + 0.1 * (Num.double(usage["cache_read_input_tokens"]) ?? 0)
            + 5 * (Num.double(usage["output_tokens"]) ?? 0)
        return Usage(
            timestamp: timestamp,
            session: (entry["sessionId"] as? String) ?? fallbackSession,
            name: SessionAttribution.projectName(entry["cwd"] as? String),
            weight: weight,
            messageID: (message["id"] as? String) ?? (entry["requestId"] as? String)
        )
    }

    private static func codexEntry(_ entry: [String: Any], fallbackSession: String, into state: inout FileState) {
        let payload = entry["payload"] as? [String: Any] ?? [:]
        switch entry["type"] as? String {
        case "session_meta":
            state.session = (payload["id"] as? String) ?? state.session
            state.name = SessionAttribution.projectName(payload["cwd"] as? String)
        case "event_msg" where payload["type"] as? String == "token_count":
            guard let timestamp = (entry["timestamp"] as? String).flatMap(ISODate.parse) else { return }
            if let limits = payload["rate_limits"] as? [String: Any],
               timestamp > (state.rateLimits?.at ?? .distantPast) {
                state.rateLimits = RateLimits(at: timestamp, windows: codexWindows(limits))
            }
            guard let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { return }
            let input = Num.double(last["input_tokens"]) ?? 0
            let cached = Num.double(last["cached_input_tokens"]) ?? 0
            let output = Num.double(last["output_tokens"]) ?? 0
            state.usages.append(Usage(
                timestamp: timestamp,
                session: state.session ?? fallbackSession,
                name: state.name ?? "Codex",
                weight: max(0, input - cached) + 0.1 * cached + 8 * output,
                messageID: nil
            ))
        default:
            break
        }
    }

    private static func codexWindows(_ limits: [String: Any]) -> [UsageWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any],
                  let used = Num.double(window["used_percent"]) else { return nil }
            return UsageWindow.make(
                key: key,
                usedPercent: used,
                minutes: Num.double(window["window_minutes"]).map(Int.init),
                resetsAt: Num.double(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    // MARK: Files

    private static func recentFiles(under root: URL, since: Date) -> [(URL, Int, Date)] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(URL, Int, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true, let modified = values?.contentModificationDate, modified >= since {
                files.append((url, values?.fileSize ?? 0, modified))
            }
        }
        return files
    }

    /// Streams a JSONL file from `offset`, skipping lines without `needle`
    /// before paying for JSON parsing. Returns the offset after the last
    /// complete line, so a line still being written is read next time.
    private static func forEachLine(
        in url: URL,
        from offset: UInt64,
        containing needle: String?,
        _ body: ([String: Any]) -> Void
    ) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return offset }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return offset
        }
        let needleData = needle.map { Data($0.utf8) }
        var buffer = Data()
        var consumed = offset

        func process(_ line: Data) {
            guard !line.isEmpty else { return }
            if let needleData, line.range(of: needleData) == nil { return }
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                body(object)
            }
        }

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            // Walk the lines by index and trim the consumed prefix once per
            // chunk; trimming per line would copy the buffer for every line.
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                process(buffer[start..<newline])
                start = buffer.index(after: newline)
            }
            consumed += UInt64(start - buffer.startIndex)
            buffer = Data(buffer[start...])
        }
        // A last line without its newline counts once it's whole JSON.
        if !buffer.isEmpty, (try? JSONSerialization.jsonObject(with: buffer)) is [String: Any] {
            process(buffer)
            consumed += UInt64(buffer.count)
        }
        return consumed
    }
}
