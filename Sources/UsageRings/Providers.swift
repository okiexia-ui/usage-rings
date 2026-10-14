import Foundation

/// Built-in usage sources. Each one reuses the login its official CLI/app
/// already saved on this Mac and asks that provider's own usage endpoint.
///
/// Read-only by design: tokens are never refreshed, rewritten or sent
/// anywhere except the provider's own HTTPS host, and redirects are refused
/// so a token can't be forwarded to another host. The owning CLI/app keeps
/// its tokens fresh; when one has expired we say so instead.
protocol BuiltInProvider: Sendable {
    var id: String { get }
    /// Credentials exist on this Mac, so the provider is worth showing.
    func isConfigured() -> Bool
    func fetch() async throws -> ProviderUsage
}

enum ProviderError: LocalizedError {
    case notSignedIn(String)
    case expired(String)
    case http(Int)
    case rateLimited
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case let .notSignedIn(hint): hint
        case let .expired(hint): hint
        case .http(401), .http(403): "登录已失效，请在官方 App 里重新登录"
        case let .http(status): "服务器返回 HTTP \(status)"
        case .rateLimited: "查询太频繁，稍后会自动重试"
        case let .badResponse(message): message
        }
    }
}

enum BuiltInProviders {
    static let all: [any BuiltInProvider] = [
        CodexProvider(),
        ClaudeProvider(),
        OpenCodeGoProvider(),
        KimiProvider(),
    ]

    /// Fetches every configured provider concurrently; a failing provider
    /// becomes an error row instead of failing the whole refresh.
    static func fetchAll() async -> [ProviderUsage] {
        let configured = all.filter { $0.isConfigured() }
        return await withTaskGroup(of: (Int, ProviderUsage).self) { group in
            for (index, provider) in configured.enumerated() {
                group.addTask {
                    do {
                        return (index, try await provider.fetch())
                    } catch {
                        return (index, ProviderUsage.make(
                            id: provider.id,
                            windows: [],
                            error: error.localizedDescription
                        ))
                    }
                }
            }
            var results: [(Int, ProviderUsage)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

// MARK: - Codex

struct CodexProvider: BuiltInProvider {
    let id = "codex"

    private var authURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Home.url(".codex")
        return home.appendingPathComponent("auth.json")
    }

    func isConfigured() -> Bool {
        FileManager.default.fileExists(atPath: authURL.path)
    }

    func fetch() async throws -> ProviderUsage {
        do {
            return try await fetchFromAPI()
        } catch {
            // Codex logs its own rate limits; good enough offline or with an
            // expired login.
            if let local = SessionAttribution.codexLocalUsage() {
                return local
            }
            throw error
        }
    }

    private func fetchFromAPI() async throws -> ProviderUsage {
        guard let json = JSONFile.object(at: authURL),
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] as? String)?.nonEmpty else {
            throw ProviderError.notSignedIn("没有找到 Codex 登录，请先在 Codex 里登录")
        }
        if let expiry = JWT.expiry(accessToken), expiry < .now {
            throw ProviderError.expired("Codex 登录已过期，打开一次 Codex 就会自动续期")
        }

        var headers = HTTP.baseHeaders(token: accessToken)
        if let accountID = (tokens["account_id"] as? String)?.nonEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let body = try await HTTP.getJSONObject(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: headers
        )

        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse("Codex 没有返回额度信息")
        }

        let email = (tokens["id_token"] as? String).flatMap(JWT.email)
        return ProviderUsage.make(id: id, account: email, windows: windows)
    }

    static func windows(from body: [String: Any]) -> [UsageWindow] {
        let rateLimit = body["rate_limit"] as? [String: Any]
        var windows: [UsageWindow] = []
        for (key, field) in [("primary", "primary_window"), ("secondary", "secondary_window")] {
            guard let window = rateLimit?[field] as? [String: Any],
                  let used = Num.double(window["used_percent"]) else { continue }
            let minutes = Num.double(window["limit_window_seconds"]).map { Int($0 / 60) }
            windows.append(UsageWindow.make(
                key: key,
                usedPercent: used,
                minutes: minutes,
                resetsAt: Num.double(window["reset_at"]).map { Date(timeIntervalSince1970: $0) }
            ))
        }
        return windows
    }
}

// MARK: - Claude

struct ClaudeProvider: BuiltInProvider {
    let id = "claude"
    private static let keychainService = "Claude Code-credentials"

