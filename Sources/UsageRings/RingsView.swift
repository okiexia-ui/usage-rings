import AppKit
import SwiftUI

/// Callbacks from the views into the app delegate (window moves, menus).
struct RingsActions {
    var refresh: () -> Void = {}
    var openSettings: () -> Void = {}
    var setCollapsed: (Bool) -> Void = { _ in }
    var setSide: (DockSide) -> Void = { _ in }
    var dragChanged: () -> Void = {}
    var dragEnded: () -> Void = {}
    var quit: () -> Void = {}
}

/// Fixed metrics for the side column so the panel can be sized before
/// SwiftUI lays out.
struct SideLayout {
    let size: RingSize
    let showLabels: Bool
    let rowCount: Int

    var ringDiameter: CGFloat { size.diameter }
    var labelHeight: CGFloat { showLabels ? 11 : 0 }
    var labelSpacing: CGFloat { showLabels ? 3 : 0 }
    var rowHeight: CGFloat { ringDiameter + labelSpacing + labelHeight }
    var rowSpacing: CGFloat { size == .small ? 7 : 9 }
    var horizontalPadding: CGFloat { 7 }
    var verticalPadding: CGFloat { 7 }
    var handleHeight: CGFloat { 10 }
    var handleSpacing: CGFloat { 5 }

    var columnWidth: CGFloat { max(ringDiameter, 30) + horizontalPadding * 2 }

    var columnHeight: CGFloat {
        let rows = CGFloat(max(1, rowCount))
        return verticalPadding * 2 + handleHeight + handleSpacing
            + rows * rowHeight + (rows - 1) * rowSpacing
    }

    static let tabWidth: CGFloat = 14
    static func tabHeight(rowCount: Int) -> CGFloat { 16 + CGFloat(max(1, rowCount)) * 10 }

    static let cardGap: CGFloat = 6
    static let cardWidth: CGFloat = 232
    static let screenInset: CGFloat = 5

    /// `cardHeight` is the open detail card's estimated height, nil when
    /// no card is showing.
    func panelSize(collapsed: Bool, cardHeight: CGFloat?) -> CGSize {
        if collapsed {
            return CGSize(width: Self.tabWidth, height: Self.tabHeight(rowCount: rowCount))
        }
        guard let cardHeight else {
            return CGSize(width: columnWidth, height: columnHeight)
        }
        return CGSize(
            width: columnWidth + Self.cardGap + Self.cardWidth,
            height: max(columnHeight, cardHeight)
        )
    }
}

// MARK: - Side column

