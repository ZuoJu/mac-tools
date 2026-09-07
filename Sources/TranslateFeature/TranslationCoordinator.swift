import AppKit
import CoreKit
import ScreenshotFeature
import SwiftUI

/// 截图翻译协调器：框选后立即截取、OCR、翻译，并直接在截取区域呈现结果。
/// 普通模式用译文覆盖原截图区域；对照模式在上方放译文、下方保留原截图。
public final class TranslationCoordinator: NSObject, ObservableObject {
    @Published public private(set) var isSelecting = false

    public enum OverlayState: Equatable {
        case idle
        case recognizing
        case translating(original: String)
        case done(record: TranslationRecord)
        case failed(message: String)
    }

    @Published public private(set) var overlayState: OverlayState = .idle
    @Published public private(set) var targetLanguageCode = "zh-Hans"
    @Published public private(set) var isComparisonEnabled = false

    private let selection = RegionSelectionController()
    private let service: TranslationService
    private var overlayPanel: NSPanel?
    private var escMonitor: Any?
    private var runningTask: Task<Void, Never>?
    private var capturedImage: NSImage?
    private var recognizedOriginalText: String?
    /// 截取区域用于让默认译文覆盖原位置；对照模式则以它的底边对齐原图。
    private var captureRect: CGRect = .zero
    /// 每轮流程递增，防止旧请求覆盖后一次截图或重新翻译的结果。
    private var flowGeneration = 0

    /// 服务配置与历史由组合根注入。
    public var settingsProvider: (() -> TranslationSettings?)?
    public var history: TranslationHistoryStore?
    public var targetLanguageProvider: (() -> Language?)?

    public init(service: TranslationService = TranslationService()) {
        self.service = service
        super.init()
        // 截图翻译是一气呵成的操作；普通截图仍沿用默认的回车/双击确认模式。
        selection.confirmationMode = .onMouseUp
        selection.onConfirm = { [weak self] rect in
            self?.process(rect: rect)
        }
        selection.onCancel = { [weak self] in
            self?.isSelecting = false
        }
    }

    // MARK: - 入口

    /// 触发截图翻译：检查屏幕录制权限后开始框选。松开鼠标即截取并翻译。
    public func startCaptureTranslate() {
        guard !isSelecting else { return }
        guard ScreenCaptureService.hasPermission() else {
            ScreenCaptureService.requestPermission()
            FeedbackHUD.show("截图翻译需要「屏幕录制」权限，请在系统设置中勾选本工具", success: false)
            return
        }
        guard let settings = settingsProvider?(), settings.isConfigured else {
            FeedbackHUD.show("请先到「设置 → 翻译」配置翻译服务", success: false)
            return
        }
        cancelRunning()
        isSelecting = true
        selection.begin()
    }

    // MARK: - 交互

