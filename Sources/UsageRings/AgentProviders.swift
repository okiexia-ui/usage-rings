import Foundation

// MARK: - Codex

struct CodexProvider: BuiltInProvider {
    let id = "codex"

    private var authURL: URL {
        let home = ProcessEnv.value("CODEX_HOME").map { URL(fileURLWithPath: $0) } ?? Home.url(".codex")
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
            throw ProviderError.notSignedIn(tr("没有找到 Codex 登录，请先在 Codex 里登录", "No Codex login found. Sign in to Codex first"))
        }
        let renew = tr("Codex 登录已过期，打开一次 Codex 就会自动续期", "Codex login expired. Open Codex once to renew it")
        if let expiry = JWT.expiry(accessToken), expiry < .now {
            throw ProviderError.expired(renew)
        }

        var headers = HTTP.baseHeaders(token: accessToken)
        if let accountID = (tokens["account_id"] as? String)?.nonEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let body = try await HTTP.getJSONObject(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: headers,
            authHint: renew
        )

        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(tr("Codex 没有返回额度信息", "Codex returned no quota"))
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
        let configDir = ProcessEnv.value("CLAUDE_CONFIG_DIR").map { URL(fileURLWithPath: $0) } ?? Home.url(".claude")
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
            throw ProviderError.notSignedIn(tr("没有找到 Claude Code 登录，请先运行 claude 登录",
                                               "No Claude Code login found. Run claude to sign in"))
        }
        let renew = tr("Claude 登录已过期，打开一次 Claude Code 就会自动续期", "Claude login expired. Open Claude Code once to renew it")
        if let expiresAt = Num.double(oauth["expiresAt"]), expiresAt > 0,
           Date(timeIntervalSince1970: expiresAt / 1000) < .now {
            throw ProviderError.expired(renew)
        }

        var headers = HTTP.baseHeaders(token: accessToken)
        headers["anthropic-beta"] = "oauth-2025-04-20"
        let body = try await HTTP.getJSONObject(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: headers,
            authHint: renew
        )

        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(tr("Claude 没有返回额度信息", "Claude returned no quota"))
        }

        let plan = (oauth["subscriptionType"] as? String)?.nonEmpty.map { "Claude \($0.capitalized)" }
        return ProviderUsage.make(id: id, account: plan, windows: windows)
    }

    static func windows(from body: [String: Any]) -> [UsageWindow] {
        // Model-specific weekly limits come and go with the plan; they're
        // null when the plan has none.
        let fields: [(key: String, field: String, scope: String?, minutes: Int)] = [
            ("primary", "five_hour", nil, 300),
            ("secondary", "seven_day", nil, 10_080),
            ("secondary", "seven_day_opus", "opus", 10_080),
            ("secondary", "seven_day_sonnet", "sonnet", 10_080),
        ]
        var windows: [UsageWindow] = []
        for (key, field, scope, minutes) in fields {
            guard let window = body[field] as? [String: Any],
                  let used = Num.double(window["utilization"]) else { continue }
            windows.append(UsageWindow.make(
                key: key,
                scope: scope,
                usedPercent: used,
                minutes: minutes,
                resetsAt: (window["resets_at"] as? String).flatMap(ISODate.parse)
            ))
        }
        return windows
    }
}

// MARK: - OpenCode Go

struct OpenCodeGoProvider: APIKeyProvider {
    let id = "opencodego"

    private var authURL: URL {
        let dataHome = ProcessEnv.value("XDG_DATA_HOME").map { URL(fileURLWithPath: $0) } ?? Home.url(".local/share")
        return dataHome.appendingPathComponent("opencode/auth.json")
    }

    /// OpenCode stores the Go subscription key under "opencode-go".
    private func apiKey() -> (key: String, source: KeySource)? {
        if let saved = KeyStore.key(for: id) { return (saved, .saved) }
        if let env = ProcessEnv.value("OPENCODE_API_KEY") { return (env, .environment("OPENCODE_API_KEY")) }
        let entry = JSONFile.object(at: authURL)?["opencode-go"] as? [String: Any]
        if let key = (entry?["key"] as? String)?.nonEmpty {
            return (key, .file("~/.local/share/opencode/auth.json"))
        }
        return nil
    }

    func keySource() -> KeySource? { apiKey()?.source }

    func isConfigured() -> Bool {
        apiKey() != nil
    }

    func fetch() async throws -> ProviderUsage {
        guard let key = apiKey()?.key else {
            throw ProviderError.notSignedIn(tr("没有找到 OpenCode Go 的 API key", "No OpenCode Go API key found"))
        }
        let body = try await HTTP.getJSONObject(
            URL(string: "https://opencode.ai/zen/go/v1/usage")!,
            headers: HTTP.baseHeaders(token: key),
            authHint: tr("OpenCode Go 的 API key 无效或已过期", "The OpenCode Go API key was refused")
        )
        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(tr("OpenCode Go 没有返回额度信息", "OpenCode Go returned no quota"))
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
            if let date = Num.epochDate(window[key]) { return date }
        }
        return nil
    }
}

// MARK: - Kimi Code

struct KimiProvider: APIKeyProvider {
    let id = "kimi"

    private var home: URL {
        ProcessEnv.value("KIMI_CODE_HOME").map { URL(fileURLWithPath: $0) } ?? Home.url(".kimi-code")
    }

    private var credentialsURL: URL {
        home.appendingPathComponent("credentials/kimi-code.json")
    }

    /// A Kimi Code API key never expires, unlike the CLI's 15-minute access
    /// token, so it is preferred when the user has created one.
    private func apiKey() -> (key: String, source: KeySource)? {
        if let saved = KeyStore.key(for: id) { return (saved, .saved) }
        if let env = ProcessEnv.value("KIMI_CODE_API_KEY") { return (env, .environment("KIMI_CODE_API_KEY")) }
        if let claudeCode = ClaudeCodeEnv.credential(hosts: ["api.kimi.com"]), claudeCode.path.hasPrefix("/coding") {
            return (claudeCode.token, .claudeCode)
        }
        return nil
    }

    func keySource() -> KeySource? { apiKey()?.source }

    func isConfigured() -> Bool {
        apiKey() != nil || FileManager.default.fileExists(atPath: credentialsURL.path)
    }

    private func cliAccessToken() throws -> String {
        guard let credential = JSONFile.object(at: credentialsURL),
              let accessToken = (credential["access_token"] as? String)?.nonEmpty else {
            throw ProviderError.notSignedIn(tr("没有找到 Kimi Code 登录：运行 kimi 登录，或在设置里填 Kimi Code API Key",
                                               "No Kimi Code login found. Run kimi to sign in, or add a Kimi Code API key in Settings"))
        }
        if let expiresAt = Num.double(credential["expires_at"]),
           Date(timeIntervalSince1970: expiresAt) < .now {
            throw ProviderError.expired(tr("Kimi 命令行登录只在使用时有效；在设置里填 Kimi Code API Key 就能一直读到",
                                           "The Kimi CLI login only lasts while you use it. Add a Kimi Code API key in Settings to keep reading it"))
        }
        return accessToken
    }

    func fetch() async throws -> ProviderUsage {
        let accessToken = try apiKey()?.key ?? cliAccessToken()

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
            headers: headers,
            authHint: tr("Kimi Code 的 API key 或登录已失效", "The Kimi Code API key or login was refused")
        )

        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(tr("Kimi 没有返回额度信息", "Kimi returned no quota"))
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
