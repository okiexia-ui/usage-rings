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
    private var sidePanel: RingsPanel!
    private var islandPanel: RingsPanel!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var islandShrinkWork: DispatchWorkItem?
    private var mouseMonitors: [Any] = []

    private var screen: NSScreen? { NSScreen.screens.first }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let actions = RingsActions(
            refresh: { [weak self] in self?.store.refresh() },
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
        installIslandContent(actions: actions)

        Publishers.CombineLatest4(store.$providers, store.$hoveredID, store.$pinnedID, store.$isDragging)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutSide() }
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
                guard let self else { return }
                self.installIslandContent(actions: actions)
                self.layoutAll()
            }
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
        let layout = SideLayout(size: settings.ringSize, showLabels: settings.showLabels, rowCount: providers.count)
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

    private func installIslandContent(actions: RingsActions) {
        guard let screen else { return }
        islandPanel.contentView = NSHostingView(
            rootView: IslandView(store: store, settings: settings, notch: .of(screen), actions: actions)
        )
    }

    private func settingsChanged() {
        store.dataSource = settings.dataSource
        store.start(every: settings.refreshInterval)
        if !settings.displayMode.showsIsland {
            store.isIslandHovered = false
        }
        layoutAll()
    }

    private func layoutAll() {
        layoutSide()
        layoutIsland()
    }

    private var visibleProviders: [ProviderUsage] {
        store.providers.filter(settings.isVisible)
    }

    // MARK: Side column

    /// Hugs the chosen screen edge at the saved height. The column stays put;
    /// the detail card widens the panel toward the middle of the screen.
    private func layoutSide() {
        guard settings.displayMode.showsSide, let screen else {
            sidePanel.orderOut(nil)
            return
        }
        guard dragStart == nil else { return }

        let providers = visibleProviders
        let layout = SideLayout(size: settings.ringSize, showLabels: settings.showLabels, rowCount: providers.count)
        let expanded = !settings.isCollapsed && providers.contains { $0.id == store.expandedID }
        let size = layout.panelSize(collapsed: settings.isCollapsed, expanded: expanded)

        let visible = screen.visibleFrame
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

    /// Snap to whichever edge is closer and remember the height.
    private func dragEnded() {
        guard dragStart != nil, let screen else { return }
        let frame = sidePanel.frame
        let visible = screen.visibleFrame
        dragStart = nil
        settings.side = frame.midX < visible.midX ? .left : .right
        settings.verticalPosition = min(max((frame.midY - visible.minY) / visible.height, 0.05), 0.95)
        store.isDragging = false
        layoutSide()
    }

    // MARK: Island

    private func layoutIsland() {
        guard settings.displayMode.showsIsland, let screen else {
            islandPanel.orderOut(nil)
            return
        }

        let providers = visibleProviders
        let layout = IslandLayout(
            notch: .of(screen),
            rowCount: providers.count,
            maxWindows: providers.map(\.windows.count).max() ?? 1
        )

        islandShrinkWork?.cancel()
        if store.isIslandHovered {
            placeIsland(size: layout.expandedSize, on: screen)
        } else {
            // Let the collapse animation finish before the window shrinks.
            let work = DispatchWorkItem { [weak self] in
                self?.placeIsland(size: layout.collapsedSize, on: screen)
            }
            islandShrinkWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (islandPanel.isVisible ? 0.35 : 0),
                execute: work
            )
        }
        if !islandPanel.isVisible {
            placeIsland(size: layout.collapsedSize, on: screen)
            islandPanel.orderFrontRegardless()
        }
    }

    private func placeIsland(size: CGSize, on screen: NSScreen) {
        let frame = NSRect(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if islandPanel.frame != frame {
            islandPanel.setFrame(frame, display: true)
        }
    }

    // MARK: Settings window

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "用量圈设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(
                settings: settings,
                store: store,
                onRefresh: { [weak self] in self?.store.refresh() },
                onOpenCodexBar: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/CodexBar.app"))
                }
            ))
            window.center()
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

/// `UsageRings --snapshot <dir>`: fetch once and write PNGs of every layout
/// without opening a window. Handy for checking design when screen recording
/// isn't granted.
@MainActor
func renderSnapshots(to directory: URL, providers: [ProviderUsage]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let backdrop = Color(red: 0.36, green: 0.42, blue: 0.52)

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
        let defaults = UserDefaults(suiteName: "snapshot-\(UUID().uuidString)")!
        let settings = RingsSettings(defaults: defaults)
        settings.ringSize = size
        settings.isCollapsed = collapsed
        settings.side = dock
        settings.metric = metric
        settings.colorStyle = colors
        let store = UsageStore()
        store.load(providers, updatedAt: .now)
        store.pinnedID = pinned.flatMap { providers.indices.contains($0) ? providers[$0].id : nil }
        let layout = SideLayout(size: size, showLabels: true, rowCount: providers.count)
        let panel = layout.panelSize(collapsed: collapsed, expanded: store.pinnedID != nil)
        try write(name, size: panel, SideRingsView(store: store, settings: settings, actions: RingsActions()))
    }

    try side("side-small", size: .small)
    try side("side-medium", size: .medium)
    try side("side-large", size: .large)
    try side("side-collapsed", size: .medium, collapsed: true)
    try side("side-card-left", size: .medium, pinned: 1)
    try side("side-card-right", size: .medium, pinned: 2, side: .right)
    try side("side-remaining-brand", size: .medium, metric: .remaining, colors: .brand)

    let notch = NotchGeometry(width: 185, height: 32)
    for expanded in [false, true] {
        let settings = RingsSettings(defaults: UserDefaults(suiteName: "snapshot-\(UUID().uuidString)")!)
        let store = UsageStore()
        store.load(providers, updatedAt: .now)
        store.isIslandHovered = expanded
        let layout = IslandLayout(notch: notch, rowCount: providers.count,
                                  maxWindows: providers.map(\.windows.count).max() ?? 1)
        let size = expanded ? layout.expandedSize : layout.collapsedSize
        try write(expanded ? "island-expanded" : "island-collapsed", size: size,
                  IslandView(store: store, settings: settings, notch: notch, actions: RingsActions()))
    }
}

if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.indices.contains(flag + 1) {
    do {
        let source: DataSource = CommandLine.arguments.contains("--codexbar") ? .codexBar
            : CommandLine.arguments.contains("--builtin") ? .builtIn : .auto
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var fetched: Result<[ProviderUsage], any Error> = .success([])
        Task.detached {
            switch source {
            case .builtIn: fetched = .success(await BuiltInProviders.fetchAll())
            case .codexBar: fetched = Result { try CodexBarCLI.fetch() }
            case .auto: fetched = .success(await UsageStore.fetchAutoForSnapshot())
            }
            semaphore.signal()
        }
        semaphore.wait()
        let providers = try fetched.get()
        for provider in providers {
            let windows = provider.windows.map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }.joined(separator: ", ")
            print("\(provider.name): \(windows.isEmpty ? (provider.error ?? "-") : windows)")
        }
        try renderSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]), providers: providers)
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
