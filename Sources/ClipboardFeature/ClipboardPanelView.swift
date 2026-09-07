import SwiftUI
import CoreKit

/// 剪贴板历史面板：搜索、类型筛选、时间排序、固定/删除、一键复制。
public struct ClipboardPanelView: View {
    @ObservedObject public var store: ClipboardStore
    @ObservedObject public var settings: SettingsStore
    public var onCopyItem: (ClipboardItem) -> Void

    @State private var searchText = ""
    @State private var kindFilter: ClipboardKind?
    @State private var newestFirst = true
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    public init(
        store: ClipboardStore,
        settings: SettingsStore,
        onCopyItem: @escaping (ClipboardItem) -> Void,
        showsClearConfirmation: Bool = false
    ) {
        self.store = store
        self.settings = settings
        self.onCopyItem = onCopyItem
        _confirmClear = State(initialValue: showsClearConfirmation)
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 10)
            filterChips
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            content
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        // 面板内自绘确认弹层：不用 confirmationDialog——它会以 sheet 形式接管 key
        // 状态，触发面板失焦自动关闭；overlay 留在同一窗口内，清除后面板保持打开。
        .overlay {
            if confirmClear {
                clearConfirmation
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidShow)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
    }

    // MARK: - 数据

    private var pinnedVisible: [ClipboardItem] {
        filter(store.items.filter(\.pinned))
    }

    private var historyVisible: [ClipboardItem] {
        filter(store.items.filter { !$0.pinned })
    }

    private func filter(_ source: [ClipboardItem]) -> [ClipboardItem] {
        var result = source
        if let kind = kindFilter {
            result = result.filter { $0.kind == kind }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
        }
        result.sort { newestFirst ? $0.lastCopiedAt > $1.lastCopiedAt : $0.lastCopiedAt < $1.lastCopiedAt }
        return result
    }

    private var totalCount: Int { store.items.count }

    private var visibleCount: Int { pinnedVisible.count + historyVisible.count }

    // MARK: - 子视图

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索剪贴板历史…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            chip(nil, title: "全部", count: totalCount)
            ForEach(ClipboardKind.allCases) { kind in
                chip(kind, title: kind.label, count: store.items.filter { $0.kind == kind }.count)
            }
            Spacer()
            Button {
                newestFirst.toggle()
            } label: {
                Label(newestFirst ? "最新在前" : "最早在前", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("切换时间排序")
        }
    }

    private func chip(_ kind: ClipboardKind?, title: String, count: Int) -> some View {
        let selected = kindFilter == kind
        return Button {
            kindFilter = selected ? nil : kind
        } label: {
            Text(count > 0 ? "\(title) \(count)" : title)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
        .foregroundColor(selected ? Color.accentColor : Color.secondary)
    }

    @ViewBuilder
    private var content: some View {
        let pinned = pinnedVisible
        let history = historyVisible
        if pinned.isEmpty && history.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // ScrollView + LazyVStack 而非 List：List 的 NSTableView 桥接层在行内容
            // 没有系统文本/控件时整行原生点击不可靠（AXPress 正常、鼠标点击被吞），
            // 自绘行头 + 普通滚动视图没有这层问题。
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !pinned.isEmpty {
                        sectionHeader("已固定 · \(pinned.count)")
                        ForEach(pinned) { row($0) }
                    }
                    if !history.isEmpty {
                        sectionHeader("\(historyHeaderTitle) · \(history.count)")
                        ForEach(history) { row($0) }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.background)
    }

    private var historyHeaderTitle: String {
        newestFirst ? "历史（最近复制在前）" : "历史（最早复制在前）"
    }

    private func row(_ item: ClipboardItem) -> some View {
        ClipboardRowView(
            item: item,
            thumbnail: item.kind == .image ? store.image(for: item) : nil,
            onCopy: { onCopyItem(item) },
            onTogglePin: { store.togglePin(item.id) },
            onDelete: { store.remove(item.id) }
        )
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 68)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "暂无剪贴板历史" : "没有匹配的结果")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "复制任意文本、图片或文件，会自动记录到这里" : "试试其他关键词或筛选条件")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 30)
    }

    private var footer: some View {
        HStack {
            Text(visibleCount == totalCount
                 ? "共 \(totalCount) 条 · 点击条目复制并关闭面板"
                 : "显示 \(visibleCount) / \(totalCount) 条 · 点击条目复制并关闭面板")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                confirmClear = true
            } label: {
                Label("清除未固定", systemImage: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(store.items.filter { !$0.pinned }.isEmpty)
        }
    }

    private var clearConfirmation: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.2))
                .contentShape(Rectangle())
                .onTapGesture { confirmClear = false }
            VStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.red)
                Text("确定清除所有未固定的历史条目？")
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("已固定条目将保留，清除后不可恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button {
                        confirmClear = false
                    } label: {
                        Text("取消")
                            .font(.system(size: 13))
                            .frame(width: 118, height: 26)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    Button {
                        confirmClear = false
                        store.clearAll(keepingPinned: true)
                    } label: {
                        Text("清除未固定条目")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 118, height: 26)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 5)
            )
            .padding(24)
        }
    }
}
