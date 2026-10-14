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

    private func write(_ lines: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(data: try JSONSerialization.data(withJSONObject: $0), encoding: .utf8)! }
            .joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        // Scans skip files untouched since the window opened; date them at the test clock.
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
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
        let local = try #require(SessionAttribution.codexLocalUsage(lookback: 3_600, root: root, now: now))
        #expect(local.windows.map(\.usedPercent) == [45])
        #expect(local.windows.first?.label == "周")
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
        #expect(windows.map(\.label) == ["5h", "周"])
        #expect(windows.map(\.usedPercent) == [12, 96])
        #expect(windows.first?.resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
    }

    @Test func claudeWindows() {
        let body: [String: Any] = [
            "five_hour": ["utilization": 62.0, "resets_at": "2026-10-14T09:00:00.000Z"],
            "seven_day": ["utilization": 84.0, "resets_at": "2026-10-14T08:00:00Z"],
            "seven_day_opus": NSNull(),
        ]
        let windows = ClaudeProvider.windows(from: body)
        #expect(windows.map(\.label) == ["5h", "周"])
        #expect(windows.map(\.usedPercent) == [62, 84])
        #expect(windows.allSatisfy { $0.resetsAt != nil })
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
        #expect(windows.map(\.label) == ["5h", "周", "月"])
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
        #expect(windows.map(\.label) == ["5h", "周"])
        #expect(windows.map { Int($0.usedPercent.rounded()) } == [20, 30])
    }

    @Test func jwtClaims() {
        // header.payload.signature with payload {"exp":1800000000,"email":"dev@example.com"}
        let payload = Data(#"{"exp":1800000000,"email":"dev@example.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).sig"
        #expect(JWT.expiry(token) == now)
        #expect(JWT.email(token) == "dev@example.com")
    }
}
