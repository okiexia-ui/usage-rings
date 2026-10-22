import Foundation

struct QuotaAlert: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
}

/// Which windows have already been announced, kept across launches so a
/// restart doesn't repeat them.
struct AlertLedger: Codable, Equatable {
    /// Windows above the threshold that already got their alert.
    var warned: Set<String> = []
    /// Windows seen used up, waiting to announce their reset.
    var exhausted: Set<String> = []
}

/// Decides what to announce after each refresh. Crossing the threshold
/// alerts once; dropping back below it (a reset, usually) re-arms the
/// alert. A used-up window announces when it's usable again.
enum AlertPolicy {
    /// Re-arm a little below the threshold, so a reading that wobbles
    /// around it doesn't alert every refresh.
    static let rearmMargin: Double = 5
    static let exhaustedAt: Double = 99.5
    /// A used-up window counts as reset once it's back under this.
    static let resetBelow: Double = 50

    static func alerts(
        for providers: [ProviderUsage],
        threshold: Double,
        onReset: Bool,
        ledger: inout AlertLedger,
        now: Date = .now
    ) -> [QuotaAlert] {
        var alerts: [QuotaAlert] = []
        var current = Set<String>()

        for provider in providers {
            for window in provider.windows {
                let key = "\(provider.id)#\(window.id)"
                current.insert(key)
                let used = window.usedPercent
                let name = "\(provider.name) \(window.label)"

                if threshold > 0, !provider.isStale {
                    if used >= threshold, !ledger.warned.contains(key) {
                        ledger.warned.insert(key)
                        alerts.append(QuotaAlert(
                            id: "warn-\(key)",
                            title: used >= exhaustedAt
                                ? tr("\(name) 额度已用完", "\(name) quota used up")
                                : tr("\(name) 已用 \(Int(used.rounded()))%", "\(name) at \(Int(used.rounded()))%"),
                            body: detail(window, now: now)
                        ))
                    } else if used < threshold - rearmMargin {
                        ledger.warned.remove(key)
                    }
                }

                if used >= exhaustedAt {
                    ledger.exhausted.insert(key)
                } else if used < resetBelow, ledger.exhausted.remove(key) != nil, onReset {
                    alerts.append(QuotaAlert(
                        id: "reset-\(key)",
                        title: tr("\(name) 额度已重置", "\(name) quota reset"),
                        body: tr("可以继续用了，现在已用 \(Int(used.rounded()))%。", "Ready to use again; \(Int(used.rounded()))% used so far.")
                    ))
                }
            }
        }

        // Forget windows that disappeared (provider hidden or signed out).
        ledger.warned.formIntersection(current)
        ledger.exhausted.formIntersection(current)
        return alerts
    }

    private static func detail(_ window: UsageWindow, now: Date) -> String {
        var parts: [String] = []
        if window.usedPercent < exhaustedAt, let runsOut = Pace.of(window, now: now)?.runsOutIn {
            parts.append(tr("按现在速度 \(TimeText.duration(runsOut))后用完", "At this pace it runs out in \(TimeText.duration(runsOut))"))
        }
        if let reset = window.resetsAt, reset > now {
            parts.append(tr("\(TimeText.duration(reset.timeIntervalSince(now)))后重置", "resets in \(TimeText.duration(reset.timeIntervalSince(now)))"))
        }
        let joined = parts.joined(separator: tr("，", ", "))
        return joined.isEmpty ? "" : joined + tr("。", ".")
    }
}

#if canImport(UserNotifications) && canImport(AppKit)
import UserNotifications

/// Posts quota alerts as macOS notifications. Permission is asked the first
/// time there's something to say, not at launch.
@MainActor
final class QuotaNotifier {
    private static let ledgerKey = "alertLedger"
    private var ledger: AlertLedger

    init() {
        ledger = UserDefaults.standard.data(forKey: Self.ledgerKey)
            .flatMap { try? JSONDecoder().decode(AlertLedger.self, from: $0) } ?? AlertLedger()
    }

    /// Notifications need a bundle identity; `swift run` and snapshot mode
    /// have none, and the notification center would trap without one.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func update(_ providers: [ProviderUsage], threshold: Double, onReset: Bool) {
        let alerts = AlertPolicy.alerts(for: providers, threshold: threshold, onReset: onReset, ledger: &ledger)
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: Self.ledgerKey)
        }
        post(alerts)
    }

    func sendTest() {
        post([QuotaAlert(
            id: "test-\(UUID().uuidString)",
            title: tr("用量圈通知正常", "Usage Rings notifications work"),
            body: tr("额度快用完或重置时会这样提醒你。", "This is how you'll hear about quotas running low or resetting.")
        )])
    }

    private func post(_ alerts: [QuotaAlert]) {
        guard canNotify, !alerts.isEmpty else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                content.sound = .default
                let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            }
        }
    }
}
#endif
