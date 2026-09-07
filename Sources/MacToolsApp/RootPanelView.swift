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
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text("历史剪贴板")
                    .font(.system(size: 14, weight: .semibold))
                Text("最近复制内容，点击即可恢复")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(settings.clipboardHotKey.display)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .help("设置（⌘,）")
        }
    }
}
