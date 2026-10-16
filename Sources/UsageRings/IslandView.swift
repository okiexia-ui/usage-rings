import AppKit
import SwiftUI

/// Size and position of the camera housing on notched MacBooks; on other
/// displays the island hangs from the middle of the menu bar.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// Left edge of the notch, measured from the screen's left edge.
    var minX: CGFloat = 0

    var maxX: CGFloat { minX + width }

    @MainActor
    static func of(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let minX = left.maxX - screen.frame.minX
            return NotchGeometry(width: max(0, right.minX - left.maxX), height: top, minX: minX)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(width: 0, height: max(24, menuBar), minX: screen.frame.width / 2)
    }
}

/// Room in the menu bar between the notch and the first status item to its
/// right. Status items are ordinary windows at the status-bar level, so their
/// frames are readable without any permission.
enum MenuBarSpace {
    @MainActor
    static func freeWidthRightOfNotch(on screen: NSScreen, notch: NotchGeometry) -> CGFloat? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenTop = primaryHeight - screen.frame.maxY   // CG coordinates start top-left
        let notchRight = screen.frame.minX + notch.maxX

        var leftmost: CGFloat?
        for window in list {
            guard window[kCGWindowLayer as String] as? Int == statusLevel,
                  (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  abs(rect.minY - screenTop) <= 1, rect.height <= 44,
                  rect.minX >= notchRight - 1, rect.maxX <= screen.frame.maxX + 1 else { continue }
            leftmost = min(leftmost ?? rect.minX, rect.minX)
        }
        return leftmost.map { max(0, $0 - notchRight - 4) }
    }
}

struct IslandLayout {
    let notch: NotchGeometry
    let rowCount: Int
    let maxWindows: Int
    /// Free menu-bar width right of the notch; nil = unconstrained.
    var rightSpace: CGFloat?

    static let miniSpacing: CGFloat = 7
    static let outerPadding: CGFloat = 9
    static let notchGap: CGFloat = 9
    static let emptyWing: CGFloat = 14
    static let columnWidth: CGFloat = 90
    static let expandedRing: CGFloat = 46
    /// A lone provider puts its name and number in the right wing instead
    /// of leaving it empty.
    static let soloLabelWidth: CGFloat = 78

    private var count: Int { max(1, rowCount) }

    /// Collapsed rings fill the notch's height; many providers shrink a bit
    /// so the pill doesn't sprawl across the menu bar.
    var miniRing: CGFloat {
        let full = max(18, notch.height - 6)
        return count > 6 ? max(18, full - 4) : full
    }

    func ringsWidth(_ rings: Int) -> CGFloat {
        guard rings > 0 else { return Self.emptyWing }
        let n = CGFloat(rings)
        return Self.outerPadding + n * miniRing + (n - 1) * Self.miniSpacing + Self.notchGap
    }

    private var symmetricWing: CGFloat {
        let wing = ringsWidth((count + 1) / 2)
        return rowCount == 1 ? max(wing, Self.soloLabelWidth) : wing
    }

    /// Symmetric when the menu bar has room; otherwise the right wing keeps
    /// only what fits beside the status items and the rest moves left.
    var isSymmetric: Bool { symmetricWing <= (rightSpace ?? .infinity) }

    var rightCount: Int {
        if isSymmetric { return count - (count + 1) / 2 }
        var fit = 0
        while fit < count, ringsWidth(fit + 1) <= (rightSpace ?? 0) { fit += 1 }
        return min(fit, count - (count + 1) / 2)
    }

    var leftCount: Int { count - rightCount }
    var showsSoloLabel: Bool { rowCount == 1 && isSymmetric }

    var leftWing: CGFloat { isSymmetric ? symmetricWing : ringsWidth(leftCount) }
    var rightWing: CGFloat {
        if isSymmetric { return symmetricWing }
        return min(ringsWidth(rightCount), max(Self.emptyWing, rightSpace ?? 0))
    }

    var collapsedSize: CGSize {
        CGSize(width: leftWing + notch.width + rightWing, height: notch.height)
    }

    var expandedSize: CGSize {
        let lines = CGFloat(min(max(maxWindows, 1), 3))
        let column = Self.expandedRing + 5 + 15 + 4 + lines * 14 + 3 + 13 + 13
        return CGSize(
            width: max(collapsedSize.width, CGFloat(count) * Self.columnWidth + 36),
            height: notch.height + 10 + column + 10 + 18 + 14
        )
    }
}

