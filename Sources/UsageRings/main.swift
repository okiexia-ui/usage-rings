#if canImport(AppKit)
import AppKit
import Combine
import SwiftUI

/// Borderless floating panel that never steals focus from the app you're in.
final class RingsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func make(level: NSWindow.Level) -> RingsPanel {
        let panel = RingsPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = UsageStore()
    private let settings = RingsSettings()
    private let notifier = QuotaNotifier()
    private var sidePanel: RingsPanel!
    private var islandPanel: RingsPanel!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var actions = RingsActions()

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var islandShrinkWork: DispatchWorkItem?
    private var mouseMonitors: [Any] = []
    /// What the island and menus were last built for, to rebuild on change.
    private var islandNotch: NotchGeometry?
    private var builtLanguage: Bool?

    /// The display the side column lives on: the one picked in Settings when
    /// it's connected, else the main display (the one with the menu bar).
    private var sideScreen: NSScreen? {
        let screens = NSScreen.screens
        if !settings.screenName.isEmpty, let chosen = screens.first(where: { $0.localizedName == settings.screenName }) {
            return chosen
        }
        return screens.first
    }

    /// The island wraps a notch when any display has one (a MacBook next to
    /// an external main display, say); otherwise it hangs from the side
    /// column's display.
    private var islandScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? sideScreen
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Text fields only get ⌘V / ⌘C / ⌘A / ⌘Z through menu key
        // equivalents; an accessory app has no menu bar unless we build one.
        NSApp.mainMenu = makeMainMenu()
        builtLanguage = L10n.isChinese

        actions = RingsActions(
            refresh: { [weak self] in self?.store.refresh(force: true) },
            openSettings: { [weak self] in self?.openSettings() },
            setCollapsed: { [weak self] in self?.setCollapsed($0) },
            setSide: { [weak self] side in
                self?.settings.side = side
                self?.settings.verticalPosition = 0.5
            },
            dragChanged: { [weak self] in self?.dragChanged() },
            dragEnded: { [weak self] in self?.dragEnded() },
            quit: { NSApp.terminate(nil) }
        )

        sidePanel = RingsPanel.make(level: .floating)
        sidePanel.contentView = NSHostingView(
            rootView: SideRingsView(store: store, settings: settings, actions: actions)
        )