struct SideRingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: RingsSettings
    let actions: RingsActions

    private var providers: [ProviderUsage] { store.providers.filter(settings.isVisible) }

    private var layout: SideLayout {
        SideLayout(size: settings.ringSize, showLabels: settings.showLabels, rowCount: providers.count)
    }

    private var expandedProvider: ProviderUsage? {
        guard !settings.isCollapsed else { return nil }
        return providers.first { $0.id == store.expandedID }
    }

    private var recommendation: ProviderUsage? { Recommendation.pick(providers) }

    var body: some View {
        HStack(alignment: .center, spacing: SideLayout.cardGap) {
            if settings.side == .right, let provider = expandedProvider {
                card(provider)
            }

            Group {
                if settings.isCollapsed {
                    collapsedTab
                } else {
                    column
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in actions.dragChanged() }
                    .onEnded { _ in actions.dragEnded() }
            )
            .contextMenu { menu }

            if settings.side == .left, let provider = expandedProvider {
                card(provider)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: settings.side == .left ? .leading : .trailing
        )
        .opacity(settings.opacity)
        .animation(.easeOut(duration: 0.14), value: store.expandedID)
    }

    private func card(_ provider: ProviderUsage) -> some View {
        DetailCard(
            provider: provider,
            appearance: RingAppearance(settings),
            lastUpdated: store.lastUpdated,
            lastError: store.lastError,
            isPinned: store.pinnedID == provider.id,
            recommendation: recommendation
        )
        .transition(.opacity)
    }

    private var column: some View {
        VStack(spacing: 0) {
            Button {
                actions.setCollapsed(true)
            } label: {
                Image(systemName: settings.side == .left ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: layout.handleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("收起")
            .padding(.bottom, layout.handleSpacing)

            VStack(spacing: layout.rowSpacing) {
                if providers.isEmpty {
                    placeholderRow
                } else {
                    ForEach(providers) { provider in
                        ringRow(provider)
                    }
                }
            }
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, layout.verticalPadding)
        .frame(width: layout.columnWidth, height: layout.columnHeight)
        .background(PanelBackground(cornerRadius: min(18, layout.columnWidth / 2)))
    }

    private func ringRow(_ provider: ProviderUsage) -> some View {
        let isActive = store.expandedID == provider.id

        return VStack(spacing: layout.labelSpacing) {
            UsageRing(provider: provider, appearance: RingAppearance(settings))
                .frame(width: layout.ringDiameter, height: layout.ringDiameter)
                .overlay(alignment: .topTrailing) {
                    if recommendation?.id == provider.id {
                        Image(systemName: "sparkle")
                            .font(.system(size: max(7, layout.ringDiameter * 0.2), weight: .bold))
                            .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.35))
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .offset(x: 3, y: -3)
                            .help("下一个任务建议用它")
                    }
                }
                .scaleEffect(isActive ? 1.06 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isActive)

            if settings.showLabels {
                Text(provider.shortName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(isActive ? 0.9 : 0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: layout.columnWidth - 4, height: layout.labelHeight)
            }
        }
        .frame(height: layout.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            store.pinnedID = store.pinnedID == provider.id ? nil : provider.id
        }
    }

    private var placeholderRow: some View {
        VStack(spacing: layout.labelSpacing) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: settings.ringSize.lineWidth, dash: [2.5, 3.5]))
                    .padding(settings.ringSize.lineWidth / 2)
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: layout.ringDiameter, height: layout.ringDiameter)
            .help(store.lastError ?? "正在读取 CodexBar…")

            if settings.showLabels {
                Text(store.isLoading ? "读取中" : "无数据")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(height: layout.labelHeight)
            }
        }
        .frame(height: layout.rowHeight)
    }

    /// Collapsed: a slim tab hugging the screen edge, one dot per provider.
    private var collapsedTab: some View {
        VStack(spacing: 4) {
            ForEach(providers.isEmpty ? [] : providers) { provider in
                Circle()
                    .fill(dotColor(provider))
                    .frame(width: 6, height: 6)
            }
            if providers.isEmpty {
                Circle().fill(.white.opacity(0.3)).frame(width: 6, height: 6)
            }
        }
        .frame(width: SideLayout.tabWidth, height: SideLayout.tabHeight(rowCount: providers.count))
        .background(PanelBackground(cornerRadius: SideLayout.tabWidth / 2))
        .contentShape(Rectangle())
        .onTapGesture { actions.setCollapsed(false) }
        .help("展开用量圈")
    }

    private func dotColor(_ provider: ProviderUsage) -> Color {
        guard let peak = provider.peak else { return .white.opacity(0.3) }
        return RingAppearance(settings).color(peak, providerID: provider.providerID)
    }

    @ViewBuilder
    private var menu: some View {
        Button("立即刷新") { actions.refresh() }
        Button(settings.isCollapsed ? "展开" : "收起") { actions.setCollapsed(!settings.isCollapsed) }
        Button(settings.side == .left ? "停靠到右边" : "停靠到左边") {
            actions.setSide(settings.side == .left ? .right : .left)
        }
        Divider()
        Button("设置…") { actions.openSettings() }
        Button("退出用量圈") { actions.quit() }
    }
}

// MARK: - Ring

/// Concentric rings, one per quota window, outermost = longest window.
struct UsageRing: View {
    let provider: ProviderUsage
    let appearance: RingAppearance
    var diameter: CGFloat?
    /// Tiny rings (the collapsed island): thinner stroke, number without "%".
    var compact = false

    private var size: CGFloat { diameter ?? appearance.size.diameter }
    private var lineWidth: CGFloat { compact ? 2.5 : appearance.size.lineWidth }
    private let ringGap: CGFloat = 1.5

    /// With fewer rings than windows, keep the longest window plus the
    /// tightest of the rest so the most urgent limit is always drawn.
    private var windows: [UsageWindow] {
        let all = provider.windows
        let limit = appearance.size.maxRings
        guard all.count > limit else { return all }
        if limit == 1 { return provider.peak.map { [$0] } ?? [] }
        let outer = all[0]
        let rest = all.dropFirst().sorted { $0.usedPercent > $1.usedPercent }
        return [outer] + rest.prefix(limit - 1).sorted { $0.spanRank > $1.spanRank }
    }

