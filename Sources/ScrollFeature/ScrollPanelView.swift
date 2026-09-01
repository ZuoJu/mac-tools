import AppKit
import CoreKit
import SwiftUI

/// 滚轮方向反转面板：主开关 + 按设备类型的方向偏好 + 权限引导。
public struct ScrollPanelView: View {
    @ObservedObject public var reverser: ScrollReverser
    @ObservedObject public var settings: SettingsStore

    public init(reverser: ScrollReverser, settings: SettingsStore) {
        self.reverser = reverser
        self.settings = settings
    }

    public var body: some View {
        let conflictingApps = ScrollReverser.conflictingScrollApps()
        return VStack(spacing: 0) {
            if needsPermission {
                permissionBanner
            }
            if !conflictingApps.isEmpty {
                conflictBanner(conflictingApps)
            }
            ScrollView {
                VStack(spacing: 10) {
                    masterCard
                    if settings.scrollReverseEnabled {
                        diagnosticsLine
                    }
                    if let error = reverser.lastError, settings.scrollReverseEnabled {
                        errorLine(error)
                    }
                    deviceCard
                    advancedCard
                    inputMonitoringCard
                    noteCard
                }
                .padding(12)
            }
        }
    }

    private var needsPermission: Bool {
        settings.scrollReverseEnabled && !AXHelper.isTrusted()
    }

    private var statusText: String {
        if !settings.scrollReverseEnabled { return "已停止" }
        if !AXHelper.isTrusted() { return "等待辅助功能权限（勾选后自动生效，无需重启）" }
        return reverser.isRunning ? "运行中 · 对所有应用全局生效" : "等待辅助功能权限"
    }

    private var statusColor: Color {
        if !settings.scrollReverseEnabled { return Color.secondary }
        return AXHelper.isTrusted() ? Color.green : Color.orange
    }

    /// 引擎诊断行：确认事件 tap 是否真的在接收系统滚动事件。
    private var diagnosticsLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "stethoscope")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(reverser.diagnosticsText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 子视图

    private var masterCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 18))
                .foregroundStyle(settings.scrollReverseEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("滚轮方向反转")
                    .font(.system(size: 14, weight: .semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.scrollReverseEnabled },
                set: { enabled in
                    settings.scrollReverseEnabled = enabled
                    if enabled {
                        _ = reverser.start()
                    } else {
                        reverser.stop()
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var deviceCard: some View {
        VStack(spacing: 0) {
            deviceRow(
                symbol: "computermouse",
                title: "反转鼠标滚轮",
                subtitle: "反转外接鼠标滚轮的垂直滚动方向",
                isOn: Binding(
                    get: { settings.scrollReverseMouse },
                    set: { settings.scrollReverseMouse = $0 }
                )
            )
            Divider().padding(.leading, 46)
            deviceRow(
                symbol: "laptopcomputer",
                title: "反转触控板滚动",
                subtitle: "默认关闭，保持系统“自然滚动”不变",
                isOn: Binding(
                    get: { settings.scrollReverseTrackpad },
                    set: { settings.scrollReverseTrackpad = $0 }
                )
            )
            Divider().padding(.leading, 46)
            deviceRow(
                symbol: "arrow.left.arrow.right",
                title: "横向滚动同时反转",
                subtitle: "开启反转的设备，水平方向也随之反转",
                isOn: Binding(
                    get: { settings.scrollReverseHorizontal },
                    set: { settings.scrollReverseHorizontal = $0 }
                )
            )
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func deviceRow(symbol: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!settings.scrollReverseEnabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { settings.scrollTreatSmoothWheelAsMouse },
                set: { settings.scrollTreatSmoothWheelAsMouse = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("进阶：平滑滚轮鼠标按鼠标处理")
                        .font(.system(size: 13, weight: .medium))
                    Text("罗技 MX 等平滑滚轮鼠标发出的是连续事件，默认会被识别为触控板；如果你的鼠标开了反转却不生效，请开启此项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!settings.scrollReverseEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("开关即时生效；授权后也会自动恢复运行，无需重启本工具或系统", systemImage: "bolt.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("设备识别与 Scroll Reverser 一致：触控板滚动必伴两指触摸，妙控鼠标/平滑滚轮没有，自动分别对待", systemImage: "computermouse.and.hand.pointer.left.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("反转通过系统事件层实现，对所有应用全局生效", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label("偏好设置会自动保存，重启后恢复上次状态", systemImage: "externaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    /// 输入监控权限提示：部分 macOS 版本上事件 tap 缺它会静默收不到事件。
    @ViewBuilder
    private var inputMonitoringCard: some View {
        if settings.scrollReverseEnabled, !InputMonitoringAccess.isGranted() {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("输入监控权限未授权")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("请求授权") {
                        DispatchQueue.global(qos: .userInitiated).async {
                            InputMonitoringAccess.request()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    Button("打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
                Text("部分 macOS 版本要求此权限，事件监听才能收到滚动事件（系统弹窗只出现一次）。若下方诊断计数在你滚动后始终为 0，请授权。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        }
    }

    private var permissionBanner: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("反转滚动需要“辅助功能”权限")
                    .font(.caption)
                Spacer()
                Button("重新检查") {
                    _ = reverser.start()
                }
                .font(.caption)
                .buttonStyle(.borderless)
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("勾选授权后本页会自动恢复运行，无需退出重启。已勾选仍显示未授权？多半是勾选到了旧构建副本的条目：到系统设置里取消勾选、删掉旧的 MacTools 条目后重新勾选（每次重新编译都会生成新指纹，可能产生多个条目）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("当前运行副本：\(Bundle.main.bundlePath)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private func conflictBanner(_ apps: [String]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text("检测到 \(apps.joined(separator: "、")) 正在运行：它同样会改写滚动方向，两者会互相抵消或叠加。请退出其中一方，本功能的反转才会按预期生效。")
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.10))
    }

    private func errorLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
    }
}
