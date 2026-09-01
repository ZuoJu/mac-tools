import Foundation

public extension Notification.Name {
    /// 面板被打开，供内部视图响应（如聚焦搜索框）。
    static let panelDidShow = Notification.Name("MacTools.panelDidShow")
}

public extension Date {
    /// formatter 创建昂贵，列表行高频调用必须复用。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    var relativeDisplayText: String {
        Self.relativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}

public func byteCountText(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