    /// 切换目标语言时直接复用 OCR 原文重新翻译，无需重新截图。
    public func selectTargetLanguage(code: String) {
        guard LanguageCatalog.language(forCode: code) != nil, code != targetLanguageCode else { return }
        targetLanguageCode = code
        guard let original = recognizedOriginalText, !original.isEmpty else { return }

        runningTask?.cancel()
        flowGeneration += 1
        let generation = flowGeneration
        runningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.translate(original: original, targetCode: code, generation: generation)
        }
    }

    public func setComparisonEnabled(_ enabled: Bool) {
        guard isComparisonEnabled != enabled else { return }
        isComparisonEnabled = enabled
        resizeOverlay()
    }

    public func copyOriginal() {
        guard let original = recognizedOriginalText, !original.isEmpty else { return }
        copy(original, feedback: "原文已复制")
    }

    public func copyTranslation() {
        guard case .done(let record) = overlayState else { return }
        copy(record.translatedText, feedback: "译文已复制")
    }

    public func closeOverlay() {
        cancelRunning()
    }

    /// 离屏渲染器与 UI 回归检查用：构造已完成的截图翻译状态，不发起 OCR 或网络请求。
    public func injectForPreview(
        record: TranslationRecord,
        comparisonEnabled: Bool = false
    ) {
        targetLanguageCode = record.targetLanguage
        recognizedOriginalText = record.sourceText
        isComparisonEnabled = comparisonEnabled
        overlayState = .done(record: record)
    }

    // MARK: - 翻译流程

    private func process(rect: CGRect) {
        isSelecting = false
        guard let image = ScreenCaptureService.capture(globalRect: rect) else {
            FeedbackHUD.show("截取失败，请重试", success: false)
            return
        }
        captureRect = rect
        capturedImage = image
        recognizedOriginalText = nil
        isComparisonEnabled = false
        targetLanguageCode = (targetLanguageProvider?()
            ?? settingsProvider?().flatMap { LanguageCatalog.language(forCode: $0.defaultTargetCode) }
            ?? LanguageCatalog.all[0]).code

        flowGeneration += 1
        let generation = flowGeneration
        showOverlay(state: .recognizing, image: image)

        runningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let original = try await OCRService.recognizeText(in: image)
                guard !Task.isCancelled, self.flowGeneration == generation else { return }
                let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.updateOverlay(.failed(message: TranslationError.noTextInImage.errorDescription ?? "未识别到文字"), generation: generation)
                    return
                }
                self.recognizedOriginalText = trimmed
                await self.translate(original: trimmed, targetCode: self.targetLanguageCode, generation: generation)
            } catch let error as TranslationError where error == .cancelled {
                // 用户关闭面板：静默结束。
            } catch let error as TranslationError {
                guard !Task.isCancelled else { return }
                self.updateOverlay(.failed(message: error.errorDescription ?? "翻译失败"), generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self.updateOverlay(.failed(message: error.localizedDescription), generation: generation)
            }
        }
    }

    private func translate(original: String, targetCode: String, generation: Int) async {
        guard let settings = settingsProvider?(),
              let target = LanguageCatalog.language(forCode: targetCode) else {
            updateOverlay(.failed(message: "翻译配置无效，请检查设置"), generation: generation)
            return
        }
        updateOverlay(.translating(original: original), generation: generation)
        do {
            let outcome = try await service.translate(
                TranslationQuery(text: original, source: nil, target: target),
                settings: settings
            )
            guard !Task.isCancelled, flowGeneration == generation else { return }
            let record = TranslationRecord(
                sourceText: original,
                translatedText: outcome.translatedText,
                sourceLanguage: LanguageCatalog.auto.code,
                targetLanguage: target.code,
                fromScreenshot: true
            )
            history?.add(record)
            updateOverlay(.done(record: record), generation: generation)
        } catch let error as TranslationError where error == .cancelled {
            // 用户切换语言或关闭面板时取消旧请求，不显示错误。
        } catch let error as TranslationError {
            guard !Task.isCancelled else { return }
            updateOverlay(.failed(message: error.errorDescription ?? "翻译失败"), generation: generation)
        } catch {
            guard !Task.isCancelled else { return }
            updateOverlay(.failed(message: error.localizedDescription), generation: generation)
        }
    }

    private func cancelRunning() {
        runningTask?.cancel()
        runningTask = nil
        flowGeneration += 1
        closeOverlayPanel()
    }

    private func updateOverlay(_ state: OverlayState, generation: Int) {
        guard flowGeneration == generation else { return }
        overlayState = state
    }

    private func copy(_ text: String, feedback: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        FeedbackHUD.show(feedback)
    }

    // MARK: - 截图内译文覆盖层

    private func showOverlay(state: OverlayState, image: NSImage) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: overlaySize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: TranslateOverlayView(coordinator: self, image: image))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        overlayPanel = panel
        overlayState = state
        positionOverlay()
        panel.orderFrontRegardless()
        panel.makeKey()
        installEscMonitor()
    }

    private var overlaySize: NSSize {
        let visible = overlayVisibleFrame
        let imageSize = capturedImage?.size ?? captureRect.size
        let width = min(max(max(imageSize.width, 360), 1), min(680, visible.width - 24))
        let scaledImageHeight = width * max(imageSize.height, 1) / max(imageSize.width, 1)
        let toolbarHeight: CGFloat = 46

        if isComparisonEnabled {
            let maximumImageHeight = max(140, visible.height - 210)
            let imageHeight = min(max(scaledImageHeight, 140), maximumImageHeight)
            let translationHeight = min(max(imageHeight * 0.55, 142), 230)
            return NSSize(width: width, height: min(imageHeight + translationHeight + toolbarHeight, visible.height - 16))
        }
        return NSSize(width: width, height: min(max(scaledImageHeight, 180), visible.height - 16))
    }

    private var overlayVisibleFrame: NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(captureRect) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func resizeOverlay() {
        guard let overlayPanel else { return }
        overlayPanel.setContentSize(overlaySize)
        positionOverlay()
    }

    private func positionOverlay() {
        guard let overlayPanel else { return }
        let size = overlayPanel.frame.size
        let visible = overlayVisibleFrame
        let preferredX = captureRect.midX - size.width / 2
        // 对照时固定原图底边；普通模式则居中覆盖原截图位置。
        let preferredY = isComparisonEnabled
            ? captureRect.minY - 46
            : captureRect.midY - size.height / 2
        let origin = NSPoint(
            x: min(max(preferredX, visible.minX + 8), visible.maxX - size.width - 8),
            y: min(max(preferredY, visible.minY + 8), visible.maxY - size.height - 8)
        )
        overlayPanel.setFrameOrigin(origin)
    }

    private func closeOverlayPanel() {
        removeEscMonitor()
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        capturedImage = nil
        recognizedOriginalText = nil
        overlayState = .idle
        isComparisonEnabled = false
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.overlayPanel != nil {
                self.cancelRunning()
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
        }
        escMonitor = nil
    }
}
