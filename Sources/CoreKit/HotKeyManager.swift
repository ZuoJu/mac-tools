import AppKit
import Carbon.HIToolbox
import Foundation

/// 应用内快捷键的稳定 ID（全局注册的走 HotKeyManager；截图会话内的操作键走本地监视）。
public enum HotKeyIDs {
    public static let clipboardPanel = "clipboardPanel"
    public static let screenshotTrigger = "screenshotTrigger"
    public static let screenshotPin = "screenshotPin"
    public static let screenshotCopy = "screenshotCopy"
    public static let screenshotDiscard = "screenshotDiscard"
    public static let translateTrigger = "translateTrigger"
}

/// 快捷键冲突检测：在我们自己注册的组合之间、以及常见系统快捷键之间查重。
public enum HotKeyConflict {
    public struct Entry {
        public let name: String
        public let combo: KeyCombo
        public init(name: String, combo: KeyCombo) {
            self.name = name
            self.combo = combo
        }
    }

    /// 按键是否相同（keyCode + 修饰键）。
    public static func isSame(_ a: KeyCombo, _ b: KeyCombo) -> Bool {
        a.keyCode == b.keyCode && a.carbonModifiers == b.carbonModifiers
    }

    /// 在给定条目中查找与目标组合重复的项，返回其名称。
    public static func duplicate(of combo: KeyCombo, in entries: [Entry]) -> String? {
        entries.first { isSame(combo, $0.combo) }?.name
    }

