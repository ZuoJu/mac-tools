import AppKit
import CoreKit
import SwiftUI

/// 剪贴板历史单行视图。
struct ClipboardRowView: View {
    let item: ClipboardItem
    let thumbnail: NSImage?
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        // 列表已改为 ScrollView，因此点击手势不再受 NSTableView 吞掉。这里不用
        // Button 包住整行：macOS 中嵌套 Button 会让固定/删除也可能触发“复制”。
        HStack(spacing: 10) {
            leadingIcon
                .frame(width: 46, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(metaText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                actionButton(
                    symbol: item.pinned ? "pin.slash" : "pin",
                    help: item.pinned ? "取消固定" : "固定",
                    action: onTogglePin
                )
                actionButton(
                    symbol: "trash",
                    tint: .red,
                    help: "删除",
                    action: onDelete
                )
            } else if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? Color.accentColor.opacity(0.10) : .clear)
                .padding(.horizontal, 6)
        }
        .onHover { hovering = $0 }
        .gesture(TapGesture().onEnded(onCopy), including: .gesture)
        .contextMenu {
            Button(action: onCopy) {
                Label("复制到剪贴板", systemImage: "doc.on.doc")
            }
            Button(action: onTogglePin) {
                Label(item.pinned ? "取消固定" : "固定", systemImage: item.pinned ? "pin.slash" : "pin")
            }
            if item.kind == .files, let first = item.filePaths.first {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func actionButton(
        symbol: String,
        tint: Color = .primary,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var leadingIcon: some View {
        Group {
            switch item.kind {
            case .image:
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 46, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.1)))
                } else {
                    placeholderIcon("photo")
                }
            case .files:
                placeholderIcon("folder.fill")
            case .text:
                placeholderIcon("doc.text")
            }
        }
    }

    private func placeholderIcon(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(0.06))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            )
    }

    private var metaText: String {
        var parts: [String] = [item.lastCopiedAt.relativeDisplayText]
        if let app = item.sourceAppName, !app.isEmpty { parts.append(app) }
        switch item.kind {
        case .image:
            if let size = item.byteSize { parts.append(byteCountText(size)) }
        case .files:
            parts.append("\(item.filePaths.count) 个项目")
        case .text:
            if let size = item.byteSize { parts.append(byteCountText(size)) }
        }
        if item.numberOfCopies > 1 { parts.append("×\(item.numberOfCopies)") }
        return parts.joined(separator: " · ")
    }
}
