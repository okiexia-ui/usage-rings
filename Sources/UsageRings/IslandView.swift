#if canImport(AppKit)
import AppKit
import SwiftUI

extension NotchGeometry {
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
            rightSpace: store.islandRightSpace,
            maxWidth: store.islandMaxWidth
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
            Button(tr("立即刷新", "Refresh Now")) { actions.refresh() }
            Button(tr("设置…", "Settings…")) { actions.openSettings() }
            Divider()
            Button(tr("退出用量圈", "Quit Usage Rings")) { actions.quit() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(settings.opacity)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isExpanded)
        .accessibilityElement(children: isExpanded ? .contain : .ignore)
        .accessibilityLabel(isExpanded ? "" : tr("用量圈：", "Usage Rings: ")
            + providers.map { UsageSpeech.summary($0, appearance: miniAppearance) }.joined(separator: tr("。", ". ")))
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

    /// Providers in rows of `columnsPerRow`, so a long list wraps instead of
    /// running off a narrow screen.
    private var rows: [[ProviderUsage]] {
        let perRow = layout.columnsPerRow
        return stride(from: 0, to: providers.count, by: perRow).map {
            Array(providers[$0..<min($0 + perRow, providers.count)])
        }
    }

    private var expandedContent: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 8) {
                VStack(spacing: IslandLayout.rowGap) {
                    ForEach(rows, id: \.first?.id) { row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(row) { provider in
                                column(provider, now: context.date)
                                    .frame(width: IslandLayout.columnWidth)
                            }
                        }
                    }
                }
                if let pick = Recommendation.pick(providers) {
                    let left = 100 - Int((pick.peak?.usedPercent ?? 0).rounded())
                    HStack(spacing: 4) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.35))
                        Text(tr("下一个任务建议用 \(pick.name) · 还剩 \(left)%", "Next task: try \(pick.name) · \(left)% left"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(height: 16)
                    .accessibilityElement(children: .combine)
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

            Text(provider.isStale ? tr("\(provider.shortName) · 旧", "\(provider.shortName) · old") : provider.shortName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(provider.isStale ? 0.5 : 0.85))
                .lineLimit(1)
                .help(provider.error ?? "")

            if provider.windows.isEmpty {
                Text(tr("读取失败", "Unavailable"))
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
                        .lineLimit(1)
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
                    Text(tr("⛔ 已用完", "⛔ Used up"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Severity.color(100))
                        .lineLimit(1)
                        .frame(height: 13)
                } else if !provider.isStale,
                   let runsOut = provider.windows.compactMap({ Pace.of($0, now: now)?.runsOutIn }).min() {
                    Text(tr("⚡ \(DetailCard.duration(runsOut))后用完", "⚡ out in \(DetailCard.duration(runsOut))"))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Severity.color(95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(height: 13)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageSpeech.summary(provider, appearance: appearance, now: now))
    }
}
#endif
