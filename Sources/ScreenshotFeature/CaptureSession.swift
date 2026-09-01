import AppKit
import CoreGraphics
import CoreKit
import Foundation

/// 一次截图会话的状态：预览模式 ↔ 编辑模式，标注数据与工具选择。
public final class CaptureSession: ObservableObject {
    public enum Mode {
        case preview
        case editing
    }

    public struct PendingText {
        var point: CGPoint // 图像坐标（左下原点，基线位置）
        var value: String = ""
    }

    @Published public var mode: Mode = .preview
    @Published public var annotations: [Annotation] = []
    @Published public var tool: AnnotationTool = .pen
    @Published public var colorIndex = 0
    @Published public var draftText: PendingText?

    let image: NSImage
    let cgImage: CGImage
    /// 图像点尺寸（Retina 下为像素的一半）。
    let size: CGSize
    /// 截取区域（AppKit 全局坐标），用于摆放会话窗口与贴图。
    let captureRect: CGRect

    lazy var renderer: AnnotationRenderer = AnnotationRenderer(baseImage: cgImage, size: size)

    public init(image: NSImage, captureRect: CGRect) {
        self.image = image
        self.captureRect = captureRect
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            fatalError("截图图像缺少 CGImage 表示")
        }
        self.cgImage = cgImage
        self.size = image.size
    }

    /// 画布显示缩放：大截图 fit-to-screen 时 < 1；标注坐标始终在图像空间。
    public var displayScale: CGFloat = 1

    /// 画布显示尺寸（= 图像尺寸 × 显示缩放，保证窗口不超出屏幕）。
    public var displaySize: CGSize {
        CGSize(width: size.width * displayScale, height: size.height * displayScale)
    }

    public func addAnnotation(_ annotation: Annotation) {
        annotations.append(annotation)
    }

    public func undo() {
        if draftText != nil {
            draftText = nil
            return
        }
        guard !annotations.isEmpty else { return }
        annotations.removeLast()
    }

    public func clearAnnotations() {
        annotations.removeAll()
        renderer.invalidateMosaicCache()
    }

    /// 合成最终图像（含全部标注）。
    public func compositeImage() -> NSImage {
        guard !annotations.isEmpty else { return image }
        return renderer.composite(annotations: annotations)
    }
}

/// 画布视图：绘制底图 + 标注 + 草稿，处理绘制类工具的鼠标交互。
public final class AnnotationCanvasView: NSView {
    private(set) var session: CaptureSession
    private var draft: Annotation?
    private var draftPoints: [CGPoint] = []
    private var dragStart: CGPoint?

    public init(session: CaptureSession) {
        self.session = session
        super.init(frame: NSRect(origin: .zero, size: session.displaySize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unsupported")
    }

    func refresh() {
        needsDisplay = true
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    /// 视图坐标 → 图像坐标（视图按 displayScale 缩放显示，除回去即可）。
    private func imagePoint(from viewPoint: CGPoint) -> CGPoint {
        let scale = session.displayScale
        guard scale > 0, scale != 1 else { return viewPoint }
        return CGPoint(x: viewPoint.x / scale, y: viewPoint.y / scale)
    }

    private func colorIndex() -> Int { session.colorIndex }

    public override func mouseDown(with event: NSEvent) {
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
        dragStart = point
        draftPoints = [point]
        switch session.tool {
        case .pen:
            draft = .stroke(id: UUID(), points: draftPoints, colorIndex: colorIndex(), width: 5)
        case .mosaic:
            draft = .mosaic(id: UUID(), points: draftPoints, brushWidth: 28, blockSize: 14)
        case .arrow:
            draft = .arrow(id: UUID(), from: point, to: point, colorIndex: colorIndex(), width: 5)
        case .text:
            draft = nil
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(from: convert(event.locationInWindow, from: nil))
        switch session.tool {
        case .pen, .mosaic:
            draftPoints.append(point)
            if case .stroke(let id, _, let colorIndex, _) = draft {
                draft = .stroke(id: id, points: draftPoints, colorIndex: colorIndex, width: 5)
            } else if case .mosaic(let id, _, let brushWidth, let blockSize) = draft {
                draft = .mosaic(id: id, points: draftPoints, brushWidth: brushWidth, blockSize: blockSize)
            }
        case .arrow:
            if case .arrow(let id, let from, _, let colorIndex, let width) = draft {
                draft = .arrow(id: id, from: from, to: point, colorIndex: colorIndex, width: width)
            }
        case .text:
            break
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        defer { needsDisplay = true }
        switch session.tool {
        case .pen, .mosaic, .arrow:
            guard let draft else { return }
            session.addAnnotation(draft)
            self.draft = nil
            draftPoints = []
            dragStart = nil
        case .text:
            session.draftText = CaptureSession.PendingText(point: imagePoint(from: convert(event.locationInWindow, from: nil)))
            dragStart = nil
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // 画布视图按 displayScale 缩放摆放；绘制前统一放大回图像坐标系
        if session.displayScale != 1 {
            context.scaleBy(x: session.displayScale, y: session.displayScale)
        }
        renderer.draw(annotations: session.annotations, draft: draft, in: context)
        context.restoreGState()
    }

    private var renderer: AnnotationRenderer { session.renderer }
}
