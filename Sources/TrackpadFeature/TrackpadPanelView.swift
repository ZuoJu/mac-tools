import SwiftUI
import CoreKit

public struct TrackpadPanelView: View {
    @ObservedObject private var controller: TrackpadController
    public init(controller: TrackpadController) { self.controller = controller }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("触摸板边缘控制", systemImage: "hand.draw")
                        .font(.title2.bold())
                    Spacer()
                    Toggle("启用", isOn: $controller.enabled).toggleStyle(.switch)
                }
                Text("单指在边缘停留片刻，再上下滑动。上滑增大，下滑减小。")
                    .font(.callout).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        zone("亮度", symbol: "sun.max.fill", color: .orange)
                            .frame(width: geometry.size.width * controller.edgeWidth)
                        VStack(spacing: 8) {
                            Image(systemName: "hand.point.up.left").font(.title2)
                            Text("正常使用").font(.callout)
                            Text("移动 · 多指手势").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        zone("音量", symbol: "speaker.wave.2.fill", color: .blue)
                            .frame(width: geometry.size.width * controller.edgeWidth)
                    }
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.12)))
                }.frame(height: 190)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle().fill(controller.isRunning ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(controller.status).font(.callout)
                    }
                    if !controller.deviceSummary.isEmpty {
                        Text(controller.deviceSummary).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(controller.lastAdjustment).font(.caption).foregroundStyle(.secondary)
                    if controller.enabled && !controller.isRunning {
                        HStack {
                            Button("授权辅助功能") { controller.requestPermission() }
                            Button("重新连接") { controller.reconnect() }
                        }
                    }
                    if controller.isRunning {
                        Button("重新连接触摸板") { controller.reconnect() }.font(.caption)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("每侧边缘宽度"); Spacer(); Text("\(Int((controller.edgeWidth * 100).rounded()))%") }
                    Slider(value: $controller.edgeWidth, in: 0.08...0.25, step: 0.01)
                    HStack { Text("调节灵敏度"); Spacer(); Text(String(format: "%.1f×", controller.sensitivity)) }
                    Slider(value: $controller.sensitivity, in: 0.5...2, step: 0.1)
                }.font(.callout)
                Text("从左右边缘开始，停留约 0.2 秒后滑动；抬手结束。中间区域、多指操作、按下点击均不会调节。亮度优先控制内置屏幕，最低保留 5%；音量跟随当前系统输出设备。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("调节时屏幕底部居中显示当前参数和百分比，同时显示 macOS 原生提示；光标保持不动，抬手立即恢复，数值提示稍后淡出。需要辅助功能权限。普通外接显示器和不支持系统音量的设备会显示提示。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .frame(minWidth: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func zone(_ title: String, symbol: String, color: Color) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "chevron.up")
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption)
            Image(systemName: "chevron.down")
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(0.12))
    }
}
