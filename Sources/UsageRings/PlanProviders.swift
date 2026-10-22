import Foundation

// MARK: - Zhipu GLM Coding Plan (bigmodel.cn / z.ai)

/// GLM Coding Plan keys work on one of Zhipu's two hosts: open.bigmodel.cn
/// (mainland China) or api.z.ai (international).
struct ZaiProvider: APIKeyProvider {
    let id = "zai"
    static let mainland = "open.bigmodel.cn"
    static let international = "api.z.ai"

    private func credential() -> (key: String, hosts: [String], source: KeySource)? {
        let both = [Self.mainland, Self.international]
        if let saved = KeyStore.key(for: id) { return (saved, both, .saved) }
        for name in ["ZHIPU_API_KEY", "BIGMODEL_API_KEY", "ZHIPUAI_API_KEY", "GLM_API_KEY"] {
            if let key = Environment.value(name) { return (key, [Self.mainland], .environment(name)) }
        }
        if let key = Environment.value("Z_AI_API_KEY") { return (key, [Self.international], .environment("Z_AI_API_KEY")) }
        if let claudeCode = ClaudeCodeEnv.credential(hosts: ["bigmodel.cn", "z.ai"]) {
            let host = claudeCode.host.hasSuffix("z.ai") ? Self.international : Self.mainland
            return (claudeCode.token, [host], .claudeCode)
        }
        return nil
    }

    func keySource() -> KeySource? { credential()?.source }

    func isConfigured() -> Bool { credential() != nil }

    func fetch() async throws -> ProviderUsage {
        guard let credential = credential() else {
            throw ProviderError.notSignedIn(tr("没有找到智谱 GLM 的 API key", "No Z.ai GLM API key found"))
        }
        let refused = tr("智谱 GLM 的 API key 无效或已过期", "The Z.ai GLM API key was refused")
        let body = try await PreferredHost.firstAnswer(hosts: credential.hosts, providerID: id) { host in
            try await HTTP.getJSONObject(
                URL(string: "https://\(host)/api/monitor/usage/quota/limit")!,
                headers: HTTP.baseHeaders(token: credential.key),
                authHint: refused
            )
        }
        let parsed = try Self.parse(body)
        return ProviderUsage.make(id: id, account: parsed.plan, windows: parsed.windows)
    }

    /// `data.limits[]`: TOKENS_LIMIT / CREDIT_LIMIT entries are the plan's
    /// windows (5-hour, weekly); TIME_LIMIT is the separate MCP-call
    /// allowance and isn't drawn.
    static func parse(_ body: [String: Any], now: Date = .now) throws -> (windows: [UsageWindow], plan: String?) {
        if body["success"] as? Bool == false || (Num.double(body["code"]).map { $0 != 200 } ?? false) {
            let message = (body["msg"] as? String)?.nonEmpty ?? tr("智谱 GLM 返回了错误", "Z.ai GLM returned an error")
            let code = Num.double(body["code"]).map(Int.init)
            // 1000–1004: missing, invalid or expired key.
            if let code, (401...403).contains(code) || (1000...1004).contains(code) {
                throw ProviderError.expired(tr("智谱 GLM 的 API key 无效或已过期", "The Z.ai GLM API key was refused"))
            }
            throw ProviderError.badResponse(message)
        }
        guard let data = body["data"] as? [String: Any], let limits = data["limits"] as? [[String: Any]] else {
            throw ProviderError.badResponse(tr("智谱 GLM 没有返回额度信息", "Z.ai GLM returned no quota"))
        }

        let unitMinutes: [Int: Int] = [1: 1_440, 3: 60, 5: 1, 6: 10_080]
        var spans: [(minutes: Int?, used: Double, reset: Date?)] = []
        for limit in limits {
            guard let type = limit["type"] as? String, type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" else { continue }
            let minutes = Num.double(limit["number"]).flatMap { number in
                Num.double(limit["unit"]).flatMap { unitMinutes[Int($0)] }.map { Int(number) * $0 }
            }.flatMap { $0 > 0 ? $0 : nil }

            var used = Num.double(limit["percentage"])
            // Counts are more precise than the rounded percentage.
            if let total = Num.double(limit["usage"]), total > 0 {
                if let remaining = Num.double(limit["remaining"]) {
                    used = max(0, total - remaining) / total * 100
                } else if let current = Num.double(limit["currentValue"]) {
                    used = current / total * 100
                }
            }
            guard let used else { continue }

            var reset = Num.epochDate(limit["nextResetTime"])
            // A 5-hour reset can't be more than 5 hours off; anything else is
            // a timezone mix-up, better left blank than wrong.
            if minutes == 300, let date = reset, date > now.addingTimeInterval(5 * 3_600 + 60) {
                reset = nil
            }
            spans.append((minutes, used, reset))
        }

        let keys = ["primary", "secondary", "tertiary"]
        let windows = spans
            .sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
            .prefix(keys.count)
            .enumerated()
            .map { index, span in
                UsageWindow.make(key: keys[index], usedPercent: span.used, minutes: span.minutes, resetsAt: span.reset)
            }
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(tr("智谱 GLM 没有返回 Coding Plan 额度", "Z.ai GLM returned no Coding Plan quota"))
        }

