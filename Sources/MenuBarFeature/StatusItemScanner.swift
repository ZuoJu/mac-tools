import AppKit
import ApplicationServices
import Foundation

/// 扫描结果：一个状态栏窗口的原始信息。
public struct ScannedStatusItem {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let ownerName: String?
    public let bounds: CGRect
    /// 是否处于离屏折叠区（x <= -2000 由本应用使用）。
    public let offScreen: Bool
}

/// 状态栏图标扫描：通过 CGWindowList 找到菜单栏上的状态栏窗口（layer 25）。
public enum StatusItemScanner {
    /// 系统级状态项所属进程名，布局时单独标记。
    public static let systemOwnerNames: Set<String> = [
        "Control Center", "SystemUIServer", "TextInputMenuAgent",
        "NotificationCenter", "Spotlight", "Dock", "WindowServer",
    ]

    /// 本应用使用的离屏折叠区起点。
    public static let offScreenX: CGFloat = -2400

    public static func scan(excludingPIDs excluded: Set<Int>) -> [ScannedStatusItem] {
        guard let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        var result: [ScannedStatusItem] = []
        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == statusLevel else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  !excluded.contains(pid) else { continue }
            guard let windowNumber = info[kCGWindowNumber as String] as? Int else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (boundsDict["X"] as? NSNumber)?.doubleValue,
                  let y = (boundsDict["Y"] as? NSNumber)?.doubleValue,
                  let width = (boundsDict["Width"] as? NSNumber)?.doubleValue,
                  let height = (boundsDict["Height"] as? NSNumber)?.doubleValue else { continue }
            // 过滤明显不是状态栏图标的窗口
            guard width >= 10, width <= 500, height >= 14, height <= 60 else { continue }
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            let offScreen = x <= StatusItemScanner.offScreenX + 400
            guard offScreen || (x > -500 && y >= -2 && y <= 6) else { continue }
            let ownerName = info[kCGWindowOwnerName as String] as? String
            guard ownerName != "WindowServer" else { continue }
            result.append(
                ScannedStatusItem(
                    windowID: CGWindowID(UInt32(windowNumber)),
                    pid: pid_t(pid),
                    ownerName: ownerName,
                    bounds: bounds,
                    offScreen: offScreen
                )
            )
        }
        // 从右往左排列：右侧为“高优先级”区域
        return result.sorted { $0.bounds.minX > $1.bounds.minX }
    }
}
