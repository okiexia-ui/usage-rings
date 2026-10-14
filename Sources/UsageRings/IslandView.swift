import AppKit
import SwiftUI

/// Size of the camera housing on notched MacBooks; on other displays the
/// island hangs from the middle of the menu bar.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat

    @MainActor
    static func of(_ screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(width: max(0, screen.frame.width - left.width - right.width), height: top)
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(width: 0, height: max(24, menuBar))
    }
}

struct IslandLayout {
    let notch: NotchGeometry
    let rowCount: Int
    let maxWindows: Int

    static let miniRing: CGFloat = 16
    static let miniSpacing: CGFloat = 5
    static let outerPadding: CGFloat = 12
    static let notchGap: CGFloat = 8
    static let columnWidth: CGFloat = 78
    static let expandedRing: CGFloat = 40

    private var count: Int { max(1, rowCount) }
    var leftCount: Int { (count + 1) / 2 }
    var rightCount: Int { count - leftCount }

    var wingWidth: CGFloat {
        let rings = CGFloat(leftCount)
        return Self.outerPadding + rings * Self.miniRing + (rings - 1) * Self.miniSpacing + Self.notchGap
    }

    var collapsedSize: CGSize {
        CGSize(width: notch.width + wingWidth * 2, height: notch.height)
    }

    var expandedSize: CGSize {
        let lines = CGFloat(min(max(maxWindows, 1), 3))
        return CGSize(
            width: max(collapsedSize.width, CGFloat(count) * Self.columnWidth + 32),
            height: notch.height + 8 + Self.expandedRing + 5 + 13 + 4 + lines * 13 + 3 + 12 + 12 + 8 + 16 + 12
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
            maxWindows: providers.map(\.windows.count).max() ?? 1
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
        RingAppearance(size: .small, metric: settings.metric, colorStyle: settings.colorStyle, showCenterText: false)
    }

    private var collapsedContent: some View {
        let left = Array(providers.prefix(layout.leftCount))
        let right = Array(providers.dropFirst(layout.leftCount))

        return HStack(spacing: 0) {
            wing(left)
            Color.clear.frame(width: notch.width)
            wing(right)
        }
        .frame(height: notch.height)
    }

    private func wing(_ items: [ProviderUsage]) -> some View {
        HStack(spacing: IslandLayout.miniSpacing) {
            ForEach(items) { provider in
                UsageRing(provider: provider, appearance: miniAppearance, diameter: IslandLayout.miniRing)
                    .frame(width: IslandLayout.miniRing, height: IslandLayout.miniRing)
            }
        }
        .frame(width: layout.wingWidth)
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
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.35))
                        Text("下一个任务建议用 \(pick.name) · 还剩 \(100 - Int((pick.peak?.usedPercent ?? 0).rounded()))%")
                            .font(.system(size: 10, weight: .medium))
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
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(provider.isStale ? 0.5 : 0.85))
                .lineLimit(1)
                .help(provider.error ?? "")

            if provider.windows.isEmpty {
                Text("读取失败")
                    .font(.system(size: 9))
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
                        .font(.system(size: 9.5, design: .rounded))
                        .monospacedDigit()
                        .frame(height: 12)
                    }
                }
                if let reset = provider.peak?.resetsAt {
                    Text("↻ " + DetailCard.countdown(until: reset, from: now))
                        .font(.system(size: 8.5))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                if !provider.isStale,
                   let runsOut = provider.windows.compactMap({ Pace.of($0, now: now)?.runsOutIn }).min() {
                    Text("⚡ \(DetailCard.duration(runsOut))后用完")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Severity.color(95))
                        .lineLimit(1)
                        .frame(height: 12)
                }
            }
        }
    }
}