        let plan = ["planName", "plan", "plan_type", "packageName", "level"]
            .lazy
            .compactMap { (data[$0] as? String)?.nonEmpty }
            .first
        return (windows, plan.map { "GLM \($0)" })
    }
}

// MARK: - MiniMax Coding Plan

/// MiniMax Coding Plan (`sk-cp-…`) keys, on the mainland (minimaxi.com) or
/// international (minimax.io) API.
struct MiniMaxProvider: APIKeyProvider {
    let id = "minimax"
    static let mainland = "api.minimaxi.com"
    static let international = "api.minimax.io"
    /// The original Coding Plan endpoint and the newer Token Plan one.
    static let paths = ["v1/api/openplatform/coding_plan/remains", "v1/token_plan/remains"]

    private func credential() -> (key: String, hosts: [String], source: KeySource)? {
        let both = [Self.mainland, Self.international]
        if let saved = KeyStore.key(for: id) { return (saved, both, .saved) }
        for name in ["MINIMAX_CODING_API_KEY", "MINIMAX_API_KEY"] {
            if let key = Environment.value(name) { return (key, both, .environment(name)) }
        }
        if let claudeCode = ClaudeCodeEnv.credential(hosts: ["minimaxi.com", "minimax.io"]) {
            let host = claudeCode.host.hasSuffix("minimax.io") ? Self.international : Self.mainland
            return (claudeCode.token, [host], .claudeCode)
        }
        return nil
    }

    func keySource() -> KeySource? { credential()?.source }

    func isConfigured() -> Bool { credential() != nil }

    func fetch() async throws -> ProviderUsage {
        guard let credential = credential() else {
            throw ProviderError.notSignedIn(tr("没有找到 MiniMax 的 API key", "No MiniMax API key found"))
        }
        let refused = tr("MiniMax 的 API key 无效或已过期", "The MiniMax API key was refused")
        var headers = HTTP.baseHeaders(token: credential.key)
        headers["MM-API-Source"] = "UsageRings"

        // Every host × path pair, so a key for either plan in either region
        // is found; the one that answered goes first next time.
        let endpoints = credential.hosts.flatMap { host in Self.paths.map { "\(host)/\($0)" } }
        return try await PreferredHost.firstAnswer(hosts: endpoints, providerID: id) { endpoint in
            let body = try await HTTP.getJSONObject(URL(string: "https://\(endpoint)")!, headers: headers, authHint: refused)
            let parsed = try Self.parse(body)
            return ProviderUsage.make(id: id, account: parsed.plan, windows: parsed.windows)
        }
    }

