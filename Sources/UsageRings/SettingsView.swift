import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: RingsSettings
    @ObservedObject var store: UsageStore
    let onRefresh: () -> Void
    let onOpenCodexBar: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("显示") {
                Picker("显示方式", selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if settings.displayMode.showsIsland {
                    Text("灵动岛和 Open Island 都画在刘海上，同时开会重叠，建议只留一个。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.displayMode.showsSide {
                    Picker("停靠", selection: $settings.side) {
                        ForEach(DockSide.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("圆环大小", selection: $settings.ringSize) {
                        ForEach(RingSize.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Toggle("显示名称", isOn: $settings.showLabels)
                    Toggle("收起到屏幕边缘", isOn: $settings.isCollapsed)
                }

                Toggle("圆心显示百分比", isOn: $settings.showCenterText)

                LabeledContent("不透明度") {
                    Slider(value: $settings.opacity, in: 0.4...1)
                        .frame(width: 180)
                }
            }

            Section("数据") {
                Picker("数据来源", selection: $settings.dataSource) {
                    ForEach(DataSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.dataSource.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("圆环表示", selection: $settings.metric) {
                    ForEach(RingMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("配色", selection: $settings.colorStyle) {
                    ForEach(ColorStyle.allCases) { Text($0.title).tag($0) }
                }

                Picker("刷新间隔", selection: $settings.refreshMinutes) {
                    ForEach(RingsSettings.refreshChoices, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 分钟" : "\(minutes.formatted()) 分钟").tag(minutes)
                    }
                }

                HStack {
                    Button("立即刷新", action: onRefresh)
                        .disabled(store.isLoading)
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if let updated = store.lastUpdated {
                        Text("上次更新 \(updated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if store.providers.isEmpty {
                    Text(settings.dataSource != .codexBar
                        ? "没有找到已登录的 agent。登录 Codex、Claude Code、OpenCode Go 或 Kimi Code 后会自动出现。"
                        : "还没有读到账号。先在 CodexBar 里打开要监控的服务。")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.providers) { provider in
                    Toggle(isOn: Binding(
                        get: { settings.isVisible(provider) },
                        set: { settings.setVisible($0, providerID: provider.providerID) }
                    )) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(BrandPalette.color(for: provider.providerID))
                                .frame(width: 8, height: 8)
                            Text(provider.name)
                            if let account = provider.account {
                                Text(account)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if settings.dataSource != .builtIn {
                    Button("在 CodexBar 里添加或管理账号…", action: onOpenCodexBar)
                }
            } header: {
                Text("账号")
            } footer: {
                Text(settings.dataSource != .codexBar
                    ? "只读取各家官方工具保存在本机的登录，直接发给各自的官方接口，不经过任何第三方。"
                    : "用量数据来自 CodexBar（codexbar usage），登录和授权都在 CodexBar 里完成。")
            }

            Section {
                APIKeyRow(
                    providerID: "kimi",
                    title: "Kimi Code API Key",
                    hint: "Kimi 命令行的登录 15 分钟就过期，填一个 API key 就能一直读到用量。",
                    link: URL(string: "https://www.kimi.com/code/console"),
                    onChange: onRefresh
                )
                APIKeyRow(
                    providerID: "opencodego",
                    title: "OpenCode Go API Key",
                    hint: "登录过 OpenCode Go 的话会自动读取，一般不用填。",
                    link: URL(string: "https://opencode.ai/auth"),
                    onChange: onRefresh
                )
            } header: {
                Text("API Key（可选）")
            } footer: {
                Text("只保存在本机 ~/Library/Application Support/UsageRings/keys.json（仅你的账户可读），只发给对应服务的官方接口。")
            }

            Section("其他") {
                Toggle("开机启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 520)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// One provider's API key: write-only in the UI (a saved key is never shown).
private struct APIKeyRow: View {
    let providerID: String
    let title: String
    let hint: String
    let link: URL?
    let onChange: () -> Void

    @State private var draft = ""
    @State private var isSaved = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                if isSaved {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            HStack {
                SecureField(isSaved ? "已保存，输入新的可以替换" : "粘贴 API key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("保存", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isSaved {
                    Button("清除") { store(nil) }
                }
            }
            HStack(spacing: 6) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let link {
                    Link("去创建", destination: link)
                        .font(.caption)
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { isSaved = KeyStore.key(for: providerID) != nil }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        store(key)
    }

    private func store(_ key: String?) {
        do {
            try KeyStore.setKey(key, for: providerID)
            draft = ""
            error = nil
            isSaved = key != nil
            onChange()
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }
}
