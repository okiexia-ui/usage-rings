import Foundation
import Testing
@testable import UsageRings

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func window(_ used: Double, minutes: Int = 300, resetsIn: TimeInterval?, key: String = "primary") -> UsageWindow {
    UsageWindow.make(key: key, usedPercent: used, minutes: minutes, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
}

private func provider(_ id: String, _ windows: [UsageWindow], stale: Bool = false) -> ProviderUsage {
    var usage = ProviderUsage.make(id: id, windows: windows)
    usage.isStale = stale
    return usage
}

/// Runs `body` with the interface in Chinese, without touching the global setting.
private func zh<T>(_ body: () throws -> T) rethrows -> T {
    try L10n.$pinned.withValue(.chinese, operation: body)
}

private func en<T>(_ body: () throws -> T) rethrows -> T {
    try L10n.$pinned.withValue(.english, operation: body)
}

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

// MARK: - Pace

struct PaceTests {
    @Test func halfwayThroughAtEightyPercentRunsOutEarly() throws {
        // 5h window, 2.5h elapsed, 80% used: rate = 80 / 9000 s, so the last
        // 20% lasts 2250 s, well before the 9000 s reset.
        let pace = try #require(Pace.of(window(80, resetsIn: 9_000), now: now))
        #expect(abs(pace.expectedPercent - 50) < 0.01)
        let runsOut = try #require(pace.runsOutIn)
        #expect(abs(runsOut - 2_250) < 1)
        #expect(!pace.willLastToReset)
    }

    @Test func evenPaceLastsToReset() throws {
        let pace = try #require(Pace.of(window(30, resetsIn: 9_000), now: now))
        #expect(pace.willLastToReset)
        #expect(pace.delta(used: 30) < 0)
    }

    @Test func tooEarlyOrUnknownWindowGivesNoPace() {
        // Only 5 minutes into a 5h window.
        #expect(Pace.of(window(10, resetsIn: 17_700), now: now) == nil)
        #expect(Pace.of(window(10, resetsIn: nil), now: now) == nil)
        // Already reset.
        #expect(Pace.of(window(10, resetsIn: -60), now: now) == nil)
    }

    @Test func zeroUsageLasts() throws {
        let pace = try #require(Pace.of(window(0, resetsIn: 9_000), now: now))
        #expect(pace.willLastToReset)
    }
}

// MARK: - Recommendation

struct RecommendationTests {
    @Test func prefersAProviderThatLastsOverOneWithMoreHeadroom() throws {
        let tight = provider("claude", [window(90, resetsIn: 9_000)])
        let burning = provider("codex", [window(40, resetsIn: 17_000)])      // 40% after ~5 min of 5h → runs out
        let steady = provider("kimi", [window(50, minutes: 10_080, resetsIn: 302_400)]) // half a week, half used
        let pick = try #require(Recommendation.pick([tight, burning, steady], now: now))
        #expect(pick.providerID == "kimi")
    }

    @Test func picksMostHeadroomWhenAllLast() throws {
        let a = provider("claude", [window(30, resetsIn: 9_000)])
        let b = provider("kimi", [window(10, resetsIn: 9_000)])
        #expect(try #require(Recommendation.pick([a, b], now: now)).providerID == "kimi")
    }

    @Test func skipsStaleAndEmptyAndNeedsAnAlternative() {
        let fresh = provider("claude", [window(30, resetsIn: 9_000)])
        let stale = provider("kimi", [window(0, resetsIn: 9_000)], stale: true)
        let failed = provider("codex", [])
        // Only one usable candidate: nothing to recommend switching to.
        #expect(Recommendation.pick([fresh, stale, failed], now: now) == nil)
    }

    @Test func noRecommendationWhenEverythingIsNearlyOut() {
        let a = provider("claude", [window(92, resetsIn: 9_000)])
        let b = provider("kimi", [window(95, resetsIn: 9_000)])
        #expect(Recommendation.pick([a, b], now: now) == nil)
    }
}

// MARK: - Session attribution

struct SessionAttributionTests {
    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-rings-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func line(_ entry: [String: Any]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: entry), encoding: .utf8)!
    }

    private func write(_ lines: [[String: Any]], to url: URL, modified: Date = now) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map(line).joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        // Scans skip files untouched since the window opened; date them at the test clock.
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func append(_ text: String, to url: URL, modified: Date) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: now.addingTimeInterval(offset))
    }

    private func claudeEntry(session: String, cwd: String, id: String, model: String = "claude-opus-5-5",
                             at offset: TimeInterval, input: Int = 0, output: Int = 0, cacheRead: Int = 0) -> [String: Any] {
        [
            "type": "assistant",
            "sessionId": session,
            "cwd": cwd,
            "timestamp": iso(offset),
            "message": [
                "id": id,
                "model": model,
                "usage": [
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": cacheRead,
                    "cache_creation_input_tokens": 0,
                ],
            ],
        ]
    }

    @Test func claudeSharesWeighTokensDedupeAndSkipOtherModels() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try write([
            claudeEntry(session: "s1", cwd: "/work/alpha", id: "m1", at: -600, output: 300),          // 1500
            claudeEntry(session: "s1", cwd: "/work/alpha", id: "m1", at: -600, output: 300),          // duplicate block
            claudeEntry(session: "s1", cwd: "/work/alpha", id: "m2", at: -300, cacheRead: 5_000),     // 500
            claudeEntry(session: "s1", cwd: "/work/alpha", id: "m3", model: "kimi-for-coding", at: -200, output: 9_000),
            claudeEntry(session: "s1", cwd: "/work/alpha", id: "m4", at: -40_000, output: 9_000),     // before window
        ], to: root.appendingPathComponent("-work-alpha/s1.jsonl"))
        try write([
            claudeEntry(session: "s2", cwd: "/work/beta", id: "m5", at: -100, input: 500),            // 500
        ], to: root.appendingPathComponent("-work-beta/s2.jsonl"))

        let shares = SessionAttribution.shares(
            providerID: "claude",
            since: now.addingTimeInterval(-18_000),
            until: now,
            claudeRoot: root
        )
        try #require(shares.map(\.name) == ["alpha", "beta"])
        #expect(abs(shares[0].weightedTokens - 2_000) < 0.001)
        #expect(abs(shares[0].share - 0.8) < 0.001)
        #expect(abs(shares[1].share - 0.2) < 0.001)
    }

    @Test func codexSharesAndLocalRateLimits() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        func tokenCount(_ offset: TimeInterval, input: Int, cached: Int, output: Int, used: Double) -> [String: Any] {
            [
                "timestamp": iso(offset),
                "type": "event_msg",
                "payload": [
                    "type": "token_count",
                    "info": ["last_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output]],
                    "rate_limits": [
                        "primary": ["used_percent": used, "window_minutes": 10_080, "resets_at": now.timeIntervalSince1970 + 86_400],
                    ],
                ],
            ]
        }

        try write([
            ["timestamp": iso(-900), "type": "session_meta", "payload": ["id": "c1", "cwd": "/work/gamma"]],
            tokenCount(-800, input: 1_000, cached: 1_000, output: 100, used: 40),  // 100 + 800 = 900
            tokenCount(-700, input: 2_100, cached: 1_000, output: 0, used: 42),    // 1100 + 100 = 1200
        ], to: root.appendingPathComponent("2026/10/14/rollout-c1.jsonl"))
        try write([
            ["timestamp": iso(-500), "type": "session_meta", "payload": ["id": "c2", "cwd": "/work/delta"]],
            tokenCount(-400, input: 900, cached: 0, output: 0, used: 45),          // 900
        ], to: root.appendingPathComponent("2026/10/14/rollout-c2.jsonl"))

        let shares = SessionAttribution.shares(
            providerID: "codex",
            since: now.addingTimeInterval(-3_600),
            until: now,
            codexRoot: root
        )
        try #require(shares.map(\.name) == ["gamma", "delta"])
        #expect(abs(shares[0].weightedTokens - 2_100) < 0.001)
        #expect(abs(shares[0].share - 0.7) < 0.001)

        // The newest snapshot (45%) wins, labelled as a local reading.
        let local = try zh { try #require(SessionAttribution.codexLocalUsage(lookback: 3_600, root: root, now: now)) }
        #expect(local.windows.map(\.usedPercent) == [45])
        #expect(zh { local.windows.first?.label } == "周")
        #expect(local.account == "本地记录")
    }

    @Test func sameProjectSessionsAreNumbered() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([
            claudeEntry(session: "a", cwd: "/work/app", id: "1", at: -60, output: 200),
            claudeEntry(session: "b", cwd: "/work/app", id: "2", at: -50, output: 100),
        ], to: root.appendingPathComponent("-work-app/a.jsonl"))
        let shares = SessionAttribution.shares(providerID: "claude", since: now.addingTimeInterval(-600), until: now, claudeRoot: root)
        #expect(shares.map(\.name) == ["app", "app #2"])
    }

    @Test func appendedLinesAreReadOnceAndPartialLinesWait() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("-work-app/s.jsonl")
        let since = now.addingTimeInterval(-3_600)
        func weight() -> Double {
            SessionAttribution.shares(providerID: "claude", since: since, until: now, claudeRoot: root)
                .reduce(0) { $0 + $1.weightedTokens }
        }

        try write([claudeEntry(session: "s", cwd: "/work/app", id: "1", at: -60, output: 100)], to: file)
        #expect(weight() == 500)

        // A line still being written is left for the next scan…
        let next = try line(claudeEntry(session: "s", cwd: "/work/app", id: "2", at: -30, output: 20))
        try append("\n" + next.prefix(40), to: file, modified: now.addingTimeInterval(1))
        #expect(weight() == 500)

        // …and counted once it's complete, without recounting the first.
        try append(String(next.dropFirst(40)) + "\n", to: file, modified: now.addingTimeInterval(2))
        #expect(weight() == 600)

        // A rewritten (shorter) file is read from the start again.
        try write([claudeEntry(session: "s", cwd: "/work/app", id: "3", at: -10, output: 1)], to: file,
                  modified: now.addingTimeInterval(3))
        #expect(weight() == 5)
    }
}

