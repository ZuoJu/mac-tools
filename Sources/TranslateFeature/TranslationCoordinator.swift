import AppKit
import CoreKit
import ScreenshotFeature
import SwiftUI

/// 截图翻译协调器：框选 → 截取 → Vision OCR → AI 翻译 → 气泡浮窗展示。
/// 复用截图模块的 RegionSelection 框选与 ScreenCaptureService 截取；
/// 翻译走 TranslationService（与文本翻译同一接口）。
public final class TranslationCoordinator: NSObject, ObservableObject {
    @Published public private(set) var isSelecting = false

    /// 气泡当前状态（驱动浮窗 UI）。
    public enum BubbleState: Equatable {
        case idle
        case recognizing
        case translating(original: String)
        case done(record: TranslationRecord)
        case failed(message: String)
    }

    @Published public private(set) var bubbleState: BubbleState = .idle

    private let selection = RegionSelectionController()
    private let service: TranslationService
    private var bubblePanel: NSPanel?
    private var escMonitor: Any?
    private var runningTask: Task<Void, Never>?
    /// 截取区域（气泡定位用）。
    private var captureRect: CGRect = .zero
    /// 流程代数：新一轮截图翻译开始时自增；在途旧任务的气泡更新
    /// 因代数不匹配被丢弃，避免旧失败覆盖新气泡状态（取消竞态）。
    private var flowGeneration = 0

    /// 服务配置与历史由组合根注入。
    public var settingsProvider: (() -> TranslationSettings?)?
    public var history: TranslationHistoryStore?
    /// 目标语言提供方（默认取设置里的默认目标语言）。
    public var targetLanguageProvider: (() -> Language?)?

    public init(service: TranslationService = TranslationService()) {
        self.service = service
        super.init()
        selection.onConfirm = { [weak self] rect in
            self?.process(rect: rect)
        }
        selection.onCancel = { [weak self] in
            self?.isSelecting = false
        }
    }

    // MARK: - 入口

    /// 触发截图翻译：检查屏幕录制权限 → 开始框选。
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
        // 新一次截图翻译开始时，取消进行中的旧任务并关掉旧气泡
        cancelRunning()
        isSelecting = true
        selection.begin()
    }

    // MARK: - 流程

    private func process(rect: CGRect) {
        isSelecting = false
        guard let image = ScreenCaptureService.capture(globalRect: rect) else {
            FeedbackHUD.show("截取失败，请重试", success: false)
            return
        }
        captureRect = rect
        flowGeneration += 1
        let generation = flowGeneration
        showBubble(state: .recognizing, near: rect)

        runningTask = Task { [weak self] in
            guard let self else { return }
            do {
                let original = try await OCRService.recognizeText(in: image)
                guard !Task.isCancelled else { return }
                let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    self.updateBubble(.failed(message: TranslationError.noTextInImage.errorDescription ?? "未识别到文字"), generation: generation)
                    return
                }
                self.updateBubble(.translating(original: trimmed), generation: generation)

                guard let settings = self.settingsProvider?() else { return }
                let target = self.targetLanguageProvider?()
                    ?? LanguageCatalog.language(forCode: settings.defaultTargetCode)
                    ?? LanguageCatalog.all[0]
                let outcome = try await self.service.translate(
                    TranslationQuery(text: trimmed, source: nil, target: target),
                    settings: settings
                )
                guard !Task.isCancelled else { return }
                let record = TranslationRecord(
                    sourceText: trimmed,
                    translatedText: outcome.translatedText,
                    sourceLanguage: LanguageCatalog.auto.code,
                    targetLanguage: target.code,
                    fromScreenshot: true
                )
                // 历史存储是 @Published：写入必须回主线程
                await MainActor.run {
                    guard self.flowGeneration == generation else { return }
                    self.history?.add(record)
                }
                self.updateBubble(.done(record: record), generation: generation)
            } catch let error as TranslationError where error == .cancelled {
                // 用户取消：静默收场
            } catch let error as TranslationError {
                guard !Task.isCancelled else { return }
                self.updateBubble(.failed(message: error.errorDescription ?? "翻译失败"), generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                self.updateBubble(.failed(message: error.localizedDescription), generation: generation)
            }
        }
    }

    private func cancelRunning() {
        runningTask?.cancel()
        runningTask = nil
        flowGeneration += 1
        closeBubble()
    }

    // MARK: - 气泡浮窗

    private func updateBubble(_ state: BubbleState, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.flowGeneration == generation else { return } // 旧流程的迟到更新直接丢弃
            self.bubbleState = state
            if state == .idle { self.closeBubble() }
        }
    }

    private func showBubble(state: BubbleState, near rect: CGRect) {
        let view = TranslateBubbleView(
            coordinator: self,
            onCopy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                FeedbackHUD.show("译文已复制")
            },
            onClose: { [weak self] in
                self?.cancelRunning()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        // 高度与视图 maxHeight(300) 对齐：过矮会裁剪长译文
        let contentSize = NSSize(width: 400, height: 300)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "截图翻译"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        // 优先显示在截取区域下方；放不下则放上方；整体夹在屏幕可见区域内
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: rect.minX, y: rect.minY - contentSize.height - 10)
        if origin.y < visible.minY {
            origin.y = rect.maxY + 10
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - contentSize.width - 8)
        origin.y = max(origin.y, visible.minY + 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
        bubblePanel = panel
        bubbleState = state
        installEscMonitor()
    }

    private func closeBubble() {
        removeEscMonitor()
        bubblePanel?.orderOut(nil)
        bubblePanel = nil
        bubbleState = .idle
    }

    /// 气泡可见期间 Esc 关闭（非激活面板成为 key window 即可收到）。
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.bubblePanel != nil {
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
