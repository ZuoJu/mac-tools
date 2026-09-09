import Carbon.HIToolbox
import Foundation
import AppKit

/// 应用全局设置（UserDefaults 持久化）。
/// 所有属性都在主线程访问；didSet 负责持久化与即时生效（主题、快捷键）。
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    private enum Keys {
        static let theme = "theme"
        static let clipboardEnabled = "clipboard.enabled"
        static let maxHistoryItems = "clipboard.maxHistoryItems"
        static let retentionDays = "clipboard.retentionDays"
        static let autoPasteOnClick = "clipboard.autoPasteOnClick"
        static let ignoreSensitiveApps = "clipboard.ignoreSensitiveApps"
        static let ignoredAppBundleIDs = "clipboard.ignoredAppBundleIDs"
        static let clipboardHotKey = "clipboard.hotKey"
        static let scrollReverseEnabled = "scroll.reverseEnabled"
        static let scrollReverseMouse = "scroll.reverseMouse"
        static let scrollReverseTrackpad = "scroll.reverseTrackpad"
        static let scrollReverseHorizontal = "scroll.reverseHorizontal"
        static let scrollTreatSmoothWheelAsMouse = "scroll.treatSmoothWheelAsMouse"
        static let screenshotTriggerHotKey = "screenshot.triggerHotKey"
        static let screenshotPinHotKey = "screenshot.pinHotKey"
        static let screenshotCopyHotKey = "screenshot.copyHotKey"
        static let screenshotDiscardHotKey = "screenshot.discardHotKey"
        static let translateTriggerHotKey = "translate.triggerHotKey"
        static let scrollClassificationV2Migrated = "scroll.classificationV2Migrated"
    }

    private let defaults: UserDefaults

    @Published public var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme); theme.apply() }
    }
    @Published public var clipboardEnabled: Bool {
        didSet { defaults.set(clipboardEnabled, forKey: Keys.clipboardEnabled) }
    }
    /// 历史上限，0 表示不限制。
    @Published public var maxHistoryItems: Int {
        didSet { defaults.set(maxHistoryItems, forKey: Keys.maxHistoryItems) }
    }
    /// 自动清理：保留天数，0 表示永不清理。
    @Published public var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) }
    }
    /// 点击条目复制后，向前台应用模拟 ⌘V 粘贴（需要辅助功能权限）。
    @Published public var autoPasteOnClick: Bool {
        didSet { defaults.set(autoPasteOnClick, forKey: Keys.autoPasteOnClick) }
    }
    @Published public var ignoreSensitiveApps: Bool {
        didSet { defaults.set(ignoreSensitiveApps, forKey: Keys.ignoreSensitiveApps) }
    }
    @Published public var ignoredAppBundleIDs: [String] {
        didSet { defaults.set(ignoredAppBundleIDs, forKey: Keys.ignoredAppBundleIDs) }
    }
    @Published public var clipboardHotKey: KeyCombo {
        didSet {
            persistHotKey(clipboardHotKey, forKey: Keys.clipboardHotKey)
            HotKeyManager.shared.register(id: HotKeyIDs.clipboardPanel, combo: clipboardHotKey)
        }
    }
    /// 滚轮方向反转总开关（实时启停，重启后恢复）。
    @Published public var scrollReverseEnabled: Bool {
        didSet { defaults.set(scrollReverseEnabled, forKey: Keys.scrollReverseEnabled) }
    }
    /// 反转鼠标滚轮（离散滚动事件）。
    @Published public var scrollReverseMouse: Bool {
        didSet { defaults.set(scrollReverseMouse, forKey: Keys.scrollReverseMouse) }
    }
    /// 反转触控板滚动（连续滚动事件），默认关闭以保持系统自然滚动。
    @Published public var scrollReverseTrackpad: Bool {
        didSet { defaults.set(scrollReverseTrackpad, forKey: Keys.scrollReverseTrackpad) }
    }
    /// 已反转设备的横向滚动是否同时反转。
    @Published public var scrollReverseHorizontal: Bool {
        didSet { defaults.set(scrollReverseHorizontal, forKey: Keys.scrollReverseHorizontal) }
    }
    /// 进阶：把平滑滚轮鼠标发出的连续事件也按鼠标偏好处理（默认关）。
    @Published public var scrollTreatSmoothWheelAsMouse: Bool {
        didSet { defaults.set(scrollTreatSmoothWheelAsMouse, forKey: Keys.scrollTreatSmoothWheelAsMouse) }
    }
    /// 截图触发快捷键（全局，默认 ⌥⇧S）。
    @Published public var screenshotTriggerHotKey: KeyCombo {
        didSet {
            persistHotKey(screenshotTriggerHotKey, forKey: Keys.screenshotTriggerHotKey)
            HotKeyManager.shared.register(id: HotKeyIDs.screenshotTrigger, combo: screenshotTriggerHotKey)
        }
    }
    /// 截图会话内：固定显示快捷键（默认 ⌥⇧P，仅会话期间生效，不全局注册）。
    @Published public var screenshotPinHotKey: KeyCombo {
        didSet { persistHotKey(screenshotPinHotKey, forKey: Keys.screenshotPinHotKey) }
    }
    /// 截图会话内：复制到剪贴板快捷键（默认 ⌥⇧C，仅会话期间生效）。
    @Published public var screenshotCopyHotKey: KeyCombo {
        didSet { persistHotKey(screenshotCopyHotKey, forKey: Keys.screenshotCopyHotKey) }
    }
    /// 截图会话内：取消并丢弃快捷键（默认 ⌥⇧X，仅会话期间生效）。
    @Published public var screenshotDiscardHotKey: KeyCombo {
        didSet { persistHotKey(screenshotDiscardHotKey, forKey: Keys.screenshotDiscardHotKey) }
    }
    /// 截图翻译触发快捷键（全局，默认 ⌥⇧T）。
    @Published public var translateTriggerHotKey: KeyCombo {
        didSet {
            persistHotKey(translateTriggerHotKey, forKey: Keys.translateTriggerHotKey)
            HotKeyManager.shared.register(id: HotKeyIDs.translateTrigger, combo: translateTriggerHotKey)
        }
    }

    @Published public private(set) var featureHotKeys: [String: KeyCombo]

    public func setHotKey(_ combo: KeyCombo?, for action: FeatureShortcut) {
        featureHotKeys[action.rawValue] = combo
        if let data = try? JSONEncoder().encode(featureHotKeys) {
            defaults.set(data, forKey: "shortcuts.features")
        }
        if let combo { HotKeyManager.shared.register(id: action.id, combo: combo) }
        else { HotKeyManager.shared.unregister(id: action.id) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        featureHotKeys = defaults.data(forKey: "shortcuts.features")
            .flatMap { try? JSONDecoder().decode([String: KeyCombo].self, from: $0) } ?? [:]

        theme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        clipboardEnabled = defaults.object(forKey: Keys.clipboardEnabled) as? Bool ?? true
        maxHistoryItems = defaults.object(forKey: Keys.maxHistoryItems) as? Int ?? 500
        retentionDays = defaults.object(forKey: Keys.retentionDays) as? Int ?? 0
        autoPasteOnClick = defaults.object(forKey: Keys.autoPasteOnClick) as? Bool ?? false
        ignoreSensitiveApps = defaults.object(forKey: Keys.ignoreSensitiveApps) as? Bool ?? true
        ignoredAppBundleIDs = defaults.stringArray(forKey: Keys.ignoredAppBundleIDs) ?? []

        if let data = defaults.data(forKey: Keys.clipboardHotKey),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            clipboardHotKey = combo
        } else {
            clipboardHotKey = .defaultClipboard
        }

        scrollReverseEnabled = defaults.object(forKey: Keys.scrollReverseEnabled) as? Bool ?? false
        scrollReverseMouse = defaults.object(forKey: Keys.scrollReverseMouse) as? Bool ?? true
        scrollReverseTrackpad = defaults.object(forKey: Keys.scrollReverseTrackpad) as? Bool ?? false
        scrollReverseHorizontal = defaults.object(forKey: Keys.scrollReverseHorizontal) as? Bool ?? false
        scrollTreatSmoothWheelAsMouse = defaults.object(forKey: Keys.scrollTreatSmoothWheelAsMouse) as? Bool ?? false

        screenshotTriggerHotKey = Self.readHotKey(defaults, forKey: Keys.screenshotTriggerHotKey) ?? KeyCombo(
            keyCode: 1, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧S")
        screenshotPinHotKey = Self.readHotKey(defaults, forKey: Keys.screenshotPinHotKey) ?? KeyCombo(
            keyCode: 35, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧P")
        screenshotCopyHotKey = Self.readHotKey(defaults, forKey: Keys.screenshotCopyHotKey) ?? KeyCombo(
            keyCode: 8, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧C")
        screenshotDiscardHotKey = Self.readHotKey(defaults, forKey: Keys.screenshotDiscardHotKey) ?? KeyCombo(
            keyCode: 7, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧X")
        translateTriggerHotKey = Self.readHotKey(defaults, forKey: Keys.translateTriggerHotKey) ?? KeyCombo(
            keyCode: 17, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧T")

        // 一次性迁移：旧版把平滑滚轮鼠标的连续事件误判为触控板，用户为求
        // 生往往把偏好翻成了「反转触控板、不反转鼠标」。新版判别已与
        // Scroll Reverser 对齐（平滑滚轮归入鼠标），把被翻反的偏好恢复默认。
        if !defaults.bool(forKey: Keys.scrollClassificationV2Migrated) {
            defaults.set(true, forKey: Keys.scrollClassificationV2Migrated)
            if defaults.object(forKey: Keys.scrollReverseMouse) != nil
                || defaults.object(forKey: Keys.scrollReverseTrackpad) != nil {
                scrollReverseMouse = true
                scrollReverseTrackpad = false
                defaults.set(true, forKey: Keys.scrollReverseMouse)
                defaults.set(false, forKey: Keys.scrollReverseTrackpad)
            }
        }
    }

    private func persistHotKey(_ combo: KeyCombo, forKey key: String) {
        if let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: key)
        }
    }

    private static func readHotKey(_ defaults: UserDefaults, forKey key: String) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    /// 组合根完成回调接线后调用，注册当前全部全局快捷键。
    public func applyHotKeysNow() {
        for action in FeatureShortcut.allCases {
            if let combo = featureHotKeys[action.rawValue] { HotKeyManager.shared.register(id: action.id, combo: combo) }
            else { HotKeyManager.shared.unregister(id: action.id) }
        }
        HotKeyManager.shared.register(id: HotKeyIDs.clipboardPanel, combo: clipboardHotKey)
        HotKeyManager.shared.register(id: HotKeyIDs.screenshotTrigger, combo: screenshotTriggerHotKey)
        HotKeyManager.shared.register(id: HotKeyIDs.translateTrigger, combo: translateTriggerHotKey)
    }
}
