import AppKit
import SwiftUI

/// Fixed metrics so the panel can be sized before SwiftUI lays out.
enum RingsLayout {
    static let ringSize: CGFloat = 60
    static let lineWidth: CGFloat = 4.5
    static let ringGap: CGFloat = 1.5
    static let labelHeight: CGFloat = 14
    static let rowSpacing: CGFloat = 12
    static let columnPadding: CGFloat = 12
    static let columnWidth: CGFloat = ringSize + columnPadding * 2
    static let cardGap: CGFloat = 8
    static let cardWidth: CGFloat = 250
    static let screenInset: CGFloat = 6

    static var rowHeight: CGFloat { ringSize + 4 + labelHeight }

    static func columnHeight(rowCount: Int) -> CGFloat {
        let rows = CGFloat(max(1, rowCount))
        return columnPadding * 2 + rows * rowHeight + (rows - 1) * rowSpacing
    }

    static func panelSize(rowCount: Int, expanded: Bool) -> CGSize {
        CGSize(
            width: columnWidth + (expanded ? cardGap + cardWidth : 0),
            height: columnHeight(rowCount: rowCount)
        )
    }
}

enum Severity {
    static func color(_ usedPercent: Double) -> Color {
        switch usedPercent {
        case 90...: Color(red: 1.0, green: 0.33, blue: 0.33)
        case 70..<90: Color(red: 1.0, green: 0.62, blue: 0.2)
        default: Color(red: 0.25, green: 0.86, blue: 0.48)
        }
    }
}

struct RingsRootView: View {
    @ObservedObject var store: UsageStore
    let onRefresh: () -> Void
    let onToggleLaunchAtLogin: () -> Void
    let isLaunchAtLoginEnabled: () -> Bool
    let onOpenCodexBar: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: RingsLayout.cardGap) {
            column
            if let provider = store.providers.first(where: { $0.id == store.expandedID }) {
                DetailCard(
                    provider: provider,
                    lastUpdated: store.lastUpdated,
                    lastError: store.lastError,
                    isPinned: store.pinnedID == provider.id
                )
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onHover { inside in
            if !inside { store.hoveredID = nil }
        }
        .animation(.easeOut(duration: 0.15), value: store.expandedID)
    }

    private var column: some View {
        VStack(spacing: RingsLayout.rowSpacing) {
            if store.providers.isEmpty {
                placeholderRow
            } else {
                ForEach(store.providers) { provider in
                    ringRow(provider)
                }
            }
        }
        .padding(RingsLayout.columnPadding)
        .frame(width: RingsLayout.columnWidth)
        .background(PanelBackground(cornerRadius: 22))
        .contextMenu {
            Button("立即刷新") { onRefresh() }
            Button(isLaunchAtLoginEnabled() ? "✓ 开机启动" : "开机启动") { onToggleLaunchAtLogin() }
            Button("打开 CodexBar") { onOpenCodexBar() }
            Divider()
            Button("退出用量圈") { onQuit() }
        }
    }

    private func ringRow(_ provider: ProviderUsage) -> some View {
        VStack(spacing: 4) {
            UsageRing(provider: provider)
                .frame(width: RingsLayout.ringSize, height: RingsLayout.ringSize)
            Text(provider.shortName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(store.expandedID == provider.id ? 0.95 : 0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: RingsLayout.labelHeight)
        }
        .frame(height: RingsLayout.rowHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { store.hoveredID = provider.id }
        }
        .onTapGesture {
            store.pinnedID = store.pinnedID == provider.id ? nil : provider.id
        }
    }

    private var placeholderRow: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: RingsLayout.lineWidth, dash: [3, 4]))
                    .padding(RingsLayout.lineWidth / 2)
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: RingsLayout.ringSize, height: RingsLayout.ringSize)
            .help(store.lastError ?? "正在读取 CodexBar…")
            Text(store.isLoading ? "读取中" : "无数据")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(height: RingsLayout.labelHeight)
        }
        .frame(height: RingsLayout.rowHeight)
    }
}

/// Concentric rings, one per quota window, outermost = longest window.
struct UsageRing: View {
    let provider: ProviderUsage

    private var windows: [UsageWindow] { Array(provider.windows.prefix(3)) }

    var body: some View {
        ZStack {
            if windows.isEmpty {
                Circle()
                    .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: RingsLayout.lineWidth, dash: [3, 4]))
                    .padding(RingsLayout.lineWidth / 2)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    ring(window, inset: CGFloat(index) * (RingsLayout.lineWidth + RingsLayout.ringGap))
                }
                if let peak = provider.peak {
                    Text("\(Int(peak.usedPercent.rounded()))%")
                        .font(.system(size: windows.count >= 3 ? 10 : 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.92))
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .padding(.horizontal, CGFloat(windows.count) * (RingsLayout.lineWidth + RingsLayout.ringGap) + 2)
                }
            }
        }
    }

    private func ring(_ window: UsageWindow, inset: CGFloat) -> some View {
        let half = RingsLayout.lineWidth / 2
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.1), lineWidth: RingsLayout.lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, window.usedPercent / 100))
                .stroke(
                    Severity.color(window.usedPercent),
                    style: StrokeStyle(lineWidth: RingsLayout.lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: window.usedPercent)
        }
        .padding(inset + half)
    }
}

struct DetailCard: View {
    let provider: ProviderUsage
    let lastUpdated: Date?
    let lastError: String?
    let isPinned: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 4)
                    if let account = provider.account {
                        Text(account)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let error = provider.error, provider.windows.isEmpty {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(provider.windows) { window in
                    windowRow(window, now: context.date)
                }

                footer(now: context.date)
            }
            .padding(12)
            .frame(width: RingsLayout.cardWidth, alignment: .leading)
            .background(PanelBackground(cornerRadius: 16))
        }
    }

    private func windowRow(_ window: UsageWindow, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 22, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(Severity.color(window.usedPercent))
                        .frame(width: geometry.size.width * window.usedPercent / 100)
                }
            }
            .frame(height: 5)

            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Severity.color(window.usedPercent))
                .frame(width: 36, alignment: .trailing)

            Text(window.resetsAt.map { Self.countdown(until: $0, from: now) } ?? "")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 62, alignment: .trailing)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func footer(now: Date) -> some View {
        if let lastError {
            Text(lastError)
                .font(.system(size: 9.5))
                .foregroundStyle(.orange.opacity(0.7))
                .lineLimit(2)
        } else if let lastUpdated {
            Text("更新于 \(Self.relative(lastUpdated, now: now)) · 右键可刷新")
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.32))
        }
    }

    static func countdown(until date: Date, from now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "即将重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)天\(hours)时后" : "\(days)天后" }
        if hours > 0 { return "\(hours)时\(minutes)分后" }
        return "\(max(1, minutes))分钟后"
    }

    static func relative(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3_600) 小时前"
    }
}

extension EnvironmentValues {
    /// ImageRenderer can't draw AppKit views, so snapshots swap the blur for
    /// a flat fill.
    @Entry var isRenderingSnapshot = false
}

struct PanelBackground: View {
    let cornerRadius: CGFloat
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    var body: some View {
        if isRenderingSnapshot {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(white: 0.12).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
        } else {
            BlurBackground(cornerRadius: cornerRadius)
        }
    }
}

/// Dark behind-window blur so the rings stay legible over any wallpaper.
private struct BlurBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}
