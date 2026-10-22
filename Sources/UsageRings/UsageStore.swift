#if canImport(Combine)
import Combine
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var providers: [ProviderUsage] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false
    /// Provider whose detail card is showing (hover), or pinned by a click.
    @Published var hoveredID: String?
    @Published var pinnedID: String?
    /// The side column is being dragged; suppress hover cards meanwhile.
    @Published var isDragging = false
    @Published var isIslandHovered = false
    /// Menu-bar room right of the notch, measured by the app delegate.
    @Published var islandRightSpace: CGFloat?
    /// Screen room the app delegate measured, so long provider lists shrink
    /// to fit instead of running off the screen.
    @Published var sideMaxHeight: CGFloat?
    @Published var islandMaxWidth: CGFloat?

    var expandedID: String? { isDragging ? nil : (hoveredID ?? pinnedID) }

    /// Where usage comes from; the app delegate keeps this in sync with settings.
    var dataSource: DataSource = .builtIn {
        didSet {
            if dataSource != oldValue { refresh(force: true) }
        }
    }

    /// Called with every fresh set of readings (quota alerts listen here).
    var onUpdate: (([ProviderUsage]) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var pollInterval: Duration?
    private var resetTask: Task<Void, Never>?
    /// Bumped by every refresh, so a slow fetch that a newer one superseded
    /// can't land on top of it.
    private var generation = 0

    private static let lastGoodKey = "lastGoodUsage"
    /// Last successful reading per provider, kept across launches so an
    /// expired login still shows where that quota stood.
    private var lastGood: [String: ProviderUsage] = {
        guard let data = UserDefaults.standard.data(forKey: UsageStore.lastGoodKey),
              let decoded = try? JSONDecoder().decode([String: ProviderUsage].self, from: data) else { return [:] }
        return decoded
    }()

    /// Snapshot mode only: render a fixed dataset without polling.
    func load(_ providers: [ProviderUsage], updatedAt: Date) {
        self.providers = providers
        self.lastUpdated = updatedAt
    }

    /// Starts polling, or restarts it when the interval changed.
    func start(every interval: Duration = .seconds(150)) {
        guard pollTask == nil || pollInterval != interval else { return }
        pollTask?.cancel()
        pollInterval = interval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh(force: Bool = false) {
        guard force || !isLoading else { return }
        isLoading = true
        generation += 1
        let current = generation

        let source = dataSource
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await UsageFetch.fetch(source)
            }.value

            guard let self, current == self.generation else { return }
            self.isLoading = false
            switch result {
            case let .success(providers):
                self.providers = UsageFetch.fillingFromLastGood(providers, lastGood: &self.lastGood, now: .now)
                self.lastUpdated = .now
                self.lastError = nil
                self.saveLastGood()
                self.scheduleResetRefresh()
                self.onUpdate?(self.providers)
            case let .failure(error):
                // Keep the last good rings on a transient failure.
                self.lastError = error.localizedDescription
            }
        }
    }

    /// A window that just reset is back at zero; refresh shortly after
    /// instead of showing it nearly empty until the next poll.
    private func scheduleResetRefresh() {
        resetTask?.cancel()
        guard let next = UsageFetch.nextReset(in: providers, after: .now) else { return }
        let delay = next.timeIntervalSinceNow + 15
        let pollSeconds = Double(pollInterval?.components.seconds ?? 150)
        guard delay < pollSeconds else { return }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func saveLastGood() {
        if let data = try? JSONEncoder().encode(lastGood) {
            UserDefaults.standard.set(data, forKey: Self.lastGoodKey)
        }
    }
}
#endif
