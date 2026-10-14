import Foundation

// MARK: - Pace

/// How fast a quota window is being used compared with an even pace.
struct Pace: Equatable {
    /// Share of the window that has elapsed, 0…100.
    let expectedPercent: Double
    /// Seconds until the window is used up at the current rate, if it will
    /// run out before it resets.
    let runsOutIn: TimeInterval?

    var willLastToReset: Bool { runsOutIn == nil }

    /// Positive = ahead of an even pace (burning faster than time passes).
    func delta(used: Double) -> Double { used - expectedPercent }

    static func of(_ window: UsageWindow, now: Date = .now) -> Pace? {
        guard let resetsAt = window.resetsAt,
              let minutes = window.windowMinutes, minutes > 0 else { return nil }
        let length = TimeInterval(minutes * 60)
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = length - remaining
        // Too early in the window to say anything meaningful.
        guard remaining > 0, elapsed > min(600, length * 0.02) else { return nil }

        let expected = min(100, max(0, elapsed / length * 100))
        guard window.usedPercent > 0 else {
            return Pace(expectedPercent: expected, runsOutIn: nil)
        }
        let rate = window.usedPercent / elapsed
        let secondsToEmpty = (100 - window.usedPercent) / rate
        return Pace(expectedPercent: expected, runsOutIn: secondsToEmpty < remaining ? secondsToEmpty : nil)
    }
}

// MARK: - Recommendation

enum Recommendation {
    /// The provider with the most headroom that won't run dry before its
    /// windows reset; falls back to plain headroom when every provider is
    /// on track to run out.
    static func pick(_ providers: [ProviderUsage], now: Date = .now) -> ProviderUsage? {
        let candidates = providers.filter { !$0.windows.isEmpty && !$0.isStale }
        guard candidates.count > 1 else { return nil }

        func headroom(_ provider: ProviderUsage) -> Double {
            100 - (provider.peak?.usedPercent ?? 100)
        }
        func lasts(_ provider: ProviderUsage) -> Bool {
            provider.windows.allSatisfy { Pace.of($0, now: now)?.willLastToReset ?? true }
        }

        let ranked = candidates.sorted { lhs, rhs in
            if lasts(lhs) != lasts(rhs) { return lasts(lhs) }
            return headroom(lhs) > headroom(rhs)
        }
        guard let best = ranked.first, headroom(best) >= 15 else { return nil }
        return best
    }
}

