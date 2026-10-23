import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

// MARK: - GitHub Copilot

/// Copilot's editor plugins (Neovim, Vim, JetBrains, Xcode, Zed…) keep the
/// GitHub OAuth token in `~/.config/github-copilot`; a token pasted into
/// Settings works too.
struct CopilotProvider: APIKeyProvider {
    let id = "copilot"

    private var configDirectory: URL {
        (ProcessEnv.value("XDG_CONFIG_HOME").map { URL(fileURLWithPath: $0) } ?? Home.url(".config"))
            .appendingPathComponent("github-copilot", isDirectory: true)
    }

    private func credential() -> (token: String, source: KeySource)? {
        if let saved = KeyStore.key(for: id) { return (saved, .saved) }
        for file in ["apps.json", "hosts.json"] {
            if let token = Self.token(inConfig: JSONFile.object(at: configDirectory.appendingPathComponent(file))) {
                return (token, .file("~/.config/github-copilot/\(file)"))
            }
        }
        return nil
    }

    /// `{"github.com[:app id]": {"user": …, "oauth_token": …}}`; only
    /// github.com entries, so an Enterprise token never goes to api.github.com.
    static func token(inConfig config: [String: Any]?) -> String? {
        guard let config else { return nil }
        for (host, value) in config.sorted(by: { $0.key < $1.key })
        where host == "github.com" || host.hasPrefix("github.com:") {
            if let token = ((value as? [String: Any])?["oauth_token"] as? String)?.nonEmpty {
                return token
            }
        }
        return nil
    }

    func keySource() -> KeySource? { credential()?.source }

    func isConfigured() -> Bool { credential() != nil }

    func fetch() async throws -> ProviderUsage {
        guard let token = credential()?.token else {
            throw ProviderError.notSignedIn(tr("没有找到 GitHub Copilot 登录", "No GitHub Copilot login found"))
        }
        // The headers Copilot's own editor plugins send to this endpoint.
        let headers = [
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        ]
        let body = try await HTTP.getJSONObject(
            URL(string: "https://api.github.com/copilot_internal/user")!,
            headers: headers,
            authHint: tr("GitHub Copilot 登录已失效，请在编辑器里重新登录 Copilot", "GitHub Copilot signed out. Sign in to Copilot again in your editor")
        )
        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(tr("Copilot 当前套餐不限量，没有额度可显示", "This Copilot plan is unlimited; there's no quota to show"))
        }
        return ProviderUsage.make(id: id, account: Self.planName(body["copilot_plan"] as? String), windows: windows)
    }

    /// Monthly premium requests and, on Free, chat and completions.
    static func windows(from body: [String: Any]) -> [UsageWindow] {
        let reset = resetDate(body["quota_reset_date"] as? String ?? body["limited_user_reset_date"] as? String)
        var used: [String: Double] = [:]

        let snapshots = body["quota_snapshots"] as? [String: Any] ?? [:]
        for (field, scope) in [("premium_interactions", "premium"), ("chat", "chat"), ("completions", "completions")] {
            guard let snapshot = snapshots[field] as? [String: Any],
                  snapshot["unlimited"] as? Bool != true else { continue }
            let entitlement = Num.double(snapshot["entitlement"])
            let remaining = Num.double(snapshot["remaining"])
            // Zero entitlement and zero left: a placeholder, not an empty quota.
            if entitlement == 0, remaining == 0 { continue }
            if let left = Num.double(snapshot["percent_remaining"]) {
                used[scope] = 100 - left
            } else if let entitlement, entitlement > 0, let remaining {
                used[scope] = (entitlement - remaining) / entitlement * 100
            }
        }

        // Copilot Free reports counts left against monthly allowances instead.
        let monthly = body["monthly_quotas"] as? [String: Any] ?? [:]
        let left = body["limited_user_quotas"] as? [String: Any] ?? [:]
        for scope in ["chat", "completions"] where used[scope] == nil {
            guard let total = Num.double(monthly[scope]), total > 0,
                  let remaining = Num.double(left[scope]) else { continue }
            used[scope] = (total - max(0, remaining)) / total * 100
        }

        return ["premium", "chat", "completions"].compactMap { scope in
            used[scope].map { UsageWindow.make(key: "tertiary", scope: scope, usedPercent: $0, minutes: 43_200, resetsAt: reset) }
        }
    }

    static func planName(_ plan: String?) -> String? {
        switch plan?.lowercased() {
        case nil, "", "unknown": nil
        case "individual": "Copilot Pro"
        case "individual_pro": "Copilot Pro+"
        case "business": "Copilot Business"
        case "enterprise": "Copilot Enterprise"
        case "free": "Copilot Free"
        case let other?: "Copilot \(other.capitalized)"
        }
    }

    /// `2026-11-01` (UTC midnight) or a full timestamp.
    static func resetDate(_ string: String?) -> Date? {
        guard let string = string?.nonEmpty else { return nil }
        if let date = ISODate.parse(string) { return date }
        return ISODate.parse(string + "T00:00:00Z")
    }
}

// MARK: - Cursor

/// Reads the session Cursor.app keeps in its own state database, read-only,
/// and asks cursor.com for the billing cycle's included usage.
struct CursorProvider: BuiltInProvider {
    let id = "cursor"

