import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Borderless floating panel that never steals focus from the app you're in.
final class RingsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var panel: RingsPanel!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = RingsRootView(
            store: store,
            onRefresh: { [weak self] in self?.store.refresh() },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            isLaunchAtLoginEnabled: { SMAppService.mainApp.status == .enabled },
            onOpenCodexBar: {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/CodexBar.app"))
            },
            onQuit: { NSApp.terminate(nil) }
        )

        panel = RingsPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.contentView = NSHostingView(rootView: root)

        layoutPanel()
        panel.orderFrontRegardless()

        Publishers.CombineLatest3(store.$providers, store.$hoveredID, store.$pinnedID)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutPanel() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutPanel() }
            .store(in: &cancellables)

        store.start()
    }

    /// Pinned to the left edge, vertically centered on the menu-bar screen.
    /// The rings column never moves; the detail card widens the panel to the
    /// right.
    private func layoutPanel() {
        guard let screen = NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let expanded = store.providers.contains { $0.id == store.expandedID }
        let size = RingsLayout.panelSize(rowCount: store.providers.count, expanded: expanded)
        let frame = NSRect(
            x: visible.minX + RingsLayout.screenInset,
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
    }

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "开机启动设置失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// `UsageRings --snapshot <dir>`: fetch once and write PNGs of the collapsed
/// column and each provider's detail card, without opening a window. Handy
/// for checking layout when screen recording isn't granted.
@MainActor
func renderSnapshots(to directory: URL) throws {
    let providers = try CodexBarCLI.fetch()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    func write(_ name: String, expandedID: String?) throws {
        let store = UsageStore()
        store.load(providers, updatedAt: .now)
        store.pinnedID = expandedID
        let size = RingsLayout.panelSize(rowCount: providers.count, expanded: expandedID != nil)
        let view = RingsRootView(
            store: store,
            onRefresh: {},
            onToggleLaunchAtLogin: {},
            isLaunchAtLoginEnabled: { false },
            onOpenCodexBar: {},
            onQuit: {}
        )
        .environment(\.isRenderingSnapshot, true)
        .frame(width: size.width, height: size.height)
        .background(Color(red: 0.36, green: 0.42, blue: 0.52))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw CodexBarCLIError.invalidOutput
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    try write("collapsed", expandedID: nil)
    for provider in providers {
        try write("card-\(provider.providerID)", expandedID: provider.id)
    }
}

if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
   CommandLine.arguments.indices.contains(flag + 1) {
    do {
        try renderSnapshots(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
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