// MARK: - Session attribution

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
        let totals: [String: (name: String, weight: Double)]
        switch providerID {
        case "claude": totals = claude(since: since, until: until, root: claudeRoot)
        case "codex": totals = codex(since: since, until: until, root: codexRoot).totals
        default: return []
        }
        let sum = totals.values.reduce(0) { $0 + $1.weight }
        guard sum > 0 else { return [] }

        // Disambiguate several sessions in the same project.
        var seen: [String: Int] = [:]
        return totals
            .sorted { $0.value.weight > $1.value.weight }
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
            .filter { $0.resetsAt != nil && $0.windowMinutes != nil }
            .min { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
    }

    // MARK: Claude Code

    private static func claude(since: Date, until: Date, root: URL) -> [String: (name: String, weight: Double)] {
        var totals: [String: (name: String, weight: Double)] = [:]
        var seenMessages = Set<String>()

        for file in recentFiles(under: root, since: since) {
            forEachLine(in: file, containing: "\"usage\"") { entry in
                guard entry["type"] as? String == "assistant",
                      let message = entry["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      // Only the Claude subscription: CC Switch can point Claude
                      // Code at other providers' models, which don't count here.
                      (message["model"] as? String)?.hasPrefix("claude") == true,
                      let timestamp = (entry["timestamp"] as? String).flatMap(ISODate.parse),
                      timestamp >= since, timestamp <= until else { return }

                // Streaming writes one entry per content block with the same usage.
                let messageID = (message["id"] as? String) ?? (entry["requestId"] as? String) ?? UUID().uuidString
                guard seenMessages.insert(messageID).inserted else { return }

                let weight = (Num.double(usage["input_tokens"]) ?? 0)
                    + 1.25 * (Num.double(usage["cache_creation_input_tokens"]) ?? 0)
                    + 0.1 * (Num.double(usage["cache_read_input_tokens"]) ?? 0)
                    + 5 * (Num.double(usage["output_tokens"]) ?? 0)
                let session = (entry["sessionId"] as? String) ?? file.deletingPathExtension().lastPathComponent
                let name = projectName(entry["cwd"] as? String)
                totals[session, default: (name, 0)].weight += weight
                totals[session]?.name = name
            }
        }
        return totals
    }

    // MARK: Codex

    struct CodexScan {
        var totals: [String: (name: String, weight: Double)] = [:]
        /// The newest rate-limit snapshot Codex itself recorded.
        var latestRateLimits: (at: Date, limits: [String: Any])?
    }

    static func codex(since: Date, until: Date = .now, root: URL = defaultCodexRoot) -> CodexScan {
        var scan = CodexScan()

        for file in recentFiles(under: root, since: since) {
            var sessionID = file.deletingPathExtension().lastPathComponent
            var name = "Codex"
            forEachLine(in: file, containing: nil) { entry in
                let payload = entry["payload"] as? [String: Any] ?? [:]
                switch entry["type"] as? String {
                case "session_meta":
                    sessionID = (payload["id"] as? String) ?? sessionID
                    name = projectName(payload["cwd"] as? String)
                case "event_msg" where payload["type"] as? String == "token_count":
                    guard let timestamp = (entry["timestamp"] as? String).flatMap(ISODate.parse) else { return }
                    if let limits = payload["rate_limits"] as? [String: Any],
                       scan.latestRateLimits.map({ timestamp > $0.at }) ?? true {
                        scan.latestRateLimits = (timestamp, limits)
                    }
                    guard timestamp >= since, timestamp <= until,
                          let info = payload["info"] as? [String: Any],
                          let last = info["last_token_usage"] as? [String: Any] else { return }
                    let input = Num.double(last["input_tokens"]) ?? 0
                    let cached = Num.double(last["cached_input_tokens"]) ?? 0
                    let output = Num.double(last["output_tokens"]) ?? 0
                    let weight = max(0, input - cached) + 0.1 * cached + 8 * output
                    scan.totals[sessionID, default: (name, 0)].weight += weight
                    scan.totals[sessionID]?.name = name
                default:
                    break
                }
            }
        }
        return scan
    }

    /// Codex usage straight from Codex's own logs: works offline and with an
    /// expired login, as long as Codex ran recently.
    static func codexLocalUsage(
        lookback: TimeInterval = 7 * 86_400,
        root: URL = defaultCodexRoot,
        now: Date = .now
    ) -> ProviderUsage? {
        guard let latest = codex(since: now.addingTimeInterval(-lookback), until: now, root: root).latestRateLimits
        else { return nil }
        var windows: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let window = latest.limits[key] as? [String: Any],
                  let used = Num.double(window["used_percent"]) else { continue }
            let reset = Num.double(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            // A window that already reset says nothing about now.
            if let reset, reset < now { continue }
            windows.append(UsageWindow.make(
                key: key,
                usedPercent: used,
                minutes: Num.double(window["window_minutes"]).map(Int.init),
                resetsAt: reset
            ))
        }
        guard !windows.isEmpty else { return nil }
        var usage = ProviderUsage.make(id: "codex", account: "本地记录", windows: windows)
        usage.updatedAt = latest.at
        return usage
    }

    // MARK: File scanning

    private static func recentFiles(under root: URL, since: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            if values?.isRegularFile == true, let modified = values?.contentModificationDate, modified >= since {
                files.append(url)
            }
        }
        return files
    }

    /// Streams a JSONL file line by line, skipping lines without `needle`
    /// before paying for JSON parsing.
    private static func forEachLine(in url: URL, containing needle: String?, _ body: ([String: Any]) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let needleData = needle.map { Data($0.utf8) }
        var buffer = Data()

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
            buffer = Data(buffer[start...])
        }
        process(buffer)
    }

    private static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "未知项目" }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        if name == NSUserName() || cwd == NSHomeDirectory() { return "主目录" }
        return name.isEmpty ? "未知项目" : name
    }
}
