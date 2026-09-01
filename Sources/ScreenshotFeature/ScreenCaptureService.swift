import AppKit
import CoreGraphics
import CoreKit
import Foundation
import SwiftUI

/// 屏幕截取服务：屏幕录制权限检测 + 指定区域截取。
/// 说明：使用 CGWindowListCreateImage（macOS 14 起标记软弃用但仍是 CLT 环境下
/// 无需 ScreenCaptureKit 异步栈的可靠同步方案），依赖「屏幕录制」权限。
public enum ScreenCaptureService {
    /// 权限检查结果短缓存：面板 body 高频调用，CGPreflight 不宜每帧执行。
    private static var permissionCache: (time: Date, value: Bool)?
    private static let permissionTTL: TimeInterval = 2

    public static func hasPermission() -> Bool {
        if let cache = permissionCache, Date().timeIntervalSince(cache.time) < permissionTTL {
            return cache.value
        }
        let value = CGPreflightScreenCaptureAccess()
        permissionCache = (Date(), value)
        return value
    }

    /// 手动失效缓存（面板“重新检测”按钮用）。
    public static func invalidatePermissionCache() {
        permissionCache = nil
    }

    /// 请求权限：会打开系统设置的「屏幕录制」授权面板。
    public static func requestPermission() {
        invalidatePermissionCache()
        _ = CGRequestScreenCaptureAccess()
    }

    /// 截取全局坐标（AppKit，左下原点）矩形内的屏幕内容，返回逐像素图像 + 点尺寸。
    public static func capture(globalRect: CGRect) -> NSImage? {
        guard hasPermission(), globalRect.width >= 1, globalRect.height >= 1 else { return nil }
        // AppKit 全局坐标（左下原点）→ CG 全局坐标（左上原点，主屏高度为基准）
        let primaryHeight = NSScreen.screens.first?.frame.height ?? globalRect.maxY
        let cgRect = CGRect(
            x: globalRect.minX,
            y: primaryHeight - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
        // 软弃用告警可接受；截取前本工具的框选窗口已隐藏，不会入镜
        guard let cgImage = CGWindowListCreateImage(cgRect, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution]) else {
            return nil
        }
        let image = NSImage(size: cgRect.size)
        image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        return image
    }
}
