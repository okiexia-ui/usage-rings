#if canImport(AppKit)
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: RingsSettings
    @ObservedObject var store: UsageStore
    let onRefresh: () -> Void
    let onOpenCodexBar: () -> Void
    let onTestAlert: () -> Void

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section(tr("显示", "Display")) {
                Picker(tr("显示方式", "Show as"), selection: $settings.displayMode) {
                    ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if settings.displayMode.showsIsland {
                    Text(tr("灵动岛画在带刘海的屏幕上（没有的话就在主显示器菜单栏中间）。它和 Open Island 都画在刘海上，同时开会重叠，建议只留一个。",
                            "The island sits on the display with a notch (or the middle of the main display's menu bar). It overlaps Open Island if both run; keep one."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if settings.displayMode.showsSide {
                    Picker(tr("显示器", "Display"), selection: $settings.screenName) {
                        Text(tr("主显示器", "Main display")).tag("")
                        ForEach(ScreenChoice.names, id: \.self) { Text($0).tag($0) }
                        if !settings.screenName.isEmpty, !ScreenChoice.names.contains(settings.screenName) {
                            Text(tr("\(settings.screenName)（未连接）", "\(settings.screenName) (not connected)")).tag(settings.screenName)
                        }
                    }

                    Picker(tr("停靠", "Dock"), selection: $settings.side) {
                        ForEach(DockSide.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker(tr("圆环大小", "Ring size"), selection: $settings.ringSize) {
                        ForEach(RingSize.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Toggle(tr("显示名称", "Show names"), isOn: $settings.showLabels)
                    Toggle(tr("收起到屏幕边缘", "Collapse to the screen edge"), isOn: $settings.isCollapsed)
                }

                Toggle(tr("圆心显示百分比", "Percentage in the middle"), isOn: $settings.showCenterText)

                LabeledContent(tr("不透明度", "Opacity")) {
                    Slider(value: $settings.opacity, in: 0.4...1)
                        .frame(width: 180)
                }

                Picker(tr("语言", "Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
            }

            Section(tr("数据", "Data")) {
                Picker(tr("数据来源", "Source"), selection: $settings.dataSource) {
                    ForEach(DataSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.dataSource.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(tr("圆环表示", "Rings show"), selection: $settings.metric) {
                    ForEach(RingMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker(tr("配色", "Colors"), selection: $settings.colorStyle) {
                    ForEach(ColorStyle.allCases) { Text($0.title).tag($0) }
                }

                Picker(tr("刷新间隔", "Refresh every"), selection: $settings.refreshMinutes) {
                    ForEach(RingsSettings.refreshChoices, id: \.self) { minutes in
                        Text(tr("\(minutes.formatted()) 分钟", "\(minutes.formatted()) min")).tag(minutes)
                    }
                }

                HStack {
                    Button(tr("立即刷新", "Refresh Now"), action: onRefresh)
                        .disabled(store.isLoading)
                    if store.isLoading {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if let updated = store.lastUpdated {
                        Text(tr("上次更新 \(updated.formatted(date: .omitted, time: .shortened))",
                                "Updated \(updated.formatted(date: .omitted, time: .shortened))"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker(tr("用量超过", "When usage passes"), selection: $settings.alertThreshold) {
                    ForEach(RingsSettings.alertChoices, id: \.self) { threshold in
                        Text(threshold == 0 ? tr("不提醒", "Off") : "\(Int(threshold))%").tag(threshold)
                    }
                }
                Toggle(tr("用完的额度重置时提醒", "When a used-up quota resets"), isOn: $settings.alertOnReset)
                Button(tr("发一条测试通知", "Send a Test Notification"), action: onTestAlert)
            } header: {
                Text(tr("提醒", "Alerts"))
            } footer: {
                Text(tr("每个额度周期最多提醒一次。第一次提醒时 macOS 会询问是否允许通知。",
                        "At most one alert per quota window. macOS asks for permission the first time."))
            }

            Section {
                if store.providers.isEmpty {
                    Text(settings.dataSource != .codexBar
                        ? tr("没有找到已登录的服务。登录 \(BuiltInProviders.summary) 中的任意一个，或在下面填 API Key，就会自动出现。",
                             "No signed-in service found. Sign in to any of \(BuiltInProviders.summary), or add an API key below, and it shows up.")
                        : tr("还没有读到账号。先在 CodexBar 里打开要监控的服务。", "No accounts yet. Turn on the services to watch in CodexBar first."))
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
                    Button(tr("在 CodexBar 里添加或管理账号…", "Add or Manage Accounts in CodexBar…"), action: onOpenCodexBar)
                }
            } header: {
                Text(tr("账号", "Accounts"))
            } footer: {
                Text(settings.dataSource != .codexBar
                    ? tr("只读取各家官方工具保存在本机的登录，直接发给各自的官方接口，不经过任何第三方。",
                         "Only reads the logins each service's own tools saved on this Mac, and sends them straight to that service. No third parties.")
                    : tr("用量数据来自 CodexBar（codexbar usage），登录和授权都在 CodexBar 里完成。",
                         "Usage comes from CodexBar (codexbar usage); sign-in and authorization happen in CodexBar."))
            }

            Section {
                ForEach(APIKeyRow.Spec.all) { spec in
                    APIKeyRow(spec: spec, onChange: onRefresh)
                }
            } header: {
                Text(tr("API Key（可选）", "API keys (optional)"))
            } footer: {
                Text(tr("只保存在本机 ~/Library/Application Support/UsageRings/keys.json（仅你的账户可读），只发给对应服务的官方接口。",
                        "Stored only in ~/Library/Application Support/UsageRings/keys.json (readable by your account only), and only sent to that service's own API."))
            }

            Section(tr("其他", "Other")) {
                Toggle(tr("开机启动", "Open at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent(tr("版本", "Version"), value: HTTP.appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, idealWidth: 460, minHeight: 520, idealHeight: 680)
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

/// Displays the side column can live on, by name (IDs change across reconnects).
enum ScreenChoice {
    @MainActor
    static var names: [String] {
        var seen = Set<String>()
        return NSScreen.screens.map(\.localizedName).filter { seen.insert($0).inserted }
    }
}

/// One provider's API key: write-only in the UI (a saved key is never shown).
private struct APIKeyRow: View {
    struct Spec: Identifiable {
        let providerID: String
        let title: String
        let hint: String
        let link: URL?

        var id: String { providerID }

        static var all: [Spec] {
            [
                Spec(providerID: "kimi", title: "Kimi Code API Key",
                     hint: tr("Kimi 命令行的登录 15 分钟就过期，填一个 API key 就能一直读到用量。",
                              "The Kimi CLI login expires after 15 minutes; an API key keeps usage readable."),
                     link: URL(string: "https://www.kimi.com/code/console")),
                Spec(providerID: "zai", title: tr("智谱 GLM Coding Plan API Key", "Z.ai GLM Coding Plan API key"),
                     hint: tr("国内 bigmodel.cn 和国际 z.ai 的 key 都可以，会自动识别。",
                              "Keys from bigmodel.cn (China) or z.ai (international) both work."),
                     link: URL(string: tr("https://bigmodel.cn/usercenter/proj-mgmt/apikeys", "https://z.ai/manage-apikey/apikey-list"))),
                Spec(providerID: "minimax", title: tr("MiniMax Coding Plan API Key", "MiniMax Coding Plan API key"),
                     hint: tr("Coding Plan / Token Plan 的 key（sk-cp-…），国内和国际站都可以。",
                              "A Coding Plan or Token Plan key (sk-cp-…), China or international."),
                     link: URL(string: tr("https://platform.minimaxi.com/user-center/payment/coding-plan",
                                          "https://platform.minimax.io/user-center/payment/coding-plan"))),
                Spec(providerID: "copilot", title: tr("GitHub Copilot 令牌", "GitHub Copilot token"),
                     hint: tr("在 Neovim、JetBrains、Xcode 等编辑器里登录过 Copilot 的话会自动读取，一般不用填。",
                              "Read automatically if you signed in to Copilot in Neovim, JetBrains, Xcode and the like."),
                     link: nil),
                Spec(providerID: "opencodego", title: "OpenCode Go API Key",
                     hint: tr("登录过 OpenCode Go 的话会自动读取，一般不用填。", "Read automatically if you signed in to OpenCode Go."),
                     link: URL(string: "https://opencode.ai/auth")),
            ]
        }
    }

    let spec: Spec
    let onChange: () -> Void

    @State private var draft = ""
    @State private var isSaved = false
    @State private var detected: KeySource?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(spec.title)
                Spacer()
                if isSaved {
                    Label(tr("已保存", "Saved"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if detected != nil {
                    Label(tr("已找到", "Found"), systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                SecureField(
                    "API key",
                    text: $draft,
                    prompt: Text(isSaved ? tr("已保存，输入新的可以替换", "Saved; type a new one to replace it") : tr("粘贴或输入", "Paste or type"))
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .onSubmit(save)
                Button(tr("粘贴", "Paste")) {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .help(tr("把剪贴板里的内容填进来", "Fill in what's on the clipboard"))
                Button(tr("保存", "Save"), action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isSaved {
                    Button(tr("清除", "Clear")) { store(nil) }
                }
            }
            if let detected, !isSaved {
                Text(tr("正在使用 \(detected.description) 里的 key，不用再填。", "Using the key from \(detected.description); nothing to fill in."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(spec.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let link = spec.link {
                    Link(tr("去创建", "Create one"), destination: link)
                        .font(.caption)
                }
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        isSaved = KeyStore.key(for: spec.providerID) != nil
        detected = (BuiltInProviders.provider(spec.providerID) as? any APIKeyProvider)?.keySource()
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        store(key)
    }

    private func store(_ key: String?) {
        do {
            try KeyStore.setKey(key, for: spec.providerID)
            draft = ""
            error = nil
            reload()
            onChange()
        } catch {
            self.error = tr("保存失败：\(error.localizedDescription)", "Couldn't save: \(error.localizedDescription)")
        }
    }
}
#endif
