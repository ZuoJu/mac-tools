import AppKit
import CoreKit
import SwiftUI

/// 截图功能面板：入口说明、快捷键速览、权限状态、固定贴图管理。
public struct ScreenshotPanelView: View {
    @ObservedObject public var coordinator: ScreenshotCoordinator
    @ObservedObject public var settings: SettingsStore
    @State private var permissionTick = 0

    public init(coordinator: ScreenshotCoordinator, settings: SettingsStore) {
        self.coordinator = coordinator
        self.settings = settings
    }

    public var body: some View {
        let _ = permissionTick // 手动“重新检测”后触发重渲染
        return VStack(spacing: 0) {
            if !ScreenCaptureService.hasPermission() {
                permissionBanner
            }
            ScrollView {
                VStack(spacing: 10) {
                    triggerCard
                    flowCard
                    pinnedCard
                }
                .padding(12)
            }
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("截图需要「屏幕录制」权限")
                .font(.caption)
            Spacer()
            Button("重新检测") {
                ScreenCaptureService.invalidatePermissionCache()
                permissionTick += 1
            }
            .font(.caption)
            .buttonStyle(.borderless)
            Button("打开系统设置") {
                ScreenCaptureService.requestPermission()
                permissionTick += 1
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private var triggerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "crosshair.in.box")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("区域截图")
                    .font(.system(size: 14, weight: .semibold))
                Text("快捷键 \(settings.screenshotTriggerHotKey.display) 触发 · 拖拽框选 · 手柄实时调整")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                coordinator.startCapture(
                    pinCombo: settings.screenshotPinHotKey,
                    copyCombo: settings.screenshotCopyHotKey,
                    discardCombo: settings.screenshotDiscardHotKey
                )
            } label: {
                Label("开始截图", systemImage: "camera.viewfinder")
            }
            .controlSize(.large)
            .disabled(!ScreenCaptureService.hasPermission())
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var flowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("截图后浮动工具栏", systemImage: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
            flowRow(symbol: "pin.fill", title: "固定显示最上面", sub: "截图以贴图形式悬浮，可拖动，随时关闭")
            flowRow(symbol: "doc.on.doc", title: "复制到剪贴板", sub: "含全部标注的最终图像")
            flowRow(symbol: "trash", title: "取消并丢弃", sub: "不保存直接关闭")
            flowRow(symbol: "pencil.and.outline", title: "标记编辑", sub: "画笔 / 箭头 / 文字 / 马赛克，标注后再复制或固定")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func flowRow(symbol: String, title: String, sub: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(sub).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var pinnedCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "pin")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("固定中的贴图：\(coordinator.pinnedCount) 张")
                    .font(.system(size: 13, weight: .medium))
                Text("贴图悬浮在所有窗口之上，可拖动；点贴图右上角 × 单独关闭")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("全部关闭") {
                coordinator.closeAllPinned()
            }
            .buttonStyle(.borderless)
            .disabled(coordinator.pinnedCount == 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }
}
