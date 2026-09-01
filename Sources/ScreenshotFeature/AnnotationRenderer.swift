import AppKit
import CoreGraphics
import Foundation

/// 标注工具类型。
public enum AnnotationTool: String, CaseIterable, Identifiable {
    case pen
    case arrow
    case text
    case mosaic

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .pen: return "pencil.tip"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .mosaic: return "squareshape.split.2x2"
        }
    }

    public var label: String {
        switch self {
        case .pen: return "画笔"
        case .arrow: return "箭头"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }
}

/// 一条标注（图像坐标空间，点为单位）。
public enum Annotation: Equatable {
    case stroke(id: UUID, points: [CGPoint], colorIndex: Int, width: CGFloat)
    case arrow(id: UUID, from: CGPoint, to: CGPoint, colorIndex: Int, width: CGFloat)
    case text(id: UUID, at: CGPoint, content: String, colorIndex: Int, fontSize: CGFloat)
    case mosaic(id: UUID, points: [CGPoint], brushWidth: CGFloat, blockSize: CGFloat)

    public var id: UUID {
        switch self {
        case .stroke(let id, _, _, _): return id
        case .arrow(let id, _, _, _, _): return id
        case .text(let id, _, _, _, _): return id
        case .mosaic(let id, _, _, _): return id
        }
    }
}

/// 标注调色板（与面板 UI 共用索引）。
public enum AnnotationPalette {
    public static let colors: [NSColor] = [
        NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1),   // 红
        NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1),   // 橙黄
        NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1),  // 绿
        NSColor(red: 0.24, green: 0.48, blue: 1.0, alpha: 1),   // 蓝
        NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),  // 黑
    ]

    public static func color(at index: Int) -> NSColor {
        guard colors.indices.contains(index) else { return colors[0] }
        return colors[index]
    }
}

/// 把标注渲染进 CGContext。预览（NSView.draw）与导出（合成位图）共用同一条绘制路径，
/// 保证“所见即所得”。
public final class AnnotationRenderer {
    public let baseImage: CGImage
    public let size: CGSize
    /// 图像像素与点尺寸的比例（Retina 截图为 2）。
    public let pixelScale: CGFloat
    private var mosaicCache: [UUID: CGImage] = [:]

    public init(baseImage: CGImage, size: CGSize) {
        self.baseImage = baseImage
        self.size = size
        self.pixelScale = size.width > 0 ? CGFloat(baseImage.width) / size.width : 1
    }

    public func invalidateMosaicCache() {
        mosaicCache.removeAll()
    }

    public func draw(annotations: [Annotation], draft: Annotation?, in context: CGContext) {
        context.draw(baseImage, in: CGRect(origin: .zero, size: size))
        for annotation in annotations {
            draw(annotation, in: context)
        }
        if let draft {
            draw(draft, in: context)
        }
    }