    /// 常见系统/全局快捷键表（防止用户录出必然冲突的组合）。
    public static let knownSystemShortcuts: [Entry] = [
        .init(name: "系统：拷贝 ⌘C", combo: KeyCombo(keyCode: 8, carbonModifiers: UInt32(cmdKey), display: "⌘C")),
        .init(name: "系统：粘贴 ⌘V", combo: KeyCombo(keyCode: 9, carbonModifiers: UInt32(cmdKey), display: "⌘V")),
        .init(name: "系统：剪切 ⌘X", combo: KeyCombo(keyCode: 7, carbonModifiers: UInt32(cmdKey), display: "⌘X")),
        .init(name: "系统：撤销 ⌘Z", combo: KeyCombo(keyCode: 6, carbonModifiers: UInt32(cmdKey), display: "⌘Z")),
        .init(name: "系统：退出应用 ⌘Q", combo: KeyCombo(keyCode: 12, carbonModifiers: UInt32(cmdKey), display: "⌘Q")),
        .init(name: "系统：关闭窗口 ⌘W", combo: KeyCombo(keyCode: 13, carbonModifiers: UInt32(cmdKey), display: "⌘W")),
        .init(name: "系统：截图（全屏）⌘⇧3", combo: KeyCombo(keyCode: 20, carbonModifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧3")),
        .init(name: "系统：截图（区域）⌘⇧4", combo: KeyCombo(keyCode: 21, carbonModifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧4")),
        .init(name: "系统：截图与录屏 ⌘⇧5", combo: KeyCombo(keyCode: 23, carbonModifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧5")),
        .init(name: "系统：聚焦搜索 ⌘空格", combo: KeyCombo(keyCode: 49, carbonModifiers: UInt32(cmdKey), display: "⌘空格")),
        .init(name: "系统：切换输入法 ⌃空格", combo: KeyCombo(keyCode: 49, carbonModifiers: UInt32(controlKey), display: "⌃空格")),
    ]

    /// 与系统快捷键冲突则返回描述，否则 nil。
    public static func systemConflict(of combo: KeyCombo) -> String? {
        knownSystemShortcuts.first { isSame(combo, $0.combo) }?.name
    }

    /// 汇总某个组合的全部冲突描述（自身重复 + 系统快捷键）。
    public static func describe(
        combo: KeyCombo,
        selfEntries: [Entry],
        excludingName excluded: String? = nil
    ) -> [String] {
        var messages: [String] = []
        if let name = duplicate(of: combo, in: selfEntries.filter { $0.name != excluded }) {
            messages.append("与「\(name)」重复，请更换")
        }
        if let name = systemConflict(of: combo) {
            messages.append("与「\(name)」冲突，可能被系统拦截")
        }
        return messages
    }
}

/// 全局快捷键管理：Carbon RegisterEventHotKey 单引擎。
///
/// 与 Maccy（sindresorhus/KeyboardShortcuts）同款方案：系统级热键注册，
/// 不需要任何隐私权限，应用在后台/其他软件聚焦时同样触发，命中组合会被
/// 系统吞掉不会再传给前台应用。
///
/// 旧实现曾把 CGEventTap 键盘拦截作为主引擎、Carbon 只做兜底：但键盘 tap
/// 在未授予「输入监控」权限时能创建成功却永远收不到事件（macOS 10.15+
/// 的静默失败），一旦误判 tap 可用就会注销 Carbon，导致快捷键只在自家
/// 窗口聚焦时生效。故整体改为 Carbon 常驻。
public final class HotKeyManager: ObservableObject {
    public static let shared = HotKeyManager()

    /// 是否有任一组合注册成功。
    @Published public private(set) var isRegistered = false
    /// 最近一次同步注册结果（测试/诊断用；isRegistered 为异步发布版本）。
    public private(set) var lastRegistrationSucceeded = false
    /// 注册失败的原因（例如组合被其他应用占用），供设置页展示。
    @Published public private(set) var lastRegistrationError: String?
    /// 最近一次命中的组合（设置页诊断“按键到底有没有进来”）。
    @Published public private(set) var lastFired: (id: String, at: Date)?
    /// 触发去抖：按住按键不放时系统热键随键盘重复率连续触发，250ms 内只算一次。
    private var lastFireAt: [String: Date] = [:]

    /// 录制新快捷键时暂停热键：否则当前已注册的组合会被系统吞掉，
    /// 录制器永远录不到自己（KeyboardShortcuts 的 isPaused 同款处理）。
    private var paused = false

    /// 动作回调：参数为注册时的 id。
    public var onAction: ((String) -> Void)?

    private var carbonRefs: [String: EventHotKeyRef] = [:]
    private var idByNumeric: [UInt32: String] = [:]
    private var registeredCombos: [String: KeyCombo] = [:]
    private var nextNumericID: UInt32 = 1
    private var handlerInstalled = false
    private let signature: FourCharCode = 0x4D43544C // "MCTL"
    private let lock = NSLock()

    private init() {}

    // MARK: - 注册

    /// 注册/更新一个组合。已存在的 id 会被替换。
    public func register(id: String, combo: KeyCombo) {
        lock.lock()
        registeredCombos[id] = combo
        lock.unlock()
        refresh()
    }

    public func unregister(id: String) {
        lock.lock()
        registeredCombos[id] = nil
        lock.unlock()
        refresh()
    }

    /// 权限状态等外部条件变化时重算一遍注册（Carbon 不依赖权限，此处只是幂等刷新）。
    public func reevaluate() {
        refresh()
    }

    /// 调试/自动化验证用：注册状态快照。
    public func debugSnapshot() -> [String: Any] {
        lock.lock()
        let comboCount = registeredCombos.count
        lock.unlock()
        var snapshot: [String: Any] = [
            "isRegistered": isRegistered,
            "registeredCombos": comboCount,
        ]
        if let error = lastRegistrationError { snapshot["error"] = error }
        if let fired = lastFired {
            snapshot["lastFiredId"] = fired.id
            snapshot["lastFiredAt"] = fired.at.timeIntervalSince1970
        }
        return snapshot
    }

    /// 暂停/恢复全部热键（快捷键录制期间暂停，避免组合被自己吞掉）。
    public func setPaused(_ paused: Bool) {
        lock.lock()
        self.paused = paused
        lock.unlock()
        refresh()
    }

    /// 重新注册全部组合：先注销旧的，再按当前注册表逐个注册。
    private func refresh() {
        teardownCarbon()
        lock.lock()
        let paused = self.paused
        let combos = registeredCombos
        lock.unlock()

        guard !combos.isEmpty else {
            publish(registered: false, error: nil)
            lastRegistrationSucceeded = false
            return
        }
        guard !paused else {
            // 暂停期间不注册，录制完成后调用 setPaused(false) 会重新注册
            publish(registered: false, error: nil)
            lastRegistrationSucceeded = false
            return
        }

        installCarbonHandler()
        var registered = false
        var failures: [String] = []
        if let target = GetEventDispatcherTarget() {
            for (id, combo) in combos {
                let numeric = nextNumericID
                nextNumericID += 1
                let hotKeyID = EventHotKeyID(signature: signature, id: numeric)
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, target, 0, &ref)
                if status == noErr, let ref {
                    carbonRefs[id] = ref
                    lock.lock()
                    idByNumeric[numeric] = id
                    lock.unlock()
                    registered = true
                } else {
                    // 常见原因：同一组合已被其他工具（或本应用旧实例）注册
                    failures.append("\(combo.display)（\(id)）注册失败：可能被其他应用占用，请更换组合")
                }
            }
        } else {
            failures.append("系统热键服务不可用")
        }
        publish(registered: registered, error: failures.first)
        lastRegistrationSucceeded = registered
    }

    private func publish(registered: Bool, error: String?) {
        if Thread.isMainThread {
            isRegistered = registered
            lastRegistrationError = error
        } else {
            DispatchQueue.main.async {
                self.isRegistered = registered
                self.lastRegistrationError = error
            }
        }
    }

    private func teardownCarbon() {
        for (_, ref) in carbonRefs {
            UnregisterEventHotKey(ref)
        }
        carbonRefs.removeAll()
        lock.lock()
        idByNumeric.removeAll()
        lock.unlock()
    }

    // MARK: - Carbon 系统热键

    /// 事件分发目标上安装一次 kEventHotKeyPressed 处理器（KeyboardShortcuts 同款目标）。
    private func installCarbonHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        guard let target = GetEventDispatcherTarget() else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            target,
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                if hotKeyID.signature == manager.signature, let id = manager.idByNumeric[hotKeyID.id] {
                    manager.fire(id: id)
                }
                return noErr
            },
            1,
            &eventType,
            context,
            nil
        )
    }

    fileprivate func fire(id: String) {
        let deliver: () -> Void = { [weak self] in
            guard let self else { return }
            let now = Date()
            if let last = self.lastFireAt[id], now.timeIntervalSince(last) < 0.25 {
                return // 按键重复：同一组合 250ms 内只触发一次
            }
            self.lastFireAt[id] = now
            self.lastFired = (id, now)
            self.onAction?(id)
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }
}

/// 全局快捷键组合（Carbon keyCode + 修饰键）。
public struct KeyCombo: Codable, Equatable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    /// 展示用文本，如 "⌘⇧V"。录制时生成，避免运行时做 keyCode 转换。
    public var display: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    /// 剪贴板面板默认快捷键 ⌥⇧V（V = kVK_ANSI_V = 9）。
    /// 刻意与 Maccy 默认的 ⌘⇧V 区分，避免两个工具争抢同一组合。
    public static let defaultClipboard = KeyCombo(
        keyCode: 9,
        carbonModifiers: UInt32(optionKey | shiftKey),
        display: "⌥⇧V"
    )

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    /// 纯函数：判定一次按键是否命中组合（修饰键需精确匹配，多按 Fn 等不算）。
    public static func shouldFire(
        keyCode: Int64,
        flagsRaw: UInt64,
        wantKeyCode: UInt32,
        wantModifiers: UInt32
    ) -> Bool {
        guard keyCode == Int64(wantKeyCode) else { return false }
        // 修饰键位于第 16~23 位（alpha/shift/ctrl/opt/cmd/num/help/fn），只比较这一段
        let modifierMask = CGEventFlags(rawValue: 0x00FF_FFFF & 0x00FF_0000)
        let flags = CGEventFlags(rawValue: flagsRaw).intersection(modifierMask)
        var want: CGEventFlags = []
        if wantModifiers & UInt32(cmdKey) != 0 { want.insert(.maskCommand) }
        if wantModifiers & UInt32(shiftKey) != 0 { want.insert(.maskShift) }
        if wantModifiers & UInt32(optionKey) != 0 { want.insert(.maskAlternate) }
        if wantModifiers & UInt32(controlKey) != 0 { want.insert(.maskControl) }
        return flags == want
    }
}