    static func parse(_ body: [String: Any], now: Date = .now) throws -> (windows: [UsageWindow], plan: String?) {
        let data = body["data"] as? [String: Any] ?? body
        let status = (data["base_resp"] ?? body["base_resp"]) as? [String: Any]
        if let code = Num.double(status?["status_code"]), code != 0 {
            let message = (status?["status_msg"] as? String)?.nonEmpty ?? "status_code \(Int(code))"
            let lower = message.lowercased()
            if code == 1004 || code == 2049 || lower.contains("api key") || lower.contains("login") {
                throw ProviderError.expired(tr("MiniMax 的 API key 无效或已过期", "The MiniMax API key was refused"))
            }
            throw ProviderError.badResponse(message)
        }

        guard let models = data["model_remains"] as? [[String: Any]], !models.isEmpty else {
            throw ProviderError.badResponse(tr("MiniMax 没有返回额度信息", "MiniMax returned no quota"))
        }
        // The plan also meters speech, image and video models; coding runs
        // on the text model.
        let model = models.first { isTextModel($0["model_name"] as? String) } ?? models[0]

        var windows: [UsageWindow] = []
        if let window = window(model, key: "primary", prefix: "current_interval", start: "start_time",
                               end: "end_time", remains: "remains_time", now: now) {
            windows.append(window)
        }
        if let window = window(model, key: "secondary", prefix: "current_weekly", start: "weekly_start_time",
                               end: "weekly_end_time", remains: "weekly_remains_time", now: now) {
            windows.append(window)
        }
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(tr("MiniMax 没有返回 Coding Plan 额度", "MiniMax returned no Coding Plan quota"))
        }

        let plan = ["current_subscribe_title", "plan_name", "combo_title", "current_plan_title"]
            .lazy
            .compactMap { (data[$0] as? String)?.nonEmpty }
            .first ?? ((data["current_combo_card"] as? [String: Any])?["title"] as? String)?.nonEmpty
        return (windows, plan)
    }

    static func isTextModel(_ name: String?) -> Bool {
        guard let lower = name?.lowercased() else { return false }
        return lower == "general" || lower.contains("minimax-m") || lower.hasPrefix("m2")
    }

    /// One window from `<prefix>_total_count` / `<prefix>_usage_count`. Despite
    /// its name, `usage_count` is what's *left*.
    private static func window(
        _ model: [String: Any], key: String, prefix: String,
        start: String, end: String, remains: String, now: Date
    ) -> UsageWindow? {
        let total = Num.double(model["\(prefix)_total_count"])
        let left = Num.double(model["\(prefix)_usage_count"])
        let leftPercent = Num.double(model["\(prefix)_remaining_percent"])
        let status = Num.double(model["\(prefix)_status"])

        // Status 3 with nothing on it and nothing used: the plan has no such
        // window, or it's unlimited.
        if status == 3, (total ?? 0) == 0, (left ?? 0) == 0, (leftPercent ?? 100) >= 100 { return nil }

        let used: Double
        if let leftPercent {
            used = 100 - leftPercent
        } else if let total, total > 0, let left {
            used = max(0, total - left) / total * 100
        } else {
            return nil
        }

        let startDate = Num.epochDate(model[start])
        let endDate = Num.epochDate(model[end])
        var minutes: Int?
        if let startDate, let endDate {
            let span = Int(endDate.timeIntervalSince(startDate) / 60)
            minutes = span > 0 ? span : nil
        }

        var reset = endDate.flatMap { $0 > now ? $0 : nil }
        if reset == nil, let left = Num.double(model[remains]), left > 0 {
            reset = now.addingTimeInterval(left > 1_000_000 ? left / 1000 : left)
        }
        return UsageWindow.make(key: key, usedPercent: used, minutes: minutes ?? (key == "primary" ? 300 : 10_080), resetsAt: reset)
    }
}
