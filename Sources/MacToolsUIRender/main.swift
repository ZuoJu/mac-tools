import AppKit
import CoreKit
import ClipboardFeature
import MenuBarFeature
import ScrollFeature
import ScreenshotFeature
import SwiftUI
import TranslateFeature

/// 离屏渲染面板 UI 为 PNG：`swift run MacToolsUIRender <输出目录>`
/// 用于无交互环境下检查面板视觉效果。

let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : FileManager.default.temporaryDirectory
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

_ = NSApplication.shared

func render<V: View>(_ view: V, size: NSSize, name: String, appearance: NSAppearance.Name = NSAppearance.Name.aqua) {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.appearance = NSAppearance(named: appearance)
    window.backgroundColor = .windowBackgroundColor
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(origin: .zero, size: size)
    window.contentView = hostingView
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    guard let raw = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        print("❌ 无法创建位图: \(name)")
        return
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: raw)
    // 把渲染结果合成到窗口背景色之上（SwiftUI 透明区域显示为正常窗口底色）
    let scaled = hostingView.window?.backingScaleFactor ?? 2
    guard let final = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scaled),
        pixelsHigh: Int(size.height * scaled),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        print("❌ 无法创建合成位图: \(name)")
        return
    }
    final.size = size
    if let context = NSGraphicsContext(bitmapImageRep: final) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        let image = NSImage(size: size)
        image.addRepresentation(raw)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    guard let png = final.representation(using: .png, properties: [:]) else {
        print("❌ 无法编码 PNG: \(name)")
        return
    }
    let url = outputDir.appendingPathComponent(name)
    try? png.write(to: url)
    print("✅ \(url.path)")
}

func clipItem(
    kind: ClipboardKind,
    text: String? = nil,
    fileNames: [String]? = nil,
    imagePixels: (Double, Double)? = nil,
    date: Date,
    pinned: Bool = false,
    copies: Int = 1,
    app: String = "Safari 浏览器"
) -> ClipboardItem {
    ClipboardItem(
        kind: kind,
        text: text,
        imagePixelWidth: imagePixels?.0,
        imagePixelHeight: imagePixels?.1,
        fileNames: fileNames,
        fingerprint: UUID().uuidString,
        numberOfCopies: copies,
        pinned: pinned,
        firstCopiedAt: date,
        lastCopiedAt: date,
        sourceAppName: app
    )
}

// MARK: - 剪贴板面板（含数据）

let clipDir = outputDir.appendingPathComponent("render-clip-data", isDirectory: true)
try? FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
let clipStore = ClipboardStore(
    fileURL: clipDir.appendingPathComponent("history.json"),
    imagesDirectory: clipDir,
    autoSave: false
)
let now = Date()
clipStore.record(clipItem(kind: .text, text: "MacTools：把 Maccy 的剪贴板历史与 Ice 的状态栏管理合成一个菜单栏工具", date: now, app: "ZCode"))
clipStore.record(clipItem(kind: .files, fileNames: ["设计稿.sketch", "需求文档.pdf", "截图.png"], date: now.addingTimeInterval(-90), app: "访达"))
clipStore.record(clipItem(kind: .image, imagePixels: (1280, 800), date: now.addingTimeInterval(-240), app: "微信"))
clipStore.record(clipItem(kind: .text, text: "git rebase -i HEAD~3", date: now.addingTimeInterval(-600), pinned: true, app: "终端"))
clipStore.record(clipItem(kind: .text, text: "https://github.com/p0deje/Maccy", date: now.addingTimeInterval(-1500), copies: 3, app: "Chrome"))

// MARK: - 菜单栏图标控制器（预览数据）

let managedController = MenuBarController()
managedController.injectForPreview(
    items: [
        ManagedStatusItem(pid: 432, ownerName: "控制中心", title: "Wi-Fi", width: 38, naturalX: 1258, naturalY: 0, section: .alwaysVisible, isSystem: true),
        ManagedStatusItem(pid: 525, ownerName: "Clash Verge", width: 34, naturalX: 1142, naturalY: 0, section: .hidden),
        ManagedStatusItem(pid: 606, ownerName: "CleanMyMac X 菜单", width: 38, naturalX: 1176, naturalY: 0, section: .alwaysHidden),
        ManagedStatusItem(pid: 2193, ownerName: "微信", width: 54, naturalX: 1088, naturalY: 0, section: .alwaysVisible),
        ManagedStatusItem(pid: 8607, ownerName: "Google Chrome", width: 38, naturalX: 900, naturalY: 0, section: .hidden),
    ],
    isManaging: true
)

// MARK: - 剪贴板面板（含数据）

