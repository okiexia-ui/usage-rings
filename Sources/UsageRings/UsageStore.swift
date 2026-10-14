import Foundation

/// One quota window (5-hour session, weekly, monthly…) for a provider account.
struct UsageWindow: Identifiable, Equatable, Sendable {
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

struct ProviderUsage: Identifiable, Equatable, Sendable {
    let providerID: String
    let name: String
    let shortName: String
    let account: String?
    /// Longest window first (outer ring → inner ring).
    let windows: [UsageWindow]
    let error: String?

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

        let names = displayNames[providerID]
        let fallbackName = providerID.prefix(1).uppercased() + providerID.dropFirst()
        return ProviderUsage(
            providerID: providerID,
            name: names?.name ?? fallbackName,
            shortName: names?.short ?? fallbackName,
            account: account,
            windows: windows.sorted { $0.spanRank > $1.spanRank },
            error: error
        )
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

    private static let displayNames: [String: (name: String, short: String)] = [
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
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
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

    private var pollTask: Task<Void, Never>?
    private var pollInterval: Duration?

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

    func refresh() {
        guard !isLoading else { return }
        isLoading = true

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try CodexBarCLI.fetch() }
            }.value

            guard let self else { return }
            self.isLoading = false
            switch result {
            case let .success(providers):
                self.providers = providers
                self.lastUpdated = .now
                self.lastError = nil
            case let .failure(error):
                // Keep the last good rings on a transient failure.
                self.lastError = error.localizedDescription
            }
        }
    }
}