    private var credentialsFileURL: URL {
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? Home.url(".claude")
        return configDir.appendingPathComponent(".credentials.json")
    }

    func isConfigured() -> Bool {
        FileManager.default.fileExists(atPath: credentialsFileURL.path)
            || Shell.run("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService]) != nil
    }

    /// Claude Code writes this keychain item with the system `security`
    /// tool, so reading it the same way doesn't raise a keychain prompt.
    private func credentials() -> [String: Any]? {
        if let output = Shell.run("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-w"]),
           let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return JSONFile.object(at: credentialsFileURL)
    }

    func fetch() async throws -> ProviderUsage {
        guard let oauth = credentials()?["claudeAiOauth"] as? [String: Any],
              let accessToken = (oauth["accessToken"] as? String)?.nonEmpty else {
            throw ProviderError.notSignedIn("没有找到 Claude Code 登录，请先运行 claude 登录")
        }
        if let expiresAt = Num.double(oauth["expiresAt"]), expiresAt > 0,
           Date(timeIntervalSince1970: expiresAt / 1000) < .now {
            throw ProviderError.expired("Claude 登录已过期，打开一次 Claude Code 就会自动续期")
        }

        var headers = HTTP.baseHeaders(token: accessToken)
        headers["anthropic-beta"] = "oauth-2025-04-20"
        let body = try await HTTP.getJSONObject(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: headers
        )

        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse("Claude 没有返回额度信息")
        }

        let plan = (oauth["subscriptionType"] as? String)?.nonEmpty.map { "Claude \($0.capitalized)" }
        return ProviderUsage.make(id: id, account: plan, windows: windows)
    }

    static func windows(from body: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        for (key, field, minutes) in [("primary", "five_hour", 300), ("secondary", "seven_day", 10_080)] {
            guard let window = body[field] as? [String: Any],
                  let used = Num.double(window["utilization"]) else { continue }
            windows.append(UsageWindow.make(
                key: key,
                usedPercent: used,
                minutes: minutes,
                resetsAt: (window["resets_at"] as? String).flatMap(ISODate.parse)
            ))
        }
        return windows
    }
}

// MARK: - OpenCode Go

struct OpenCodeGoProvider: BuiltInProvider {
    let id = "opencodego"

    private var authURL: URL {
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Home.url(".local/share")
        return dataHome.appendingPathComponent("opencode/auth.json")
    }

    /// OpenCode stores the Go subscription key under "opencode-go".
    private func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENCODE_API_KEY"]?.nonEmpty {
            return env
        }
        let entry = JSONFile.object(at: authURL)?["opencode-go"] as? [String: Any]
        return (entry?["key"] as? String)?.nonEmpty ?? KeyStore.key(for: id)
    }

    func isConfigured() -> Bool {
        apiKey() != nil
    }

    func fetch() async throws -> ProviderUsage {
        guard let key = apiKey() else {
            throw ProviderError.notSignedIn("没有找到 OpenCode Go 的 API key")
        }
        let body = try await HTTP.getJSONObject(
            URL(string: "https://opencode.ai/zen/go/v1/usage")!,
            headers: HTTP.baseHeaders(token: key)
        )
        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse("OpenCode Go 没有返回额度信息")
        }
        return ProviderUsage.make(id: id, windows: windows)
    }

    static func windows(from body: [String: Any], now: Date = .now) -> [UsageWindow] {
        guard let usage = body["usage"] as? [String: Any] else { return [] }
        var windows: [UsageWindow] = []
        for (key, field, minutes) in [("primary", "rolling", 300), ("secondary", "weekly", 10_080), ("tertiary", "monthly", 43_200)] {
            guard let window = usage[field] as? [String: Any],
                  let used = percent(window) else { continue }
            windows.append(UsageWindow.make(key: key, usedPercent: used, minutes: minutes, resetsAt: reset(window, now: now)))
        }
        return windows
    }

    private static func percent(_ window: [String: Any]) -> Double? {
        for key in ["usagePercent", "usedPercent", "percentUsed", "percent"] {
            if let value = Num.double(window[key]) { return value }
        }
        if let used = Num.double(window["used"] ?? window["usage"]),
           let limit = Num.double(window["limit"] ?? window["total"]), limit > 0 {
            return used / limit * 100
        }
        return nil
    }

    private static func reset(_ window: [String: Any], now: Date) -> Date? {
        for key in ["resetInSec", "resetInSeconds", "resetSeconds"] {
            if let seconds = Num.double(window[key]) { return now.addingTimeInterval(seconds) }
        }
        for key in ["resetAt", "resetsAt", "reset_at"] {
            if let string = window[key] as? String, let date = ISODate.parse(string) { return date }
            if let epoch = Num.double(window[key]) {
                return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1000 : epoch)
            }
        }
        return nil
    }
}