render(
    ClipboardPanelView(store: clipStore, settings: .shared, onCopyItem: { _ in }),
    size: NSSize(width: 480, height: 600),
    name: "clipboard-panel.png"
)

// MARK: - 剪贴板面板（空状态）

let emptyStore = ClipboardStore(
    fileURL: clipDir.appendingPathComponent("empty.json"),
    imagesDirectory: clipDir,
    autoSave: false
)
render(
    ClipboardPanelView(store: emptyStore, settings: .shared, onCopyItem: { _ in }),
    size: NSSize(width: 480, height: 600),
    name: "clipboard-panel-empty.png"
)

// MARK: - 菜单栏图标面板（未接管）

let idleController = MenuBarController()
render(
    MenuBarPanelView(controller: idleController),
    size: NSSize(width: 480, height: 600),
    name: "menubar-panel-idle.png"
)

// MARK: - 菜单栏图标面板（已接管）

render(
    MenuBarPanelView(controller: managedController),
    size: NSSize(width: 480, height: 600),
    name: "menubar-panel-managed.png"
)

// MARK: - 滚轮方向面板（开启 / 关闭两种状态，使用隔离的 UserDefaults 测试域）

func renderScrollPanels() {
    guard let renderDefaults = UserDefaults(suiteName: "MacToolsUIRender.temp") else { return }
    renderDefaults.removePersistentDomain(forName: "MacToolsUIRender.temp")
    let scrollSettings = SettingsStore(defaults: renderDefaults)
    let reverser = ScrollReverser()

    // 关闭态
    render(
        ScrollPanelView(reverser: reverser, settings: scrollSettings),
        size: NSSize(width: 480, height: 600),
        name: "scroll-panel-off.png"
    )

    // 开启态（默认偏好：反转鼠标、保留触控板自然滚动）
    scrollSettings.scrollReverseEnabled = true
    render(
        ScrollPanelView(reverser: reverser, settings: scrollSettings),
        size: NSSize(width: 480, height: 600),
        name: "scroll-panel-on.png"
    )
}

renderScrollPanels()

// MARK: - 截图功能面板（权限缺失提示态 + 正常态）

func renderScreenshotPanels() {
    guard let defaults = UserDefaults(suiteName: "MacToolsUIRender.screenshot") else { return }
    defaults.removePersistentDomain(forName: "MacToolsUIRender.screenshot")
    let settings = SettingsStore(defaults: defaults)
    let coordinator = ScreenshotCoordinator()
    render(
        ScreenshotPanelView(coordinator: coordinator, settings: settings),
        size: NSSize(width: 480, height: 600),
        name: "screenshot-panel.png"
    )
}

// MARK: - 截图会话视图（演示截图 + 标注：画笔/箭头/文字/马赛克）

func renderCaptureSessionDemo() {
    // 构造 420×240 演示“截图”：渐变底 + 网格
    let width = 420, height = 240
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let colors = [CGColor(red: 0.16, green: 0.52, blue: 0.96, alpha: 1), CGColor(red: 0.10, green: 0.22, blue: 0.48, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 240), options: [])
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    for x in stride(from: 0, through: width, by: 40) {
        context.move(to: CGPoint(x: CGFloat(x), y: 0))
        context.addLine(to: CGPoint(x: CGFloat(x), y: 240))
    }
    for y in stride(from: 0, through: height, by: 40) {
        context.move(to: CGPoint(x: 0, y: CGFloat(y)))
        context.addLine(to: CGPoint(x: 420, y: CGFloat(y)))
    }
    context.strokePath()
    let cg = context.makeImage()!
    let demoImage = NSImage(size: NSSize(width: 420, height: 240))
    demoImage.addRepresentation(NSBitmapImageRep(cgImage: cg))

    let session = CaptureSession(
        image: demoImage,
        captureRect: CGRect(x: 100, y: 500, width: 420, height: 240)
    )
    // 编辑模式 + 预置标注，展示画笔/箭头/文字/马赛克效果
    session.mode = .editing
    session.tool = .pen
    session.addAnnotation(.stroke(id: UUID(), points: [CGPoint(x: 40, y: 60), CGPoint(x: 80, y: 100), CGPoint(x: 120, y: 70)], colorIndex: 0, width: 5))
    session.addAnnotation(.arrow(id: UUID(), from: CGPoint(x: 200, y: 80), to: CGPoint(x: 320, y: 160), colorIndex: 3, width: 5))
    session.addAnnotation(.text(id: UUID(), at: CGPoint(x: 60, y: 200), content: "这里注意！", colorIndex: 4, fontSize: 22))
    session.addAnnotation(.mosaic(id: UUID(), points: [CGPoint(x: 240, y: 40), CGPoint(x: 340, y: 60)], brushWidth: 26, blockSize: 12))

    render(
        CaptureSessionView(
            session: session,
            onPin: {},
            onCopy: {},
            onDiscard: {}
        ),
        size: NSSize(width: 460, height: 420),
        name: "screenshot-session.png"
    )
}

