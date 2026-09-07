import AppKit
import CoreGraphics
import CoreKit
import Foundation

/// 区域框选：在每块屏幕上铺一层遮罩窗口，拖拽出矩形后可拖边角手柄实时调整，
/// 回车 / 双击确认，Esc 取消。确认回调给出 AppKit 全局坐标矩形。
public final class RegionSelectionController: NSObject {
    public enum ConfirmationMode {
        /// 保持选区，允许拖动手柄后通过回车或双击确认。
        case explicit
        /// 第一次拖拽结束即确认选区，适合截图翻译等一气呵成的流程。
        case onMouseUp
    }

    private var windows: [SelectionWindow] = []
    let state = SelectionState()
    public var onConfirm: ((CGRect) -> Void)?
    public var onCancel: (() -> Void)?
    public var confirmationMode: ConfirmationMode = .explicit
    /// 取消 / 确认都会置回 false。
    public var isActive: Bool { !windows.isEmpty }

    public func begin() {
        end()
        for screen in NSScreen.screens {
            let window = SelectionWindow(screen: screen)
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.state = state
            view.confirmationMode = confirmationMode
            view.onConfirm = { [weak self] rect in
                self?.end()
                self?.onConfirm?(rect)
            }
            view.onCancel = { [weak self] in
                self?.end()
                self?.onCancel?()
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        windows.first?.makeFirstResponder(windows.first?.contentView)
    }

    public func end() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        state.reset()
        // begin() 里 set 了 crosshair，结束时恢复默认光标避免残留
        NSCursor.arrow.set()
    }
}

/// 框选共享状态：所有屏幕的遮罩视图同步显示同一个全局矩形（AppKit 左下原点）。
final class SelectionState: ObservableObject {
    @Published var rect: CGRect = .null
    var phase: Phase = .waiting

    enum Phase {
        case waiting
        case dragging
        case adjusting
    }

    func reset() {
        rect = .null
        phase = .waiting
    }
}

final class SelectionWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
}

/// 单屏遮罩视图：暗色蒙层 + 挖空选区 + 手柄 + 尺寸标签 + 全部交互。
/// 本视图是所在窗口的 contentView（原点重合），视图坐标即窗口坐标。
final class SelectionView: NSView {
    var state: SelectionState?
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var confirmationMode: RegionSelectionController.ConfirmationMode = .explicit

    private var dragOrigin: CGPoint = .zero
    private var resizeHandle: Handle = .none
    private var moveOffset: CGSize = .zero

    private enum Handle { case none, topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - 坐标换算（视图坐标 = 窗口坐标）

    private func toGlobal(_ localPoint: CGPoint) -> CGPoint {
        guard let window else { return localPoint }
        return window.convertToScreen(NSRect(origin: localPoint, size: .zero)).origin
    }

    private func toLocal(_ globalPoint: CGPoint) -> CGPoint {
        guard let window else { return globalPoint }
        return window.convertFromScreen(NSRect(origin: globalPoint, size: .zero)).origin
    }

    private var localRect: CGRect {
        guard let state, state.rect != .null else { return .null }
        let origin = toLocal(state.rect.origin)
        return CGRect(origin: origin, size: state.rect.size)
    }

    private func setGlobalRect(fromLocal local: CGRect) {
        guard let state else { return }
        let origin = toGlobal(local.origin)
        state.rect = CGRect(origin: origin, size: local.size)
    }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        guard let state else { return }
        let local = convert(event.locationInWindow, from: nil)
        dragOrigin = local
        if state.phase == .adjusting {
            let rect = localRect
            let handle = handle(at: local, rect: rect)
            if handle != .none {
                resizeHandle = handle
                return
            }
            if rect.contains(local) {
                moveOffset = CGSize(width: local.x - rect.minX, height: local.y - rect.minY)
                resizeHandle = .none
                return
            }
            // 点击选区外：重新框选
        }
        state.phase = .dragging
        state.rect = .null
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state, let screenFrame = window?.screen?.frame else { return }
        let local = convert(event.locationInWindow, from: nil).clamped(to: bounds)
        switch state.phase {
        case .dragging:
            let localRect = normalizedRect(dragOrigin, local)
            setGlobalRect(fromLocal: localRect)
        case .adjusting:
            let rect = localRect
            var newRect = rect
            if resizeHandle == .none {
                newRect.origin = CGPoint(x: local.x - moveOffset.width, y: local.y - moveOffset.height)
            } else {
                newRect = resizedRect(rect, handle: resizeHandle, to: local)
            }
            newRect = newRect.intersection(screenFrame)
            guard newRect.width >= 4, newRect.height >= 4 else { return }
            setGlobalRect(fromLocal: newRect)
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let state else { return }
        if event.clickCount >= 2, state.phase == .adjusting {
            confirmIfNeeded()
            return
        }
        switch state.phase {
        case .dragging:
            if state.rect != .null, state.rect.width >= 8, state.rect.height >= 8 {
                state.phase = .adjusting
                if confirmationMode == .onMouseUp {
                    confirmIfNeeded()
                    return
                }
            } else {
                state.rect = .null
                state.phase = .waiting
            }
        case .adjusting:
            resizeHandle = .none
        default:
            break
        }
        needsDisplay = true
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return / 小键盘 Enter
            confirmIfNeeded()
        default:
            break
        }
    }

