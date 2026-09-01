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
        HStack(spacing: 10) {
            leadingIcon
                .frame(width: 46, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(metaText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: onTogglePin) {
                    Image(systemName: item.pinned ? "pin.slash" : "pin")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(item.pinned ? "取消固定" : "固定")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("删除")
            } else if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onCopy() }
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
