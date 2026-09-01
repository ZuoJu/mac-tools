import AppKit
import SwiftUI

// MARK: - 带占位文本的输入框（NSTextView 封装）

/// 原生 NSTextView 封装：占位文本与输入文字共用同一 textContainer 排版，
/// 严格同行对齐（SwiftUI TextEditor + 手工 padding 的叠加方案必然有偏差）。
/// 固定高度 + 内部纵向滚动（不显示滚动条），高度不随内容变化导致布局跳动。
public struct PlaceholderTextEditor: NSViewRepresentable {
    @Binding var text: String
    public var placeholder: String
    public var font: NSFont = .systemFont(ofSize: 13)
    public var height: CGFloat = 112
    /// 超限状态（外框红色提示由容器负责，这里只透传给边框）。
    public var invalid: Bool = false

    public init(text: Binding<String>, placeholder: String, font: NSFont = .systemFont(ofSize: 13), height: CGFloat = 112, invalid: Bool = false) {
        self._text = text
        self.placeholder = placeholder
        self.font = font
        self.height = height
        self.invalid = invalid
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        textView.placeholder = placeholder
        textView.placeholderFont = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.delegate = context.coordinator
        // 作为滚动文档视图的标准配置：纵向可伸缩、宽度跟随、自动换行
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        // 滚动条彻底不占布局空间
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 6, bottom: 6, right: 4)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as? PlaceholderTextView
        // 仅在外部值变化时同步，避免打断输入光标
        if let textView, textView.string != text {
            textView.string = text
        }
        textView?.placeholder = placeholder
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaceholderTextEditor
        weak var scrollView: NSScrollView?

        public init(_ parent: PlaceholderTextEditor) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// 绘制占位文本的 NSTextView 子类：占位串与正文共用同一文本容器原点。
final class PlaceholderTextView: NSTextView {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }
    var placeholderFont: NSFont = .systemFont(ofSize: 13)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        // textContainerOrigin 与正文排版一致 → 与输入内容严格同行
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = CGPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: placeholderFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}

// MARK: - 细滚动条容器

/// 内容高度 / 视口高度 / 滚动偏移的 PreferenceKey。
private struct ThinScrollContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ThinScrollOffset: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ThinScrollViewportHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// 自带 3pt 细滚动条的滚动容器：隐藏系统滚动条，右侧覆盖自绘指示器。
/// 不占布局空间、不受系统“始终显示滚动条”设置影响，仅在内容可滚动时出现。
public struct ThinScrollContainer<Content: View>: View {
    @ViewBuilder var content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var maxOffset: CGFloat { max(contentHeight - viewportHeight, 0) }

    public var body: some View {
        ScrollView {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ThinScrollContentHeight.self, value: geo.size.height)
                            .preference(key: ThinScrollOffset.self, value: -geo.frame(in: .named("thinScroll")).minY)
                    }
                )
        }
        .coordinateSpace(name: "thinScroll")
        .scrollIndicators(.hidden)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ThinScrollViewportHeight.self, value: geo.size.height)
            }
        )
        .overlay(alignment: .trailing) {
            if maxOffset > 1 {
                ThinKnob(progress: maxOffset > 0 ? min(max(offset, 0) / maxOffset, 1) : 0,
                         ratio: viewportHeight / max(contentHeight, 1))
                    .padding(.vertical, 3)
                    .padding(.trailing, 2)
            }
        }
        .onPreferenceChange(ThinScrollContentHeight.self) { contentHeight = $0 }
        .onPreferenceChange(ThinScrollOffset.self) { offset = $0 }
        .onPreferenceChange(ThinScrollViewportHeight.self) { viewportHeight = $0 }
    }

    /// 3pt 宽的胶囊滑块：随滚动位置移动，带轻微过渡。
    private struct ThinKnob: View {
        let progress: CGFloat
        let ratio: CGFloat

        var body: some View {
            GeometryReader { geo in
                let trackHeight = geo.size.height
                let knobHeight = max(trackHeight * min(max(ratio, 0.05), 1), 22)
                Capsule()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 4, height: knobHeight)
                    .offset(y: progress * (trackHeight - knobHeight))
                    .animation(.easeOut(duration: 0.12), value: progress)
            }
            .frame(width: 3)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - 卡片样式

/// 翻译页统一的卡片外观（输入框 / 译文区共用）。
public struct TranslateCardBackground: ViewModifier {
    public var invalid: Bool = false

    public init(invalid: Bool = false) { self.invalid = invalid }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        invalid ? Color.red.opacity(0.55) : Color.primary.opacity(0.1),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    public func translateCard(invalid: Bool = false) -> some View {
        modifier(TranslateCardBackground(invalid: invalid))
    }
}