    private func draw(_ annotation: Annotation, in context: CGContext) {
        switch annotation {
        case .stroke(_, let points, let colorIndex, let width):
            guard points.count > 1 else { return }
            context.saveGState()
            let path = CGMutablePath()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path)
            context.setStrokeColor(AnnotationPalette.color(at: colorIndex).cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            context.restoreGState()

        case .arrow(_, let from, let to, let colorIndex, let width):
            context.saveGState()
            let color = AnnotationPalette.color(at: colorIndex)
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            // 箭杆：留出箭头长度
            let angle = atan2(to.y - from.y, to.x - from.x)
            let headLength = max(width * 3, 10)
            let shaftEnd = CGPoint(
                x: to.x - cos(angle) * headLength * 0.6,
                y: to.y - sin(angle) * headLength * 0.6
            )
            context.move(to: from)
            context.addLine(to: shaftEnd)
            context.strokePath()
            // 箭头三角
            let head = CGMutablePath()
            head.move(to: to)
            head.addLine(to: CGPoint(x: to.x - cos(angle + 0.42) * headLength, y: to.y - sin(angle + 0.42) * headLength))
            head.addLine(to: CGPoint(x: to.x - cos(angle - 0.42) * headLength, y: to.y - sin(angle - 0.42) * headLength))
            head.closeSubpath()
            context.addPath(head)
            context.fillPath()
            context.restoreGState()

        case .text(_, let at, let content, let colorIndex, let fontSize):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: AnnotationPalette.color(at: colorIndex),
            ]
            let attributed = NSAttributedString(string: content, attributes: attributes)
            // CGContext 文字坐标系原点在左下，绘制基线放在 at.y
            attributed.draw(at: CGPoint(x: at.x, y: at.y - fontSize))

        case .mosaic(let id, let points, let brushWidth, let blockSize):
            guard let first = points.first else { return }
            let path = CGMutablePath()
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            var boundingBox = path.boundingBoxOfPath.insetBy(dx: -brushWidth, dy: -brushWidth)
            boundingBox = boundingBox.intersection(CGRect(origin: .zero, size: size))
            guard !boundingBox.isEmpty else { return }
            let pixelated = cachedPixelatedImage(id: id, rect: boundingBox, blockSize: blockSize)
                ?? pixelatedImage(rect: boundingBox, blockSize: blockSize)
            guard let pixelated else { return }
            context.saveGState()
            context.addPath(path)
            context.setLineWidth(brushWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.replacePathWithStrokedPath()
            context.clip()
            context.interpolationQuality = .none
            context.draw(pixelated, in: boundingBox)
            context.restoreGState()
        }
    }

    /// 取底图某个矩形区域做像素化（调用方按 annotation id 缓存结果）。
    private func pixelatedImage(rect: CGRect, blockSize: CGFloat) -> CGImage? {
        let block = max(blockSize, 4)
        let scaleX = floor(rect.minX * pixelScale)
        let scaleY = floor(rect.minY * pixelScale)
        let cropX = max(0, scaleX)
        let cropY = max(0, scaleY)
        let cropWidth = min(CGFloat(baseImage.width) - cropX, ceil(rect.width * pixelScale))
        let cropHeight = min(CGFloat(baseImage.height) - cropY, ceil(rect.height * pixelScale))
        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        guard cropRect.width >= 2, cropRect.height >= 2,
              let cropped = baseImage.cropping(to: cropRect) else { return nil }
        let divisor = block * pixelScale
        let smallWidth = max(1, Int(CGFloat(cropped.width) / divisor))
        let smallHeight = max(1, Int(CGFloat(cropped.height) / divisor))
        guard let smallContext = CGContext(
            data: nil, width: smallWidth, height: smallHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        smallContext.interpolationQuality = CGInterpolationQuality.low
        smallContext.draw(cropped, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let small = smallContext.makeImage() else { return nil }
        guard let upContext = CGContext(
            data: nil, width: Int(cropRect.width), height: Int(cropRect.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        upContext.interpolationQuality = CGInterpolationQuality.none
        upContext.draw(small, in: CGRect(x: 0, y: 0, width: cropRect.width, height: cropRect.height))
        return upContext.makeImage()
    }

    /// 供外部按 annotation id 预热/清理缓存（数量上限保护，防止长会话内存膨胀）。
    public func cachedPixelatedImage(id: UUID, rect: CGRect, blockSize: CGFloat) -> CGImage? {
        if let cached = mosaicCache[id] { return cached }
        if mosaicCache.count > 24 {
            mosaicCache.removeAll()
        }
        guard let image = pixelatedImage(rect: rect, blockSize: blockSize) else { return nil }
        mosaicCache[id] = image
        return image
    }

    /// 合成最终图像（含标注），用于复制 / 固定。
    public func composite(annotations: [Annotation]) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * pixelScale),
            pixelsHigh: Int(size.height * pixelScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: size)
        }
        rep.size = size
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            draw(annotations: annotations, draft: nil, in: context.cgContext)
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