    private func confirmIfNeeded() {
        guard let state, state.phase == .adjusting, state.rect != .null else { return }
        let rect = state.rect
        onConfirm?(rect)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let state else { return }
        // 1. 全屏暗色蒙层
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        let rect = localRect
        if rect.isNull || rect.isEmpty {
            // 未开始拖拽时的操作提示
            let text = confirmationMode == .onMouseUp
                ? "拖拽框选区域 · 松开鼠标立即确认 · Esc 取消"
                : "拖拽框选区域 · 回车或双击确认 · Esc 取消"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2),
                withAttributes: attributes
            )
            return
        }

        // 2. 挖空选区（透明合成，露出真实屏幕内容）
        rect.fill(using: .clear)

        // 3. 选区边框
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()

        // 4. 尺寸标签
        let label = "\(Int(state.rect.width)) × \(Int(state.rect.height))"
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = label.size(withAttributes: labelAttributes)
        var labelRect = CGRect(
            x: rect.midX - textSize.width / 2 - 10,
            y: rect.maxY + 8,
            width: textSize.width + 20,
            height: textSize.height + 8
        )
        if labelRect.maxY > bounds.maxY - 2 {
            labelRect.origin.y = rect.minY - labelRect.height - 8
        }
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        label.draw(at: CGPoint(x: labelRect.minX + 10, y: labelRect.minY + 4), withAttributes: labelAttributes)

        // 5. 调整阶段：8 个手柄
            if state.phase == .adjusting {
                for point in handlePoints(rect: rect) {
                    let handleRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                    NSColor.white.setFill()
                    NSBezierPath(roundedRect: handleRect, xRadius: 2, yRadius: 2).fill()
                    NSColor.controlAccentColor.setStroke()
                    NSBezierPath(roundedRect: handleRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).stroke()
                }
            }
    }

    // MARK: - 几何辅助

    private func handlePoints(rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    private func handle(at point: CGPoint, rect: CGRect) -> Handle {
        let threshold: CGFloat = 8
        let candidates: [(CGFloat, CGFloat, Handle)] = [
            (rect.minX, rect.minY, .bottomLeft), (rect.maxX, rect.minY, .bottomRight),
            (rect.minX, rect.maxY, .topLeft), (rect.maxX, rect.maxY, .topRight),
            (rect.midX, rect.minY, .bottom), (rect.midX, rect.maxY, .top),
            (rect.minX, rect.midY, .left), (rect.maxX, rect.midY, .right),
        ]
        for candidate in candidates {
            if abs(point.x - candidate.0) <= threshold, abs(point.y - candidate.1) <= threshold {
                return candidate.2
            }
        }
        return .none
    }

    private func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 以手柄为活动端调整矩形（对侧固定）。
    private func resizedRect(_ rect: CGRect, handle: Handle, to point: CGPoint) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = point.x; maxY = point.y
        case .topRight: maxX = point.x; maxY = point.y
        case .bottomLeft: minX = point.x; minY = point.y
        case .bottomRight: maxX = point.x; minY = point.y
        case .top: maxY = point.y
        case .bottom: minY = point.y
        case .left: minX = point.x
        case .right: maxX = point.x
        case .none: break
        }
        return normalizedRect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }
}

extension CGPoint {
    func clamped(to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}
