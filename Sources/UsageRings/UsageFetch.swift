import Foundation

/// Fetching and merging readings, kept free of UI state so it runs off the
/// main actor and can be tested on its own.
enum UsageFetch {
    static func fetch(_ source: DataSource) async -> Result<[ProviderUsage], any Error> {
        let fetched: Result<[ProviderUsage], any Error>
        switch source {
        case .builtIn:
            fetched = .success(await BuiltInProviders.fetchAll())
        case .codexBar:
            fetched = await codexBar()
        case .auto:
            fetched = .success(await fetchAuto())
        }
        // Transcript scanning stays off the main actor too.
        return fetched.map(attributingSessions)
    }

    /// Built-in first; anything it can't read is filled from CodexBar when
    /// CodexBar happens to be installed. Without CodexBar this is just the
    /// built-in result.
    static func fetchAuto() async -> [ProviderUsage] {
        async let builtIn = BuiltInProviders.fetchAll()
        let codexBar: [ProviderUsage] = CodexBarCLI.executableURL() == nil
            ? []
            : ((try? await Self.codexBar().get()) ?? [])
        return merge(builtIn: await builtIn, codexBar: codexBar)
    }

    static func merge(builtIn own: [ProviderUsage], codexBar: [ProviderUsage]) -> [ProviderUsage] {
        var merged: [ProviderUsage] = own.map { mine in
            guard mine.windows.isEmpty,
                  let theirs = codexBar.first(where: { $0.providerID == mine.providerID && !$0.windows.isEmpty })
            else { return mine }
            return theirs
        }
        let ownIDs = Set(own.map(\.providerID))
        merged += codexBar.filter { !ownIDs.contains($0.providerID) }
        return merged
    }

    /// The CLI blocks while it runs (up to its timeout), so it waits on a
    /// plain dispatch thread rather than holding a concurrency-pool thread.
    private static func codexBar() async -> Result<[ProviderUsage], any Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Result { try CodexBarCLI.fetch() })
            }
        }
    }

    /// Adds "which session used it" shares for providers whose agents keep
    /// local transcripts (Claude Code, Codex).
    static func attributingSessions(_ providers: [ProviderUsage]) -> [ProviderUsage] {
        providers.map { provider in
            guard ["claude", "codex"].contains(provider.providerID),
                  let window = SessionAttribution.attributionWindow(for: provider),
                  let resetsAt = window.resetsAt,
                  let minutes = window.windowMinutes else { return provider }
            var enriched = provider
            enriched.sessionShares = SessionAttribution.shares(
                providerID: provider.providerID,
                since: resetsAt.addingTimeInterval(-TimeInterval(minutes * 60))
            )
            return enriched
        }
    }

    /// The last good reading, marked stale. A window whose reset time has
    /// passed since then is known to be back at zero.
    static func staleReading(_ cached: ProviderUsage, error: String?, now: Date) -> ProviderUsage {
        var stale = cached
        stale.isStale = true
        stale.error = error
        stale.windows = cached.windows.map { window in
            guard let resetsAt = window.resetsAt, resetsAt <= now else { return window }
            return window.with(usedPercent: 0, resetsAt: nil)
        }
        return stale
    }

    /// Stamps fresh readings and swaps a failed provider for its last good
    /// reading, marked stale, so the ring keeps its place. `lastGood` is
    /// updated with every fresh reading.
    static func fillingFromLastGood(
        _ fresh: [ProviderUsage],
        lastGood: inout [String: ProviderUsage],
        now: Date
    ) -> [ProviderUsage] {
        fresh.map { provider -> ProviderUsage in
            if !provider.windows.isEmpty {
                var stamped = provider
                stamped.updatedAt = provider.updatedAt ?? now
                stamped.isStale = false
                lastGood[provider.providerID] = stamped
                return stamped
            }
            guard let cached = lastGood[provider.providerID] else { return provider }
            return staleReading(cached, error: provider.error, now: now)
        }
    }

    /// The soonest reset still ahead, so a refresh can land right after it.
    static func nextReset(in providers: [ProviderUsage], after now: Date) -> Date? {
        providers
            .flatMap(\.windows)
            .compactMap(\.resetsAt)
            .filter { $0 > now }
            .min()
    }
}
