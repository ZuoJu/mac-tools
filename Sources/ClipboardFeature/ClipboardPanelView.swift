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
    @State private var favoritesOnly = false
    public var onOpenSettings: (() -> Void)?
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    public init(
        store: ClipboardStore,
        settings: SettingsStore,
        onCopyItem: @escaping (ClipboardItem) -> Void,
        showsClearConfirmation: Bool = false,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.onOpenSettings = onOpenSettings
        self.store = store
        self.settings = settings
        self.onCopyItem = onCopyItem
        _confirmClear = State(initialValue: showsClearConfirmation)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                searchField.frame(width: 180)
                filterChips
                Spacer(minLength: 0)
            }
            .overlay(alignment: .trailing) {
                HStack(spacing: 12) {
                    Button { newestFirst.toggle() } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }.help(newestFirst ? "最新在前" : "最早在前")
                    Button { confirmClear = true } label: {
                        Image(systemName: "trash")
                    }.help("清除未收藏条目")
                    if let onOpenSettings {
                        Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                            .help("设置")
                    }
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .frame(height: 52)
            content
        }
        .background(.regularMaterial)

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
        favoritesOnly ? [] : filter(store.items.filter { !$0.pinned })
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
        HStack(spacing: 8) {
            chip(nil, title: "全部", color: .pink)
            chip(.text, title: "文本", color: .green)
            chip(.image, title: "图片", color: .orange)
            chip(.files, title: "文件", color: .cyan)
            Button {
                favoritesOnly.toggle()
                kindFilter = nil
            } label: {
                Text("收藏")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.purple.opacity(favoritesOnly ? 0.8 : 0.22), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
        }
    }

    private func chip(_ kind: ClipboardKind?, title: String, color: Color) -> some View {
        let selected = kindFilter == kind && !favoritesOnly
        return Button {
            kindFilter = kind
            favoritesOnly = false
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(color.opacity(selected ? 0.8 : 0.22), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        let items = pinnedVisible + historyVisible
        if items.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ClipboardRowView(
                                item: item,
                                thumbnail: item.kind == .image ? store.image(for: item) : nil,
                                index: index + 1,
                                onCopy: { onCopyItem(item) },
                                onTogglePin: { store.togglePin(item.id) },
                                onDelete: { store.remove(item.id) }
                            )
                            .frame(width: 286, height: max(180, geometry.size.height - 40))
                        }
                    }
                    .frame(height: max(180, geometry.size.height - 40), alignment: .top)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
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
                Text("确定清除所有未收藏的历史条目？")
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                Text("已收藏条目将保留，清除后不可恢复。")
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
                        Text("清除未收藏条目")
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
