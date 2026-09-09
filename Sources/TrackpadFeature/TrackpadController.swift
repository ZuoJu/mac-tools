import AppKit
import CoreKit
import TrackpadBridge

public final class TrackpadController: ObservableObject {
    @Published public var enabled: Bool { didSet { defaults.set(enabled, forKey: "trackpad.enabled"); sync() } }
    @Published public var edgeWidth: Double { didSet { defaults.set(edgeWidth, forKey: "trackpad.edgeWidth"); resetGesture() } }
    @Published public var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: "trackpad.sensitivity"); resetGesture() } }
    @Published public private(set) var isRunning = false
    @Published public private(set) var status = "已关闭"
    @Published public private(set) var deviceSummary = ""
    @Published public private(set) var lastAdjustment = "尚未调节"
    public private(set) var framesReceived = 0
    private let defaults: UserDefaults
    private let levels = SystemLevels()
    private var gesture = DeviceGestures()
    private var deviceFrames: [String: Int] = [:]
    private var lastAdjustmentDevice: String?
    private let cursorLock = CursorLock()
    private let levelHUD = LevelHUD()
    private var nativeOSDAvailable: Bool?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var generation = 0
    private final class Subscription {
        weak var owner: TrackpadController?
        let generation: Int
        init(owner: TrackpadController, generation: Int) { self.owner = owner; self.generation = generation }
    }
    private var subscription: Subscription?
    private var suspended = false
    private var lastFrame = Date.distantPast
    private var pendingDelta = 0.0
    private var lastAdjustmentAt = Date.distantPast

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "trackpad.enabled")
        let width = defaults.double(forKey: "trackpad.edgeWidth")
        edgeWidth = width > 0 ? min(0.25, max(0.08, width)) : 0.15
        let gain = defaults.double(forKey: "trackpad.sensitivity")
        sensitivity = gain > 0 ? min(2, max(0.5, gain)) : 1
    }

    deinit { stop() }

    /// Explicit lifecycle: preview/test construction never installs device callbacks.
    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isRunning && !AXHelper.isTrusted() { self.stopHardware() }
            if self.enabled && !self.isRunning && !self.suspended { self.sync() }
            if self.gesture.expire(at: ProcessInfo.processInfo.systemUptime) {
                self.pendingDelta = 0
                self.levelHUD.endGesture()
                _ = self.cursorLock.setLocked(false)
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspended = true; self?.stopHardware()
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.suspended = false; self?.sync()
        })
        sync()
    }

    public func stop() {
        timer?.invalidate(); timer = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        stopHardware()
    }

    public func requestPermission() { _ = AXHelper.isTrusted(prompt: true); sync() }
    public func reconnect() { stopHardware(); sync() }

    private func sync() {
        guard enabled, !suspended else { stopHardware(); status = enabled ? "睡眠中" : "已关闭"; return }
        guard !isRunning else { return }
        guard AXHelper.isTrusted() else { status = "等待辅助功能授权"; return }
        let mask = [CGEventType.mouseMoved, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<TrackpadController>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.resetGesture()
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                }
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type) { owner.cancelUntilLift() }
                if type == .scrollWheel, owner.cursorLock.isLocked,
                   Date().timeIntervalSince(owner.lastFrame) < 0.25 { return nil }
                if type == .mouseMoved, owner.cursorLock.isLocked,
                   Date().timeIntervalSince(owner.lastFrame) < 0.25 {
                    if owner.cursorLock.holdPosition() { return nil }
                    owner.cancelUntilLift()
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            status = "无法建立触摸板监听，请检查辅助功能权限"; return
        }
        tap = newTap; source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        let subscription = Subscription(owner: self, generation: generation)
        self.subscription = subscription
        let result = MTEdgeStart({ deviceID, builtIn, points, count, time, context in
            guard let context else { return }
            let subscription = Unmanaged<Subscription>.fromOpaque(context).takeUnretainedValue()
            let contacts = (0..<Int(count)).map { index -> EdgeTouch in
                let point = points![index]
                return EdgeTouch(id: point.identifier, x: Double(point.x), y: Double(point.y))
            }
            DispatchQueue.main.async { [subscription] in
                guard let owner = subscription.owner, owner.isRunning,
                      owner.generation == subscription.generation else { return }
                owner.consume(contacts, deviceID: deviceID, builtIn: builtIn != 0, timestamp: time)
            }
        }, Unmanaged.passUnretained(subscription).toOpaque())
        guard result == 0 else {
            stopHardware()
            status = result == -2 ? "未检测到触摸板，请连接后重试" : "当前系统不支持触摸板位置读取"
            return
        }
        deviceSummary = "内置 \(MTEdgeDeviceCount(1)) 块 · 外接 \(MTEdgeDeviceCount(0)) 块"
        deviceFrames.removeAll()
        isRunning = true
        status = "已开启 · 左侧亮度 / 右侧音量"
    }

    private func stopHardware() {
        if isRunning { MTEdgeStop() }
        isRunning = false
        deviceSummary = ""
        generation += 1
        subscription = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        resetGesture()
    }

    private func resetGesture() {
        gesture.reset(); pendingDelta = 0
        levelHUD.dismiss()
        _ = cursorLock.setLocked(false)
    }
    private func cancelUntilLift() {
        gesture.cancelUntilLift(); pendingDelta = 0
        levelHUD.endGesture()
        _ = cursorLock.setLocked(false)
    }

    private func consume(_ touches: [EdgeTouch], deviceID: UInt64, builtIn: Bool, timestamp: Double) {
        framesReceived += 1
        let deviceName = "\(builtIn ? "内置" : "外接"):\(deviceID)"
        deviceFrames[deviceName, default: 0] += 1
        let previousDevice = gesture.activeDeviceID
        let change = gesture.update(deviceID: deviceID, touches: touches, at: timestamp,
                                    receivedAt: ProcessInfo.processInfo.systemUptime,
                                    width: edgeWidth, sensitivity: sensitivity)
        if gesture.activeDeviceID == deviceID {
            lastFrame = Date()
            levelHUD.keepVisible()
        }
        if previousDevice != nil && gesture.activeDeviceID == nil { levelHUD.endGesture() }
        if previousDevice != gesture.activeDeviceID || !gesture.isArmed { pendingDelta = 0 }
        guard NSEvent.pressedMouseButtons == 0 else { cancelUntilLift(); return }
        guard cursorLock.setLocked(gesture.isArmed) else {
            lastAdjustment = "无法锁定光标，本次调节已取消"
            cancelUntilLift()
            return
        }
        guard let change else { return }
        pendingDelta += change.delta
        guard Date().timeIntervalSince(lastAdjustmentAt) >= 0.04 else { return }
        let delta = min(0.08, max(-0.08, pendingDelta))
        pendingDelta = 0
        lastAdjustmentAt = Date()
        lastAdjustmentDevice = deviceName
        adjustLevel(side: change.side, delta: delta)
    }

    public func adjustLevel(side: EdgeGesture.Side, delta: Double) {
        guard delta.isFinite else { return }
        do {
            let value = try side == .brightness ? levels.adjustBrightness(by: delta) : levels.adjustVolume(by: delta)
            lastAdjustment = "\(side == .brightness ? "亮度" : "音量") \(Int((value * 100).rounded()))%"
            levelHUD.show(side: side, value: value)
            nativeOSDAvailable = NativeLevelOSD.show(side: side, value: value)
            if nativeOSDAvailable == false { lastAdjustment += " · 系统提示暂不可用" }
        } catch {
            lastAdjustment = error.localizedDescription
            levelHUD.dismiss()
            FeedbackHUD.show(lastAdjustment, success: false)
            cancelUntilLift()
        }
    }

    public func debugSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = ["enabled": enabled, "isRunning": isRunning, "status": status,
            "framesReceived": framesReceived, "isControlling": gesture.isControlling,
            "cursorLocked": cursorLock.isLocked, "lastAdjustment": lastAdjustment]
        snapshot["devices"] = deviceSummary
        snapshot["deviceFrames"] = deviceFrames
        if let lastAdjustmentDevice { snapshot["lastAdjustmentDevice"] = lastAdjustmentDevice }
        if let nativeOSDAvailable { snapshot["nativeOSDAvailable"] = nativeOSDAvailable }
        return snapshot
    }
}
