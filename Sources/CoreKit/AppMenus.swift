import AppKit

/// 程序化主菜单：LSUIElement/无 NIB 应用必须手工创建。
/// 关键作用：文本框的 ⌘X/⌘C/⌘V/⌘A/⌘Z 键等效依赖菜单项走响应链，
/// 没有「编辑」菜单时这些快捷键在 SecureField/TextField/TextEditor
/// 中全部失效（右键菜单粘贴不受影响）。辅助应用不显示菜单栏，
/// 但 NSApp.mainMenu 仍参与按键分发。
public enum AppMenus {
    /// 构建主菜单：应用菜单（关于/设置/退出）+ 编辑菜单（标准文本操作）。
    /// - Parameter onOpenSettings: 「设置…」点击回调（⌘,）。
    public static func makeMainMenu(onOpenSettings: @escaping () -> Void) -> NSMenu {
        let mainMenu = NSMenu()

        // 应用菜单
        let appMenuItem = NSMenuItem(title: "MacTools", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "MacTools")
        appMenu.addItem(
            withTitle: "关于 MacTools",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(MenuTarget.settings), keyEquivalent: ",")
        let target = MenuTarget(onOpenSettings: onOpenSettings)
        settingsItem.target = target
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 MacTools",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 编辑菜单：文本操作键等效（修复 ⌘V/⌘C/⌘X/⌘A/⌘Z）
        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 主菜单持有 target，防止其被释放导致设置项失效
        objc_setAssociatedObject(mainMenu, &MenuTarget.associationKey, target, .OBJC_ASSOCIATION_RETAIN)
        return mainMenu
    }

    /// 菜单动作转发目标（主菜单生命周期内常驻）。
    final class MenuTarget: NSObject {
        nonisolated(unsafe) static var associationKey: UInt8 = 0
        private let onOpenSettings: () -> Void

        init(onOpenSettings: @escaping () -> Void) {
            self.onOpenSettings = onOpenSettings
        }

        @objc func settings() {
            onOpenSettings()
        }
    }
}
