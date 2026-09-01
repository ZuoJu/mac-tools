import AppKit
import SwiftUI

/// 轻量反馈 HUD：屏幕下方居中弹出提示，1.8 秒后自动消失。
/// 原属截图模块，翻译等新模块同样需要，上移到 CoreKit 共用。
public enum FeedbackHUD {
    private static var currentWindow: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    public static func show(_ text: String, success: Bool = true) {
        dismissCurrent()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let hud = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hud.level = .statusBar
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.ignoresMouseEvents = true

        let icon = success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        let iconColor: NSColor = success ? .systemGreen : .systemOrange
        let hosting = NSHostingView(
            rootView: HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(Color(nsColor: iconColor))
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            )
        )
        hud.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hud.setFrame(
            NSRect(
                x: screen.midX - size.width / 2,
                y: screen.minY + 84,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        hud.alphaValue = 0
        hud.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            hud.animator().alphaValue = 1
        }
        currentWindow = hud

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                hud.animator().alphaValue = 0
            }, completionHandler: {
                hud.orderOut(nil)
                if currentWindow === hud { currentWindow = nil }
            })
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    public static func dismissCurrent() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        currentWindow?.orderOut(nil)
        currentWindow = nil
    }
}
