import Foundation
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case side, island, both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .side: "侧边圆环"
        case .island: "灵动岛"
        case .both: "两个都要"
        }
    }

    var showsSide: Bool { self != .island }
    var showsIsland: Bool { self != .side }
}

enum DockSide: String, CaseIterable, Identifiable {
    case left, right

    var id: String { rawValue }
    var title: String { self == .left ? "左边" : "右边" }
}

enum RingSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }

    var diameter: CGFloat {
        switch self {
        case .small: 30
        case .medium: 38
        case .large: 50
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .small: 3
        case .medium: 3.5
        case .large: 4
        }
    }

    /// Rings drawn per provider. Small keeps one ring (the tightest limit)
    /// so the percentage still fits in the middle.
    var maxRings: Int {
        switch self {
        case .small: 1
        case .medium: 2
        case .large: 3
        }
    }
}

enum RingMetric: String, CaseIterable, Identifiable {
    case used, remaining

    var id: String { rawValue }
    var title: String { self == .used ? "已用" : "剩余" }
}

enum ColorStyle: String, CaseIterable, Identifiable {
    case traffic, brand

    var id: String { rawValue }
    var title: String { self == .traffic ? "按用量（绿 / 橙 / 红）" : "品牌色" }
}

/// User preferences, persisted to UserDefaults on every change.
@MainActor
final class RingsSettings: ObservableObject {
    static let refreshChoices: [Double] = [1, 2.5, 5, 10]

    @Published var displayMode: DisplayMode { didSet { store(displayMode.rawValue, "displayMode") } }
    @Published var side: DockSide { didSet { store(side.rawValue, "side") } }
    /// Vertical center of the side column, 0 = bottom … 1 = top of the screen.
    @Published var verticalPosition: Double { didSet { store(verticalPosition, "verticalPosition") } }
    @Published var ringSize: RingSize { didSet { store(ringSize.rawValue, "ringSize") } }
    @Published var metric: RingMetric { didSet { store(metric.rawValue, "metric") } }
    @Published var colorStyle: ColorStyle { didSet { store(colorStyle.rawValue, "colorStyle") } }
    @Published var showLabels: Bool { didSet { store(showLabels, "showLabels") } }
    @Published var showCenterText: Bool { didSet { store(showCenterText, "showCenterText") } }
    @Published var opacity: Double { didSet { store(opacity, "opacity") } }
    @Published var isCollapsed: Bool { didSet { store(isCollapsed, "isCollapsed") } }
    @Published var hiddenProviders: [String] { didSet { store(hiddenProviders, "hiddenProviders") } }
    @Published var refreshMinutes: Double { didSet { store(refreshMinutes, "refreshMinutes") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .side
        side = DockSide(rawValue: defaults.string(forKey: "side") ?? "") ?? .left
        verticalPosition = defaults.object(forKey: "verticalPosition") as? Double ?? 0.5
        ringSize = RingSize(rawValue: defaults.string(forKey: "ringSize") ?? "") ?? .medium
        metric = RingMetric(rawValue: defaults.string(forKey: "metric") ?? "") ?? .used
        colorStyle = ColorStyle(rawValue: defaults.string(forKey: "colorStyle") ?? "") ?? .traffic
        showLabels = defaults.object(forKey: "showLabels") as? Bool ?? true
        showCenterText = defaults.object(forKey: "showCenterText") as? Bool ?? true
        opacity = defaults.object(forKey: "opacity") as? Double ?? 1
        isCollapsed = defaults.bool(forKey: "isCollapsed")
        hiddenProviders = defaults.stringArray(forKey: "hiddenProviders") ?? []
        refreshMinutes = defaults.object(forKey: "refreshMinutes") as? Double ?? 2.5
    }

    var refreshInterval: Duration {
        .milliseconds(Int(max(1, refreshMinutes) * 60_000))
    }

    func isVisible(_ provider: ProviderUsage) -> Bool {
        !hiddenProviders.contains(provider.providerID)
    }

    func setVisible(_ visible: Bool, providerID: String) {
        if visible {
            hiddenProviders.removeAll { $0 == providerID }
        } else if !hiddenProviders.contains(providerID) {
            hiddenProviders.append(providerID)
        }
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Ring colors and the number shown for a window, given the user's choices.
struct RingAppearance {
    let size: RingSize
    let metric: RingMetric
    let colorStyle: ColorStyle
    let showCenterText: Bool

    @MainActor
    init(_ settings: RingsSettings, size: RingSize? = nil) {
        self.size = size ?? settings.ringSize
        metric = settings.metric
        colorStyle = settings.colorStyle
        showCenterText = settings.showCenterText
    }

    init(size: RingSize, metric: RingMetric, colorStyle: ColorStyle, showCenterText: Bool) {
        self.size = size
        self.metric = metric
        self.colorStyle = colorStyle
        self.showCenterText = showCenterText
    }

    func fraction(_ window: UsageWindow) -> Double {
        let used = window.usedPercent / 100
        return metric == .used ? used : 1 - used
    }

    func value(_ window: UsageWindow) -> Int {
        Int((metric == .used ? window.usedPercent : 100 - window.usedPercent).rounded())
    }

    func color(_ window: UsageWindow, providerID: String) -> Color {
        colorStyle == .brand ? BrandPalette.color(for: providerID) : Severity.color(window.usedPercent)
    }

    /// Text tint for numbers: brand mode still flags a limit that's nearly out.
    func valueColor(_ window: UsageWindow, providerID: String) -> Color {
        if colorStyle == .brand, window.usedPercent < 90 {
            return .white.opacity(0.92)
        }
        return Severity.color(window.usedPercent)
    }
}

enum Severity {
    static func color(_ usedPercent: Double) -> Color {
        switch usedPercent {
        case 90...: Color(red: 1.0, green: 0.36, blue: 0.36)
        case 70..<90: Color(red: 1.0, green: 0.66, blue: 0.24)
        default: Color(red: 0.30, green: 0.88, blue: 0.52)
        }
    }
}

enum BrandPalette {
    static func color(for providerID: String) -> Color {
        switch providerID {
        case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex", "openai": Color(red: 0.86, green: 0.88, blue: 0.92)
        case "opencode", "opencodego": Color(red: 0.96, green: 0.62, blue: 0.04)
        case "kimi", "moonshot": Color(red: 0.31, green: 0.48, blue: 1.0)
        case "cursor": Color(red: 0.65, green: 0.55, blue: 0.98)
        case "gemini", "antigravity": Color(red: 0.26, green: 0.52, blue: 0.96)
        case "copilot": Color(red: 0.55, green: 0.36, blue: 0.96)
        case "deepseek": Color(red: 0.30, green: 0.42, blue: 1.0)
        case "zai": Color(red: 0.13, green: 0.83, blue: 0.93)
        case "minimax": Color(red: 0.96, green: 0.25, blue: 0.37)
        case "doubao": Color(red: 0.15, green: 0.39, blue: 0.92)
        default: Color(red: 0.61, green: 0.64, blue: 0.69)
        }
    }
}
