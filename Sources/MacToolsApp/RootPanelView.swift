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
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider()
            ClipboardPanelView(
                store: clipStore,
                settings: settings,
                onCopyItem: onCopyItem
            )
        }
        .frame(width: 480, height: 640)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("历史剪贴板", systemImage: "doc.on.clipboard")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("共 \(clipStore.items.count) 条")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("设置（⌘,）")
        }
    }
}