// MARK: - Kimi Code

struct KimiProvider: BuiltInProvider {
    let id = "kimi"

    private var home: URL {
        ProcessInfo.processInfo.environment["KIMI_CODE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? Home.url(".kimi-code")
    }

    private var credentialsURL: URL {
        home.appendingPathComponent("credentials/kimi-code.json")
    }

    /// A Kimi Code API key never expires, unlike the CLI's 15-minute access
    /// token, so it is preferred when the user has created one.
    private var apiKey: String? {
        ProcessInfo.processInfo.environment["KIMI_CODE_API_KEY"]?.nonEmpty ?? KeyStore.key(for: id)
    }

    func isConfigured() -> Bool {
        apiKey != nil || FileManager.default.fileExists(atPath: credentialsURL.path)
    }

    private func cliAccessToken() throws -> String {
        guard let credential = JSONFile.object(at: credentialsURL),
              let accessToken = (credential["access_token"] as? String)?.nonEmpty else {
            throw ProviderError.notSignedIn("没有找到 Kimi Code 登录：运行 kimi 登录，或在设置里填 Kimi Code API Key")
        }
        if let expiresAt = Num.double(credential["expires_at"]),
           Date(timeIntervalSince1970: expiresAt) < .now {
            throw ProviderError.expired("Kimi 命令行登录只在使用时有效；在设置里填 Kimi Code API Key 就能一直读到")
        }
        return accessToken
    }

    func fetch() async throws -> ProviderUsage {
        let accessToken = try apiKey ?? cliAccessToken()

        // The Code API expects the same device identity headers as the CLI.
        var headers = HTTP.baseHeaders(token: accessToken)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        headers["X-Msh-Platform"] = "kimi_code_cli"
        headers["X-Msh-Version"] = HTTP.appVersion
        headers["X-Msh-Device-Name"] = Self.ascii(ProcessInfo.processInfo.hostName)
        headers["X-Msh-Device-Model"] = "macOS \(osVersion) \(Self.architecture)"
        headers["X-Msh-Os-Version"] = osVersion
        headers["X-Msh-Device-Id"] = deviceID()

        let body = try await HTTP.getJSONObject(
            URL(string: "https://api.kimi.com/coding/v1/usages")!,
            headers: headers
        )

        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse("Kimi 没有返回额度信息")
        }
        return ProviderUsage.make(id: id, windows: windows)
    }

    static func windows(from body: [String: Any]) -> [UsageWindow] {
        poolWindows(body) ?? legacyWindows(body)
    }

    /// Newer shape: `usages.limit_5h / limit_7d / limit_month_total` ratios.
    private static func poolWindows(_ body: [String: Any]) -> [UsageWindow]? {
        guard let pools = body["usages"] as? [String: Any] else { return nil }
        var windows: [UsageWindow] = []
        for (key, field, minutes) in [("primary", "limit_5h", 300), ("secondary", "limit_7d", 10_080), ("tertiary", "limit_month_total", 43_200)] {
            guard let pool = pools[field] as? [String: Any],
                  let ratio = Num.double(pool["used_ratio"]) else { continue }
            windows.append(UsageWindow.make(
                key: key,
                usedPercent: min(1, ratio) * 100,
                minutes: minutes,
                resetsAt: (pool["reset_time"] as? String).flatMap(ISODate.parse)
            ))
        }
        return windows.isEmpty ? nil : windows
    }

    /// Older shape: weekly `usage` plus a `limits` array of rate windows.
    private static func legacyWindows(_ body: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let limits = body["limits"] as? [[String: Any]],
           let first = limits.first,
           let detail = first["detail"] as? [String: Any],
           let used = detailPercent(detail) {
            let window = first["window"] as? [String: Any]
            windows.append(UsageWindow.make(
                key: "primary",
                usedPercent: used,
                minutes: windowMinutes(window) ?? 300,
                resetsAt: detailReset(detail)
            ))
        }
        if let weekly = body["usage"] as? [String: Any], let used = detailPercent(weekly) {
            windows.append(UsageWindow.make(key: "secondary", usedPercent: used, minutes: 10_080, resetsAt: detailReset(weekly)))
        }
        return windows
    }

