import Foundation

enum CodexBarCLIError: Error, LocalizedError {
    case notInstalled
    case timedOut
    case failed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled: tr("没有找到 CodexBar 命令行（brew install --cask codexbar）",
                               "CodexBar's command line tool isn't installed (brew install --cask codexbar)")
        case .timedOut: tr("CodexBar 查询超时", "CodexBar timed out")
        case let .failed(message): tr("CodexBar 查询失败：\(message)", "CodexBar failed: \(message)")
        case .invalidOutput: tr("CodexBar 返回了无法解析的数据", "CodexBar returned data that couldn't be read")
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
        _ = fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        _ = fileManager.createFile(atPath: stderrURL.path, contents: nil)
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
                  let used = Num.double(raw["usedPercent"]) else { continue }
            var minutes = Num.double(raw["windowMinutes"]).map { Int($0) }
            var scope: String?
            if minutes == nil, let name = labels[key]?.nonEmpty {
                // A named span ("weekly") is as good as a duration; anything
                // else ("Opus") keeps its own name.
                minutes = WindowLabel.minutes(forName: name)
                scope = minutes == nil ? name : nil
            }
            windows.append(UsageWindow.make(
                key: key,
                scope: scope,
                usedPercent: used,
                minutes: minutes,
                resetsAt: (raw["resetsAt"] as? String).flatMap(ISODate.parse)
            ))
        }

        let error = (entry["error"] as? [String: Any]).map { shortError($0["message"] as? String) }
        // Balance-only accounts have no quota windows to draw.
        if windows.isEmpty, error == nil {
            return nil
        }

        return ProviderUsage.make(id: providerID, account: account, windows: windows, error: error)
    }

    static func shortError(_ message: String?) -> String {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else { return tr("暂时读不到", "Unavailable right now") }
        let first = message
            .split(whereSeparator: { $0 == "." || $0 == "\n" || $0 == "。" })
            .first
            .map(String.init) ?? message
        return first.count > 90 ? String(first.prefix(87)) + "…" : first
    }
}