    var body: some View {
        ZStack {
            if windows.isEmpty {
                Circle()
                    .stroke(.white.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, dash: [2.5, 3.5]))
                    .padding(lineWidth / 2)
                Image(systemName: "exclamationmark")
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    ring(window, inset: CGFloat(index) * (lineWidth + ringGap))
                }
                if appearance.showCenterText, let peak = provider.peak {
                    centerText(peak)
                }
            }
        }
        .frame(width: size, height: size)
        .opacity(provider.isStale ? 0.45 : 1)
        .saturation(provider.isStale ? 0.3 : 1)
    }

    private func centerText(_ peak: UsageWindow) -> some View {
        let inner = size - 2 * CGFloat(windows.count) * (lineWidth + ringGap)
        let fontSize = compact ? min(max(inner * 0.58, 8), 12) : min(max(inner * 0.46, 7.5), 13)

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(appearance.value(peak))")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
            if !compact {
                Text("%")
                    .font(.system(size: fontSize * 0.62, weight: .semibold, design: .rounded))
                    .opacity(0.6)
            }
        }
        .monospacedDigit()
        .foregroundStyle(appearance.valueColor(peak, providerID: provider.providerID))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: max(inner - 2, 8))
    }

    private func ring(_ window: UsageWindow, inset: CGFloat) -> some View {
        let color = appearance.color(window, providerID: provider.providerID)
        let fraction = min(max(appearance.fraction(window), 0.002), 1)

        return ZStack {
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(0.55), color],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * fraction)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 1.6)
                .animation(.easeOut(duration: 0.6), value: fraction)
        }
        .padding(inset + lineWidth / 2)
    }
}

// MARK: - Detail card

struct DetailCard: View {
    let provider: ProviderUsage
    let appearance: RingAppearance
    let lastUpdated: Date?
    let lastError: String?
    let isPinned: Bool
    var recommendation: ProviderUsage?

    private static let spacing: CGFloat = 6
    private static let maxShareRows = 3

