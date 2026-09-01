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
        hidesOnDeactivate = true
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
    /// 调试/自动化测试用：禁用失焦与失活自动关闭。
    var debugAutoCloseDisabled = false

    private var escMonitor: Any?
    private var lastResignKeyAt = Date.distantPast

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

    func toggle(statusItemButton: NSStatusBarButton?) {
        if panel.isVisible {
            close()
            return
        }
        // 刚因点击状态栏图标而失焦关闭时，这次点击视为“关闭”而非重新打开
        if Date().timeIntervalSince(lastResignKeyAt) < 0.3 { return }
        show(below: statusItemButton)
    }

    func close() {
        panel.orderOut(nil)
    }

    private func show(below button: NSStatusBarButton?) {
        position(below: button)
        // 非激活面板必须用 orderFrontRegardless：应用处于后台时也能直接显示（Maccy 同款）
        panel.orderFrontRegardless()
        panel.makeKey()
        onShow?()
    }

    private func position(below button: NSStatusBarButton?) {
        let size = panel.frame.size
        var topLeft: NSPoint
        if let buttonWindow = button?.window, let button = button {
            let buttonFrame = buttonWindow.convertToScreen(button.frame)
            let screen = NSScreen.screens.first { $0.frame.intersects(buttonFrame) } ?? NSScreen.main
            let minX = screen?.visibleFrame.minX ?? 8
            let maxX = (screen?.visibleFrame.maxX ?? 1440) - size.width - 8
            let x = max(minX, min(buttonFrame.maxX - size.width + 12, maxX))
            topLeft = NSPoint(x: x, y: buttonFrame.minY - 6)
        } else {
            let screen = NSScreen.main
            topLeft = NSPoint(
                x: ((screen?.frame.width ?? 1440) - size.width) / 2,
                y: (screen?.frame.height ?? 900) / 2 + size.height / 2
            )
        }
        panel.setFrameTopLeftPoint(topLeft)
    }

    func windowDidResignKey(_ notification: Notification) {
        lastResignKeyAt = Date()
        guard !debugAutoCloseDisabled else { return }
        close()
    }
}
