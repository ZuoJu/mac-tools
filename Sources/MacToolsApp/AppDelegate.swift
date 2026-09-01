import AppKit
import Combine
import SwiftUI
import CoreKit
import ClipboardFeature
import MenuBarFeature
import ScrollFeature
import ScreenshotFeature
import TranslateFeature

/// 组合根：装配各功能模块、状态栏入口、面板、快捷键与设置。
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settings: SettingsStore!
    private var clipboardStore: ClipboardStore!
    private var monitor: ClipboardMonitor!
    private var menuBarController: MenuBarController!
    private var scrollReverser: ScrollReverser!
    private var screenshotCoordinator: ScreenshotCoordinator!
    private var translationSettings: TranslationSettings!
    private var translationService: TranslationService!
    private var translationHistory: TranslationHistoryStore!
    private var translationCoordinator: TranslationCoordinator!
    private var panelController: PanelController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 应用改名迁移：必须在访问任何设置/数据路径之前执行
        AppMigration.migrateIfNeeded()
        settings = .shared
        settings.theme.apply()

        clipboardStore = ClipboardStore()
        clipboardStore.limitsProvider = { [weak self] in
            (self?.settings.maxHistoryItems ?? 500, self?.settings.retentionDays ?? 0)
        }
        monitor = ClipboardMonitor()
        monitor.ignoreSensitiveApps = settings.ignoreSensitiveApps
        monitor.extraIgnoredBundleIDs = Set(settings.ignoredAppBundleIDs)
        monitor.onCaptured = { [weak self] item in
            self?.clipboardStore.record(item)
        }

        menuBarController = MenuBarController()
        scrollReverser = ScrollReverser()
        screenshotCoordinator = ScreenshotCoordinator()

        translationSettings = TranslationSettings()
        translationService = TranslationService()
        translationHistory = TranslationHistoryStore()
        translationHistory.limitsProvider = { [weak self] in
            self?.translationSettings.historyLimit ?? 100
        }
        translationCoordinator = TranslationCoordinator(service: translationService)
        translationCoordinator.settingsProvider = { [weak self] in
            self?.translationSettings
        }
        translationCoordinator.history = translationHistory
        translationHistory.load()

        panelController = PanelController(
            rootView: RootPanelView(
                clipStore: clipboardStore,
                settings: settings,
                onCopyItem: { [weak self] item in self?.handleCopy(item) },
                onOpenSettings: { [weak self] in self?.openSettings() }
            )
        )
        panelController.onShow = {
            NotificationCenter.default.post(name: .panelDidShow, object: nil)
        }

        setupStatusItem()
        setupHotKey()
        // 主菜单：文本框 ⌘V/⌘C 等键等效依赖 Edit 菜单项（无菜单栏应用必建）
        NSApp.mainMenu = AppMenus.makeMainMenu { [weak self] in
            self?.openSettings()
        }
        setupSettingsObservers()
        syncScrollFeature()
        watchScrollSettings()

        clipboardStore.load()
        if settings.clipboardEnabled {
            monitor.start()
        }
        // 上次退出时处于接管状态 → 自动恢复菜单栏管理
        menuBarController.restoreIfNeeded()

        // 调试/自动化测试辅助：启动后自动打开面板或设置窗口
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--debug-open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                if arguments.contains("--debug-stay-open") {
                    self.panelController.panel.hidesOnDeactivate = false
                    self.panelController.debugAutoCloseDisabled = true
                }
                self.panelController.toggle(statusItemButton: self.statusItem?.button)
            }
        }
        if arguments.contains("--debug-open-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.openSettings()
            }
        }
        // 调试/自动化测试辅助：周期性把引擎状态导出为 JSON 文件
        if let index = arguments.firstIndex(of: "--debug-dump-state"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            startStateDumping(to: path)
        }
    }

    private var stateDumpTimer: Timer?

    private func startStateDumping(to path: String) {
        stateDumpTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state: [String: Any] = [
                "scroll": self.scrollReverser.debugSnapshot(),
                "hotkey": HotKeyManager.shared.debugSnapshot(),
                "mainMenuEditItems": NSApp.mainMenu?
                    .items.first { $0.submenu?.title == "编辑" }?
                    .submenu?.items.count ?? 0,
                "scrollSettings": [
                    "enabled": self.settings.scrollReverseEnabled,
                    "reverseMouse": self.settings.scrollReverseMouse,
                    "reverseTrackpad": self.settings.scrollReverseTrackpad,
                    "reverseHorizontal": self.settings.scrollReverseHorizontal,
                    "treatSmoothAsMouse": self.settings.scrollTreatSmoothWheelAsMouse,
                ],
                "at": Date().timeIntervalSince1970,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stateDumpTimer = timer
    }

    func windowWillClose(_ notification: Notification) {
        // 功能窗口关闭后从缓存移除，下次重新创建
        guard let window = notification.object as? NSWindow else { return }
        moduleWindows = moduleWindows.filter { $0.value !== window }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 用户可能刚在系统设置里授予了权限：重新评估快捷键与滚轮引擎
        HotKeyManager.shared.reevaluate()
        syncScrollFeature()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        menuBarController?.restorePositions()
        scrollReverser?.destroy()
        screenshotCoordinator?.closeAllPinned()
        // 剪贴板历史是防抖落盘（0.5s），退出前强制刷盘避免最后几条丢失
        clipboardStore?.persistNowSync()
    }

    // MARK: - 状态栏入口

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: -1) // NSStatusItemVariableLength
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "MacTools")
            button.image?.size = NSSize(width: 18, height: 18)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            button.action = #selector(statusItemClicked)
            button.toolTip = "MacTools（左键面板 / 右键菜单）"
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            panelController.toggle(statusItemButton: statusItem?.button)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let clipboardItem = NSMenuItem(title: "历史剪贴板（左键 / \(settings.clipboardHotKey.display)）", action: #selector(panelItemClicked), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        let translateShotItem = NSMenuItem(title: "截图翻译（\(settings.translateTriggerHotKey.display)）", action: #selector(translateShotClicked), keyEquivalent: "")
        translateShotItem.target = self
        translateShotItem.image = NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: "截图翻译")
        menu.addItem(translateShotItem)
        menu.addItem(.separator())

        for module in ModuleFeature.allCases {
            let item = NSMenuItem(title: module.menuTitle, action: #selector(moduleItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = ModuleFeature.allCases.firstIndex(of: module) ?? 0
            item.image = NSImage(systemSymbolName: module.symbolName, accessibilityDescription: module.menuTitle)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let settingsMenuItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 MacTools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: (statusItem?.button?.bounds.height ?? 24) + 4),
            in: statusItem?.button
        )
    }

    @objc private func panelItemClicked() {
        panelController.toggle(statusItemButton: statusItem?.button)
    }

    @objc private func translateShotClicked() {
        translationCoordinator.startCaptureTranslate()
    }

    @objc private func moduleItemClicked(_ sender: NSMenuItem) {
        guard let module = ModuleFeature(rawValue: sender.tag) else { return }
        openModuleWindow(module)
    }

    // MARK: - 快捷键

    private func setupHotKey() {
        HotKeyManager.shared.onAction = { [weak self] id in
            guard let self else { return }
            switch id {
            case HotKeyIDs.clipboardPanel:
                self.panelController.toggle(statusItemButton: self.statusItem?.button)
            case HotKeyIDs.screenshotTrigger:
                self.screenshotCoordinator.startCapture(
                    pinCombo: self.settings.screenshotPinHotKey,
                    copyCombo: self.settings.screenshotCopyHotKey,
                    discardCombo: self.settings.screenshotDiscardHotKey
                )
            case HotKeyIDs.translateTrigger:
                self.translationCoordinator.startCaptureTranslate()
            default:
                break
            }
        }
        settings.applyHotKeysNow()
    }

    private func setupSettingsObservers() {
        settings.$clipboardEnabled
            .dropFirst()
            .sink { [weak self] enabled in
                enabled ? self?.monitor.start() : self?.monitor.stop()
            }
            .store(in: &cancellables)

        settings.$ignoreSensitiveApps
            .dropFirst()
            .sink { [weak self] ignore in
                self?.monitor.ignoreSensitiveApps = ignore
            }
            .store(in: &cancellables)

        settings.$ignoredAppBundleIDs
            .dropFirst()
            .sink { [weak self] ids in
                self?.monitor.extraIgnoredBundleIDs = Set(ids)
            }
            .store(in: &cancellables)
    }

    // MARK: - 滚轮方向反转

    /// 把设置同步到反转引擎并按总开关启停（任何相关设置变化都会调用，实时生效）。
    private func syncScrollFeature() {
        scrollReverser.updatePreferences(
            reverseMouse: settings.scrollReverseMouse,
            reverseTrackpad: settings.scrollReverseTrackpad,
            reverseHorizontal: settings.scrollReverseHorizontal,
            treatContinuousAsMouse: settings.scrollTreatSmoothWheelAsMouse
        )
        if settings.scrollReverseEnabled {
            if !scrollReverser.isRunning {
                _ = scrollReverser.start()
            }
        } else {
            scrollReverser.stop()
        }
    }

    private func watchScrollSettings() {
        for publisher in [
            settings.$scrollReverseEnabled,
            settings.$scrollReverseMouse,
            settings.$scrollReverseTrackpad,
            settings.$scrollReverseHorizontal,
            settings.$scrollTreatSmoothWheelAsMouse,
        ] {
            publisher
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncScrollFeature() }
                .store(in: &cancellables)
        }
    }

    // MARK: - 剪贴板复制交互

    private func handleCopy(_ item: ClipboardItem) {
        clipboardStore.copyToPasteboard(item)
        monitor.suppressCurrentChange()
        panelController.close()
        if settings.autoPasteOnClick {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                Paster.pasteToActiveApp()
            }
        }
    }

    // MARK: - 功能模块独立窗口

    /// 可从右键菜单打开的功能面板。
    enum ModuleFeature: Int, CaseIterable {
        case translate
        case menuBar
        case scroll
        case screenshot

        var menuTitle: String {
            switch self {
            case .translate: return "文本翻译…"
            case .menuBar: return "菜单栏图标管理…"
            case .scroll: return "滚轮方向设置…"
            case .screenshot: return "截图…"
            }
        }

        var windowTitle: String {
            switch self {
            case .translate: return "文本翻译"
            case .menuBar: return "菜单栏图标管理"
            case .scroll: return "滚轮方向"
            case .screenshot: return "截图"
            }
        }

        var symbolName: String {
            switch self {
            case .translate: return "translate"
            case .menuBar: return "menubar.rectangle"
            case .scroll: return "computermouse"
            case .screenshot: return "camera.viewfinder"
            }
        }
    }

    private var moduleWindows: [ModuleFeature: NSWindow] = [:]

    private func openModuleWindow(_ module: ModuleFeature) {
        panelController.close()
        if let existing = moduleWindows[module] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let rootView: AnyView
        switch module {
        case .translate:
            rootView = AnyView(TextTranslatePanelView(
                settings: translationSettings,
                history: translationHistory,
                service: translationService
            ))
        case .menuBar:
            rootView = AnyView(MenuBarPanelView(controller: menuBarController))
        case .scroll:
            rootView = AnyView(ScrollPanelView(reverser: scrollReverser, settings: settings))
        case .screenshot:
            rootView = AnyView(ScreenshotPanelView(coordinator: screenshotCoordinator, settings: settings))
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = module.windowTitle
        window.isReleasedWhenClosed = false
        window.center()
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.delegate = self
        moduleWindows[module] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 设置窗口

    @objc func openSettings() {
        let window: NSWindow
        if let existing = settingsWindow {
            window = existing
        } else {
            window = makeSettingsWindow()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTools 设置"
        window.isReleasedWhenClosed = false
        window.center()
        let hostingView = NSHostingView(
            rootView: SettingsView(
                settings: settings,
                clipboardStore: clipboardStore,
                menuBarController: menuBarController,
                scrollReverser: scrollReverser,
                screenshotCoordinator: screenshotCoordinator,
                translationSettings: translationSettings,
                translationHistory: translationHistory,
                translationService: translationService,
                onOpenTextTranslate: { [weak self] in
                    self?.openModuleWindow(.translate)
                }
            )
        )
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        return window
    }
}
