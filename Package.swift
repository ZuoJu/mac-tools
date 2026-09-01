// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacTools",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MacTools", targets: ["MacToolsApp"])
    ],
    targets: [
        // 基础设施：设置、快捷键、登录项、主题、路径
        .target(name: "CoreKit"),
        // 功能模块一：历史剪贴板管理（Maccy 风格）
        .target(name: "ClipboardFeature", dependencies: ["CoreKit"]),
        // 功能模块二：菜单栏/状态栏图标管理（Ice 风格）
        .target(name: "MenuBarFeature", dependencies: ["CoreKit"]),
        // 功能模块三：全局滚轮方向反转（Scroll Reverser 风格）
        .target(name: "ScrollFeature", dependencies: ["CoreKit"]),
        // 功能模块四：区域截图 + 标注（Snip/清理风格）
        .target(name: "ScreenshotFeature", dependencies: ["CoreKit"]),
        // 功能模块五：AI 翻译（截图 OCR 翻译 + 文本翻译，OpenAI 兼容服务）
        .target(name: "TranslateFeature", dependencies: ["CoreKit"]),
        // 组合根：状态栏入口、面板、设置窗口
        .executableTarget(
            name: "MacToolsApp",
            dependencies: ["CoreKit", "ClipboardFeature", "MenuBarFeature", "ScrollFeature", "ScreenshotFeature", "TranslateFeature"]
        ),
        // 自包含测试运行器：环境仅有 Command Line Tools（无 Xcode/XCTest），
        // 用可执行目标 + 退出码承载单测，`swift run MacToolsTestRunner` 执行。
        .executableTarget(
            name: "MacToolsTestRunner",
            dependencies: ["CoreKit", "ClipboardFeature", "MenuBarFeature", "ScrollFeature", "ScreenshotFeature", "TranslateFeature"]
        ),
        // UI 预览渲染器：把面板 SwiftUI 视图离屏渲染为 PNG，便于无界面环境做视觉检查。
        .executableTarget(
            name: "MacToolsUIRender",
            dependencies: ["CoreKit", "ClipboardFeature", "MenuBarFeature", "ScrollFeature", "ScreenshotFeature", "TranslateFeature"]
        ),
    ]
)
