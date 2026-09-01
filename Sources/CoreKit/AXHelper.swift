import AppKit
import ApplicationServices
import Foundation
import IOKit.hidsystem

/// 私有 API：把 AXWindow 元素映射到 CGWindowID（Ice 同款做法）。
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ axWindow: AXUIElement, _ windowID: UnsafeMutablePointer<UInt32>) -> AXError

/// 「输入监控」权限（kTCCServiceListenEvent）：macOS 10.15+ 上事件 tap
/// 能否收到系统事件取决于它（Scroll Reverser 的 PermissionsManager 同款检测）。
/// 与辅助功能是两项独立授权；检测是快速非阻塞的，请求会弹系统弹窗且
/// 每个应用一生只弹一次。
public enum InputMonitoringAccess {
    public static func isGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// 触发系统授权弹窗（阻塞调用，需在后台线程执行；只会弹一次）。
    public static func request() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}

/// 辅助功能（AX）基础能力：权限检测、枚举窗口、读取标题、移动窗口位置。
/// 供菜单栏图标管理（AXUIElement 移动）与滚轮方向反转（事件 tap 权限检测）共用。
public enum AXHelper {
    public static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func applicationElement(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    public static func windows(ofApp app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: UInt32 = 0
        guard _AXUIElementGetWindow(element, &id) == .success else { return nil }
        return id
    }

    public static func title(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    @discardableResult
    public static func moveElement(_ element: AXUIElement, to point: CGPoint) -> Bool {
        var target = point
        guard let value = AXValueCreate(.cgPoint, &target) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }
}
