import Foundation

/// One quota window (5-hour session, weekly, monthly…) for a provider account.
struct UsageWindow: Identifiable, Equatable, Codable, Sendable {
    let key: String
    /// Names a window that is more than a time span: Copilot's premium
    /// requests, Claude's model-specific weekly limits, CodexBar's own names.
    var scope: String?
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    var id: String { scope.map { "\(key)-\($0)" } ?? key }

    /// Worked out when shown, so it follows the interface language.
    var label: String { WindowLabel.text(minutes: windowMinutes, scope: scope, key: key) }

    /// Longer windows sit on the outer ring.
    var spanRank: Int {
        if let windowMinutes { return windowMinutes }
        switch key {
        case "tertiary": return 43_200
        case "secondary": return 10_080
        default: return 300
        }
    }

    func with(usedPercent: Double, resetsAt: Date?) -> UsageWindow {
        UsageWindow(key: key, scope: scope, usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }
}

struct ProviderUsage: Identifiable, Equatable, Codable, Sendable {
    let providerID: String
    var account: String?
    /// Longest window first (outer ring → inner ring).
    var windows: [UsageWindow]
    var error: String?
    /// When these windows were fetched.
    var updatedAt: Date?
    /// The latest refresh failed; windows are the last good reading.
    var isStale = false
    /// Local sessions' shares of the attributed (shortest) window.
    var sessionShares: [SessionShare] = []

    var id: String { "\(providerID)|\(account ?? "")" }
    var name: String { ProviderCatalog.name(for: providerID) }
    var shortName: String { ProviderCatalog.shortName(for: providerID) }

    var peak: UsageWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    static func make(id: String, account: String? = nil, windows: [UsageWindow], error: String? = nil) -> ProviderUsage {
        ProviderUsage(
            providerID: id,
            account: account,
            windows: windows.sorted { $0.spanRank > $1.spanRank },
            error: error
        )
    }
}

extension UsageWindow {
    static func make(key: String, scope: String? = nil, usedPercent: Double, minutes: Int?, resetsAt: Date?) -> UsageWindow {
        UsageWindow(
            key: key,
            scope: scope,
            usedPercent: min(max(usedPercent.isFinite ? usedPercent : 0, 0), 100),
            windowMinutes: minutes,
            resetsAt: resetsAt
        )
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}

/// Short window names: "5h", 周 / Wk, 月 / Mo, or the scope's own name.
enum WindowLabel {
    static func text(minutes: Int?, scope: String?, key: String) -> String {
        if let scope { return scopeText(scope) }
        if let minutes, minutes > 0 {
            if minutes < 24 * 60 { return "\(max(1, minutes / 60))h" }
            if minutes <= 2 * 24 * 60 { return tr("日", "Day") }
            if minutes <= 8 * 24 * 60 { return tr("周", "Wk") }
            return tr("月", "Mo")
        }
        switch key {
        case "primary": return "5h"
        case "secondary": return tr("周", "Wk")
        default: return tr("月", "Mo")
        }
    }

    private static func scopeText(_ scope: String) -> String {
        switch scope {
        case "premium": tr("高级", "Prem")
        case "chat": tr("对话", "Chat")
        case "completions": tr("补全", "Comp")
        case "opus": "Opus"
        case "sonnet": "Sonnet"
        case "pro": "Pro"
        case "flash": "Flash"
        case "flash-lite": "Lite"
        default: String(scope.prefix(6))
        }
    }

    /// Free-text window names (CodexBar's `rateWindowLabels`) mapped to a
    /// span when they name one; nil leaves the name as the window's scope.
    static func minutes(forName name: String) -> Int? {
        switch name.lowercased() {
        case "session", "5-hour", "5 hour", "5h": 300
        case "daily", "day": 1_440
        case "weekly", "week": 10_080
        case "monthly", "month": 43_200
        default: nil
        }
    }

