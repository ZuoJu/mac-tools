import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 菜单栏图标管理面板：接管开关、显隐切换、拖拽排序。
public struct MenuBarPanelView: View {
    @ObservedObject public var controller: MenuBarController
    @State private var draggingID: String?

    public init(controller: MenuBarController) {
        self.controller = controller
    }

    public var body: some View {
        let conflictingApps = MenuBarController.conflictingMenuBarApps()
        return VStack(spacing: 0) {
            if let error = controller.lastError {
                errorBanner(error)
            }
            if !conflictingApps.isEmpty {
                conflictBanner(conflictingApps)
            }
            if !controller.accessibilityGranted {
                permissionBanner
            }
            if controller.isManaging {
                managedContent
            } else {
                setupContent
            }
        }
    }

    // MARK: - 未接管

    private var setupContent: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("管理菜单栏图标")
                .font(.system(size: 15, weight: .semibold))
            Text("「接管」＝取得菜单栏图标的排列权（与 Ice 同思路）：\n接管后每个图标可归入三个分区——始终显示 / 默认隐藏 / 始终隐藏，\n菜单栏出现两个分隔符按钮，各自展开对应分区，\n展开后点开图标菜单、菜单关闭会自动收回，\n新出现的图标会被自动纳入管理，停止接管全部还原。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                controller.enable()
            } label: {
                Label("接管菜单栏图标", systemImage: "hand.tap")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            Text("自定义收缩哪些图标：接管后在每行右侧选择分区即可；\n也可以「全部折叠」后把常用的几个改回「始终显示」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 已接管

    private var managedContent: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(controller.items) { item in
                        MenuBarItemRow(
                            item: item,
                            onSectionChange: { section in controller.setItemSection(id: item.id, section: section) },
                            onMoveUp: { controller.shiftItem(id: item.id, offset: -1) },
                            onMoveDown: { controller.shiftItem(id: item.id, offset: 1) }
                        )
                        .onDrag {
                            draggingID = item.id
                            return NSItemProvider(object: item.id as NSString)
                        }
                        .onDrop(
                            of: [UTType.plainText],
                            delegate: ReorderDropDelegate(
                                targetID: item.id,
                                draggingID: $draggingID,
                                onReorder: { dragged, target in
                                    controller.moveItem(id: dragged, to: target)
                                },
                                onFinished: { controller.applyReorder() }
                            )
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            Divider()
            Text("拖拽调整优先级（列表靠右越优先）· 分区：始终显示 / 默认隐藏（分隔符1）/ 始终隐藏（分隔符2）· 展开区点开菜单后会自动收回")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 6)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("共 \(controller.items.count) 个 · 始终显示 \(controller.items.filter { $0.section == .alwaysVisible }.count) / 默认隐藏 \(controller.items.filter { $0.section == .hidden }.count) / 始终隐藏 \(controller.items.filter { $0.section == .alwaysHidden }.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                controller.hideAllNonSystem()
            } label: {
                Label("全部折叠", systemImage: "eye.slash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            Button {
                controller.showAll()
            } label: {
                Label("全部显示", systemImage: "eye")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            Button {
                controller.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("重新扫描")
            Button(role: .destructive) {
                controller.disable()
            } label: {
                Label("停止接管", systemImage: "xmark.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 提示条

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            Text(text)
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    private func conflictBanner(_ apps: [String]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text("检测到 \(apps.joined(separator: "、")) 正在管理菜单栏：它会持续重排图标、与本功能争抢布局。请先退出该工具（在其菜单栏图标菜单里 Quit），再重新接管本功能。")
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.10))
    }

    private var permissionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("移动图标需要“辅助功能”权限")
                .font(.caption)
            Spacer()
            Button("打开系统设置") {
                openAccessibilitySettings()
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 拖拽排序的放置代理：dropEntered 时渐进重排。
struct ReorderDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingID: String?
    var onReorder: (String, String) -> Void
    var onFinished: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = draggingID, dragged != targetID else { return }
        onReorder(dragged, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        onFinished()
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingID != nil
    }
}

/// 管理列表的一行。
struct MenuBarItemRow: View {
    let item: ManagedStatusItem
    let onSectionChange: (ItemSection) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.isSystem {
                Text("系统")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up").font(.system(size: 8))
                }
                .buttonStyle(.borderless)
                .help("优先级上移")
                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .buttonStyle(.borderless)
                .help("优先级下移")
            }
            Picker("", selection: Binding(
                get: { item.section },
                set: onSectionChange
            )) {
                ForEach(ItemSection.allCases) { section in
                    Text(section.label).tag(section)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 104)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(item.section == .alwaysVisible ? Color.primary.opacity(0.05) : Color.primary.opacity(0.03))
        )
    }

    private var subtitle: String {
        ["PID \(item.pid)", "\(Int(item.width))pt", item.section.label].joined(separator: " · ")
    }

    private var icon: Image {
        if let appIcon = AppIconCache.icon(pid: item.pid) {
            return Image(nsImage: appIcon)
        }
        return Image(systemName: "menubar.rectangle")
    }
}

/// 按进程号缓存应用图标。
enum AppIconCache {
    static let cache = NSCache<NSString, NSImage>()

    static func icon(pid: Int) -> NSImage? {
        let key = "\(pid)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSRunningApplication(processIdentifier: pid_t(pid))?.icon
        if let icon {
            cache.setObject(icon, forKey: key)
        }
        return icon
    }
}
