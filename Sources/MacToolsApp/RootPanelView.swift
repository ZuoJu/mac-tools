import SwiftUI
import CoreKit
import ClipboardFeature

/// 下拉面板根视图：仅历史剪贴板列表（Maccy 式单一职责）。
/// 菜单栏图标 / 滚轮方向 / 截图三个功能面板从状态栏右键菜单以独立窗口打开。
struct RootPanelView: View {
    @ObservedObject var clipStore: ClipboardStore
    @ObservedObject var settings: SettingsStore
    var onCopyItem: (ClipboardItem) -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        ClipboardPanelView(
            store: clipStore,
            settings: settings,
            onCopyItem: onCopyItem,
            onOpenSettings: onOpenSettings
        )
    }
}