    private var databaseURL: URL {
        Home.url("Library/Application Support/Cursor/User/globalStorage").appendingPathComponent("state.vscdb")
    }

    /// Signed in, not just installed: a Cursor that was never logged into
    /// shouldn't add a ring that can only say so.
    func isConfigured() -> Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
            && StateDatabase.values(at: databaseURL, keys: ["cursorAuth/accessToken"])["cursorAuth/accessToken"]?.nonEmpty != nil
    }

    func fetch() async throws -> ProviderUsage {
        let values = StateDatabase.values(
            at: databaseURL,
            keys: ["cursorAuth/accessToken", "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType"]
        )
        guard let token = values["cursorAuth/accessToken"]?.nonEmpty,
              let userID = JWT.subject(token)?.split(separator: "|").last.map(String.init),
              userID.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else {
            throw ProviderError.notSignedIn(tr("没有找到 Cursor 登录，请先在 Cursor 里登录", "No Cursor login found. Sign in to Cursor first"))
        }
        let renew = tr("Cursor 登录已过期，打开一次 Cursor 就会自动续期", "Cursor login expired. Open Cursor once to renew it")
        if let expiry = JWT.expiry(token), expiry < .now.addingTimeInterval(60) {
            throw ProviderError.expired(renew)
        }

        let body = try await HTTP.getJSONObject(
            URL(string: "https://cursor.com/api/usage-summary")!,
            headers: [
                "Cookie": "WorkosCursorSessionToken=\(userID)%3A%3A\(token)",
                "Accept": "application/json",
                "User-Agent": "UsageRings/\(HTTP.appVersion)",
            ],
            authHint: renew
        )
        guard let window = Self.window(from: body) else {
            throw ProviderError.badResponse(body["isUnlimited"] as? Bool == true
                ? tr("Cursor 当前套餐不限量，没有额度可显示", "This Cursor plan is unlimited; there's no quota to show")
                : tr("Cursor 没有返回额度信息", "Cursor returned no quota"))
        }
        let membership = (body["membershipType"] as? String ?? values["cursorAuth/stripeMembershipType"])?.nonEmpty
        let account = values["cursorAuth/cachedEmail"]?.nonEmpty ?? membership.map { "Cursor \($0.capitalized)" }
        return ProviderUsage.make(id: id, account: account, windows: [window])
    }

    /// The billing cycle's included usage. Percent fields are already in
    /// percent; dollar fields are in cents.
    static func window(from body: [String: Any]) -> UsageWindow? {
        let individual = body["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]

        var used = Num.double(plan?["totalPercentUsed"])
        if used == nil {
            for pool in [plan, individual?["overall"] as? [String: Any],
                         (body["teamUsage"] as? [String: Any])?["pooled"] as? [String: Any]] {
                if let pool, let spent = Num.double(pool["used"]), let limit = Num.double(pool["limit"]), limit > 0 {
                    used = spent / limit * 100
                    break
                }
            }
        }
        guard let used else { return nil }

        let start = (body["billingCycleStart"] as? String).flatMap(ISODate.parse)
        let end = (body["billingCycleEnd"] as? String).flatMap(ISODate.parse)
        let minutes = start.flatMap { start in end.map { Int($0.timeIntervalSince(start) / 60) } }
        return UsageWindow.make(
            key: "tertiary",
            usedPercent: used,
            minutes: (minutes ?? 0) > 0 ? minutes : 43_200,
            resetsAt: end
        )
    }
}

/// Read-only lookups in a VS Code-style `state.vscdb` (an `ItemTable` of
/// key/value rows).
enum StateDatabase {
    static func values(at url: URL, keys: [String]) -> [String: String] {
        #if canImport(SQLite3)
        if let values = try? read(url.path, keys: keys, immutable: false) { return values }
        // An idle WAL database can't open read-only once its sidecars are
        // gone; immutable mode reads it without recreating them. Never while
        // a WAL exists: that would skip Cursor's latest writes.
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path + "-wal"),
              !fileManager.fileExists(atPath: url.path + "-shm") else { return [:] }
        return (try? read(url.absoluteURL.absoluteString + "?immutable=1", keys: keys, immutable: true)) ?? [:]
        #else
        [:]
        #endif
    }

    #if canImport(SQLite3)
    private struct Failure: Error {}

    private static func read(_ filename: String, keys: [String], immutable: Bool) throws -> [String: String] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0)
        guard sqlite3_open_v2(filename, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw Failure()
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else {
            throw Failure()
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var values: [String: String] = [:]
        for key in keys {
            sqlite3_reset(statement)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                values[key] = text(statement)
            case SQLITE_DONE:
                continue
            default:
                throw Failure()
            }
        }
        return values
    }

    /// TEXT as UTF-8; BLOBs are UTF-8 or, from some VS Code builds, UTF-16LE.
    private static func text(_ statement: OpaquePointer?) -> String? {
        switch sqlite3_column_type(statement, 0) {
        case SQLITE_TEXT:
            return sqlite3_column_text(statement, 0).map { String(cString: $0) }
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            if data.count >= 2, data[data.startIndex + 1] == 0 {
                return String(data: data, encoding: .utf16LittleEndian)
            }
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }
    #endif
}
