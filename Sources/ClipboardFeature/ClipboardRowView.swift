import AppKit
import CoreKit
import SwiftUI

/// 横向剪贴板卡片；内容区域复制，底部按钮独立处理收藏操作。
struct ClipboardRowView: View {
    let item: ClipboardItem
    let thumbnail: NSImage?
    let index: Int
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var tint: Color {
        switch item.kind {
        case .text: return Color(red: 0.32, green: 0.83, blue: 0.43)
        case .image: return Color(red: 0.98, green: 0.77, blue: 0.33)
        case .files: return Color(red: 0.36, green: 0.75, blue: 0.87)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack {
                    Text(item.kind == .text ? "纯文本" : item.kind.label)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    sourceIcon.frame(width: 26, height: 26)
                }
                HStack {
                    Text(item.lastCopiedAt.relativeDisplayText)
                    Spacer()
                    Text(item.sourceAppName ?? "未知应用").lineLimit(1)
                }.font(.system(size: 11))
            }
            .foregroundStyle(Color.black.opacity(0.8))
            .padding(12)
            .background(tint)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onCopy)

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onCopy)

            HStack(spacing: 8) {
                Text("\(index)").foregroundStyle(.teal)
                Spacer(minLength: 0)
                Text(sizeText).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onTogglePin) {
                    Image(systemName: item.pinned ? "star.fill" : "star")
                        .foregroundStyle(item.pinned ? Color.orange : Color.secondary)
                }.help(item.pinned ? "取消收藏" : "收藏")
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                }.help("复制并关闭面板")
            }
            .font(.system(size: 13))
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.bottom, 9).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hovering ? tint : .clear, lineWidth: 3)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("复制到剪贴板", action: onCopy)
            Button(item.pinned ? "取消收藏" : "收藏", action: onTogglePin)
            if item.kind == .files, let first = item.filePaths.first {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)])
                }
            }
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .text:
            Text(String((item.text ?? "").prefix(3000)))
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image:
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
            } else {
                Label("图片预览不可用", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        case .files:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array((item.fileNames ?? item.filePaths).prefix(8).enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: "doc.fill").lineLimit(2)
                }
            }.font(.system(size: 13))
        }
    }

    @ViewBuilder private var sourceIcon: some View {
        if let bundleID = item.sourceAppBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 18)).foregroundStyle(Color.black.opacity(0.6))
        }
    }

    private var sizeText: String {
        switch item.kind {
        case .text: return "\(item.text?.count ?? 0) 个字符"
        case .files: return "\(item.fileNames?.count ?? item.filePaths.count) 个文件"
        case .image:
            if let size = item.byteSize { return byteCountText(size) }
            if let width = item.imagePixelWidth, let height = item.imagePixelHeight {
                return "\(Int(width)) × \(Int(height))"
            }
            return "图片"
        }
    }
}
