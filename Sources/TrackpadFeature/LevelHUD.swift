import AppKit
import SwiftUI

/// A reusable, non-activating panel: frequent value updates never recreate the window.
final class LevelHUD {
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var revision = 0

    func show(side: EdgeGesture.Side, value: Double) {
        guard value.isFinite else { return }
        let hud: NSPanel
        if let panel {
            hud = panel
        } else {
            hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 64),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            hud.level = .statusBar
            hud.isOpaque = false
            hud.backgroundColor = .clear
            hud.hasShadow = true
            hud.hidesOnDeactivate = false
            hud.ignoresMouseEvents = true
            hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel = hud
        }
        let view = LevelHUDView(side: side, value: value)
        if let hosting = hud.contentView as? NSHostingView<LevelHUDView> {
            hosting.rootView = view
        } else {
            hud.contentView = NSHostingView(rootView: view)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            hud.setFrameOrigin(NSPoint(x: frame.midX - hud.frame.width / 2, y: frame.minY + 36))
        }
        hud.alphaValue = 1
        hud.orderFrontRegardless()
        keepVisible()
    }

    /// Keep the last value visible while the controlling finger remains down.
    func keepVisible() {
        guard let panel, panel.isVisible else { return }
        scheduleDismiss(after: 1.2) // Also covers interrupted device streams.
    }

    func endGesture() { scheduleDismiss(after: 0.9) }

    func dismiss() {
        revision += 1
        dismissWork?.cancel()
        dismissWork = nil
        panel?.orderOut(nil)
    }

    private func scheduleDismiss(after delay: Double) {
        revision += 1
        let expected = revision
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revision == expected, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard self?.revision == expected else { return }
                panel.orderOut(nil)
            })
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    deinit { dismissWork?.cancel(); panel?.orderOut(nil) }
}

public struct LevelHUDView: View {
    private let side: EdgeGesture.Side
    private let value: Double
    public init(side: EdgeGesture.Side, value: Double) {
        self.side = side
        self.value = value.isFinite ? min(1, max(0, value)) : 0
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: side == .brightness ? "sun.max.fill" : (value > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill"))
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(side == .brightness ? Color.orange : Color.blue)
                .frame(width: 28)
            Text("\(side == .brightness ? "屏幕亮度" : "声音")：\(Int((value * 100).rounded()))%")
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(width: 270, height: 64)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.1)))
    }
}