// MARK: - Provider response parsing

struct ProviderParsingTests {
    @Test func codexWindows() {
        let body: [String: Any] = [
            "rate_limit": [
                "primary_window": ["used_percent": 12, "limit_window_seconds": 18_000, "reset_at": 1_800_003_600],
                "secondary_window": ["used_percent": 96, "limit_window_seconds": 604_800, "reset_at": 1_800_500_000],
            ],
        ]
        let windows = CodexProvider.windows(from: body)
        #expect(zh { windows.map(\.label) } == ["5h", "周"])
        #expect(windows.map(\.usedPercent) == [12, 96])
        #expect(windows.first?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
    }

    @Test func claudeWindowsIncludingModelScopedWeeks() {
        let body: [String: Any] = [
            "five_hour": ["utilization": 62.0, "resets_at": "2026-10-14T09:00:00.000Z"],
            "seven_day": ["utilization": 84.0, "resets_at": "2026-10-14T08:00:00Z"],
            "seven_day_opus": NSNull(),
            "seven_day_sonnet": ["utilization": 91, "resets_at": "2026-10-14T08:00:00.123456+00:00"],
        ]
        let windows = ProviderUsage.make(id: "claude", windows: ClaudeProvider.windows(from: body)).windows
        #expect(zh { windows.map(\.label) } == ["周", "Sonnet", "5h"])
        #expect(windows.map(\.usedPercent) == [84, 91, 62])
        #expect(windows.allSatisfy { $0.resetsAt != nil })
        #expect(Set(windows.map(\.id)).count == 3)
    }

