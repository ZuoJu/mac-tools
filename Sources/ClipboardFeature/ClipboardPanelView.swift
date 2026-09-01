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
        onCopyItem: @escaping (ClipboardItem) -> Void
    ) {
        self.store = store
        self.settings = settings
        self.onCopyItem = onCopyItem
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
            List {
                if !pinned.isEmpty {
                    Section("已固定") {
                        ForEach(pinned) { row($0) }
                    }
                }
                if !history.isEmpty {
                    Section(historyHeaderTitle) {
                        ForEach(history) { row($0) }
                    }
                }
            }
            .listStyle(.plain)
        }
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
        .tag(item.id)
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
            Text("共 \(totalCount) 条 · 点击条目复制并关闭面板")
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
            .confirmationDialog("确定清除所有未固定的历史条目？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除未固定条目", role: .destructive) {
                    store.clearAll(keepingPinned: true)
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
