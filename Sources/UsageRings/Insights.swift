import Foundation

// MARK: - Pace

/// How fast a quota window is being used compared with an even pace.
struct Pace: Equatable {
    /// Share of the window that has elapsed, 0…100.
    let expectedPercent: Double
    /// Seconds until the window is used up at the current rate, if it will
    /// run out before it resets.
    let runsOutIn: TimeInterval?

    var willLastToReset: Bool { runsOutIn == nil }

    /// Positive = ahead of an even pace (burning faster than time passes).
    func delta(used: Double) -> Double { used - expectedPercent }

    static func of(_ window: UsageWindow, now: Date = .now) -> Pace? {
        guard let resetsAt = window.resetsAt,
              let minutes = window.windowMinutes, minutes > 0 else { return nil }
        let length = TimeInterval(minutes * 60)
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = length - remaining
        // Too early in the window to say anything meaningful.
        guard remaining > 0, elapsed > min(600, length * 0.02) else { return nil }

        let expected = min(100, max(0, elapsed / length * 100))
        guard window.usedPercent > 0 else {
            return Pace(expectedPercent: expected, runsOutIn: nil)
        }
        let rate = window.usedPercent / elapsed
        let secondsToEmpty = (100 - window.usedPercent) / rate
        return Pace(expectedPercent: expected, runsOutIn: secondsToEmpty < remaining ? secondsToEmpty : nil)
    }
}

// MARK: - Recommendation

enum Recommendation {
    /// The provider with the most headroom that won't run dry before its
    /// windows reset; falls back to plain headroom when every provider is
    /// on track to run out.
    static func pick(_ providers: [ProviderUsage], now: Date = .now) -> ProviderUsage? {
        let candidates = providers.filter { !$0.windows.isEmpty && !$0.isStale }
        guard candidates.count > 1 else { return nil }

        func headroom(_ provider: ProviderUsage) -> Double {
            100 - (provider.peak?.usedPercent ?? 100)
        }
        func lasts(_ provider: ProviderUsage) -> Bool {
            provider.windows.allSatisfy { Pace.of($0, now: now)?.willLastToReset ?? true }
        }

        let ranked = candidates.sorted { lhs, rhs in
            if lasts(lhs) != lasts(rhs) { return lasts(lhs) }
            return headroom(lhs) > headroom(rhs)
        }
        guard let best = ranked.first, headroom(best) >= 15 else { return nil }
        return best
    }
}
