import AppKit
import CoreKit
import SwiftUI

/// 会话操作快捷键的展示提示（从用户设置生成）。
public struct CaptureKeyHints {
    public var pin: String
    public var copy: String
    public var discard: String

    public init(pin: String = "⌥⇧P", copy: String = "⌥⇧C", discard: String = "⌥⇧X") {
        self.pin = pin
        self.copy = copy
        self.discard = discard
    }
}

/// 截图会话窗口内容：上方画布（预览/编辑），下方固定两行工具栏。
public struct CaptureSessionView: View {
    @ObservedObject public var session: CaptureSession
    public var keyHints: CaptureKeyHints
    public var onPin: () -> Void
    public var onCopy: () -> Void
    public var onDiscard: () -> Void
    @FocusState private var textFieldFocused: Bool

    public init(
        session: CaptureSession,
        keyHints: CaptureKeyHints = CaptureKeyHints(),
        onPin: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self.session = session
        self.keyHints = keyHints
        self.onPin = onPin
        self.onCopy = onCopy
        self.onDiscard = onDiscard
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack {
                AnnotationCanvasRepresentable(session: session)
                    .frame(width: session.displaySize.width, height: session.displaySize.height)
                    .contentShape(Rectangle())
                if session.mode == .editing, session.tool == .text, let pending = session.draftText {
                    textInputOverlay(pending)
                }
            }
            .frame(width: session.displaySize.width, height: session.displaySize.height)
            Divider()
            toolbar
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.25), radius: 18)
        )
        .padding(6)
    }

    // MARK: - 文字输入浮层

    private func textInputOverlay(_ pending: CaptureSession.PendingText) -> some View {
        let x = pending.point.x * session.displayScale
        let yTop = session.displaySize.height - pending.point.y * session.displayScale
        return TextField("输入文字，回车确认", text: Binding(
            get: { session.draftText?.value ?? "" },
            set: { session.draftText?.value = $0 }
        ))
        .focused($textFieldFocused)
        .onAppear { textFieldFocused = true }
        .textFieldStyle(.plain)
        .font(.system(size: 15))
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)).shadow(radius: 4))
        .frame(width: 200)
        .position(x: min(max(x, 100), session.displaySize.width - 100), y: min(max(yTop + 14, 14), session.displaySize.height - 14))
        .onSubmit { commitText() }
    }

    private func commitText() {
        guard let pending = session.draftText, !pending.value.isEmpty else {
            session.draftText = nil
            return
        }
        session.addAnnotation(.text(id: UUID(), at: pending.point, content: pending.value, colorIndex: session.colorIndex, fontSize: 22))
        session.draftText = nil
    }

    // MARK: - 工具栏（固定两行，预览/编辑共用窗口尺寸）

    private var toolbar: some View {
        VStack(spacing: 0) {
            toolRow
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(height: 44)
            Divider()
            actionRow
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(height: 44)
        }
    }

    @ViewBuilder
    private var toolRow: some View {
        if session.mode == .editing {
            HStack(spacing: 8) {
                ForEach(AnnotationTool.allCases) { tool in
                    ToolbarIconButton(
                        symbol: tool.symbolName,
                        label: tool.label,
                        active: session.tool == tool
                    ) {
                        session.tool = tool
                        session.draftText = nil
                    }
                }
                Divider().frame(height: 20)
                ForEach(AnnotationPalette.colors.indices, id: \.self) { index in
                    Circle()
                        .fill(Color(nsColor: AnnotationPalette.color(at: index)))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(
                                session.colorIndex == index ? Color.primary : Color.clear,
                                lineWidth: 2
                            )
                        )
                        .onTapGesture { session.colorIndex = index }
                        .help("标注颜色")
                }
                Spacer(minLength: 8)
                ToolbarIconButton(symbol: "arrow.uturn.backward", label: "撤销", active: false) {
                    session.undo()
                }
                .disabled(session.annotations.isEmpty && session.draftText == nil)
                ToolbarIconButton(symbol: "trash", label: "清空标注", active: false) {
                    session.clearAnnotations()
                }
                .disabled(session.annotations.isEmpty)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("点「标记编辑」可添加画笔 / 箭头 / 文字 / 马赛克标注")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            if session.mode == .editing {
                ToolbarIconButton(symbol: "checkmark.circle", label: "完成编辑", active: false) {
                    session.mode = .preview
                    session.draftText = nil
                }
            } else {
                ToolbarIconButton(symbol: "pencil.and.outline", label: "标记编辑", active: false) {
                    session.mode = .editing
                    session.tool = .pen
                }
            }
            Spacer(minLength: 8)
            ToolbarActionButton(title: "固定显示", sub: keyHints.pin, symbol: "pin.fill") {
                onPin()
            }
            ToolbarActionButton(title: "复制", sub: keyHints.copy, symbol: "doc.on.doc") {
                onCopy()
            }
            ToolbarActionButton(title: "丢弃", sub: keyHints.discard, symbol: "trash") {
                onDiscard()
            }
        }
    }
}

/// 工具栏图标按钮。
struct ToolbarIconButton: View {
    let symbol: String
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(width: 44, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
            )
            .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

/// 工具栏动作按钮（带副标题快捷键）。
struct ToolbarActionButton: View {
    let title: String
    let sub: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(sub).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

/// 画布的 NSViewRepresentable 桥接。
struct AnnotationCanvasRepresentable: NSViewRepresentable {
    let session: CaptureSession

    func makeNSView(context: Context) -> AnnotationCanvasView {
        AnnotationCanvasView(session: session)
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        view.refresh()
    }
}
