import CoreKit
import SwiftUI
import Carbon.HIToolbox

/// 快捷键录制控件：点击开始录制，按下含修饰键的组合完成录制，Esc 取消。
struct HotKeyRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(recording ? "请按下新快捷键…" : combo.display)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 110)
                .foregroundStyle(recording ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.bordered)
        // 视图消失（切换设置页/关窗）时必须清理监视器，否则全局按键被永久吞掉
        .onDisappear {
            if recording {
                stopRecording()
            }
        }
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        // 暂停全局热键：当前已注册的组合会被系统吞掉、录制器收不到，
        // 暂停后才能录出与现役组合相同的按键（KeyboardShortcuts 的 isPaused 同款）
        HotKeyManager.shared.setPaused(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard recording else { return event }
            if event.keyCode == 53 { // Esc 取消
                stopRecording()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !flags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return nil // 必须带修饰键，避免吞掉普通输入
            }
            let display = Self.displayString(flags: flags, characters: event.charactersIgnoringModifiers ?? "")
            combo = KeyCombo(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: KeyCombo.carbonModifiers(from: flags),
                display: display
            )
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        recording = false
        HotKeyManager.shared.setPaused(false)
    }

    static func displayString(flags: NSEvent.ModifierFlags, characters: String) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += characters.uppercased()
        return text
    }
}
