import CoreGraphics
import CoreKit
import Foundation

/// Ice 式三段分区：图标归属决定折叠行为。
public enum ItemSection: String, Codable, CaseIterable, Identifiable {
    /// 始终显示。
    case alwaysVisible
    /// 默认折叠，点分隔符 1 展开。
    case hidden
    /// 始终折叠，点分隔符 2 展开。
    case alwaysHidden

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .alwaysVisible: return "始终显示"
        case .hidden: return "默认隐藏"
        case .alwaysHidden: return "始终隐藏"
        }
    }
}

/// 一条被管理的状态栏图标（对应其他应用的一个状态栏窗口）。
public struct ManagedStatusItem: Identifiable, Equatable {
    public var id: String
    /// 图标所属应用的进程号。
    public var pid: Int
    public var ownerName: String
    /// 通过辅助功能读到的图标标题（如 "Wi-Fi"），可能为空。
    public var title: String?
    public var width: CGFloat
    /// 接管时的自然位置（CG 坐标，左上原点），用于“停止接管/退出时还原”。
    public var naturalX: CGFloat
    public var naturalY: CGFloat
    /// 所属分区（Ice 三段式）。
    public var section: ItemSection
    public var isSystem: Bool

    public init(
        id: String = UUID().uuidString,
        pid: Int,
        ownerName: String,
        title: String? = nil,
        width: CGFloat,
        naturalX: CGFloat,
        naturalY: CGFloat,
        section: ItemSection = .alwaysVisible,
        isSystem: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.ownerName = ownerName
        self.title = title
        self.width = width
        self.naturalX = naturalX
        self.naturalY = naturalY
        self.section = section
        self.isSystem = isSystem
    }

    /// 兼容旧 UI 的快捷判断：非“始终显示”即处于折叠区。
    public var hidden: Bool { section != .alwaysVisible }

    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return ownerName
    }
}

extension ManagedStatusItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, pid, ownerName, title, width, naturalX, naturalY, section, isSystem
        // 旧版本字段：迁移用
        case legacyHidden = "hidden"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pid = try container.decode(Int.self, forKey: .pid)
        ownerName = try container.decode(String.self, forKey: .ownerName)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        width = try container.decode(CGFloat.self, forKey: .width)
        naturalX = try container.decode(CGFloat.self, forKey: .naturalX)
        naturalY = try container.decode(CGFloat.self, forKey: .naturalY)
        isSystem = try container.decodeIfPresent(Bool.self, forKey: .isSystem) ?? false
        // 旧数据没有 section：按旧的 hidden 布尔迁移（藏过 → 始终隐藏，更保守）
        if let section = try container.decodeIfPresent(ItemSection.self, forKey: .section) {
            self.section = section
        } else {
            let legacyHidden = try container.decodeIfPresent(Bool.self, forKey: .legacyHidden) ?? false
            section = legacyHidden ? .alwaysHidden : .alwaysVisible
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(pid, forKey: .pid)
        try container.encode(ownerName, forKey: .ownerName)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(width, forKey: .width)
        try container.encode(naturalX, forKey: .naturalX)
        try container.encode(naturalY, forKey: .naturalY)
        try container.encode(section, forKey: .section)
        try container.encode(isSystem, forKey: .isSystem)
    }
}

/// 菜单栏管理模块的持久化状态。
public struct MenuBarState: Codable {
    public var items: [ManagedStatusItem]
    public var isManaging: Bool

    public init(items: [ManagedStatusItem], isManaging: Bool) {
        self.items = items
        self.isManaging = isManaging
    }
}

public enum MenuBarStatePersistence {
    public static func load(from url: URL = AppPaths.menuBarStateFile) -> MenuBarState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MenuBarState.self, from: data)
    }

    public static func save(_ state: MenuBarState, to url: URL = AppPaths.menuBarStateFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