renderScreenshotPanels()
renderCaptureSessionDemo()

// MARK: - 文本翻译面板（含历史数据，明暗两种外观）

func renderTranslatePanels() {
    guard let renderDefaults = UserDefaults(suiteName: "MacToolsUIRender.translate") else { return }
    renderDefaults.removePersistentDomain(forName: "MacToolsUIRender.translate")
    let translateSettings = TranslationSettings(defaults: renderDefaults)
    translateSettings.defaultTargetCode = "zh-Hans"

    let translateDir = outputDir.appendingPathComponent("render-translate-data", isDirectory: true)
    try? FileManager.default.createDirectory(at: translateDir, withIntermediateDirectories: true)
    let history = TranslationHistoryStore(
        fileURL: translateDir.appendingPathComponent("history.json"),
        autoSave: false
    )
    history.add(TranslationRecord(
        sourceText: "The quick brown fox jumps over the lazy dog.",
        translatedText: "敏捷的棕色狐狸跳过了懒惰的狗。",
        sourceLanguage: "auto", targetLanguage: "zh-Hans",
        createdAt: now.addingTimeInterval(-60), fromScreenshot: true
    ))
    history.add(TranslationRecord(
        sourceText: "滚轮方向反转的根因是设备判别把平滑滚轮误判为触控板。",
        translatedText: "The root cause of the scroll reversal failure is that smooth wheels were misclassified as trackpads.",
        sourceLanguage: "zh-Hans", targetLanguage: "en",
        createdAt: now.addingTimeInterval(-3600)
    ))
    history.add(TranslationRecord(
        sourceText: "Hello, world!",
        translatedText: "你好，世界！",
        sourceLanguage: "auto", targetLanguage: "zh-Hans",
        createdAt: now.addingTimeInterval(-86_400)
    ))

    render(
        TextTranslatePanelView(settings: translateSettings, history: history),
        size: NSSize(width: 520, height: 620),
        name: "translate-panel.png"
    )
    render(
        TextTranslatePanelView(settings: translateSettings, history: history),
        size: NSSize(width: 520, height: 620),
        name: "translate-panel-dark.png",
        appearance: .darkAqua
    )
}

renderTranslatePanels()

// MARK: - 输入框占位对齐验证图（空态 vs 填字态，同几何布局）

func renderInputAlignmentSamples() {
    func sample(_ value: String, name: String) {
        render(
            PlaceholderTextEditor(text: .constant(value), placeholder: "输入要翻译的文本…", height: 120)
                .frame(height: 120)
                .padding(12)
                .translateCard(),
            size: NSSize(width: 480, height: 144),
            name: name
        )
    }
    sample("", name: "input-align-empty.png")
    sample("测试输入内容 sample text", name: "input-align-filled.png")
}

renderInputAlignmentSamples()

// MARK: - 长历史列表（验证细滚动条出现）

func renderTranslatePanelLong() {
    guard let renderDefaults = UserDefaults(suiteName: "MacToolsUIRender.translateLong") else { return }
    renderDefaults.removePersistentDomain(forName: "MacToolsUIRender.translateLong")
    let settings = TranslationSettings(defaults: renderDefaults)
    let dir = outputDir.appendingPathComponent("render-translate-long", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let history = TranslationHistoryStore(fileURL: dir.appendingPathComponent("history.json"), autoSave: false)
    for index in 0..<30 {
        history.add(TranslationRecord(
            sourceText: "历史样例原文 \(index) - The quick brown fox jumps over the lazy dog",
            translatedText: "历史样例译文 \(index) - 敏捷的棕色狐狸跳过了懒惰的狗",
            sourceLanguage: "auto", targetLanguage: "zh-Hans",
            createdAt: now.addingTimeInterval(Double(-index * 600))
        ))
    }
    render(
        TextTranslatePanelView(settings: settings, history: history),
        size: NSSize(width: 520, height: 620),
        name: "translate-panel-long.png"
    )
}

renderTranslatePanelLong()

// MARK: - 细滚动条容器隔离测试（40 行内容放在 400pt 视口）

render(
    ThinScrollContainer {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<40, id: \.self) { index in
                Text("滚动测试行 \(index) —— scroll test row")
                    .font(.system(size: 12))
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 300, height: 400)
    .padding(10),
    size: NSSize(width: 320, height: 420),
    name: "thin-scroll-test.png"
)

print("渲染完成")
exit(0)
