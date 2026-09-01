import AppKit
import CoreKit
import SwiftUI

/// 文本翻译窗口：输入区 + 源/目标语言（自动检测 + 手动选择 + 互换）、
/// 结果区（一键复制/清空）、字数限制提示、翻译历史（查看/删除）。
/// 与截图翻译共用 TranslationService。
public struct TextTranslatePanelView: View {
    @ObservedObject public var settings: TranslationSettings
    @ObservedObject public var history: TranslationHistoryStore
    let service: TranslationService

    @State private var inputText = ""
    @State private var sourceCode = LanguageCatalog.auto.code
    @State private var targetCode: String
    @State private var resultText = ""
    @State private var isTranslating = false
    @State private var errorMessage: String?
    @State private var copyFeedback: String?
    @State private var showHistory = true
    @State private var translateTask: Task<Void, Never>?

    public init(
        settings: TranslationSettings,
        history: TranslationHistoryStore,
        service: TranslationService = TranslationService()
    ) {
        self.settings = settings
        self.history = history
        self.service = service
        _targetCode = State(initialValue: settings.defaultTargetCode)
    }

    public var body: some View {
        // 不做整窗滚动：输入/译文/历史各自内部滚动，历史区吃掉剩余空间。
        // （整窗滚动会与历史区形成嵌套滚动容器，偏好键互相污染导致细滚动条失效）
        VStack(spacing: 0) {
            languageBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            inputSection
                .padding(.horizontal, 14)
            actionBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            resultSection
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()
            historySection
                .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 520, minHeight: 600, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            // 窗口关闭时终止进行中的翻译请求
            translateTask?.cancel()
        }
    }

    // MARK: - 语言栏

    private var sourceLanguage: Language? {
        sourceCode == LanguageCatalog.auto.code ? nil : LanguageCatalog.language(forCode: sourceCode)
    }

    private var targetLanguage: Language {
        LanguageCatalog.language(forCode: targetCode) ?? LanguageCatalog.all[0]
    }

