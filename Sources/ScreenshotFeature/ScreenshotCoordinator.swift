import AppKit
import CoreKit
import SwiftUI

/// 截图功能协调器：框选 → 截取 → 会话窗口（预览/编辑）→ 固定 / 复制 / 丢弃。
/// 会话期间监听本地快捷键（Pin/Copy/Discard），无需占用全局注册。
public final class ScreenshotCoordinator: NSObject, ObservableObject {
    @Published public private(set) var isSelecting = false
    @Published public private(set) var hasActiveSession = false
    @Published public private(set) var pinnedCount = 0

    private let selection = RegionSelectionController()
    private var sessionWindow: NSPanel?
    private var session: CaptureSession?
    private var keyMonitor: Any?
    /// 会话期间的快捷键组合（从设置读取，会话开始时快照）。
    private var pinCombo: KeyCombo?
    private var copyCombo: KeyCombo?
    private var discardCombo: KeyCombo?
    /// 固定贴图窗口（可多个）。
    private var pinnedWindows: [NSPanel] = []
    /// 可选：把固定图像发送到系统分享。
    public var onPinFeedback: ((Bool) -> Void)?
    public var onCopyFeedback: ((Bool, String) -> Void)?

    public override init() {
        super.init()
        selection.onConfirm = { [weak self] rect in
            self?.startSession(rect: rect)
        }
        selection.onCancel = { [weak self] in
            self?.isSelecting = false
            FeedbackHUD.show("已取消截图", success: false)
        }
    }

    // MARK: - 入口

    /// 触发截图：检查屏幕录制权限 → 开始框选。
    public func startCapture(
        pinCombo: KeyCombo,
        copyCombo: KeyCombo,
        discardCombo: KeyCombo
    ) {
        guard !isSelecting, !hasActiveSession else { return }
        guard ScreenCaptureService.hasPermission() else {
            ScreenCaptureService.requestPermission()
            FeedbackHUD.show("需要「屏幕录制」权限，请在系统设置中勾选本工具", success: false)
            return
        }
        self.pinCombo = pinCombo
        self.copyCombo = copyCombo
        self.discardCombo = discardCombo
        isSelecting = true
        selection.begin()
    }

    // MARK: - 会话

    private func startSession(rect: CGRect) {
        isSelecting = false
        guard let image = ScreenCaptureService.capture(globalRect: rect) else {
            FeedbackHUD.show("截取失败，请重试", success: false)
            return
        }
        let session = CaptureSession(image: image, captureRect: rect)
        self.session = session

        // 大截图按可用屏幕空间缩小显示（fit-to-screen）；标注仍存图像坐标、复制/固定保持原分辨率
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let toolbarHeight: CGFloat = 96
        let maxCanvasWidth = visible.width - 32
        let maxCanvasHeight = visible.height - toolbarHeight - 60
        session.displayScale = min(1, maxCanvasWidth / session.size.width, maxCanvasHeight / session.size.height)

        let windowWidth = min(max(session.displaySize.width + 12, 560), visible.width)
        let windowHeight = min(session.displaySize.height + toolbarHeight + 16, visible.height)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "截图预览"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(
            rootView: CaptureSessionView(
                session: session,
                keyHints: .init(
                    pin: pinCombo?.display ?? "⌥⇧P",
                    copy: copyCombo?.display ?? "⌥⇧C",
                    discard: discardCombo?.display ?? "⌥⇧X"
                ),
                onPin: { [weak self] in self?.pin() },
                onCopy: { [weak self] in self?.copyToPasteboard() },
                onDiscard: { [weak self] in self?.discard() }
            )
        )
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        // 放到截取区域附近并夹在屏幕内（fit scale 计算已用 screen/visible，此处直接复用）
        let topLeft = NSPoint(x: rect.minX, y: rect.maxY)
        var origin = NSPoint(
            x: min(max(topLeft.x, visible.minX), visible.maxX - windowWidth),
            y: min(max(topLeft.y, visible.minY), visible.maxY - windowHeight)
        )
        if origin.y < visible.minY + 60 { origin.y = visible.minY + 60 }
        panel.setFrameOrigin(origin)
        // 非激活面板：成为 key window 接收键盘（会话快捷键 / Esc / 文字输入），但不抢前台应用焦点
        panel.orderFrontRegardless()
        panel.makeKey()
        sessionWindow = panel
        hasActiveSession = true
        installKeyMonitor()
    }

    private func endSession() {
        removeKeyMonitor()
        sessionWindow?.orderOut(nil)
        sessionWindow = nil
        session = nil
        hasActiveSession = false
    }

    // MARK: - 操作

    public func pin() {
        guard let session else { return }
        let composited = session.compositeImage()
        let width = session.displaySize.width
        let height = session.displaySize.height
        // 固定贴图：无边框、置顶、可拖动
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let hosting = NSHostingView(
            rootView: PinnedImageView(image: composited, onClose: { [weak self, weak panel] in
                if let panel {
                    panel.orderOut(nil)
                    self?.pinnedWindows.removeAll { $0 == panel }
                    self?.pinnedCount = self?.pinnedWindows.count ?? 0
                }
            })
        )
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        panel.contentView = hosting
        // 位置：原截取区域
        panel.setFrameOrigin(session.captureRect.origin)
        panel.orderFrontRegardless()
        pinnedWindows.append(panel)
        pinnedCount = pinnedWindows.count
        endSession()
        FeedbackHUD.show("已固定到屏幕，可拖动，点 × 关闭")
    }

    public func copyToPasteboard() {
        guard let session else { return }
        let image = session.compositeImage()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var ok = false
        if let tiff = image.tiffRepresentation {
            ok = pasteboard.setData(tiff, forType: .tiff)
            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                _ = pasteboard.setData(png, forType: .png) // 同时提供 PNG，兼容更多应用
            }
        }
        endSession()
        FeedbackHUD.show(ok ? "已复制到剪贴板" : "复制失败", success: ok)
    }

    public func discard() {
        guard hasActiveSession else { return }
        endSession()
        FeedbackHUD.show("已丢弃本次截图", success: false)
    }

    public func closeAllPinned() {
        for panel in pinnedWindows {
            panel.orderOut(nil)
        }
        pinnedWindows.removeAll()
        pinnedCount = 0
    }

    // MARK: - 会话本地快捷键（NSEvent 本地监视，不占用全局注册）

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.hasActiveSession else { return event }
            let raw = UInt64(event.modifierFlags.rawValue)
            if let combo = self.pinCombo, KeyCombo.shouldFire(
                keyCode: Int64(event.keyCode),
                flagsRaw: raw,
                wantKeyCode: combo.keyCode,
                wantModifiers: combo.carbonModifiers
            ) {
                self.pin()
                return nil
            }
            if let combo = self.copyCombo, KeyCombo.shouldFire(
                keyCode: Int64(event.keyCode),
                flagsRaw: raw,
                wantKeyCode: combo.keyCode,
                wantModifiers: combo.carbonModifiers
            ) {
                self.copyToPasteboard()
                return nil
            }
            if let combo = self.discardCombo, KeyCombo.shouldFire(
                keyCode: Int64(event.keyCode),
                flagsRaw: raw,
                wantKeyCode: combo.keyCode,
                wantModifiers: combo.carbonModifiers
            ) {
                self.discard()
                return nil
            }
            // Esc 在预览/编辑模式也可丢弃
            if event.keyCode == 53 {
                self.discard()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}

/// 固定贴图视图：显示图像，右上角关闭按钮。
struct PinnedImageView: View {
    let image: NSImage
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .frame(width: image.size.width, height: image.size.height)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.15)))
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }
}