    @Test func openCodeGoWindowsFromPercentsAndRatios() {
        let body: [String: Any] = [
            "usage": [
                "rolling": ["usagePercent": 0, "resetInSec": 3_600],
                "weekly": ["used": 41, "limit": 100, "resetAt": "2026-10-18T00:00:00Z"],
                "monthly": ["usedPercent": 41.2, "reset_at": 1_801_000_000_000.0],
            ],
        ]
        let windows = OpenCodeGoProvider.windows(from: body, now: now)
        #expect(zh { windows.map(\.label) } == ["5h", "周", "月"])
        #expect(windows.map { Int($0.usedPercent.rounded()) } == [0, 41, 41])
        #expect(windows[0].resetsAt == now.addingTimeInterval(3_600))
        #expect(windows[2].resetsAt == Date(timeIntervalSince1970: 1_801_000_000))
    }

    @Test func kimiPoolAndLegacyShapes() {
        let pools: [String: Any] = [
            "usages": [
                "limit_5h": ["used_ratio": 0.02, "reset_time": "2026-10-14T10:00:00Z"],
                "limit_7d": ["used_ratio": 0.12, "reset_time": "2026-10-20T10:00:00Z"],
            ],
        ]
        #expect(KimiProvider.windows(from: pools).map { Int($0.usedPercent.rounded()) } == [2, 12])

        let legacy: [String: Any] = [
            "usage": ["limit": "100", "used": "30", "resetTime": "2026-10-20T10:00:00Z"],
            "limits": [["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                        "detail": ["limit": "50", "remaining": "40", "resetTime": "2026-10-14T10:00:00Z"]]],
        ]
        let windows = KimiProvider.windows(from: legacy)
        #expect(zh { windows.map(\.label) } == ["5h", "周"])
        #expect(windows.map { Int($0.usedPercent.rounded()) } == [20, 30])
    }

    @Test func zaiCodingPlanWindows() throws {
        let body = try json("""
        {"code":200,"success":true,"data":{"planName":"Pro","limits":[
          {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":40,"usage":1000,"currentValue":400},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,"nextResetTime":1800300000000},
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"usage":800,"remaining":580,"nextResetTime":1800003600000}
        ]}}
        """)
        let parsed = try ZaiProvider.parse(body, now: now)
        let windows = ProviderUsage.make(id: "zai", windows: parsed.windows).windows
        // The MCP allowance (TIME_LIMIT) isn't drawn; counts beat the rounded percentage.
        #expect(zh { windows.map(\.label) } == ["周", "5h"])
        #expect(windows.map { $0.usedPercent.rounded() } == [9, 28])
        #expect(windows[1].resetsAt == now.addingTimeInterval(3_600))
        #expect(parsed.plan == "GLM Pro")
    }

    @Test func zaiDropsImpossibleFiveHourResetsAndReportsErrors() throws {
        let body = try json("""
        {"code":200,"success":true,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1800036000000}
        ]}}
        """)
        let windows = try ZaiProvider.parse(body, now: now).windows
        #expect(windows.count == 1)
        #expect(windows[0].resetsAt == nil)   // 10 hours away can't be a 5-hour reset

        #expect(throws: ProviderError.self) {
            try ZaiProvider.parse(try json(#"{"code":1001,"success":false,"msg":"token expired"}"#))
        }
        #expect(throws: ProviderError.self) {
            try ZaiProvider.parse(try json(#"{"code":200,"success":true,"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":4}]}}"#))
        }
    }

    @Test func miniMaxCodingAndTokenPlans() throws {
        // Coding Plan: `usage_count` is what's left, not what's used.
        let coding = try json("""
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"speech-hd","current_interval_total_count":100,"current_interval_usage_count":100},
          {"model_name":"MiniMax-M2","current_interval_total_count":1500,"current_interval_usage_count":1200,
           "start_time":1799990000000,"end_time":1800008000000,"remains_time":8000000,
           "current_weekly_total_count":0,"current_weekly_usage_count":0,"current_weekly_status":3}
        ],"current_subscribe_title":"Coding Plan Plus"}
        """)
        let parsed = try MiniMaxProvider.parse(coding, now: now)
        #expect(parsed.windows.count == 1)
        #expect(parsed.windows[0].usedPercent == 20)
        #expect(parsed.windows[0].windowMinutes == 300)
        #expect(parsed.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_008_000))
        #expect(parsed.plan == "Coding Plan Plus")

        // Token Plan: percentages left, nested under `data`.
        let token = try json("""
        {"base_resp":{"status_code":0,"status_msg":"success"},"data":{"current_subscribe_title":"Token Plan Plus",
         "model_remains":[{"model_name":"general","current_interval_total_count":0,"current_interval_usage_count":0,
          "current_interval_remaining_percent":"96","start_time":1799996400000,"end_time":1800014400000,
          "current_weekly_total_count":0,"current_weekly_usage_count":0,"current_weekly_remaining_percent":"99",
          "weekly_start_time":1799596800000,"weekly_end_time":1800201600000}]}}
        """)
        let windows = try MiniMaxProvider.parse(token, now: now).windows
        #expect(windows.map { $0.usedPercent.rounded() } == [4, 1])
        #expect(windows.map(\.windowMinutes) == [300, 10_080])
    }

    @Test func miniMaxRefusedKey() throws {
        let body = try json(#"{"base_resp":{"status_code":1004,"status_msg":"invalid api key"}}"#)
        #expect {
            try MiniMaxProvider.parse(body)
        } throws: { error in
            (error as? ProviderError)?.isAuthFailure == true
        }
    }

    @Test func copilotPaidAndFreePlans() throws {
        let paid = try json("""
        {"copilot_plan":"individual","quota_reset_date":"2026-11-01","quota_snapshots":{
          "premium_interactions":{"entitlement":300,"remaining":45,"percent_remaining":15,"unlimited":false},
          "chat":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true},
          "completions":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":false}
        }}
        """)
        let windows = CopilotProvider.windows(from: paid)
        #expect(windows.map(\.scope) == ["premium"])
        #expect(windows[0].usedPercent == 85)
        #expect(windows[0].resetsAt == ISODate.parse("2026-11-01T00:00:00Z"))
        #expect(zh { windows[0].label } == "高级")
        #expect(en { windows[0].label } == "Prem")
        #expect(CopilotProvider.planName("individual") == "Copilot Pro")

        // Free: counts left against monthly allowances.
        let free = try json("""
        {"copilot_plan":"free","limited_user_reset_date":"2026-11-03",
         "monthly_quotas":{"chat":50,"completions":2000},"limited_user_quotas":{"chat":40,"completions":500}}
        """)
        let freeWindows = CopilotProvider.windows(from: free)
        #expect(freeWindows.map(\.scope) == ["chat", "completions"])
        #expect(freeWindows.map(\.usedPercent) == [20, 75])
    }

    @Test func copilotTokenOnlyFromGitHubDotCom() {
        let config: [String: Any] = [
            "octo.ghe.com:Iv1.x": ["user": "a", "oauth_token": "ghu_enterprise"],
            "github.com:Iv1.b507a08c87ecfe98": ["user": "b", "oauth_token": "ghu_public"],
        ]
        #expect(CopilotProvider.token(inConfig: config) == "ghu_public")
        #expect(CopilotProvider.token(inConfig: ["octo.ghe.com": ["oauth_token": "x"]]) == nil)
    }

    @Test func cursorBillingCycle() throws {
        let body = try json("""
        {"billingCycleStart":"2026-10-01T00:00:00.000Z","billingCycleEnd":"2026-10-31T00:00:00.000Z",
         "membershipType":"pro","individualUsage":{"plan":{"used":1500,"limit":2000,"totalPercentUsed":61.5}}}
        """)
        let window = try #require(CursorProvider.window(from: body))
        #expect(window.usedPercent == 61.5)
        #expect(window.windowMinutes == 30 * 1_440)
        #expect(zh { window.label } == "月")

        // Without percentages, cents against the limit.
        let cents = try json(#"{"individualUsage":{"plan":{"used":500,"limit":2000}}}"#)
        #expect(CursorProvider.window(from: cents)?.usedPercent == 25)
        #expect(CursorProvider.window(from: try json(#"{"isUnlimited":true}"#)) == nil)
    }

    @Test func jwtClaims() {
        // header.payload.signature with payload {"exp":1800000000,"email":"dev@example.com"}
        let payload = Data(#"{"exp":1800000000,"email":"dev@example.com","sub":"auth0|user_1"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).sig"
        #expect(JWT.expiry(token) == now)
        #expect(JWT.email(token) == "dev@example.com")
        #expect(JWT.subject(token) == "auth0|user_1")
    }

    @Test func numbersFromJSON() throws {
        let body = try json(#"{"one":1,"zero":0,"text":"7.5","flag":true}"#)
        #expect(Num.double(body["one"]) == 1)
        #expect(Num.double(body["zero"]) == 0)
        #expect(Num.double(body["text"]) == 7.5)
        #expect(Num.epochDate(1_800_000_000_000) == now)
        #expect(Num.epochDate(1_800_000_000) == now)
    }
}

// MARK: - Labels, names and CodexBar

struct LabelTests {
    @Test func windowLabelsFollowTheLanguage() {
        #expect(zh { [300, 1_440, 10_080, 43_200].map { WindowLabel.text(minutes: $0, scope: nil, key: "x") } } == ["5h", "日", "周", "月"])
        #expect(en { [300, 1_440, 10_080, 43_200].map { WindowLabel.text(minutes: $0, scope: nil, key: "x") } } == ["5h", "Day", "Wk", "Mo"])
        #expect(en { ProviderCatalog.name(for: "doubao") } == "Doubao")
        #expect(zh { ProviderCatalog.name(for: "doubao") } == "豆包")
        #expect(ProviderCatalog.name(for: "somethingnew") == "Somethingnew")
    }

    @Test func codexBarNamedWindows() throws {
        let output = Data("""
        [{"provider":"zai","rateWindowLabels":{"primary":"session","secondary":"Opus"},
          "usage":{"accountEmail":"a@b.c","primary":{"usedPercent":30},"secondary":{"usedPercent":50,"windowMinutes":null}}},
         {"provider":"deepseek","usage":{}},
         {"provider":"cursor","error":{"message":"Not signed in. Open cursor.com."}}]
        """.utf8)
        let providers = try CodexBarCLI.parse(output)
        #expect(providers.map(\.providerID) == ["zai", "cursor"])
        let windows = providers[0].windows
        #expect(windows.map(\.windowMinutes).contains(300))
        #expect(windows.contains { $0.scope == "Opus" })
        #expect(providers[1].error == "Not signed in")
    }

    @Test func oldSavedReadingsStillDecode() throws {
        // Saved by 0.5.x, which stored names and labels.
        let saved = Data("""
        {"providerID":"kimi","name":"Kimi Code","shortName":"Kimi","windows":[{"key":"primary","label":"5h",
         "usedPercent":12,"windowMinutes":300,"resetsAt":800000000}],"isStale":false,"sessionShares":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(ProviderUsage.self, from: saved)
        #expect(decoded.windows.first?.label == "5h")
        #expect(decoded.name == "Kimi Code")
    }
}

// MARK: - Fetch merging

struct UsageFetchTests {
    @Test func windowsPastTheirResetDropToZero() {
        let cached = provider("kimi", [
            window(12, minutes: 10_080, resetsIn: 3_600, key: "secondary"),
            window(80, minutes: 300, resetsIn: -60, key: "primary"),
        ])
        let stale = UsageFetch.staleReading(cached, error: "登录过期", now: now)
        #expect(stale.isStale)
        #expect(stale.error == "登录过期")
        #expect(stale.windows.map(\.usedPercent) == [12, 0])
        #expect(stale.windows[0].resetsAt != nil)
        #expect(stale.windows[1].resetsAt == nil)
    }

    @Test func failedProvidersFallBackToTheirLastGoodReading() {
        var lastGood: [String: ProviderUsage] = [:]
        let good = provider("claude", [window(40, resetsIn: 600)])
        _ = UsageFetch.fillingFromLastGood([good], lastGood: &lastGood, now: now)
        #expect(lastGood["claude"]?.updatedAt == now)

        let failed = ProviderUsage.make(id: "claude", windows: [], error: "expired")
        let unknown = ProviderUsage.make(id: "kimi", windows: [], error: "no key")
        let later = now.addingTimeInterval(900)
        let result = UsageFetch.fillingFromLastGood([failed, unknown], lastGood: &lastGood, now: later)
        #expect(result[0].isStale && result[0].error == "expired")
        #expect(result[0].windows.map(\.usedPercent) == [0])   // its reset passed meanwhile
        #expect(result[0].updatedAt == now)
        #expect(!result[1].isStale && result[1].windows.isEmpty)
    }

    @Test func codexBarOnlyFillsWhatBuiltInCouldNotRead() {
        let mine = [provider("claude", [window(10, resetsIn: 60)]), provider("kimi", [])]
        let theirs = [provider("kimi", [window(30, resetsIn: 60)]), provider("claude", [window(99, resetsIn: 60)]),
                      provider("gemini", [window(5, resetsIn: 60)])]
        let merged = UsageFetch.merge(builtIn: mine, codexBar: theirs)
        #expect(merged.map(\.providerID) == ["claude", "kimi", "gemini"])
        #expect(merged.map { $0.windows.first?.usedPercent } == [10, 30, 5])
    }

    @Test func nextResetIsTheSoonestAhead() {
        let providers = [
            provider("a", [window(1, resetsIn: -10), window(1, resetsIn: 500, key: "secondary")]),
            provider("b", [window(1, resetsIn: 200)]),
        ]
        #expect(UsageFetch.nextReset(in: providers, after: now) == now.addingTimeInterval(200))
        #expect(UsageFetch.nextReset(in: [], after: now) == nil)
    }
}

struct PreferredHostTests {
    @Test func movesOnFromARefusedKeyAndRemembersTheHostThatAnswered() async throws {
        let id = "test-\(UUID().uuidString)"
        let answer = try await PreferredHost.firstAnswer(hosts: ["cn", "intl"], providerID: id) { host in
            if host == "cn" { throw ProviderError.expired("refused") }
            return host
        }
        #expect(answer == "intl")
        #expect(PreferredHost.ordered(["cn", "intl"], for: id) == ["intl", "cn"])
    }

    @Test func stopsOnRateLimitsAndReportsTheRefusal() async {
        let id = "test-\(UUID().uuidString)"
        var asked: [String] = []
        await #expect(throws: ProviderError.rateLimited) {
            try await PreferredHost.firstAnswer(hosts: ["a", "b"], providerID: id) { (host: String) -> String in
                asked.append(host)
                throw ProviderError.rateLimited
            }
        }
        #expect(asked == ["a"])

        await #expect(throws: ProviderError.expired("refused")) {
            try await PreferredHost.firstAnswer(hosts: ["a", "b"], providerID: id) { (host: String) -> String in
                throw host == "a" ? ProviderError.expired("refused") : ProviderError.http(404)
            }
        }
    }
}

// MARK: - Credentials on disk (shared global overrides, so serialized)

@Suite(.serialized)
struct CredentialTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usage-rings-creds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func savesClearsAndKeepsTheKeyFilePrivate() throws {
        let file = try temporaryDirectory().appendingPathComponent("keys.json")
        KeyStore.fileURLOverride = file
        defer {
            KeyStore.fileURLOverride = nil
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }

        #expect(KeyStore.key(for: "kimi") == nil)
        try KeyStore.setKey("  sk-test-123  ", for: "kimi")
        try KeyStore.setKey("oc-key", for: "opencodego")
        #expect(KeyStore.key(for: "kimi") == "sk-test-123")
        #expect(KeyStore.key(for: "opencodego") == "oc-key")

        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        try KeyStore.setKey(nil, for: "kimi")
        #expect(KeyStore.key(for: "kimi") == nil)
        #expect(KeyStore.key(for: "opencodego") == "oc-key")
    }

    @Test func codingPlanKeysFromClaudeCodeSettings() throws {
        let directory = try temporaryDirectory()
        KeyStore.fileURLOverride = directory.appendingPathComponent("keys.json")
        ClaudeCodeEnv.settingsURLOverride = directory.appendingPathComponent("settings.json")
        ProcessEnv.override = [:]
        defer {
            KeyStore.fileURLOverride = nil
            ClaudeCodeEnv.settingsURLOverride = nil
            ProcessEnv.override = nil
            try? FileManager.default.removeItem(at: directory)
        }

        func point(at baseURL: String, token: String = "sk-plan") throws {
            let settings: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_AUTH_TOKEN": token]]
            try JSONSerialization.data(withJSONObject: settings).write(to: directory.appendingPathComponent("settings.json"))
        }

        try point(at: "https://open.bigmodel.cn/api/anthropic")
        #expect(ZaiProvider().keySource() == .claudeCode)
        #expect(!MiniMaxProvider().isConfigured())

        try point(at: "https://api.minimax.io/anthropic")
        #expect(MiniMaxProvider().keySource() == .claudeCode)
        #expect(ClaudeCodeEnv.credential(hosts: ["minimax.io"])?.host == "api.minimax.io")
        #expect(!ZaiProvider().isConfigured())

        // Kimi Code's endpoint, not the pay-as-you-go Moonshot platform.
        try point(at: "https://api.kimi.com/coding/")
        #expect(KimiProvider().keySource() == .claudeCode)
        try point(at: "https://api.moonshot.cn/anthropic")
        #expect(KimiProvider().keySource() == nil)

        // Look-alike hosts and plain HTTP are ignored.
        try point(at: "https://bigmodel.cn.example.com/api")
        #expect(!ZaiProvider().isConfigured())
        try point(at: "http://open.bigmodel.cn/api/anthropic")
        #expect(!ZaiProvider().isConfigured())

        // A saved key wins over everything else.
        try point(at: "https://open.bigmodel.cn/api/anthropic")
        try KeyStore.setKey("sk-saved", for: "zai")
        #expect(ZaiProvider().keySource() == .saved)

        ProcessEnv.override = ["MINIMAX_API_KEY": "sk-env"]
        #expect(MiniMaxProvider().keySource() == .environment("MINIMAX_API_KEY"))
    }

    @Test func copilotTokenFromEditorPluginConfig() throws {
        let directory = try temporaryDirectory()
        KeyStore.fileURLOverride = directory.appendingPathComponent("keys.json")
        ProcessEnv.override = ["XDG_CONFIG_HOME": directory.path]
        defer {
            KeyStore.fileURLOverride = nil
            ProcessEnv.override = nil
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(!CopilotProvider().isConfigured())

        let config = directory.appendingPathComponent("github-copilot", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"github.com":{"user":"octo","oauth_token":"gho_x"}}"#.utf8).write(to: config.appendingPathComponent("hosts.json"))
        #expect(CopilotProvider().keySource() == .file("~/.config/github-copilot/hosts.json"))
    }
}

// MARK: - Island layout

struct IslandLayoutTests {
    private let notch = NotchGeometry(width: 179, height: 32, minX: 646)

    @Test func symmetricWhenTheMenuBarHasRoom() {
        let layout = IslandLayout(notch: notch, rowCount: 4, maxWindows: 2, rightSpace: nil)
        #expect(layout.isSymmetric)
        #expect(layout.leftCount == 2 && layout.rightCount == 2)
        #expect(layout.leftWing == layout.rightWing)
        #expect(layout.miniRing == 26)   // notch height minus 6: fills the bar
        #expect(layout.collapsedSize.width == layout.leftWing * 2 + 179)
    }

    @Test func crowdedRightSideMovesRingsLeft() {
        // 49pt free: one 26pt ring fits (9 + 26 + 9 = 44), two don't.
        let layout = IslandLayout(notch: notch, rowCount: 4, maxWindows: 2, rightSpace: 49)
        #expect(!layout.isSymmetric)
        #expect(layout.rightCount == 1 && layout.leftCount == 3)
        #expect(layout.rightWing <= 49)
        #expect(layout.collapsedSize.width == layout.leftWing + 179 + layout.rightWing)
    }

    @Test func noRoomAtAllKeepsEveryRingLeft() {
        let layout = IslandLayout(notch: notch, rowCount: 3, maxWindows: 2, rightSpace: 6)
        #expect(layout.rightCount == 0 && layout.leftCount == 3)
        #expect(layout.rightWing == IslandLayout.emptyWing)
    }

    @Test func soloProviderLabelsTheRightWingOnlyWhenItFits() {
        #expect(IslandLayout(notch: notch, rowCount: 1, maxWindows: 1, rightSpace: nil).showsSoloLabel)
        #expect(!IslandLayout(notch: notch, rowCount: 1, maxWindows: 1, rightSpace: 40).showsSoloLabel)
    }
}

struct FittingLayoutTests {
    @Test func sideColumnShrinksToFitTheScreen() {
        let roomy = SideLayout.fitting(size: .large, showLabels: true, rowCount: 4, maxHeight: 900)
        #expect(roomy.size == .large && roomy.showLabels)

        let tall = SideLayout(size: .large, showLabels: true, rowCount: 12).columnHeight
        let fitted = SideLayout.fitting(size: .large, showLabels: true, rowCount: 12, maxHeight: tall - 1)
        #expect(fitted.columnHeight <= tall - 1)
        #expect(fitted.size != .large)

        // Nothing fits: the smallest layout, without names.
        let squeezed = SideLayout.fitting(size: .medium, showLabels: true, rowCount: 40, maxHeight: 200)
        #expect(squeezed.size == .small && !squeezed.showLabels)
    }

    @Test func expandedIslandWrapsOnNarrowScreens() {
        let notch = NotchGeometry(width: 179, height: 32, minX: 646)
        let wide = IslandLayout(notch: notch, rowCount: 8, maxWindows: 2)
        #expect(wide.expandedRows == 1 && wide.columnsPerRow == 8)

        let narrow = IslandLayout(notch: notch, rowCount: 8, maxWindows: 2, maxWidth: 500)
        #expect(narrow.columnsPerRow == 5 && narrow.expandedRows == 2)
        #expect(narrow.expandedSize.width <= 500)
        #expect(narrow.expandedSize.height > wide.expandedSize.height)
    }
}

struct AlertPolicyTests {
    private func reading(_ used: Double, stale: Bool = false) -> [ProviderUsage] {
        [provider("claude", [window(used, resetsIn: 3_600)], stale: stale)]
    }

    @Test func alertsOnceWhenCrossingAndRearmsAfterDroppingBack() {
        var ledger = AlertLedger()
        #expect(AlertPolicy.alerts(for: reading(50), threshold: 80, onReset: true, ledger: &ledger, now: now).isEmpty)

        let crossed = zh { AlertPolicy.alerts(for: reading(85), threshold: 80, onReset: true, ledger: &ledger, now: now) }
        #expect(crossed.count == 1)
        #expect(crossed.first?.title == "Claude 5h 已用 85%")
        #expect(crossed.first?.body.contains("后重置") == true)

        // Still above, or wobbling just under: no repeat.
        #expect(AlertPolicy.alerts(for: reading(90), threshold: 80, onReset: true, ledger: &ledger, now: now).isEmpty)
        #expect(AlertPolicy.alerts(for: reading(78), threshold: 80, onReset: true, ledger: &ledger, now: now).isEmpty)
        #expect(AlertPolicy.alerts(for: reading(81), threshold: 80, onReset: true, ledger: &ledger, now: now).isEmpty)

        // Clearly back down (a reset), then up again: a new alert.
        _ = AlertPolicy.alerts(for: reading(10), threshold: 80, onReset: true, ledger: &ledger, now: now)
        #expect(AlertPolicy.alerts(for: reading(82), threshold: 80, onReset: true, ledger: &ledger, now: now).count == 1)
    }

    @Test func announcesWhenAUsedUpWindowResets() {
        var ledger = AlertLedger()
        let out = en { AlertPolicy.alerts(for: reading(100), threshold: 90, onReset: true, ledger: &ledger, now: now) }
        #expect(out.map(\.title) == ["Claude 5h quota used up"])

        let reset = en { AlertPolicy.alerts(for: reading(3), threshold: 90, onReset: true, ledger: &ledger, now: now) }
        #expect(reset.map(\.title) == ["Claude 5h quota reset"])
        #expect(ledger.exhausted.isEmpty)

        // Reset alerts off: nothing, but the window is still forgotten.
        _ = AlertPolicy.alerts(for: reading(100), threshold: 0, onReset: false, ledger: &ledger, now: now)
        #expect(AlertPolicy.alerts(for: reading(0), threshold: 0, onReset: false, ledger: &ledger, now: now).isEmpty)
        #expect(ledger.exhausted.isEmpty)
    }

    @Test func staleReadingsDontWarnAndVanishedWindowsAreForgotten() {
        var ledger = AlertLedger()
        #expect(AlertPolicy.alerts(for: reading(95, stale: true), threshold: 80, onReset: true, ledger: &ledger, now: now).isEmpty)
        _ = AlertPolicy.alerts(for: reading(95), threshold: 80, onReset: true, ledger: &ledger, now: now)
        #expect(!ledger.warned.isEmpty)
        _ = AlertPolicy.alerts(for: [], threshold: 80, onReset: true, ledger: &ledger, now: now)
        #expect(ledger == AlertLedger())
    }
}

struct TimeTextTests {
    @Test func countdownsAndDurationsInBothLanguages() {
        #expect(zh { TimeText.countdown(until: now.addingTimeInterval(2 * 3_600 + 5 * 60), from: now) } == "2时5分后")
        #expect(en { TimeText.countdown(until: now.addingTimeInterval(2 * 3_600 + 5 * 60), from: now) } == "in 2h 5m")
        #expect(en { TimeText.countdown(until: now.addingTimeInterval(3 * 86_400), from: now) } == "in 3d")
        #expect(zh { TimeText.countdown(until: now.addingTimeInterval(-5), from: now) } == "即将重置")
        #expect(zh { TimeText.duration(30) } == "1分钟")
        #expect(en { TimeText.duration(90_000) } == "1d 1h")
        #expect(en { TimeText.relative(now.addingTimeInterval(-7_200), now: now) } == "2 h ago")
    }
}
