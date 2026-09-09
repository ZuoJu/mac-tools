import SwiftUI
import CoreKit
import ClipboardFeature
import MenuBarFeature
import ScrollFeature
import ScreenshotFeature
import TranslateFeature

/// 设置窗口：通用 / 快捷键 / 剪贴板 / 翻译 / 菜单栏图标 / 滚轮方向 / 截图 / 关于。
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var clipboardStore: ClipboardStore
    @ObservedObject var menuBarController: MenuBarController
    @ObservedObject var scrollReverser: ScrollReverser
    @ObservedObject var screenshotCoordinator: ScreenshotCoordinator
    @ObservedObject var translationSettings: TranslationSettings
    @ObservedObject var translationHistory: TranslationHistoryStore
    let translationService: TranslationService
    var onOpenTextTranslate: () -> Void
    @ObservedObject var hotKeyManager: HotKeyManager = .shared

    @State private var showIgnoredApps = false
    @State private var loginItemError: String?
    @State private var translateTestState: TranslateTestState = .idle
    @State private var showAPIKey = false

    enum TranslateTestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    private enum SettingsTab: String, CaseIterable {
        case general = "通用", shortcuts = "快捷键", clipboard = "剪贴板", translate = "翻译"
        case menuBar = "菜单栏图标", scroll = "滚轮方向", screenshot = "截图", about = "关于"
    }
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置分类", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)
            Divider()
            Group {
                switch selectedTab {
                case .general: generalTab
                case .shortcuts: shortcutsTab
                case .clipboard: clipboardTab
                case .translate: translateTab
                case .menuBar: menuBarTab
                case .scroll: scrollTab
                case .screenshot: screenshotTab
                case .about: aboutTab
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section("启动") {
                Toggle("开机自动启动", isOn: Binding(
                    get: { LoginItem.isEnabled },
                    set: { enabled in
                        let result = LoginItem.setEnabled(enabled)
                        if case let .failure(error) = result {
                            loginItemError = error.localizedDescription
                        } else {
                            loginItemError = nil
                        }
                    }
                ))
                if let error = loginItemError {
                    Text("设置失败：\(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("外观") {
                Picker("主题", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("快捷键") {
                Text("全部功能的快捷键可在上方“快捷键”页统一设置，修改后立即生效。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsTab: some View {
        Form {
            Section("全局快捷键") {
                hotKeyRow(title: "剪贴板面板", binding: $settings.clipboardHotKey, systemHint: "")
                conflictHint(combo: settings.clipboardHotKey, name: "剪贴板面板")
                hotKeyRow(title: "触发截图", binding: $settings.screenshotTriggerHotKey, systemHint: "")
                conflictHint(combo: settings.screenshotTriggerHotKey, name: "截图触发")
                hotKeyRow(title: "截图翻译", binding: $settings.translateTriggerHotKey, systemHint: "")
                conflictHint(combo: settings.translateTriggerHotKey, name: "截图翻译")
                ForEach(FeatureShortcut.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        HotKeyRecorder(combo: Binding(
                            get: { settings.featureHotKeys[action.rawValue] ?? KeyCombo(keyCode: 0, carbonModifiers: 0, display: "未设置") },
                            set: { settings.setHotKey($0, for: action) }
                        ))
                        if settings.featureHotKeys[action.rawValue] != nil {
                            Button { settings.setHotKey(nil, for: action) } label: {
                                Image(systemName: "xmark.circle")
                            }.buttonStyle(.borderless).help("清除快捷键")
                        }
                    }
                    if let combo = settings.featureHotKeys[action.rawValue] {
                        conflictHint(combo: combo, name: action.title)
                    }
                }
            }
            Section("截图后操作（仅截图会话生效）") {
                hotKeyRow(title: "固定显示", binding: $settings.screenshotPinHotKey, systemHint: "")
                conflictHint(combo: settings.screenshotPinHotKey, name: "截图·固定显示")
                hotKeyRow(title: "复制", binding: $settings.screenshotCopyHotKey, systemHint: "")
                conflictHint(combo: settings.screenshotCopyHotKey, name: "截图·复制")
                hotKeyRow(title: "取消并丢弃", binding: $settings.screenshotDiscardHotKey, systemHint: "")
                conflictHint(combo: settings.screenshotDiscardHotKey, name: "截图·丢弃")
            }
            Section("状态") {
                Text(hotKeyStatusText).font(.caption)
                if let error = hotKeyManager.lastRegistrationError { Text(error).foregroundStyle(.orange) }
                Text(hotKeyDiagnosticsText).font(.caption)
                Text("点击按钮后按下含修饰键的组合；Esc 取消。新增功能默认未设置，设置后在后台也生效；亮度和声音每次调节 5%。橙色提示表示快捷键冲突。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var hotKeyStatusText: String {
        if hotKeyManager.isPaused {
            return "录制中，快捷键暂时停用"
        }
        if !hotKeyManager.isRegistered {
            return "注册失败，请更换组合后重试"
        }
        return "已注册 · 系统热键（免权限 · 全局生效）"
    }

    /// 按下快捷键后此处会更新：用于区分“没注册上”与“被其他软件抢占”。
    private var hotKeyDiagnosticsText: String {
        guard let last = hotKeyManager.lastFired else {
            return "启动后尚未捕获到按键"
        }
        let seconds = Int(Date().timeIntervalSince(last.at))
        let name = FeatureShortcut.allCases.first { $0.id == last.id }?.title
            ?? [HotKeyIDs.clipboardPanel: "剪贴板面板", HotKeyIDs.screenshotTrigger: "截图触发", HotKeyIDs.translateTrigger: "截图翻译"][last.id] ?? last.id
        return seconds < 60 ? "\(seconds) 秒前捕获（\(name)）" : "较久前捕获（\(name)）"
    }

    // MARK: - 剪贴板

    private var clipboardTab: some View {
        Form {
            Section("记录") {
                Toggle("启用剪贴板监听", isOn: $settings.clipboardEnabled)
                Toggle("忽略密码管理器等敏感应用", isOn: $settings.ignoreSensitiveApps)
                HStack {
                    Text("忽略的应用")
                    Spacer()
                    Text("\(settings.ignoredAppBundleIDs.count) 个")
                        .foregroundStyle(.secondary)
                    Button("编辑…") { showIgnoredApps = true }
                }
            }
            Section("清理") {
                Picker("历史上限", selection: $settings.maxHistoryItems) {
                    Text("100 条").tag(100)
                    Text("200 条").tag(200)
                    Text("500 条").tag(500)
                    Text("1000 条").tag(1000)
                    Text("不限制").tag(0)
                }
                Picker("自动清理", selection: $settings.retentionDays) {
                    Text("永不清理").tag(0)
                    Text("保留 1 天").tag(1)
                    Text("保留 7 天").tag(7)
                    Text("保留 30 天").tag(30)
                    Text("保留 90 天").tag(90)
                    Text("保留 365 天").tag(365)
                }
                Text("固定（收藏）的条目不受清理策略影响")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("交互") {
                Text("双击条目：有输入焦点时粘贴，否则仅复制到剪贴板")
                    .font(.caption).foregroundStyle(.secondary)
                Text("需要辅助功能权限；关闭时仅复制到剪贴板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showIgnoredApps) {
            IgnoredAppsEditor(bundleIDs: $settings.ignoredAppBundleIDs)
        }
    }

    // MARK: - 翻译

    private var translateTab: some View {
        Form {
            Section("AI 翻译服务") {
                Picker("服务商预设", selection: Binding(
                    get: {
                        // 匹配当前地址+模型，找不到归为自定义
                        TranslationSettings.presets.first {
                            $0.baseURL == translationSettings.apiBaseURL && $0.model == translationSettings.model
                        }?.id ?? "custom"
                    },
                    set: { id in
                        guard let preset = TranslationSettings.presets.first(where: { $0.id == id }) else { return }
                        translationSettings.apply(preset: preset)
                        translateTestState = .idle
                    }
                )) {
                    ForEach(TranslationSettings.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    Text("自定义").tag("custom")
                }
                TextField("API 地址（一般以 /v1 结尾）", text: $translationSettings.apiBaseURL)
                    .font(.system(size: 12, design: .monospaced))
                HStack(spacing: 6) {
                    if showAPIKey {
                        TextField("API 密钥（本地 Ollama 可留空）", text: $translationSettings.apiKey)
                            .font(.system(size: 12, design: .monospaced))
                    } else {
                        SecureField("API 密钥（本地 Ollama 可留空）", text: $translationSettings.apiKey)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    // 显隐切换：便于确认密钥粘贴是否完整
                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help(showAPIKey ? "隐藏密钥" : "显示密钥")
                    // 一键粘贴剪贴板中的密钥（⌘V 快捷键也随主菜单修复一并可用）
                    Button {
                        if let text = NSPasteboard.general.string(forType: .string)?
                            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                            translationSettings.apiKey = text
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("粘贴剪贴板中的密钥")
                }
                TextField("模型", text: $translationSettings.model)
                    .font(.system(size: 12, design: .monospaced))
                HStack {
                    Button("测试连接") {
                        testTranslationConnection()
                    }
                    .disabled(translateTestState == .testing)
                    if translateTestState == .testing {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在请求…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                switch translateTestState {
                case .success(let text):
                    Label("连接成功：\(text)", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                case .idle, .testing:
                    EmptyView()
                }
                Text("兼容 OpenAI Chat Completions 协议：OpenAI、DeepSeek、智谱 GLM、Moonshot 及本地 Ollama 均可直连。密钥仅保存在本机，用于向你选择的服务发起请求。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("翻译偏好") {
                Picker("默认目标语言", selection: $translationSettings.defaultTargetCode) {
                    ForEach(LanguageCatalog.targetOptions) { language in
                        Text(language.displayName).tag(language.code)
                    }
                }
                Stepper("请求超时 \(translationSettings.timeoutSeconds) 秒", value: $translationSettings.timeoutSeconds, in: 5...120, step: 5)
                Stepper("失败自动重试 \(translationSettings.maxRetries) 次", value: $translationSettings.maxRetries, in: 0...3)
                Stepper("历史记录上限 \(translationSettings.historyLimit) 条", value: $translationSettings.historyLimit, in: 20...500, step: 20)
            }
            Section("截图翻译") {
                HStack {
                    Text("触发快捷键（全局）")
                    Spacer()
                    HotKeyRecorder(combo: $settings.translateTriggerHotKey)
                }
                conflictHint(combo: settings.translateTriggerHotKey, name: "截图翻译")
                Text("按键或菜单栏右键「截图翻译」后拖拽框选区域，松开鼠标即自动识别并翻译。译文会直接覆盖在截取位置；底部可切换目标语言、复制原文或译文，并开启上下对照。文字识别在本机完成，仅原文会发送到所配置的 AI 服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("历史记录") {
                HStack {
                    Text("已保存")
                    Spacer()
                    Text("\(translationHistory.records.count) 条")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("打开文本翻译查看历史") {
                        onOpenTextTranslate()
                    }
                    Spacer()
                    Button("清空全部历史", role: .destructive) {
                        translationHistory.clearAll()
                    }
                    .disabled(translationHistory.records.isEmpty)
                }
                Text("历史（原文、译文、语言对、时间）仅保存在本机，可在文本翻译窗口中逐条删除。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func testTranslationConnection() {
        translateTestState = .testing
        let query = TranslationQuery(text: "Hello, world!", source: nil, target: LanguageCatalog.all[2])
        Task {
            do {
                let outcome = try await translationService.translate(query, settings: translationSettings)
                await MainActor.run {
                    translateTestState = .success("模型 \(outcome.model) 返回「\(String(outcome.translatedText.prefix(40)))」")
                }
            } catch let error as TranslationError {
                await MainActor.run {
                    translateTestState = .failure(error.errorDescription ?? "连接失败")
                }
            } catch {
                await MainActor.run {
                    translateTestState = .failure(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 菜单栏图标

    private var menuBarTab: some View {
        Form {
            Section("状态") {
                HStack {
                    Text("接管状态")
                    Spacer()
                    Text(menuBarController.isManaging ? "已接管" : "未接管")
                        .foregroundStyle(menuBarController.isManaging ? Color.green : Color.secondary)
                }
                HStack {
                    Text("辅助功能权限")
                    Spacer()
                    Text(menuBarController.accessibilityGranted ? "已授权" : "未授权")
                        .foregroundStyle(menuBarController.accessibilityGranted ? Color.green : Color.orange)
                    if !menuBarController.accessibilityGranted {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                if menuBarController.isManaging {
                    Button("停止接管并还原图标") {
                        menuBarController.disable()
                    }
                } else {
                    Button("接管菜单栏图标") {
                        menuBarController.enable()
                    }
                }
            }
            Section("说明") {
                Text("接管后，在面板的“菜单栏图标”页可以折叠/展开任意图标，并拖拽调整显隐优先级；菜单栏上会出现一个眼睛图标，点击即可展开或收起被折叠的区域。停止接管或退出应用时，所有图标会自动还原。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 滚轮方向

    private var scrollTab: some View {
        Form {
            Section("总开关") {
                Toggle("启用滚轮方向反转", isOn: Binding(
                    get: { settings.scrollReverseEnabled },
                    set: { enabled in
                        settings.scrollReverseEnabled = enabled
                        if enabled {
                            _ = scrollReverser.start()
                        } else {
                            scrollReverser.stop()
                        }
                    }
                ))
                HStack {
                    Text("状态")
                    Spacer()
                    Text(scrollStatusText)
                        .foregroundStyle(settings.scrollReverseEnabled && scrollReverser.isRunning ? Color.green : Color.secondary)
                }
                Text("开关即时生效，对所有应用全局生效，无需重启本工具或系统。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("按设备类型配置") {
                Toggle("反转鼠标滚轮（默认开启）", isOn: $settings.scrollReverseMouse)
                    .disabled(!settings.scrollReverseEnabled)
                Toggle("反转触控板滚动（默认关闭，保持自然滚动）", isOn: $settings.scrollReverseTrackpad)
                    .disabled(!settings.scrollReverseEnabled)
                Toggle("横向滚动同时反转", isOn: $settings.scrollReverseHorizontal)
                    .disabled(!settings.scrollReverseEnabled)
                Toggle("进阶：平滑滚轮鼠标按鼠标处理", isOn: $settings.scrollTreatSmoothWheelAsMouse)
                    .disabled(!settings.scrollReverseEnabled)
                Text("设备识别与 Scroll Reverser 一致：离散滚动判为鼠标；连续滚动结合「两指触摸手势 + 惯性相位」区分——触控板滚动必有两指触摸，妙控鼠标/罗技 MX 等平滑滚轮没有，自动归入鼠标。若个别鼠标仍被误判，再开启最后一项强制按鼠标处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("引擎诊断")
                    Spacer()
                    Text(scrollReverser.diagnosticsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("权限") {
                HStack {
                    Text("辅助功能权限")
                    Spacer()
                    Text(AXHelper.isTrusted() ? "已授权" : "未授权")
                        .foregroundStyle(AXHelper.isTrusted() ? Color.green : Color.orange)
                    if !AXHelper.isTrusted() {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                HStack {
                    Text("输入监控权限")
                    Spacer()
                    Text(InputMonitoringAccess.isGranted() ? "已授权" : "未授权")
                        .foregroundStyle(InputMonitoringAccess.isGranted() ? Color.green : Color.orange)
                    if !InputMonitoringAccess.isGranted() {
                        Button("请求授权") {
                            DispatchQueue.global(qos: .userInitiated).async {
                                InputMonitoringAccess.request()
                            }
                        }
                    }
                }
                Text("辅助功能权限必须授权（未授权时引擎会等待，勾选后自动生效，无需重启）。部分 macOS 版本上事件监听还需要输入监控权限：若下方诊断计数始终为 0，请点击「请求授权」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var scrollStatusText: String {
        if !settings.scrollReverseEnabled { return "已停止" }
        if !AXHelper.isTrusted() { return "等待辅助功能权限（授权后自动生效）" }
        return scrollReverser.isRunning ? "运行中" : "未运行"
    }

    // MARK: - 截图

    /// 当前全部快捷键条目（用于互相查重）。
    private var hotKeyEntries: [HotKeyConflict.Entry] {
        [
            .init(name: "剪贴板面板", combo: settings.clipboardHotKey),
            .init(name: "截图翻译", combo: settings.translateTriggerHotKey),
            .init(name: "截图触发", combo: settings.screenshotTriggerHotKey),
            .init(name: "截图·固定显示", combo: settings.screenshotPinHotKey),
            .init(name: "截图·复制", combo: settings.screenshotCopyHotKey),
            .init(name: "截图·丢弃", combo: settings.screenshotDiscardHotKey),
        ] + FeatureShortcut.allCases.compactMap { action in
            settings.featureHotKeys[action.rawValue].map { .init(name: action.title, combo: $0) }
        }
    }

    private func hotKeyRow(title: String, binding: Binding<KeyCombo>, systemHint: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            HotKeyRecorder(combo: binding)
        }
    }

    /// 组合冲突提示行（录制后立即显示）。
    @ViewBuilder
    private func conflictHint(combo: KeyCombo, name: String) -> some View {
        let conflicts = HotKeyConflict.describe(combo: combo, selfEntries: hotKeyEntries, excludingName: name)
        if !conflicts.isEmpty {
           ForEach(conflicts.indices, id: \.self) { index in
                    Label(conflicts[index], systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
        }
    }

    private var screenshotTab: some View {
        Form {
            Section("快捷键") {
                hotKeyRow(title: "触发截图（全局）", binding: $settings.screenshotTriggerHotKey, systemHint: "")
                conflictHint(combo: settings.screenshotTriggerHotKey, name: "截图触发")
                hotKeyRow(title: "固定显示最上面（截图后）", binding: $settings.screenshotPinHotKey, systemHint: "")
                conflictHint(combo: settings.screenshotPinHotKey, name: "截图·固定显示")
                hotKeyRow(title: "复制到剪贴板（截图后）", binding: $settings.screenshotCopyHotKey, systemHint: "")
                conflictHint(combo: settings.screenshotCopyHotKey, name: "截图·复制")
                hotKeyRow(title: "取消并丢弃（截图后）", binding: $settings.screenshotDiscardHotKey, systemHint: "")
                conflictHint(combo: settings.screenshotDiscardHotKey, name: "截图·丢弃")
                Text("点击右侧按钮后按下新组合完成录制（需含修饰键，Esc 取消）。与本工具其他快捷键或常见系统快捷键重复时会给出橙色提示，请更换组合后再使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("权限") {
                HStack {
                    Text("屏幕录制权限")
                    Spacer()
                    Text(ScreenCaptureService.hasPermission() ? "已授权" : "未授权")
                        .foregroundStyle(ScreenCaptureService.hasPermission() ? Color.green : Color.orange)
                    if !ScreenCaptureService.hasPermission() {
                        Button("打开系统设置") {
                            ScreenCaptureService.requestPermission()
                        }
                    }
                }
            }
            Section("固定中的贴图") {
                HStack {
                    Text("当前数量")
                    Spacer()
                    Text("\(screenshotCoordinator.pinnedCount) 张")
                        .foregroundStyle(.secondary)
                }
                Button("全部关闭") {
                    screenshotCoordinator.closeAllPinned()
                }
                .disabled(screenshotCoordinator.pinnedCount == 0)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var aboutTab: some View {
        Form {
            Section("关于 MacTools") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")
                        .foregroundStyle(.secondary)
                }
                Text("菜单栏工具合集：历史剪贴板管理（参考 Maccy）+ 状态栏图标收缩（参考 Ice）。使用 Swift / SwiftUI 构建，所有数据仅保存在本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("数据") {
                Button("清空全部剪贴板历史（含固定）", role: .destructive) {
                    clipboardStore.clearAll(keepingPinned: false)
                }
                Button("在访达中显示数据目录") {
                    NSWorkspace.shared.open(AppPaths.root)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 忽略应用名单编辑器。
struct IgnoredAppsEditor: View {
    @Binding var bundleIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var newID = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("忽略的应用（Bundle ID）")
                .font(.headline)
            List {
                ForEach(bundleIDs, id: \.self) { id in
                    HStack {
                        Text(id).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button {
                            bundleIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 160)
            HStack {
                TextField("com.example.app", text: $newID)
                    .textFieldStyle(.roundedBorder)
                Button("添加") {
                    let trimmed = newID.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, !bundleIDs.contains(trimmed) {
                        bundleIDs.append(trimmed)
                        newID = ""
                    }
                }
                .disabled(newID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420, height: 320)
    }
}