    private static func detailPercent(_ detail: [String: Any]) -> Double? {
        guard let limit = Num.double(detail["limit"]), limit > 0 else { return nil }
        if let used = Num.double(detail["used"]) { return used / limit * 100 }
        if let remaining = Num.double(detail["remaining"]) { return (limit - remaining) / limit * 100 }
        return nil
    }

    private static func detailReset(_ detail: [String: Any]) -> Date? {
        for key in ["resetTime", "reset_time", "reset_at"] {
            if let string = detail[key] as? String, let date = ISODate.parse(string) { return date }
        }
        return nil
    }

    private static func windowMinutes(_ window: [String: Any]?) -> Int? {
        guard let window, let duration = Num.double(window["duration"]), duration > 0 else { return nil }
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": return Int(duration)
        case "TIME_UNIT_HOUR": return Int(duration) * 60
        case "TIME_UNIT_DAY": return Int(duration) * 1_440
        default: return nil
        }
    }

    /// Reuse the CLI's device ID; never write into the CLI's directory.
    private func deviceID() -> String {
        if let existing = try? String(contentsOf: home.appendingPathComponent("device_id"), encoding: .utf8),
           let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return trimmed
        }
        let key = "kimiFallbackDeviceID"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        let generated = UUID().uuidString.lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private static func ascii(_ raw: String) -> String {
        let value = String(raw.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "unknown" : value
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}

// MARK: - Shared helpers

enum HTTP {
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    static func baseHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "UsageRings/\(appVersion)",
        ]
    }

    static func getJSONObject(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw ProviderError.rateLimited }
        guard status == 200 else { throw ProviderError.http(status) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse("返回的数据格式不对")
        }
        return object
    }
}

/// API keys the user pastes into Settings, for providers whose own tools
/// don't leave a long-lived login on disk. Stored like the agents' CLIs store
/// theirs: a JSON file only this user can read.
enum KeyStore {
    /// Tests point this at a temporary file.
    nonisolated(unsafe) static var fileURLOverride: URL?

    static var fileURL: URL {
        if let fileURLOverride { return fileURLOverride }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/UsageRings", isDirectory: true)
            .appendingPathComponent("keys.json")
    }

    static func key(for providerID: String) -> String? {
        (JSONFile.object(at: fileURL)?[providerID] as? String)?.nonEmpty
    }

    static func setKey(_ key: String?, for providerID: String) throws {
        var keys = (JSONFile.object(at: fileURL) as? [String: String]) ?? [:]
        keys[providerID] = key?.nonEmpty
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONSerialization.data(withJSONObject: keys, options: [.sortedKeys])
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum Shell {
    /// Runs a tool and returns trimmed stdout, or nil on a non-zero exit.
    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Home {
    static func url(_ relative: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative, isDirectory: true)
    }
}

enum JSONFile {
    static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum Num {
    static func double(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        case let value as String: Double(value)
        default: nil
        }
    }
}

enum ISODate {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

enum JWT {
    private static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func expiry(_ token: String) -> Date? {
        Num.double(payload(token)?["exp"]).map { Date(timeIntervalSince1970: $0) }
    }

    static func email(_ token: String) -> String? {
        (payload(token)?["email"] as? String)?.nonEmpty
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension UsageWindow {
    static func make(key: String, usedPercent: Double, minutes: Int?, resetsAt: Date?) -> UsageWindow {
        UsageWindow(
            key: key,
            label: CodexBarCLI.windowLabel(minutes: minutes, fallback: nil, key: key),
            usedPercent: min(max(usedPercent, 0), 100),
            windowMinutes: minutes,
            resetsAt: resetsAt
        )
    }
}

extension ProviderUsage {
    static func make(id: String, account: String? = nil, windows: [UsageWindow], error: String? = nil) -> ProviderUsage {
        ProviderUsage(
            providerID: id,
            name: ProviderCatalog.name(for: id),
            shortName: ProviderCatalog.shortName(for: id),
            account: account,
            windows: windows.sorted { $0.spanRank > $1.spanRank },
            error: error
        )
    }
}