    private var languageBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "translate")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
            Picker("源语言", selection: $sourceCode) {
                ForEach(LanguageCatalog.sourceOptions) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .labelsHidden()

            Button {
                if let source = sourceLanguage {
                    // 确定语言 ↔ 目标语言：直接对调，译文填回输入区便于反向翻译
                    let previousTarget = targetCode
                    targetCode = source.code
                    sourceCode = previousTarget
                    if !resultText.isEmpty {
                        inputText = resultText
                        resultText = ""
                    }
                } else {
                    // 源为自动检测：改为“目标语言 → 默认目标”；
                    // 两者相同则退到另一常用语言，保证不出现源 == 目标
                    let fallback = settings.defaultTargetCode != targetCode
                        ? settings.defaultTargetCode
                        : (targetCode == "en" ? "zh-Hans" : "en")
                    sourceCode = targetCode
                    targetCode = fallback
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("互换源语言与目标语言")

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            Picker("目标语言", selection: $targetCode) {
                ForEach(LanguageCatalog.targetOptions) { language in
                    Text(language.displayName).tag(language.code)
                }
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .labelsHidden()
        }
    }

    // MARK: - 输入区

    private var inputTooLong: Bool {
        !TranslationInput.isValid(inputText)
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlaceholderTextEditor(
                text: $inputText,
                placeholder: "输入要翻译的文本…",
                height: 108,
                invalid: inputTooLong
            )
            .frame(height: 108)
            .translateCard(invalid: inputTooLong)
            // 状态行与输入内容底部对齐：计数、超限提示、清空始终同一行
            HStack(spacing: 8) {
                Text("\(inputText.count) / \(TranslationInput.maxLength)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(inputTooLong ? Color.red : Color.secondary)
                if inputTooLong {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.red)
                    Text("超出长度限制，请分段翻译")
                        .font(.caption2)
                        .foregroundStyle(Color.red)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !inputText.isEmpty {
                    Button("清空输入") {
                        inputText = ""
                        resultText = ""
                        errorMessage = nil
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("清空输入与译文")
                }
            }
            .padding(.leading, 2)
        }
    }

    // MARK: - 操作栏（状态提示与按钮严格同一行）

    private var canTranslate: Bool {
        !isTranslating && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !inputTooLong
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if isTranslating {
                    ProgressView()
                        .controlSize(.mini)
                    Text("翻译中…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if let errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.orange)
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.orange)
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .help(errorMessage ?? "")
            .animation(.easeInOut(duration: 0.15), value: isTranslating)
            .animation(.easeInOut(duration: 0.15), value: errorMessage)

            Spacer(minLength: 12)

            Button(action: translate) {
                Label("翻译", systemImage: "sparkles")
                    .font(.system(size: 13, weight: .medium))
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!canTranslate)
        }
    }

    // MARK: - 结果区

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("译文")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !resultText.isEmpty {
                    Text("· \(sourceLanguage?.displayName ?? LanguageCatalog.auto.displayName) → \(targetLanguage.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let copyFeedback {
                    Label(copyFeedback, systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.green)
                        .transition(.opacity)
                }
                if !resultText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resultText, forType: .string)
                        withAnimation(.easeIn(duration: 0.15)) { copyFeedback = "已复制" }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeOut(duration: 0.3)) { copyFeedback = nil }
                        }
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    Button {
                        resultText = ""
                    } label: {
                        Label("清空", systemImage: "trash")
                            .font(.system(size: 12))
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            ScrollView {
                Text(resultText.isEmpty && !isTranslating ? "—" : resultText)
                    .font(.system(size: 14))
                    .foregroundStyle(resultText.isEmpty && !isTranslating ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: 68, maxHeight: 110)
            .translateCard()
        }
    }

    // MARK: - 历史区

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("翻译历史", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(history.records.count) 条")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !history.records.isEmpty {
                    Button("清空历史", role: .destructive) {
                        history.clearAll()
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            if showHistory {
                ThinScrollContainer {
                    // 注意:不能用 LazyVStack——惰性布局会让内容高度测量等于视口高度,细滚动条永远不出现
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(history.records.enumerated()), id: \.element.id) { index, record in
                            HistoryRow(record: record) {
                                history.delete(at: IndexSet(integer: index))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 96, maxHeight: .infinity)
                .overlay {
                    if history.records.isEmpty {
                        Text("暂无历史记录")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Button {
                    withAnimation { showHistory = true }
                } label: {
                    Label("展开历史（\(history.records.count) 条）", systemImage: "chevron.up")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - 翻译

    private func translate() {
        guard canTranslate else { return }
        let query = TranslationQuery(
            text: inputText.trimmingCharacters(in: .whitespacesAndNewlines),
            source: sourceLanguage,
            target: targetLanguage
        )
        isTranslating = true
        errorMessage = nil
        translateTask?.cancel()
        translateTask = Task {
            do {
                let outcome = try await service.translate(query, settings: settings)
                let record = TranslationRecord(
                    sourceText: query.text,
                    translatedText: outcome.translatedText,
                    sourceLanguage: query.source?.code ?? LanguageCatalog.auto.code,
                    targetLanguage: query.target.code,
                    fromScreenshot: false
                )
                // Task 继承的是全局执行器：@State/@Published 必须回主线程改
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    resultText = outcome.translatedText
                    history.add(record)
                    isTranslating = false
                }
            } catch let error as TranslationError where error == .cancelled {
                await MainActor.run { isTranslating = false }
            } catch let error as TranslationError {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    errorMessage = error.errorDescription
                    isTranslating = false
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                    isTranslating = false
                }
            }
        }
    }
}

/// 历史行：原文 → 译文摘要 + 语言对 + 时间，悬停显示删除。
struct HistoryRow: View {
    let record: TranslationRecord
    var onDelete: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: record.fromScreenshot ? "text.viewfinder" : "text.quote")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.sourceText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(record.translatedText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(record.sourceLanguageName) → \(record.targetLanguageName)")
                    Text(Self.timeFormatter.string(from: record.createdAt))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .opacity(0.4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.translatedText, forType: .string)
            FeedbackHUD.show("译文已复制")
        }
        .help("点击复制译文")
    }
}