    /// Rough rendered width at the detail card's 10.5pt, for sizing the
    /// label column to its longest entry.
    static func estimatedWidth(_ label: String) -> Double {
        label.unicodeScalars.reduce(0) { width, scalar in
            width + (scalar.value > 0x2E80 ? 11 : 6.6)
        }
    }
}

/// Display names shared by the built-in and CodexBar sources.
enum ProviderCatalog {
    private static let names: [String: (zh: String, en: String, short: String)] = [
        "codex": ("Codex", "Codex", "Codex"),
        "openai": ("OpenAI", "OpenAI", "OpenAI"),
        "claude": ("Claude", "Claude", "Claude"),
        "cursor": ("Cursor", "Cursor", "Cursor"),
        "opencode": ("OpenCode", "OpenCode", "OpenCode"),
        "opencodego": ("OpenCode Go", "OpenCode Go", "OC Go"),
        "gemini": ("Gemini", "Gemini", "Gemini"),
        "antigravity": ("Antigravity", "Antigravity", "AGY"),
        "copilot": ("GitHub Copilot", "GitHub Copilot", "Copilot"),
        "kimi": ("Kimi Code", "Kimi Code", "Kimi"),
        "moonshot": ("Moonshot", "Moonshot", "Moonshot"),
        "deepseek": ("DeepSeek", "DeepSeek", "DeepSeek"),
        "doubao": ("豆包", "Doubao", "Doubao"),
        "zai": ("智谱 GLM", "Z.ai GLM", "GLM"),
        "minimax": ("MiniMax", "MiniMax", "MiniMax"),
        "alibaba": ("阿里云百炼", "Alibaba Model Studio", "Bailian"),
        "qwencloud": ("通义千问", "Qwen", "Qwen"),
        "openrouter": ("OpenRouter", "OpenRouter", "ORouter"),
        "windsurf": ("Windsurf", "Windsurf", "Windsurf"),
        "factory": ("Droid", "Droid", "Droid"),
        "amp": ("Amp", "Amp", "Amp"),
        "kiro": ("Kiro", "Kiro", "Kiro"),
    ]

    static func name(for id: String) -> String {
        names[id].map { tr($0.zh, $0.en) } ?? fallback(id)
    }

    static func shortName(for id: String) -> String {
        if id == "doubao" { return tr("豆包", "Doubao") }
        return names[id]?.short ?? fallback(id)
    }

    private static func fallback(_ id: String) -> String {
        id.prefix(1).uppercased() + id.dropFirst()
    }
}

// MARK: - Time wording

/// Countdowns and durations in the interface language: "2时5分后" / "in 2h 5m".
enum TimeText {
    static func countdown(until date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return tr("即将重置", "resetting") }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return hours > 0 ? tr("\(days)天\(hours)时后", "in \(days)d \(hours)h") : tr("\(days)天后", "in \(days)d")
        }
        if hours > 0 { return tr("\(hours)时\(minutes)分后", "in \(hours)h \(minutes)m") }
        return tr("\(max(1, minutes))分钟后", "in \(max(1, minutes))m")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(60, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return hours > 0 ? tr("\(days)天\(hours)时", "\(days)d \(hours)h") : tr("\(days)天", "\(days)d")
        }
        if hours > 0 { return tr("\(hours)时\(minutes)分", "\(hours)h \(minutes)m") }
        return tr("\(minutes)分钟", "\(minutes)m")
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return tr("刚刚", "just now") }
        if seconds < 3_600 { return tr("\(seconds / 60) 分钟前", "\(seconds / 60) min ago") }
        if seconds < 86_400 { return tr("\(seconds / 3_600) 小时前", "\(seconds / 3_600) h ago") }
        return tr("\(seconds / 86_400) 天前", "\(seconds / 86_400) d ago")
    }
}

// MARK: - Interface language

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, chinese = "zh", english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: tr("跟随系统", "System")
        case .chinese: "中文"
        case .english: "English"
        }
    }
}

enum L10n {
    /// Set from settings at launch and whenever the user changes it. Read
    /// from background fetches too, which only ever see a whole value.
    nonisolated(unsafe) static var language: AppLanguage = .system

    /// Tests pin a language for one task without touching the global.
    @TaskLocal static var pinned: AppLanguage?

    static var isChinese: Bool {
        switch pinned ?? language {
        case .chinese: true
        case .english: false
        case .system: systemPrefersChinese
        }
    }

    static let systemPrefersChinese: Bool = {
        guard let first = Locale.preferredLanguages.first?.lowercased() else { return true }
        return first.hasPrefix("zh")
    }()
}

/// The Chinese or English wording, following the interface language.
func tr(_ chinese: String, _ english: String) -> String {
    L10n.isChinese ? chinese : english
}