        // Above the menu bar so the island can wrap the notch.
        islandPanel = RingsPanel.make(level: NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3))
        installIslandContentIfNeeded()

        store.onUpdate = { [weak self] providers in
            guard let self else { return }
            self.notifier.update(
                providers.filter(self.settings.isVisible),
                threshold: self.settings.alertThreshold,
                onReset: self.settings.alertOnReset
            )
        }

        Publishers.CombineLatest4(store.$providers, store.$hoveredID, store.$pinnedID, store.$isDragging)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutSide() }
            .store(in: &cancellables)

        // Provider count changes the island's width.
        store.$providers
            .map(\.count)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutIsland() }
            .store(in: &cancellables)

        store.$isIslandHovered
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutIsland() }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.installIslandContentIfNeeded()
                self?.layoutAll()
            }
            .store(in: &cancellables)

        // Readings go stale while the Mac sleeps; refresh once the network
        // is likely back rather than waiting out the poll interval.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(6), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.store.refresh(force: true) }
            .store(in: &cancellables)

        installMouseTracking()
        layoutAll()
        store.dataSource = settings.dataSource
        store.start(every: settings.refreshInterval)
    }

    // MARK: Hover

    /// Hover is derived from the cursor position against the known layout
    /// rather than SwiftUI's onHover: tracking areas don't fire for a cursor
    /// that is already resting where a view appears (e.g. right after the
    /// column expands from the edge tab), and non-key panels can miss
    /// enter/exit events entirely.
    private func installMouseTracking() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        updateSideHover(mouse)
        updateIslandHover(mouse)
    }

    private func updateSideHover(_ mouse: NSPoint) {
        guard dragStart == nil, settings.displayMode.showsSide, !settings.isCollapsed, sidePanel.isVisible else {
            setHovered(nil)
            return
        }
        let frame = sidePanel.frame
        guard frame.contains(mouse) else {
            setHovered(nil)
            return
        }

        let providers = visibleProviders
        let layout = sideLayout(rowCount: providers.count)
        let column = NSRect(
            x: settings.side == .left ? frame.minX : frame.maxX - layout.columnWidth,
            y: frame.midY - layout.columnHeight / 2,
            width: layout.columnWidth,
            height: layout.columnHeight
        )
        // Over the open card (or the gap beside it): keep what's showing.
        guard column.contains(mouse) else { return }

        let offset = column.maxY - mouse.y - layout.verticalPadding - layout.handleHeight - layout.handleSpacing
        let pitch = layout.rowHeight + layout.rowSpacing
        guard offset >= 0 else {
            setHovered(nil)
            return
        }
        let index = Int(offset / pitch)
        if index < providers.count, offset - CGFloat(index) * pitch <= layout.rowHeight {
            setHovered(providers[index].id)
        }
    }

    private func setHovered(_ id: String?) {
        if store.hoveredID != id {
            store.hoveredID = id
        }
    }

    private func updateIslandHover(_ mouse: NSPoint) {
        let inside = settings.displayMode.showsIsland && islandPanel.isVisible && islandPanel.frame.contains(mouse)
        if store.isIslandHovered != inside {
            store.isIslandHovered = inside
        }
    }

    /// The island view is built for one notch; rebuild it when the island
    /// moves to a different display or the display changes shape.
    private func installIslandContentIfNeeded() {
        guard let screen = islandScreen else { return }
        let notch = NotchGeometry.of(screen)
        guard notch != islandNotch else { return }
        islandNotch = notch
        islandPanel.contentView = NSHostingView(
            rootView: IslandView(store: store, settings: settings, notch: notch, actions: actions)
        )
    }

    private func settingsChanged() {
        store.dataSource = settings.dataSource
        store.start(every: settings.refreshInterval)
        if !settings.displayMode.showsIsland {
            store.isIslandHovered = false
        }
        if builtLanguage != L10n.isChinese {
            languageChanged()
        }
        installIslandContentIfNeeded()
        layoutAll()
    }

    /// Menus are AppKit and messages come with each reading, so both are
    /// rebuilt; the SwiftUI views redraw on their own.
    private func languageChanged() {
        builtLanguage = L10n.isChinese
        NSApp.mainMenu = makeMainMenu()
        settingsWindow?.title = tr("用量圈设置", "Usage Rings Settings")
        store.refresh(force: true)
    }

    private func layoutAll() {
        layoutSide()
        layoutIsland()
    }

    private var visibleProviders: [ProviderUsage] {
        store.providers.filter(settings.isVisible)
    }

    // MARK: Side column

    private func sideLayout(rowCount: Int) -> SideLayout {
        SideLayout.fitting(size: settings.ringSize, showLabels: settings.showLabels,
                           rowCount: rowCount, maxHeight: store.sideMaxHeight)
    }

    /// Hugs the chosen screen edge at the saved height. The column stays put;
    /// the detail card widens the panel toward the middle of the screen.
    private func layoutSide() {
        guard settings.displayMode.showsSide, let screen = sideScreen else {
            sidePanel.orderOut(nil)
            return
        }
        guard dragStart == nil else { return }

        let visible = screen.visibleFrame
        let maxHeight = visible.height - 2 * SideLayout.screenInset
        if store.sideMaxHeight != maxHeight {
            store.sideMaxHeight = maxHeight
        }

        let providers = visibleProviders
        let layout = sideLayout(rowCount: providers.count)
        let expanded = settings.isCollapsed ? nil : providers.first { $0.id == store.expandedID }
        let cardHeight = expanded.map {
            DetailCard.estimatedHeight(for: $0, hasRecommendation: Recommendation.pick(providers) != nil)
        }
        let size = layout.panelSize(collapsed: settings.isCollapsed, cardHeight: cardHeight)

        let inset = settings.isCollapsed ? 0 : SideLayout.screenInset
        let x = settings.side == .left
            ? visible.minX + inset
            : visible.maxX - inset - size.width
        let centerY = visible.minY + visible.height * settings.verticalPosition
        let y = min(max(centerY - size.height / 2, visible.minY), visible.maxY - size.height)

        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        if !sidePanel.isVisible {
            sidePanel.orderFrontRegardless()
        }
        if sidePanel.frame != frame {
            sidePanel.setFrame(frame, display: true)
            DispatchQueue.main.async { [weak self] in
                self?.updateSideHover(NSEvent.mouseLocation)
            }
        }
    }

    private func setCollapsed(_ collapsed: Bool) {
        store.hoveredID = nil
        store.pinnedID = nil
        settings.isCollapsed = collapsed
    }

    private func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, sidePanel.frame.origin)
            store.isDragging = true
            store.hoveredID = nil
            store.pinnedID = nil
        }
        guard let start = dragStart else { return }
        sidePanel.setFrameOrigin(NSPoint(
            x: start.origin.x + mouse.x - start.mouse.x,
            y: start.origin.y + mouse.y - start.mouse.y
        ))
    }

    /// Snap to whichever edge is closer and remember the height. Dropped on
    /// another display, the column moves there.
    private func dragEnded() {
        guard dragStart != nil, let current = sideScreen else { return }
        let frame = sidePanel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? current
        let visible = screen.visibleFrame
        dragStart = nil
        if screen != current {
            settings.screenName = screen == NSScreen.screens.first ? "" : screen.localizedName
        }
        settings.side = frame.midX < visible.midX ? .left : .right
        settings.verticalPosition = min(max((frame.midY - visible.minY) / visible.height, 0.05), 0.95)
        store.isDragging = false
        layoutSide()
    }

    // MARK: Island

    private func layoutIsland() {
        guard settings.displayMode.showsIsland, let screen = islandScreen else {
            islandPanel.orderOut(nil)
            return
        }

        let notch = NotchGeometry.of(screen)
        // Re-measured each time: status items come and go as apps launch.
        let rightSpace = MenuBarSpace.freeWidthRightOfNotch(on: screen, notch: notch)
        if store.islandRightSpace != rightSpace {
            store.islandRightSpace = rightSpace
        }
        let maxWidth = screen.frame.width - 2 * Self.islandMargin
        if store.islandMaxWidth != maxWidth {
            store.islandMaxWidth = maxWidth
        }

        let providers = visibleProviders
        let layout = IslandLayout(
            notch: notch,
            rowCount: providers.count,
            maxWindows: providers.map(\.windows.count).max() ?? 1,
            rightSpace: rightSpace,
            maxWidth: maxWidth
        )

        // Collapsed, the pill hugs the notch (its wings may differ in width);
        // expanded, it centres on the notch, kept inside the screen.
        let collapsedFrame = NSRect(
            x: (screen.frame.minX + notch.minX - layout.leftWing).rounded(),
            y: screen.frame.maxY - layout.collapsedSize.height,
            width: layout.collapsedSize.width,
            height: layout.collapsedSize.height
        )
        let expanded = layout.expandedSize
        let notchMidX = screen.frame.minX + notch.minX + notch.width / 2
        let expandedX = min(
            max(notchMidX - expanded.width / 2, screen.frame.minX + Self.islandMargin),
            screen.frame.maxX - Self.islandMargin - expanded.width
        )
        let expandedFrame = NSRect(
            x: expandedX.rounded(),
            y: screen.frame.maxY - expanded.height,
            width: expanded.width,
            height: expanded.height
        )

        islandShrinkWork?.cancel()
        if store.isIslandHovered {
            placeIsland(expandedFrame)
        } else {
            // Let the collapse animation finish before the window shrinks.
            let work = DispatchWorkItem { [weak self] in
                self?.placeIsland(collapsedFrame)
            }
            islandShrinkWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (islandPanel.isVisible ? 0.35 : 0),
                execute: work
            )
        }
        if !islandPanel.isVisible {
            placeIsland(collapsedFrame)
            islandPanel.orderFrontRegardless()
        }
    }

    private static let islandMargin: CGFloat = 8

    private func placeIsland(_ frame: NSRect) {
        if islandPanel.frame != frame {
            islandPanel.setFrame(frame, display: true)
        }
    }

    // MARK: Settings window

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appName = tr("用量圈", "Usage Rings")

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: tr("关于用量圈", "About Usage Rings"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: tr("设置…", "Settings…"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("退出用量圈", "Quit Usage Rings"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: mainMenu)

        let editMenu = NSMenu(title: tr("编辑", "Edit"))
        editMenu.addItem(withTitle: tr("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: tr("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: tr("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: tr("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: tr("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, to: mainMenu)

        let windowMenu = NSMenu(title: tr("窗口", "Window"))
        windowMenu.addItem(withTitle: tr("关闭", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: tr("最小化", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        addSubmenu(windowMenu, to: mainMenu)

        return mainMenu
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = tr("用量圈设置", "Usage Rings Settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: 440, height: 420)
            window.setFrameAutosaveName("SettingsWindow")
            window.contentView = NSHostingView(rootView: SettingsView(
                settings: settings,
                store: store,
                onRefresh: { [weak self] in self?.store.refresh(force: true) },
                onOpenCodexBar: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/CodexBar.app"))
                },
                onTestAlert: { [weak self] in self?.notifier.sendTest() }
            ))
            if !window.setFrameUsingName("SettingsWindow") {
                window.center()
            }
            settingsWindow = window
        }
        // Show in the Dock / ⌘-Tab while settings are open, like menu bar apps do.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }
}

// MARK: - Snapshots

/// Made-up readings for README screenshots, so no real account, project or
/// usage ends up in the repository.
enum DemoData {
    static func providers(now: Date = .now) -> [ProviderUsage] {
        func window(_ key: String, _ used: Double, _ minutes: Int, resetsIn hours: Double, scope: String? = nil) -> UsageWindow {
            UsageWindow.make(key: key, scope: scope, usedPercent: used, minutes: minutes, resetsAt: now.addingTimeInterval(hours * 3_600))
        }
        var claude = ProviderUsage.make(id: "claude", account: "Claude Pro", windows: [
            window("primary", 72, 300, resetsIn: 2.2),
            window("secondary", 58, 10_080, resetsIn: 70),
        ])
        claude.sessionShares = [
            SessionShare(id: "a", name: "my-app", share: 0.61, weightedTokens: 610),
            SessionShare(id: "b", name: "website", share: 0.27, weightedTokens: 270),
            SessionShare(id: "c", name: "scripts", share: 0.12, weightedTokens: 120),
        ]
        var codex = ProviderUsage.make(id: "codex", account: "dev@example.com", windows: [
            window("secondary", 34, 10_080, resetsIn: 90),
        ])
        codex.sessionShares = [
            SessionShare(id: "d", name: "my-app", share: 0.8, weightedTokens: 800),
            SessionShare(id: "e", name: "data-tools", share: 0.2, weightedTokens: 200),
        ]
        return [
            codex,
            claude,
            ProviderUsage.make(id: "opencodego", windows: [
                window("primary", 8, 300, resetsIn: 3.5),
                window("secondary", 41, 10_080, resetsIn: 100),
                window("tertiary", 40, 43_200, resetsIn: 380),
            ]),
            ProviderUsage.make(id: "kimi", windows: [
                window("primary", 15, 300, resetsIn: 1.5),
                window("secondary", 22, 10_080, resetsIn: 120),
            ]),
        ]
    }

    /// The newer built-in services, for checking how they lay out.
    static func morePlans(now: Date = .now) -> [ProviderUsage] {
        func window(_ key: String, _ used: Double, _ minutes: Int, resetsIn hours: Double, scope: String? = nil) -> UsageWindow {
            UsageWindow.make(key: key, scope: scope, usedPercent: used, minutes: minutes, resetsAt: now.addingTimeInterval(hours * 3_600))
        }
        return providers(now: now) + [
            ProviderUsage.make(id: "zai", account: "GLM Pro", windows: [
                window("primary", 46, 300, resetsIn: 2.8),
                window("secondary", 12, 10_080, resetsIn: 130),
            ]),
            ProviderUsage.make(id: "minimax", account: "Coding Plan Plus", windows: [
                window("primary", 93, 300, resetsIn: 0.6),
            ]),
            ProviderUsage.make(id: "copilot", account: "Copilot Pro", windows: [
                window("tertiary", 64, 43_200, resetsIn: 220, scope: "premium"),
            ]),
            ProviderUsage.make(id: "cursor", account: "Cursor Pro", windows: [
                window("tertiary", 38, 43_200, resetsIn: 300),
            ]),
        ]
    }
}

/// `UsageRings --snapshot <dir>`: fetch once and write PNGs of every layout
/// without opening a window. Handy for checking design when screen recording
/// isn't granted.
@MainActor
func renderSnapshots(to directory: URL, providers: [ProviderUsage], language: AppLanguage) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let backdrop = Color(red: 0.36, green: 0.42, blue: 0.52)

    func makeSettings() -> RingsSettings {
        let settings = RingsSettings(defaults: UserDefaults(suiteName: "snapshot-\(UUID().uuidString)")!)
        settings.language = language
        return settings
    }

    func write<V: View>(_ name: String, size: CGSize, _ view: V) throws {
        let content = view
            .environment(\.isRenderingSnapshot, true)
            .frame(width: size.width, height: size.height)
            .padding(12)
            .background(backdrop)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw CodexBarCLIError.invalidOutput
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func side(_ name: String, size: RingSize, collapsed: Bool = false, pinned: Int? = nil,
              side dock: DockSide = .left, metric: RingMetric = .used, colors: ColorStyle = .traffic) throws {
        let settings = makeSettings()
        settings.ringSize = size
        settings.isCollapsed = collapsed
        settings.side = dock
        settings.metric = metric
        settings.colorStyle = colors
        let store = UsageStore()
        store.load(providers, updatedAt: .now)
        store.pinnedID = pinned.flatMap { providers.indices.contains($0) ? providers[$0].id : nil }
        let layout = SideLayout(size: size, showLabels: true, rowCount: providers.count)
        let pinnedProvider = providers.first { $0.id == store.pinnedID }
        let panel = layout.panelSize(
            collapsed: collapsed,
            cardHeight: pinnedProvider.map {
                DetailCard.estimatedHeight(for: $0, hasRecommendation: Recommendation.pick(providers) != nil)
            }
        )
        try write(name, size: panel, SideRingsView(store: store, settings: settings, actions: RingsActions()))
    }

    try side("side-small", size: .small)
    try side("side-medium", size: .medium)
    try side("side-large", size: .large)
    try side("side-collapsed", size: .medium, collapsed: true)
    try side("side-card-left", size: .medium, pinned: 1)
    try side("side-card-right", size: .medium, pinned: 2, side: .right)
    try side("side-remaining-brand", size: .medium, metric: .remaining, colors: .brand)
    for index in providers.indices.dropFirst(4) {
        try side("side-card-\(providers[index].providerID)", size: .medium, pinned: index)
    }

    let notch = NotchGeometry(width: 179, height: 32, minX: 646)
    // Collapsed island at several provider counts, to check the pill scales.
    for count in [1, 2, 3, 4, 6] {
        let settings = makeSettings()
        let store = UsageStore()
        let sample = (0..<count).map { index -> ProviderUsage in
            var copy = providers[index % max(1, providers.count)]
            if index >= providers.count { copy.account = "#\(index)" }
            return copy
        }
        store.load(sample, updatedAt: .now)
        let layout = IslandLayout(notch: notch, rowCount: count, maxWindows: 3)
        try write("island-collapsed-\(count)", size: layout.collapsedSize,
                  IslandView(store: store, settings: settings, notch: notch, actions: RingsActions()))

        // Same, with only 49pt free right of the notch (crowded menu bar).
        store.islandRightSpace = 49
        let tight = IslandLayout(notch: notch, rowCount: count, maxWindows: 3, rightSpace: 49)
        try write("island-collapsed-\(count)-tight", size: tight.collapsedSize,
                  IslandView(store: store, settings: settings, notch: notch, actions: RingsActions()))
    }
    for expanded in [false, true] {
        let settings = makeSettings()
        let store = UsageStore()
        store.load(providers, updatedAt: .now)
        store.isIslandHovered = expanded
        store.islandMaxWidth = 1_512 - 16
        let layout = IslandLayout(notch: notch, rowCount: providers.count,
                                  maxWindows: providers.map(\.windows.count).max() ?? 1, maxWidth: 1_512 - 16)
        let size = expanded ? layout.expandedSize : layout.collapsedSize
        try write(expanded ? "island-expanded" : "island-collapsed", size: size,
                  IslandView(store: store, settings: settings, notch: notch, actions: RingsActions()))
    }
}

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) {
    do {
        let source: DataSource = arguments.contains("--codexbar") ? .codexBar
            : arguments.contains("--builtin") ? .builtIn : .auto
        let language = arguments.firstIndex(of: "--lang")
            .flatMap { arguments.indices.contains($0 + 1) ? AppLanguage(rawValue: arguments[$0 + 1]) : nil } ?? .system
        L10n.language = language
        let demo = arguments.contains("--demo-all") ? DemoData.morePlans()
            : arguments.contains("--demo") ? DemoData.providers() : nil

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var fetched: Result<[ProviderUsage], any Error> = .success([])
        if demo == nil {
            Task.detached {
                fetched = await UsageFetch.fetch(source)
                semaphore.signal()
            }
            semaphore.wait()
        }
        let providers = try demo ?? fetched.get()
        for provider in providers {
            let windows = provider.windows.map { window -> String in
                var text = "\(window.label) \(Int(window.usedPercent.rounded()))%"
                if let pace = Pace.of(window) {
                    text += pace.runsOutIn.map { tr(" (≈\(Int($0 / 60))分钟后用完)", " (out in ≈\(Int($0 / 60)) min)") }
                        ?? tr(" (撑得到重置, 预期\(Int(pace.expectedPercent))%)", " (lasts to reset, even pace \(Int(pace.expectedPercent))%)")
                }
                return text
            }.joined(separator: ", ")
            print("\(provider.name): \(windows.isEmpty ? (provider.error ?? "-") : windows)")
            for share in provider.sessionShares.prefix(4) {
                print("    \(share.name): \(Int((share.share * 100).rounded()))%")
            }
        }
        if let pick = Recommendation.pick(providers) {
            print(tr("推荐下一个用: \(pick.name)", "Suggested next: \(pick.name)"))
        }
        try renderSnapshots(to: URL(fileURLWithPath: arguments[flag + 1]), providers: providers, language: language)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("snapshot failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
