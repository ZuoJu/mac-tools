import AppKit
import ApplicationServices
import CoreGraphics
import CoreKit
import Foundation

// MARK: - SPI（Scroll Reverser 同款）

/// CGEvent 内部携带 IOHIDEvent；改写滚动增量时需同步改写 IOHID 层，
/// 否则部分设备（妙控鼠标等平滑滚动）会丢失连续滚动效果。
@_silgen_name("CGEventCopyIOHIDEvent")
private func CGEventCopyIOHIDEvent(_ event: CGEvent) -> OpaquePointer?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: OpaquePointer, _ field: UInt32) -> Double

@_silgen_name("IOHIDEventSetFloatValue")
private func IOHIDEventSetFloatValue(_ event: OpaquePointer, _ field: UInt32, _ value: Double)

@_silgen_name("CFRelease")
private func cfRelease(_ pointer: OpaquePointer?)

/// IOHIDEventFieldBase(kIOHIDEventTypeScroll) = 6 << 16
private let kIOHIDEventFieldScrollX: UInt32 = (6 << 16) | 0
private let kIOHIDEventFieldScrollY: UInt32 = (6 << 16) | 1

/// kCGEventGesture（CGEventType.gesture 未在 Swift 接口导出）。
private let gestureEventType: CGEventType? = CGEventType(rawValue: 29)

// MARK: - 纯逻辑

/// 滚动事件来源设备。
public enum ScrollEventSource: Equatable {
    case mouse
    case trackpad
}

/// 一次滚动事件的处理决策（纯逻辑，独立于 CGEvent，便于单元测试）。
public struct ScrollModification: Equatable {
    /// 反转垂直方向（滚轮上下）。
    public var negateVertical: Bool
    /// 反转水平方向（滚轮左右 / 倾斜），仅当用户开启时为 true。
    public var negateHorizontal: Bool
}

public enum ScrollEventLogic {
    /// Scroll Reverser 的设备判别启发式（MouseTap.m 端口版）：
    /// 1. 离散事件必为传统鼠标滚轮；
    /// 2. 连续事件默认看触控板，但触控板滚动发生前后必然伴随“两指触摸”手势，
    ///    据此可区分：近 222ms 内有两指触摸 → 触控板；超过 333ms 无触摸且无惯性
    ///    相位 → 平滑滚轮鼠标（妙控鼠标 / 罗技 MX 等）；信息不足时沿用上次判定。
    public static func classify(
        isContinuous: Bool,
        touchingFingers: Int,
        msSinceLastTouch: Int,
        momentumPhaseNone: Bool,
        treatContinuousAsMouse: Bool,
        previous: ScrollEventSource
    ) -> ScrollEventSource {
        if !isContinuous { return .mouse }
        if treatContinuousAsMouse { return .mouse }
        if touchingFingers >= 2, msSinceLastTouch < 222 { return .trackpad }
        if momentumPhaseNone, msSinceLastTouch > 333 { return .mouse }
        return previous
    }

    /// 按来源设备套用用户偏好：不反转返回 nil（原样放行）。
    public static func modification(
        source: ScrollEventSource,
        reverseMouse: Bool,
        reverseTrackpad: Bool,
        reverseHorizontal: Bool
    ) -> ScrollModification? {
        let reversing = source == .mouse ? reverseMouse : reverseTrackpad
        guard reversing else { return nil }
        return ScrollModification(negateVertical: true, negateHorizontal: reverseHorizontal)
    }
}

// MARK: - 引擎