struct IslandView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: RingsSettings
    let notch: NotchGeometry
    let actions: RingsActions

    private var providers: [ProviderUsage] { store.providers.filter(settings.isVisible) }
    private var isExpanded: Bool { store.isIslandHovered }

    private var layout: IslandLayout {
        IslandLayout(
            notch: notch,
            rowCount: providers.count,
            maxWindows: providers.map(\.windows.count).max() ?? 1,
            rightSpace: store.islandRightSpace
        )
    }

    var body: some View {
        let size = isExpanded ? layout.expandedSize : layout.collapsedSize
        let radius = isExpanded ? 22 : notch.height * 0.42

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                bottomLeadingRadius: radius,
                bottomTrailingRadius: radius,
                style: .continuous
            )
            .fill(Color.black)

            if isExpanded {
                expandedContent
                    .padding(.top, notch.height + 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                collapsedContent
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .contextMenu {
            Button("立即刷新") { actions.refresh() }
            Button("设置…") { actions.openSettings() }
            Divider()
            Button("退出用量圈") { actions.quit() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(settings.opacity)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isExpanded)
    }

    private var miniAppearance: RingAppearance {
        RingAppearance(size: .small, metric: settings.metric, colorStyle: settings.colorStyle, showCenterText: settings.showCenterText)
    }

    private var collapsedContent: some View {
        let left = Array(providers.prefix(layout.leftCount))
        let right = Array(providers.dropFirst(layout.leftCount))

        return HStack(spacing: 0) {
            wing(left, width: layout.leftWing)
            Color.clear.frame(width: notch.width)
            if layout.showsSoloLabel, let solo = left.first {
                soloLabel(solo)
            } else {
                wing(right, width: layout.rightWing)
            }
        }
        .frame(height: notch.height)
    }

    private func wing(_ items: [ProviderUsage], width: CGFloat) -> some View {
        HStack(spacing: IslandLayout.miniSpacing) {
            ForEach(items) { provider in
                UsageRing(provider: provider, appearance: miniAppearance, diameter: layout.miniRing, compact: true)
                    .frame(width: layout.miniRing, height: layout.miniRing)
            }
        }
        .frame(width: width)
    }

    private func soloLabel(_ provider: ProviderUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(provider.shortName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            if let peak = provider.peak {
                let appearance = RingAppearance(settings, size: .small)
                Text("\(appearance.value(peak))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(appearance.valueColor(peak, providerID: provider.providerID))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: layout.rightWing)
    }

    private var expandedContent: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(providers) { provider in
                        column(provider, now: context.date)
                            .frame(width: IslandLayout.columnWidth)
                    }
                }
                if let pick = Recommendation.pick(providers) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.35))
                        Text("下一个任务建议用 \(pick.name) · 还剩 \(100 - Int((pick.peak?.usedPercent ?? 0).rounded()))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(height: 16)
                }
            }
        }
    }

    private func column(_ provider: ProviderUsage, now: Date) -> some View {
        let appearance = RingAppearance(settings, size: .medium)

        return VStack(spacing: 4) {
            UsageRing(provider: provider, appearance: appearance, diameter: IslandLayout.expandedRing)
                .frame(width: IslandLayout.expandedRing, height: IslandLayout.expandedRing)
                .padding(.bottom, 1)

            Text(provider.isStale ? "\(provider.shortName) · 旧" : provider.shortName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(provider.isStale ? 0.5 : 0.85))
                .lineLimit(1)
                .help(provider.error ?? "")

            if provider.windows.isEmpty {
                Text("读取失败")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .help(provider.error ?? "")
            } else {
                VStack(spacing: 1) {
                    ForEach(provider.windows.prefix(3)) { window in
                        HStack(spacing: 3) {
                            Text(window.label)
                                .foregroundStyle(.white.opacity(0.42))
                            Text("\(appearance.value(window))%")
                                .fontWeight(.bold)
                                .foregroundStyle(appearance.valueColor(window, providerID: provider.providerID))
                        }
                        .font(.system(size: 10.5, design: .rounded))
                        .monospacedDigit()
                        .frame(height: 13)
                    }
                }
                if let reset = provider.peak?.resetsAt {
                    Text("↻ " + DetailCard.countdown(until: reset, from: now))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                if !provider.isStale, provider.windows.contains(where: { $0.usedPercent >= 99.5 }) {
                    Text("⛔ 已用完")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Severity.color(100))
                        .lineLimit(1)
                        .frame(height: 13)
                } else if !provider.isStale,
                   let runsOut = provider.windows.compactMap({ Pace.of($0, now: now)?.runsOutIn }).min() {
                    Text("⚡ \(DetailCard.duration(runsOut))后用完")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Severity.color(95))
                        .lineLimit(1)
                        .frame(height: 13)
                }
            }
        }
    }
}
