import Foundation

/// Additional global actions; unset by default to avoid claiming users’ key combinations.
public enum FeatureShortcut: String, CaseIterable, Identifiable {
    case textTranslate
    case menuBarPanel
    case menuBarToggle
    case hiddenToggle
    case alwaysHiddenToggle
    case scrollPanel
    case scrollToggle
    case trackpadPanel
    case trackpadToggle
    case clipboardToggle
    case screenshotPanel
    case closePinned
    case settingsPanel
    case brightnessUp
    case brightnessDown
    case volumeUp
    case volumeDown
    public var id: String { "feature." + rawValue }
    public var title: String {
        switch self {
        case .textTranslate: return "文本翻译"
        case .menuBarPanel: return "菜单栏图标管理"
        case .menuBarToggle: return "开启 / 停止菜单栏接管"
        case .hiddenToggle: return "展开 / 收起隐藏图标"
        case .alwaysHiddenToggle: return "展开 / 收起始终隐藏图标"
        case .scrollPanel: return "滚轮方向设置"
        case .scrollToggle: return "开启 / 关闭滚轮反转"
        case .trackpadPanel: return "触摸板边缘控制设置"
        case .trackpadToggle: return "开启 / 关闭触摸板调节"
        case .clipboardToggle: return "开启 / 暂停剪贴板监听"
        case .screenshotPanel: return "截图设置与贴图管理"
        case .closePinned: return "关闭全部贴图"
        case .settingsPanel: return "打开设置"
        case .brightnessUp: return "增大屏幕亮度"
        case .brightnessDown: return "减小屏幕亮度"
        case .volumeUp: return "增大声音"
        case .volumeDown: return "减小声音"
        }
    }
}