/// 全局滚轮方向反转引擎（Scroll Reverser 方案）：
/// - 活动 tap 建在 `cgSessionEventTap`（会话层，tail-append），拦截改写 scrollWheel；
/// - 被动只读 tap 监听手势事件，统计两指触摸，用于区分触控板与平滑滚轮鼠标；
/// 两个 tap 都挂在独立线程的 RunLoop 上，按设备类型与用户偏好改写增量后放行，
/// 对所有应用全局生效。
public final class ScrollReverser: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public var lastError: String?
    /// 诊断信息：按设备分类的事件计数与已反转数（每 2 秒刷新）。
    @Published public private(set) var diagnosticsText = "尚未启动"
    /// 引擎是否在等待辅助功能授权（面板据此显示引导并自动恢复）。
    @Published public private(set) var waitingForPermission = false

    private let lock = NSLock()
    private var reverseMouse = true
    private var reverseTrackpad = false
    private var reverseHorizontal = false
    private var treatContinuousAsMouse = false

    private var scrollTap: CFMachPort?
    private var gestureTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var gestureSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var statsTimer: Timer?
    private var permissionTimer: Timer?
    /// 用户意图：功能开关打开时为 true（权限未授予时保持 true 以便授权后自动启动）。
    private var wantsRunning = false

    // 以下状态只在 tap 线程读写（两个 tap 同一线程），无需加锁
    private var lastTouchAtMs: UInt64 = 0
    private var touchingFingers: Int = 0
    private var lastSource: ScrollEventSource = .mouse

    // 统计（tap 线程写、主线程读，加锁）
    private var seenEvents: UInt64 = 0
    private var mouseEvents: UInt64 = 0
    private var trackpadEvents: UInt64 = 0
    private var reversedEvents: UInt64 = 0

    public init() {}

    // MARK: - 冲突检测

    private static let knownScrollToolNames: Set<String> = [
        "Scroll Reverser", "Mos", "SmoothScroll", "Mac Mouse Fix", "Smooze", "Smooze Pro",
    ]
    private static let knownScrollAppBundleIDs: Set<String> = [
        "co.pilotmoon.scroll-reverser", // Scroll Reverser
        "com.mixprogramming.mos",       // Mos
        "com.smoothscroll",             // SmoothScroll
    ]

    /// 会改写滚动方向的其他工具（与本功能同时运行会互相抵消/叠加）。
    /// 结果带短 TTL 缓存：面板 body 每次渲染都会调用，CGWindowList 全量扫描不宜每帧执行。
    private static var conflictCache: (time: Date, value: [String])?
    private static let conflictTTL: TimeInterval = 3

    public static func conflictingScrollApps() -> [String] {
        if let cache = conflictCache, Date().timeIntervalSince(cache.time) < conflictTTL {
            return cache.value
        }
        let value = computeConflictingScrollApps()
        conflictCache = (Date(), value)
        return value
    }

    public static func invalidateConflictCache() {
        conflictCache = nil
    }

    /// 双通道检测：常规应用走 NSWorkspace；后台 agent（如以登录项运行的
    /// Scroll Reverser）不在该列表里，需要扫描状态栏窗口属主。
    private static func computeConflictingScrollApps() -> [String] {
        var found: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            let bundleID = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            if knownScrollAppBundleIDs.contains(bundleID) || knownScrollToolNames.contains(name) {
                found.insert(name.isEmpty ? bundleID : name)
            }
        }
        // 全量扫描（不带 optionOnScreenOnly）：同类工具的图标可能已被隐藏到屏幕外
        if let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] {
            let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
            for info in list {
                guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                      layer == statusLevel else { continue }
                let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                if knownScrollToolNames.contains(owner) {
                    found.insert(owner)
                }
            }
        }
        return found.sorted()
    }

    // MARK: - 偏好（回调热路径读取，加锁快照）

    /// 调试/自动化验证用：引擎当前状态与事件计数的快照。
    public func debugSnapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var snapshot: [String: Any] = [
            "isRunning": isRunning,
            "mouseEvents": mouseEvents,
            "trackpadEvents": trackpadEvents,
            "reversedEvents": reversedEvents,
            "axTrusted": AXHelper.isTrusted(),
            "inputMonitoringGranted": InputMonitoringAccess.isGranted(),
        ]
        if let error = lastError { snapshot["error"] = error }
        return snapshot
    }

    public func updatePreferences(
        reverseMouse: Bool,
        reverseTrackpad: Bool,
        reverseHorizontal: Bool,
        treatContinuousAsMouse: Bool = false
    ) {
        lock.lock()
        self.reverseMouse = reverseMouse
        self.reverseTrackpad = reverseTrackpad
        self.reverseHorizontal = reverseHorizontal
        self.treatContinuousAsMouse = treatContinuousAsMouse
        lock.unlock()
    }

    // MARK: - 实时启停

    /// 启用引擎。权限未授予时不视为失败：进入等待状态并轮询，
    /// 用户在系统设置里勾选授权后自动创建 tap，无需重启应用。
    @discardableResult
    public func start() -> Bool {
        wantsRunning = true
        stopPermissionPolling()
        if scrollTap != nil {
            enableTaps()
            isRunning = true
            lastError = nil
            waitingForPermission = false
            startStatsTimer()
            return true
        }
        guard AXHelper.isTrusted() else {
            lastError = "需要辅助功能权限才能反转滚动方向（授权后自动生效，无需重启）"
            isRunning = false
            waitingForPermission = true
            startPermissionPolling()
            return false
        }
        guard installTaps() else {
            lastError = "创建事件监听失败（请确认已授予辅助功能权限后重试）"
            isRunning = false
            waitingForPermission = true
            startPermissionPolling()
            return false
        }
        isRunning = true
        lastError = nil
        waitingForPermission = false
        startStatsTimer()
        return true
    }

    /// 停止反转：禁用 tap 但保留结构，可随时再次 start（实时开关）。
    public func stop() {
        wantsRunning = false
        stopPermissionPolling()
        if let tap = scrollTap, CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let tap = gestureTap, CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        statsTimer?.invalidate()
        statsTimer = nil
        isRunning = false
        waitingForPermission = false
    }

    /// 彻底销毁 tap（应用退出时调用）。
    public func destroy() {
        stop()
        if let runLoop = tapRunLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        if let source = runLoopSource, let runLoop = tapRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let source = gestureSource, let runLoop = tapRunLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        if let tap = scrollTap {
            CFMachPortInvalidate(tap)
        }
        if let tap = gestureTap {
            CFMachPortInvalidate(tap)
        }
        scrollTap = nil
        gestureTap = nil
        runLoopSource = nil
        gestureSource = nil
        tapRunLoop = nil
    }

    /// 权限等待轮询：授权后自动重建 tap（1 秒粒度，授权检查本身极轻）。
    private func startPermissionPolling() {
        let work: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.wantsRunning else {
                self.stopPermissionPolling()
                return
            }
            guard !self.isRunning, AXHelper.isTrusted() else { return }
            // 授权到位：清掉可能存在的失效 tap 后重建
            self.teardownTaps()
            _ = self.start()
        }
        permissionTimer?.invalidate()
        if Thread.isMainThread {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in work() }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in work() }
            }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - tap 安装

    /// 创建会话层双 tap（活动改写 + 只读手势监听），并把两个 source
    /// 挂到专用线程的 RunLoop。任一活动 tap 创建失败则整体回退。
    private func installTaps() -> Bool {
        // 活动tap：改写滚动事件（需要辅助功能权限）
        var mask: CGEventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let active = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.scrollTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        // 被动tap：只读监听手势（两指触摸统计）。使用独立只读 tap 而非并入活动
        // tap，与 Scroll Reverser 一致：避免活动 tap 触发额外授权弹窗、
        // 干扰“摇晃指针定位”与“双指呼出通知中心”手势。
        var gesturePort: CFMachPort?
        if let gesture = gestureEventType {
            mask = CGEventMask(1 << gesture.rawValue)
            gesturePort = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: Self.gestureTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        }

        scrollTap = active
        gestureTap = gesturePort
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, active, 0)
        if let port = gesturePort {
            gestureSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        }
        let thread = Thread { [weak self] in
            self?.runTapLoop()
        }
        thread.name = "MacTools.ScrollTap"
        thread.stackSize = 256 * 1024
        thread.start()
        return true
    }

    /// 停止线程并清空 tap 结构（权限恢复重建 / 销毁时用）。
    private func teardownTaps() {
        if let runLoop = tapRunLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
        let sources = [runLoopSource, gestureSource].compactMap { $0 }
        if let runLoop = tapRunLoop {
            for source in sources {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
        }
        [scrollTap, gestureTap].compactMap { $0 }.forEach { CFMachPortInvalidate($0) }
        scrollTap = nil
        gestureTap = nil
        runLoopSource = nil
        gestureSource = nil
    }

    private func enableTaps() {
        [scrollTap, gestureTap].compactMap { $0 }.forEach {
            if !CGEvent.tapIsEnabled(tap: $0) {
                CGEvent.tapEnable(tap: $0, enable: true)
            }
        }
    }

    private func runTapLoop() {
        let runLoop = CFRunLoopGetCurrent()
        tapRunLoop = runLoop
        if let source = runLoopSource {
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }
        if let source = gestureSource {
            CFRunLoopAddSource(runLoop, source, .commonModes)
        }
        enableTaps()
        CFRunLoopRun()
    }

    // MARK: - 事件处理

    private static let scrollTapCallback: CGEventTapCallBack = { _, type, event, userData in
        guard let userData else { return Unmanaged.passUnretained(event) }
        let reverser = Unmanaged<ScrollReverser>.fromOpaque(userData).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统可能因超时禁用 tap，自动重新启用，保证反转持续有效
            reverser.enableTaps()
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            reverser.modify(event)
            return Unmanaged.passUnretained(event)
        default:
            reverser.enableTaps()
            return Unmanaged.passUnretained(event)
        }
    }

    private static let gestureTapCallback: CGEventTapCallBack = { _, type, event, userData in
        guard let userData else { return Unmanaged.passUnretained(event) }
        let reverser = Unmanaged<ScrollReverser>.fromOpaque(userData).takeUnretainedValue()
        reverser.trackTouch(event)
        return Unmanaged.passUnretained(event)
    }

    /// 手势事件：统计当前触摸的手指数。两指及以上才可能是触控板滚动。
    private func trackTouch(_ event: CGEvent) {
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let touching = nsEvent.touches(matching: .touching, in: nil).count
        if touching >= 2 {
            lastTouchAtMs = Self.nanoseconds()
            touchingFingers = max(touchingFingers, touching)
        }
    }

    private static func nanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let time = mach_absolute_time()
        return time * UInt64(info.numer) / UInt64(info.denom)
    }

    /// 就地改写滚动增量；不命中的事件原样放行，不影响系统其他行为。
    func modify(_ event: CGEvent) {
        lock.lock()
        seenEvents += 1
        let mouse = reverseMouse
        let trackpad = reverseTrackpad
        let horizontal = reverseHorizontal
        let smoothAsMouse = treatContinuousAsMouse
        lock.unlock()

        let nowMs = Self.nanoseconds() / 1_000_000
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1
        // 触控板滚动带有惯性相位；普通相位（none）说明是设备直发而非触控板手势
        let momentumPhaseNone = event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
        let touching = touchingFingers
        touchingFingers = 0
        let msSinceLastTouch = lastTouchAtMs == 0 ? Int.max : Int(clamping: nowMs - lastTouchAtMs)

        let source = ScrollEventLogic.classify(
            isContinuous: isContinuous,
            touchingFingers: touching,
            msSinceLastTouch: msSinceLastTouch,
            momentumPhaseNone: momentumPhaseNone,
            treatContinuousAsMouse: smoothAsMouse,
            previous: lastSource
        )
        lastSource = source

        lock.lock()
        if source == .mouse { mouseEvents += 1 } else { trackpadEvents += 1 }
        lock.unlock()

        guard let plan = ScrollEventLogic.modification(
            source: source,
            reverseMouse: mouse,
            reverseTrackpad: trackpad,
            reverseHorizontal: horizontal
        ) else { return }

        lock.lock()
        reversedEvents += 1
        lock.unlock()

        if plan.negateVertical {
            negateVertical(of: event)
        }
        if plan.negateHorizontal {
            negateHorizontal(of: event)
        }
    }

    /// 就地取反垂直增量。写入顺序必须 Delta → FixedPt → Point：
    /// 先写 DeltaAxis 会让系统按 8x/1x 联动改写后两者，顺序反了会丢平滑滚动。
    private func negateVertical(of event: CGEvent) {
        event.setIntegerValueField(
            .scrollWheelEventDeltaAxis1,
            value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        )
        event.setDoubleValueField(
            .scrollWheelEventFixedPtDeltaAxis1,
            value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        )
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis1,
            value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        )
        if let hid = CGEventCopyIOHIDEvent(event) {
            IOHIDEventSetFloatValue(hid, kIOHIDEventFieldScrollY, -IOHIDEventGetFloatValue(hid, kIOHIDEventFieldScrollY))
            cfRelease(hid)
        }
    }

    private func negateHorizontal(of event: CGEvent) {
        event.setIntegerValueField(
            .scrollWheelEventDeltaAxis2,
            value: -event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        )
        event.setDoubleValueField(
            .scrollWheelEventFixedPtDeltaAxis2,
            value: -event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
        event.setIntegerValueField(
            .scrollWheelEventPointDeltaAxis2,
            value: -event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        )
        if let hid = CGEventCopyIOHIDEvent(event) {
            IOHIDEventSetFloatValue(hid, kIOHIDEventFieldScrollX, -IOHIDEventGetFloatValue(hid, kIOHIDEventFieldScrollX))
            cfRelease(hid)
        }
    }

    /// 面板诊断：让用户能确认事件 tap 是否真的在收事件、设备分类是否正确。
    private func startStatsTimer() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let seen = self.seenEvents
            let mouse = self.mouseEvents
            let trackpad = self.trackpadEvents
            let reversed = self.reversedEvents
            self.lock.unlock()
            var text: String
            if self.isRunning {
                text = "识别为鼠标 \(mouse) · 触控板 \(trackpad) · 已反转 \(reversed)"
                if seen == 0 {
                    text += "（尚未收到任何滚动事件：请滚动一下；若始终为 0 请检查权限）"
                }
            } else {
                text = "引擎已停止"
            }
            DispatchQueue.main.async {
                if self.diagnosticsText != text { self.diagnosticsText = text }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }
}
