import SwiftUI

/// 截图翻译气泡浮窗：识别中 / 翻译中 / 结果 / 失败 四态。
/// 原文折叠展示、译文突出显示，支持一键复制与关闭（Esc 同效）。
struct TranslateBubbleView: View {
    @ObservedObject var coordinator: TranslationCoordinator
    var onCopy: (String) -> Void
    var onClose: () -> Void

    @State private var showOriginal = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .frame(maxHeight: 300)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text("截图翻译")
                .font(.system(size: 12, weight: .semibold))
            stateBadge
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        Group {
            switch coordinator.bubbleState {
            case .recognizing:
                Label("识别文字中", systemImage: "text.viewfinder")
            case .translating:
                Label("翻译中", systemImage: "sparkles")
            case .done:
                Label("完成", systemImage: "checkmark.circle.fill")
            case .failed:
                Label("失败", systemImage: "exclamationmark.triangle.fill")
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.bubbleState {
        case .idle, .recognizing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在识别截图中的文字…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .translating(let original):
            VStack(alignment: .leading, spacing: 8) {
                originalBlock(original)
                Divider()
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在翻译…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

        case .done(let record):
            VStack(alignment: .leading, spacing: 8) {
                if showOriginal {
                    originalBlock(record.sourceText)
                    Divider()
                }
                ScrollView {
                    Text(record.translatedText)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 180)
                HStack {
                    Text("\(record.sourceLanguageName) → \(record.targetLanguageName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        onCopy(record.translatedText)
                    } label: {
                        Label("复制译文", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("关闭", action: onClose)
                        .controlSize(.small)
                }
            }
        }
    }

    private func originalBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("原文")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showOriginal.toggle() }
                } label: {
                    Image(systemName: showOriginal ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(showOriginal ? "收起原文" : "展开原文")
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }
}
