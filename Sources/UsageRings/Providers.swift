import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Built-in usage sources. Each one reuses the login its official CLI/app
/// already saved on this Mac (or an API key the user pasted) and asks that
/// provider's own usage endpoint.
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

/// A provider that can run on an API key, and where it found one.
protocol APIKeyProvider: BuiltInProvider {
    func keySource() -> KeySource?
}

enum KeySource: Equatable, Sendable {
    /// Pasted into Settings.
    case saved
    case environment(String)
    /// Claude Code's settings.json points at this provider (by hand or CC Switch).
    case claudeCode
    /// Another tool's login file.
    case file(String)

    var description: String {
        switch self {
        case .saved: tr("已保存的 key", "the saved key")
        case let .environment(name): tr("环境变量 \(name)", "the \(name) environment variable")
        case .claudeCode: tr("Claude Code 设置（settings.json）", "Claude Code's settings.json")
        case let .file(path): path
        }
    }
}

enum ProviderError: LocalizedError, Equatable {
    case notSignedIn(String)
    case expired(String)
    case http(Int)
    case rateLimited
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case let .notSignedIn(hint): hint
        case let .expired(hint): hint
        case .http(401), .http(403): tr("登录已失效，请在官方 App 里重新登录", "Signed out. Sign in again in the official app")
        case let .http(status): tr("服务器返回 HTTP \(status)", "The server answered HTTP \(status)")
        case .rateLimited: tr("查询太频繁，稍后会自动重试", "Too many requests; will retry shortly")
        case let .badResponse(message): message
        }
    }

    /// The credential was refused, as opposed to the service being down.
    var isAuthFailure: Bool {
        switch self {
        case .expired, .notSignedIn, .http(401), .http(403): true
        default: false
        }
    }
}

enum BuiltInProviders {
    static let all: [any BuiltInProvider] = [
        CodexProvider(),
        ClaudeProvider(),
        CursorProvider(),
        CopilotProvider(),
        OpenCodeGoProvider(),
        KimiProvider(),
        ZaiProvider(),
        MiniMaxProvider(),
    ]

    /// "Codex, Claude Code, …" for settings copy.
    static var summary: String {
        ["Codex", "Claude Code", "Cursor", "GitHub Copilot", "OpenCode Go", "Kimi Code", tr("智谱 GLM", "Z.ai GLM"), "MiniMax"]
            .joined(separator: tr("、", ", "))
    }

    static func provider(_ id: String) -> (any BuiltInProvider)? {
        all.first { $0.id == id }
    }

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

// MARK: - Shared helpers

enum HTTP {
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        #if canImport(FoundationNetworking)
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
        #else
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
        #endif
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
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

    /// GETs a JSON object. A 401/403 becomes `.expired(authHint)` when a
    /// hint is given, so the message can say which login to renew.
    static func getJSONObject(_ url: URL, headers: [String: String], authHint: String? = nil) async throws -> [String: Any] {
        precondition(url.scheme == "https", "credentials only go over HTTPS")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw ProviderError.rateLimited }
        if let authHint, status == 401 || status == 403 { throw ProviderError.expired(authHint) }
        guard status == 200 else { throw ProviderError.http(status) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse(tr("返回的数据格式不对", "The response wasn't in the expected format"))
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

/// Claude Code pointed at another plan's Anthropic-compatible endpoint (by
/// hand, or by CC Switch, which writes the active provider here) keeps that
/// plan's key in `~/.claude/settings.json`.
enum ClaudeCodeEnv {
    struct Credential: Equatable {
        let token: String
        let host: String
        let path: String
    }

    /// Tests point this at a temporary file.
    nonisolated(unsafe) static var settingsURLOverride: URL?

    static var settingsURL: URL {
        if let settingsURLOverride { return settingsURLOverride }
        let configDir = Environment.value("CLAUDE_CONFIG_DIR").map { URL(fileURLWithPath: $0) } ?? Home.url(".claude")
        return configDir.appendingPathComponent("settings.json")
    }

    /// The configured key when the base URL's host is one of `hosts` (or a
    /// subdomain of one).
    static func credential(hosts: [String]) -> Credential? {
        guard let env = JSONFile.object(at: settingsURL)?["env"] as? [String: Any],
              let base = (env["ANTHROPIC_BASE_URL"] as? String)?.nonEmpty.flatMap(URL.init(string:)),
              base.scheme == "https",
              let host = base.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              let token = (env["ANTHROPIC_AUTH_TOKEN"] as? String)?.nonEmpty ?? (env["ANTHROPIC_API_KEY"] as? String)?.nonEmpty
        else { return nil }
        return Credential(token: token, host: host, path: base.path)
    }
}

enum Environment {
    /// Tests replace the process environment with their own.
    nonisolated(unsafe) static var override: [String: String]?

    static func value(_ name: String) -> String? {
        (override ?? ProcessInfo.processInfo.environment)[name]?.nonEmpty
    }
}

/// Remembers which of a provider's regional hosts accepted the key, so the
/// next refresh asks that one first.
enum PreferredHost {
    /// In memory for this launch; UserDefaults carries it to the next one.
    nonisolated(unsafe) private static var remembered: [String: String] = [:]
    private static let lock = NSLock()

    static func ordered(_ hosts: [String], for providerID: String) -> [String] {
        lock.lock()
        let preferred = remembered[providerID] ?? UserDefaults.standard.string(forKey: key(providerID))
        lock.unlock()
        guard let preferred, hosts.contains(preferred) else { return hosts }
        return [preferred] + hosts.filter { $0 != preferred }
    }

    static func remember(_ host: String, for providerID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard remembered[providerID] != host else { return }
        remembered[providerID] = host
        UserDefaults.standard.set(host, forKey: key(providerID))
    }

    private static func key(_ providerID: String) -> String { "preferredHost.\(providerID)" }

    /// Tries each host (all the provider's own) until one answers. A refused
    /// key or an unknown endpoint moves on to the next; network trouble and
    /// rate limits stop right away, since another region won't fix them.
    static func firstAnswer<T>(
        hosts: [String],
        providerID: String,
        _ attempt: (String) async throws -> T
    ) async throws -> T {
        var errors: [ProviderError] = []
        for host in ordered(hosts, for: providerID) {
            do {
                let result = try await attempt(host)
                remember(host, for: providerID)
                return result
            } catch let error as ProviderError where error != .rateLimited {
                errors.append(error)
            }
        }
        // A refused key says more than a 404 from the wrong region.
        throw errors.first(where: \.isAuthFailure) ?? errors.first
            ?? ProviderError.badResponse(tr("没有可用的服务地址", "No service address to ask"))
    }
}

enum Shell {
    /// Runs a tool and returns trimmed stdout, or nil on a non-zero exit.
    static func run(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
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

    /// Epoch seconds or milliseconds, whichever the number looks like.
    static func epochDate(_ value: Any?) -> Date? {
        guard let raw = double(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }
}

enum ISODate {
    // Formatters are costly to create and transcripts parse one timestamp
    // per line, so two are kept; the lock keeps them single-threaded.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: string) ?? whole.date(from: string)
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

    static func subject(_ token: String) -> String? {
        (payload(token)?["sub"] as? String)?.nonEmpty
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
