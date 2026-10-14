import Foundation

/// One quota window (5-hour session, weekly, monthly…) for a provider account.
struct UsageWindow: Identifiable, Equatable, Codable, Sendable {
    let key: String
    let label: String
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    var id: String { key }

    /// Longer windows sit on the outer ring.
    var spanRank: Int {
        if let windowMinutes { return windowMinutes }
        switch key {
        case "tertiary": return 43_200
        case "secondary": return 10_080
        default: return 300
        }
    }
}

struct ProviderUsage: Identifiable, Equatable, Codable, Sendable {
    let providerID: String
    let name: String
    let shortName: String
    let account: String?
    /// Longest window first (outer ring → inner ring).
    let windows: [UsageWindow]
    var error: String?
    /// When these windows were fetched.
    var updatedAt: Date?
    /// The latest refresh failed; windows are the last good reading.
    var isStale = false
    /// Local sessions' shares of the attributed (shortest) window.
    var sessionShares: [SessionShare] = []

    var id: String { "\(providerID)|\(account ?? "")" }

    var peak: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }
}

enum CodexBarCLIError: Error, LocalizedError {
    case notInstalled
    case timedOut
    case failed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled: "没有找到 CodexBar 命令行（brew install --cask codexbar）"
        case .timedOut: "CodexBar 查询超时"
        case let .failed(message): "CodexBar 查询失败：\(message)"
        case .invalidOutput: "CodexBar 返回了无法解析的数据"
        }
    }
}

/// Shells out to `codexbar usage --format json`. CodexBar owns every provider
/// credential (OAuth, browser cookies, API keys); this app only draws rings.
enum CodexBarCLI {
    /// GUI apps don't inherit the shell PATH, so probe install locations.
    static let candidatePaths = [
        "/opt/homebrew/bin/codexbar",
        "/usr/local/bin/codexbar",
        "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
    ]

