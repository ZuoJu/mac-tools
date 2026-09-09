import AppKit
import ApplicationServices

/// 面板打开前的输入焦点；关闭后必须仍是同一应用、同一可编辑元素。
public struct ClipboardPasteTarget {
    private let pid: pid_t
    private let element: AXUIElement

    public static func capture() -> ClipboardPasteTarget? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement(pid: app.processIdentifier),
              isEditable(element) else { return nil }
        return ClipboardPasteTarget(pid: app.processIdentifier, element: element)
    }

    public func pasteIfStillFocused() {
        guard AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let current = Self.focusedElement(pid: pid),
              CFEqual(current, element), Self.isEditable(current) else { return }
        Paster.pasteToActiveApp()
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled) == .success,
           let enabled = enabled as? Bool, !enabled { return false }
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &editable) == .success,
           let editable = editable as? Bool { return editable }
        var valueSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
           valueSettable.boolValue { return true }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
    }
}
