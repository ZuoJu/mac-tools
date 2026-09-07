import AppKit
import SwiftUI

/// 截图翻译覆盖层。默认以译文替换截图区域；开启对照后，译文置顶、原截图保留在下方。
public struct TranslateOverlayView: View {
    @ObservedObject var coordinator: TranslationCoordinator
    let image: NSImage

    private let toolbarHeight: CGFloat = 46

    public init(coordinator: TranslationCoordinator, image: NSImage) {
        self.coordinator = coordinator
        self.image = image
    }

    public var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if coordinator.isComparisonEnabled {
                    comparisonLayout(height: max(proxy.size.height - toolbarHeight, 1))
                } else {
                    translationCanvas
                }
                toolbar
                    .frame(height: toolbarHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15))
            }
        }
    }

    // MARK: - 两种显示模式

    /// 默认态：保持在原截取位置，用译文替代被截取区域中的原文。
    private var translationCanvas: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: 10)
                .opacity(0.12)
                .clipped()
            Color(nsColor: .textBackgroundColor)
                .opacity(0.82)
            translationContent(compact: false)
                .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 对照态：上方显示可复制的译文，下面显示未处理的截图原文。
    private func comparisonLayout(height: CGFloat) -> some View {
        let translationHeight = min(max(height * 0.42, 132), 220)
        return VStack(spacing: 0) {
            translationContent(compact: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: translationHeight)
                .background(Color.accentColor.opacity(0.07))
            Divider()
            originalCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var originalCanvas: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.82)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(4)
            Label("原图", systemImage: "photo")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.48), in: Capsule())
                .padding(10)
        }
        .clipped()
    }

    // MARK: - 译文内容

    @ViewBuilder
    private func translationContent(compact: Bool) -> some View {
        switch coordinator.overlayState {
        case .idle, .recognizing:
            statusContent(
                symbol: "text.viewfinder",
                title: "正在识别截图中的文字…",
                detail: "识别完成后将直接显示译文"
            )

        case .translating(let original):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在翻译成\(targetLanguage.displayName)…")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    sourceTargetBadge
                }
                Text(original)
                    .font(.system(size: compact ? 12 : 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 3 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .done(let record):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Label(compact ? "译文" : "翻译完成", systemImage: "character.book.closed.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    sourceTargetBadge
                }
                ScrollView {
                    Text(record.translatedText)
                        .font(.system(size: compact ? 13 : 16, weight: compact ? .regular : .medium))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("可从底部切换目标语言后重新翻译。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusContent(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceTargetBadge: some View {
        Text("自动检测 → \(targetLanguage.displayName)")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.07), in: Capsule())
    }

    // MARK: - 底部操作栏

    private var toolbar: some View {
        HStack(spacing: 7) {
            Picker("目标语言", selection: Binding(
                get: { coordinator.targetLanguageCode },
                set: { coordinator.selectTargetLanguage(code: $0) }
            )) {
                ForEach(LanguageCatalog.targetOptions) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 108)
            .help("切换目标语言并重新翻译")

            Divider().frame(height: 18)

            toolbarButton("原文", symbol: "doc.text", action: coordinator.copyOriginal)
                .disabled(!canCopyOriginal)
            toolbarButton("译文", symbol: "doc.on.doc", action: coordinator.copyTranslation)
                .disabled(!canCopyTranslation)

            Spacer(minLength: 2)

            Button {
                coordinator.setComparisonEnabled(!coordinator.isComparisonEnabled)
            } label: {
                Label("对照", systemImage: coordinator.isComparisonEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(coordinator.isComparisonEnabled ? Color.accentColor : Color.secondary)
            .help(coordinator.isComparisonEnabled ? "关闭原文对照" : "上方显示译文、下方显示原图")

            Button(action: coordinator.closeOverlay) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 12)
        .background(.bar)
    }

    private func toolbarButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var targetLanguage: Language {
        LanguageCatalog.language(forCode: coordinator.targetLanguageCode) ?? LanguageCatalog.all[0]
    }

    private var canCopyOriginal: Bool {
        switch coordinator.overlayState {
        case .translating, .done, .failed: return true
        case .idle, .recognizing: return false
        }
    }

    private var canCopyTranslation: Bool {
        if case .done = coordinator.overlayState { return true }
        return false
    }
}
