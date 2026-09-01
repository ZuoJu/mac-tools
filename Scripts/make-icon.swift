import AppKit

// 生成 MacTools 应用图标主图（1024×1024 PNG）
// 设计：macOS 圆角矩形底板（靛蓝渐变）+ 白色剪贴板，板顶一条“菜单栏”带三个图标点，
// 下方为历史条目线（第一条高亮并带固定图钉），呼应“剪贴板历史 + 菜单栏工具”的产品定位。
// 用法: swift Scripts/make-icon.swift <输出PNG路径>

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon-master.png"

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// MARK: - 底板（圆角矩形 + 渐变）
let backgroundRect = NSRect(x: 64, y: 64, width: 896, height: 896)
let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 208, yRadius: 208)
NSGradient(colors: [color(111, 134, 250), color(59, 78, 200)])?
    .draw(in: background, angle: -90)
// 顶部高光
if let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0.0)]) {
    let highlightPath = NSBezierPath(roundedRect: NSRect(x: 64, y: 512, width: 896, height: 448), xRadius: 208, yRadius: 208)
    highlight.draw(in: highlightPath, angle: -90)
}

// MARK: - 剪贴板投影
let sheetRect = NSRect(x: 288, y: 216, width: 448, height: 620)
let shadow = NSBezierPath(roundedRect: sheetRect.offsetBy(dx: 0, dy: -18), xRadius: 52, yRadius: 52)
color(20, 28, 90, 0.35).setFill()
shadow.fill()

// MARK: - 剪贴板板面
let sheet = NSBezierPath(roundedRect: sheetRect, xRadius: 52, yRadius: 52)
NSColor.white.setFill()
sheet.fill()

// 顶部夹子
let clipRect = NSRect(x: 288 + 224 - 92, y: 216 + 620 - 40, width: 184, height: 76)
let clip = NSBezierPath(roundedRect: clipRect, xRadius: 30, yRadius: 30)
NSGradient(colors: [color(120, 142, 252), color(74, 96, 218)])?.draw(in: clip, angle: -90)
let clipHole = NSBezierPath(roundedRect: NSRect(x: clipRect.midX - 34, y: clipRect.maxY - 40, width: 68, height: 26), xRadius: 13, yRadius: 13)
color(255, 255, 255, 0.9).setFill()
clipHole.fill()

// MARK: - 板内“菜单栏”条 + 三个图标点
let barRect = NSRect(x: sheetRect.minX + 40, y: sheetRect.maxY - 168, width: sheetRect.width - 80, height: 72)
let bar = NSBezierPath(roundedRect: barRect, xRadius: 26, yRadius: 26)
color(233, 238, 255).setFill()
bar.fill()
let dotColors = [color(126, 148, 250), color(126, 148, 250), color(126, 148, 250)]
for (index, dotColor) in dotColors.enumerated() {
    let x = barRect.minX + 38 + CGFloat(index) * 52
    let dot = NSBezierPath(ovalIn: NSRect(x: x, y: barRect.midY - 15, width: 30, height: 30))
    dotColor.setFill()
    dot.fill()
}

// MARK: - 历史条目线
func entryLine(y: CGFloat, width: CGFloat, highlighted: Bool) {
    let rect = NSRect(x: sheetRect.minX + 40, y: y, width: width, height: 42)
    let line = NSBezierPath(roundedRect: rect, xRadius: 21, yRadius: 21)
    (highlighted ? color(126, 148, 250) : color(216, 223, 245)).setFill()
    line.fill()
    if highlighted {
        // 固定图钉：橙色圆点
        let pin = NSBezierPath(ovalIn: NSRect(x: sheetRect.maxX - 40 - 62, y: y + 1, width: 40, height: 40))
        color(255, 159, 10).setFill()
        pin.fill()
    }
}
entryLine(y: 566, width: 300, highlighted: true)
entryLine(y: 478, width: 368, highlighted: false)
entryLine(y: 390, width: 328, highlighted: false)
entryLine(y: 302, width: 240, highlighted: false)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("❌ 图标渲染失败\n", stderr)
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: output))
print("✅ 已生成 \(output)")
