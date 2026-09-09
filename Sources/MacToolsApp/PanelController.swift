import AppKit
import SwiftUI

/// 非激活式面板窗口（Maccy 同款）：不抢焦点、悬浮于状态栏层、跟随所有空间。
final class Panel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        // 非激活面板本来就允许宿主应用在后台；不要再由应用失活自动隐藏。
        // 关闭统一走 windowDidResignKey，避免隐藏状态与 toggle 的可见判断不同步。
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
}

/// 下拉面板控制器：定位在状态栏图标下方、Esc 关闭、失焦自动关闭。
final class PanelController: NSObject, NSWindowDelegate {
    let panel: Panel
    var onShow: (() -> Void)?
    var onWillShow: (() -> Void)?
    /// 调试/自动化测试用：禁用失焦与失活自动关闭。
    var debugAutoCloseDisabled = false

    private var escMonitor: Any?
    private var lastResignKeyAt = Date.distantPast
    private var lastShownAt: Date?
    private var lastClosedAt: Date?
    private var visibleAfterShow = false
    private var keyAfterShow = false

    func debugSnapshot() -> [String: Any] {
        var result: [String: Any] = [
            "isVisible": panel.isVisible,
            "isKey": panel.isKeyWindow,
            "visibleAfterShow": visibleAfterShow,
            "keyAfterShow": keyAfterShow,
        ]
        if let lastShownAt { result["lastShownAt"] = lastShownAt.timeIntervalSince1970 }
        if let lastClosedAt { result["lastClosedAt"] = lastClosedAt.timeIntervalSince1970 }
        return result
    }

    init<V: View>(rootView: V, size: NSSize = NSSize(width: 480, height: 640)) {
        panel = Panel(contentRect: NSRect(origin: .zero, size: size))
        super.init()
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: rootView)
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let panel = self?.panel, panel.isVisible {
                self?.close()
                return nil
            }
            return event
        }
    }

    deinit {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
    }

    func toggle(statusItemButton: NSStatusBarButton?, fromStatusItemClick: Bool = false) {
        if panel.isVisible {
            close()
            return
        }
        // 刚因点击状态栏图标而失焦关闭时，这次点击视为“关闭”而非重新打开
        if fromStatusItemClick && Date().timeIntervalSince(lastResignKeyAt) < 0.3 { return }
        show(below: statusItemButton)
    }

    func close() {
        lastClosedAt = Date()
        panel.orderOut(nil)
    }

    private func show(below button: NSStatusBarButton?) {
        onWillShow?()
        position(below: button)
        // 非激活面板必须用 orderFrontRegardless：应用处于后台时也能直接显示（Maccy 同款）
        panel.orderFrontRegardless()
        panel.makeKey()
        lastShownAt = Date()
        visibleAfterShow = panel.isVisible
        keyAfterShow = panel.isKeyWindow
        onShow?()
    }

    private func position(below button: NSStatusBarButton?) {
        let buttonFrame = button?.window.map { $0.convertToScreen(button!.frame) }
        let screen = buttonFrame.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: visible.minX + 8, y: visible.minY + 8,
                             width: visible.width - 16, height: min(360, visible.height - 16)), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        lastResignKeyAt = Date()
        guard !debugAutoCloseDisabled else { return }
        close()
    }
}