    /// Mirrors the layout below so the panel can be sized before SwiftUI
    /// lays the card out.
    static func estimatedHeight(for provider: ProviderUsage, hasRecommendation: Bool) -> CGFloat {
        var height: CGFloat = 22 + 16
        if provider.error != nil, provider.windows.isEmpty || provider.isStale {
            height += spacing + 30
        }
        height += CGFloat(provider.windows.count) * (spacing + 16 + 13)
        let shareRows = min(provider.sessionShares.count, maxShareRows)
            + (provider.sessionShares.count > maxShareRows ? 1 : 0)
        if shareRows > 0 {
            height += spacing + 16 + CGFloat(shareRows) * 15
        }
        if hasRecommendation, !provider.windows.isEmpty {
            height += spacing + 14
        }
        return height + spacing + 13 + 8
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: Self.spacing) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Circle()
                        .fill(BrandPalette.color(for: provider.providerID))
                        .frame(width: 6, height: 6)
                    Text(provider.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer(minLength: 4)
                    if let account = provider.account {
                        Text(account)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.38))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let error = provider.error, provider.windows.isEmpty || provider.isStale {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.85))
                        Text(staleText(error, now: context.date))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ForEach(provider.windows) { window in
                    VStack(alignment: .leading, spacing: 2) {
                        windowRow(window, now: context.date)
                        paceLine(window, now: context.date)
                    }
                }

                if !provider.sessionShares.isEmpty {
                    sessionsSection
                }

                recommendationLine

                footer(now: context.date)
            }
            .padding(11)
            .frame(width: SideLayout.cardWidth, alignment: .leading)
            .background(PanelBackground(cornerRadius: 14))
        }
    }

    private func windowRow(_ window: UsageWindow, now: Date) -> some View {
        HStack(spacing: 7) {
            Text(window.label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.48))
                .frame(width: 20, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09))
                    Capsule()
                        .fill(appearance.color(window, providerID: provider.providerID))
                        .frame(width: geometry.size.width * appearance.fraction(window))
                }
            }
            .frame(height: 4)

            Text("\(appearance.value(window))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(appearance.valueColor(window, providerID: provider.providerID))
                .frame(width: 34, alignment: .trailing)

            Text(window.resetsAt.map { Self.countdown(until: $0, from: now) } ?? "")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 58, alignment: .trailing)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func paceLine(_ window: UsageWindow, now: Date) -> some View {
        Group {
            if provider.isStale {
                EmptyView()
            } else if window.usedPercent >= 99.5 {
                Label("已用完，等重置", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(Severity.color(100))
            } else if let pace = Pace.of(window, now: now) {
                if let runsOut = pace.runsOutIn {
                    Label("按现在速度 \(Self.duration(runsOut))后用完", systemImage: "bolt.fill")
                        .foregroundStyle(Severity.color(window.usedPercent >= 70 ? 95 : 80))
                } else if pace.delta(used: window.usedPercent) > 10 {
                    Text("用得偏快，不过撑得到重置")
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text("节奏正常，撑得到重置")
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
        }
        .font(.system(size: 9))
        .labelStyle(.titleAndIcon)
        .padding(.leading, 27)
        .frame(height: 11)
    }

    private var sessionsSection: some View {
        let window = SessionAttribution.attributionWindow(for: provider)
        let shown = provider.sessionShares.prefix(Self.maxShareRows)
        let others = provider.sessionShares.dropFirst(Self.maxShareRows).reduce(0) { $0 + $1.share }

        return VStack(alignment: .leading, spacing: 3) {
            Text("\(Self.periodName(window?.label))谁在用（按 token 估算）")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.4))
                .frame(height: 13)
            ForEach(Array(shown)) { share in
                shareRow(share.name, share.share)
            }
            if others > 0.005 {
                shareRow("其他", others)
            }
        }
    }

    private func shareRow(_ name: String, _ share: Double) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(.white.opacity(0.1))
                .frame(width: 48, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(BrandPalette.color(for: provider.providerID))
                        .frame(width: max(2, 48 * share), height: 3)
                }
            Text("\(Int((share * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 30, alignment: .trailing)
        }
        .frame(height: 12)
    }

    @ViewBuilder
    private var recommendationLine: some View {
        if let recommendation, !provider.windows.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.35))
                Text(recommendation.providerID == provider.providerID
                     ? "现在最宽裕，下一个任务建议用它"
                     : "下一个任务建议用 \(recommendation.name)（还剩 \(100 - Int((recommendation.peak?.usedPercent ?? 0).rounded()))%）")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(height: 13)
        }
    }

    static func periodName(_ label: String?) -> String {
        switch label {
        case "周": "这周"
        case "月": "这个月"
        case "日": "今天"
        case let label?: "这 \(label) 里"
        case nil: "这个周期"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(60, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)天\(hours)时" : "\(days)天" }
        if hours > 0 { return "\(hours)时\(minutes)分" }
        return "\(minutes)分钟"
    }

    private func staleText(_ error: String, now: Date) -> String {
        guard provider.isStale, let updatedAt = provider.updatedAt else { return error }
        return "\(error)。下面是 \(Self.relative(updatedAt, now: now))的数据。"
    }

    @ViewBuilder
    private func footer(now: Date) -> some View {
        let metric = appearance.metric == .used ? "显示已用" : "显示剩余"
        if let lastError {
            Text(lastError)
                .font(.system(size: 9))
                .foregroundStyle(.orange.opacity(0.75))
                .lineLimit(2)
        } else if let lastUpdated {
            Text("\(metric) · 更新于 \(Self.relative(lastUpdated, now: now))")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.3))
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
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }
}

// MARK: - Background

extension EnvironmentValues {
    /// ImageRenderer can't draw AppKit views, so snapshots swap the blur for
    /// a flat fill.
    @Entry var isRenderingSnapshot = false
}

struct PanelBackground: View {
    let cornerRadius: CGFloat
    @Environment(\.isRenderingSnapshot) private var isRenderingSnapshot

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if isRenderingSnapshot {
                shape.fill(Color(white: 0.1).opacity(0.92))
            } else {
                BlurBackground(cornerRadius: cornerRadius)
                shape.fill(Color.black.opacity(0.28))
            }
        }
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.16), .white.opacity(0.04)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.6
            )
        )
        .clipShape(shape)
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
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}