    static func executableURL() -> URL? {
        candidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func fetch(timeout: TimeInterval = 90) throws -> [ProviderUsage] {
        guard let executableURL = executableURL() else {
            throw CodexBarCLIError.notInstalled
        }

        // Temp files instead of pipes: no pipe-buffer stalls, and nothing has
        // to be drained concurrently while we wait on the timeout.
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("usage-rings-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let stdoutURL = scratch.appendingPathComponent("stdout.json")
        let stderrURL = scratch.appendingPathComponent("stderr.txt")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["usage", "--format", "json", "--no-color"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw CodexBarCLIError.timedOut
        }

        // Non-zero exit just means one provider failed; the JSON array is
        // still complete, so only empty stdout is fatal.
        let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
        guard !output.isEmpty else {
            let message = (try? String(contentsOf: stderrURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CodexBarCLIError.failed(String(message.prefix(160)))
        }
        return try parse(output)
    }

    static func parse(_ data: Data) throws -> [ProviderUsage] {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CodexBarCLIError.invalidOutput
        }
        return entries.compactMap(parseProvider)
    }

    private static func parseProvider(_ entry: [String: Any]) -> ProviderUsage? {
        guard let providerID = entry["provider"] as? String, !providerID.isEmpty else {
            return nil
        }

        let usage = entry["usage"] as? [String: Any] ?? [:]
        let labels = entry["rateWindowLabels"] as? [String: String] ?? [:]
        let identity = usage["identity"] as? [String: Any]
        let account = (usage["accountEmail"] as? String) ?? (identity?["accountEmail"] as? String)

        var windows: [UsageWindow] = []
        for key in ["primary", "secondary", "tertiary"] {
            guard let raw = usage[key] as? [String: Any],
                  let used = number(raw["usedPercent"]) else { continue }
            let minutes = number(raw["windowMinutes"]).map { Int($0) }
            windows.append(
                UsageWindow(
                    key: key,
                    label: windowLabel(minutes: minutes, fallback: labels[key], key: key),
                    usedPercent: min(max(used, 0), 100),
                    windowMinutes: minutes,
                    resetsAt: (raw["resetsAt"] as? String).flatMap(parseDate)
                )
            )
        }

        let error = (entry["error"] as? [String: Any]).map { shortError($0["message"] as? String) }
        // Balance-only accounts have no quota windows to draw.
        if windows.isEmpty, error == nil {
            return nil
        }

        return ProviderUsage.make(id: providerID, account: account, windows: windows, error: error)
    }

    static func windowLabel(minutes: Int?, fallback: String?, key: String) -> String {
        if let minutes, minutes > 0 {
            if minutes < 24 * 60 { return "\(max(1, minutes / 60))h" }
            if minutes <= 2 * 24 * 60 { return "日" }
            if minutes <= 8 * 24 * 60 { return "周" }
            return "月"
        }
        switch fallback?.lowercased() {
        case "session", "5-hour", "5 hour", "5h": return "5h"
        case "daily", "day": return "日"
        case "weekly", "week": return "周"
        case "monthly", "month": return "月"
        case let other?: return String(other.prefix(3))
        case nil: return key == "primary" ? "5h" : key == "secondary" ? "周" : "月"
        }
    }

    static func shortError(_ message: String?) -> String {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return "暂时读不到" }
        let first = message
            .split(whereSeparator: { $0 == "." || $0 == "\n" || $0 == "。" })
            .first
            .map(String.init) ?? message
        return first.count > 90 ? String(first.prefix(87)) + "…" : first
    }

    private static func number(_ value: Any?) -> Double? {
        Num.double(value)
    }

    private static func parseDate(_ string: String) -> Date? {
        ISODate.parse(string)
    }
}

/// Display names shared by the built-in and CodexBar sources.
enum ProviderCatalog {
    private static let names: [String: (name: String, short: String)] = [
        "codex": ("Codex", "Codex"),
        "openai": ("OpenAI", "OpenAI"),
        "claude": ("Claude", "Claude"),
        "cursor": ("Cursor", "Cursor"),
        "opencode": ("OpenCode", "OpenCode"),
        "opencodego": ("OpenCode Go", "OC Go"),
        "gemini": ("Gemini", "Gemini"),
        "antigravity": ("Antigravity", "AGY"),
        "copilot": ("Copilot", "Copilot"),
        "kimi": ("Kimi Code", "Kimi"),
        "moonshot": ("Moonshot", "Moonshot"),
        "deepseek": ("DeepSeek", "DeepSeek"),
        "doubao": ("豆包", "豆包"),
        "zai": ("智谱 GLM", "GLM"),
        "minimax": ("MiniMax", "MiniMax"),
        "qwencloud": ("通义千问", "Qwen"),
        "openrouter": ("OpenRouter", "ORouter"),
        "windsurf": ("Windsurf", "Windsurf"),
        "factory": ("Droid", "Droid"),
    ]

    static func name(for id: String) -> String {
        names[id]?.name ?? fallback(id)
    }

    static func shortName(for id: String) -> String {
        names[id]?.short ?? fallback(id)
    }

    private static func fallback(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var providers: [ProviderUsage] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false
    /// Provider whose detail card is showing (hover), or pinned by a click.
    @Published var hoveredID: String?
    @Published var pinnedID: String?
    /// The side column is being dragged; suppress hover cards meanwhile.
    @Published var isDragging = false
    @Published var isIslandHovered = false

    var expandedID: String? { isDragging ? nil : (hoveredID ?? pinnedID) }

    /// Where usage comes from; the app delegate keeps this in sync with settings.
    var dataSource: DataSource = .auto {
        didSet {
            if dataSource != oldValue { refresh(force: true) }
        }
    }

    private var pollTask: Task<Void, Never>?
    private var pollInterval: Duration?

    private static let lastGoodKey = "lastGoodUsage"
    /// Last successful reading per provider, kept across launches so an
    /// expired login still shows where that quota stood.
    private var lastGood: [String: ProviderUsage] = {
        guard let data = UserDefaults.standard.data(forKey: UsageStore.lastGoodKey),
              let decoded = try? JSONDecoder().decode([String: ProviderUsage].self, from: data) else { return [:] }
        return decoded
    }()

    /// Snapshot mode only: render a fixed dataset without polling.
    func load(_ providers: [ProviderUsage], updatedAt: Date) {
        self.providers = providers
        self.lastUpdated = updatedAt
    }

    /// Starts polling, or restarts it when the interval changed.
    func start(every interval: Duration = .seconds(150)) {
        guard pollTask == nil || pollInterval != interval else { return }
        pollTask?.cancel()
        pollInterval = interval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh(force: Bool = false) {
        guard force || !isLoading else { return }
        isLoading = true

        let source = dataSource
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () async -> Result<[ProviderUsage], any Error> in
                let fetched: Result<[ProviderUsage], any Error>
                switch source {
                case .builtIn:
                    fetched = .success(await BuiltInProviders.fetchAll())
                case .codexBar:
                    fetched = Result { try CodexBarCLI.fetch() }
                case .auto:
                    fetched = .success(await Self.fetchAuto())
                }
                // Transcript scanning stays off the main actor.
                return fetched.map(Self.attributingSessions)
            }.value

            guard let self else { return }
            self.isLoading = false
            switch result {
            case let .success(providers):
                self.providers = self.fillingFromLastGood(providers)
                self.lastUpdated = .now
                self.lastError = nil
            case let .failure(error):
                // Keep the last good rings on a transient failure.
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Built-in first; anything it can't read is filled from CodexBar when
    /// CodexBar happens to be installed. Without CodexBar this is just the
    /// built-in result.
    nonisolated static func fetchAutoForSnapshot() async -> [ProviderUsage] {
        await fetchAuto()
    }

    /// Adds "which session used it" shares for providers whose agents keep
    /// local transcripts (Claude Code, Codex).
    nonisolated static func attributingSessions(_ providers: [ProviderUsage]) -> [ProviderUsage] {
        providers.map { provider in
            guard ["claude", "codex"].contains(provider.providerID),
                  let window = SessionAttribution.attributionWindow(for: provider),
                  let resetsAt = window.resetsAt,
                  let minutes = window.windowMinutes else { return provider }
            var enriched = provider
            enriched.sessionShares = SessionAttribution.shares(
                providerID: provider.providerID,
                since: resetsAt.addingTimeInterval(-TimeInterval(minutes * 60))
            )
            return enriched
        }
    }

    nonisolated private static func fetchAuto() async -> [ProviderUsage] {
        async let builtIn = BuiltInProviders.fetchAll()
        let codexBar: [ProviderUsage] = CodexBarCLI.executableURL() == nil
            ? []
            : ((try? CodexBarCLI.fetch()) ?? [])
        let own = await builtIn

        var merged: [ProviderUsage] = own.map { mine in
            guard mine.windows.isEmpty,
                  let theirs = codexBar.first(where: { $0.providerID == mine.providerID && !$0.windows.isEmpty })
            else { return mine }
            return theirs
        }
        let ownIDs = Set(own.map(\.providerID))
        merged += codexBar.filter { !ownIDs.contains($0.providerID) }
        return merged
    }

    /// Stamps fresh readings and swaps a failed provider for its last good
    /// reading, marked stale, so the ring keeps its place.
    private func fillingFromLastGood(_ fresh: [ProviderUsage]) -> [ProviderUsage] {
        let now = Date.now
        let result = fresh.map { provider -> ProviderUsage in
            if !provider.windows.isEmpty {
                var stamped = provider
                stamped.updatedAt = provider.updatedAt ?? now
                stamped.isStale = false
                lastGood[provider.providerID] = stamped
                return stamped
            }
            guard var cached = lastGood[provider.providerID] else { return provider }
            cached.isStale = true
            cached.error = provider.error
            return cached
        }
        if let data = try? JSONEncoder().encode(lastGood) {
            UserDefaults.standard.set(data, forKey: Self.lastGoodKey)
        }
        return result
    }
}
