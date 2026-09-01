import AppKit
import ApplicationServices
import CoreKit
import Foundation

/// 菜单栏图标管理控制器（Ice 式三段分区）：
/// 1. CGWindowList 扫描状态栏图标窗口，AX 映射后移动实现折叠/展开/重排；
/// 2. 布局自右向左：[始终显示] 分隔符1 [默认隐藏] 分隔符2 [始终隐藏]；
/// 3. 两个分隔符独立展开/收起对应分区；
/// 4. 展开区图标的菜单关闭后自动收回（AX kAXMenuClosedNotification，Ice 同款）；
/// 5. 接管期间定时监听图标增删，新图标自动纳入管理；
/// 6. 停止接管/退出时全部还原。
public final class MenuBarController: ObservableObject {
    @Published public private(set) var items: [ManagedStatusItem] = []
    @Published public private(set) var isManaging = false
    /// hidden 分区（分隔符 1）当前展开。
    @Published public private(set) var hiddenSectionShown = false
    /// alwaysHidden 分区（分隔符 2）当前展开。
    @Published public private(set) var alwaysHiddenSectionShown = false
    @Published public private(set) var accessibilityGranted: Bool
    @Published public var lastError: String?

    /// 分隔符 1（hidden 分区开关）。
    private var chevron1: NSStatusItem?
    /// 分隔符 2（alwaysHidden 分区开关）。
    private var chevron2: NSStatusItem?
    private let chevronWidth: CGFloat = 26

    /// item.id -> AXWindow 元素。
    private var liveElements: [String: AXUIElement] = [:]
    /// 展开区图标的菜单监听（自动收回用）。
    private var menuObservers: [AXObserver] = []
    /// 图标增删监听定时器。
    private var watchTimer: Timer?
    private var knownWindowIDs: Set<Int> = []

    public init() {
        accessibilityGranted = AXHelper.isTrusted()
    }

    deinit {
        watchTimer?.invalidate()
    }

    // MARK: - 冲突检测

    /// 其他菜单栏管理工具（与本功能同时接管会争抢图标布局）。
    /// 结果带短 TTL 缓存：面板 body 每次渲染都会调用，不宜每帧全量扫描。
    private static var conflictCache: (time: Date, value: [String])?
    private static let conflictTTL: TimeInterval = 3

    public static func conflictingMenuBarApps() -> [String] {
        if let cache = conflictCache, Date().timeIntervalSince(cache.time) < conflictTTL {
            return cache.value
        }
        let value = computeConflictingMenuBarApps()
        conflictCache = (Date(), value)
        return value
    }

    public static func invalidateConflictCache() {
        conflictCache = nil
    }

    private static func computeConflictingMenuBarApps() -> [String] {
        let knownBundleIDs: Set<String> = [
            "com.jordanbaird.Ice",             // Ice
            "com.surteesstudios.Bartender",    // Bartender
            "com.dwarvesfoundation.hiddenbar", // Hidden Bar
            "com.dwarvesf.hidden",             // Hidden Bar（旧版）
        ]
        let knownNames: Set<String> = ["Ice", "Bartender", "Hidden Bar", "HiddenBar"]
        var found: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            let bundleID = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            if knownBundleIDs.contains(bundleID) || knownNames.contains(name) {
                found.append(name.isEmpty ? bundleID : name)
            }
        }
        return found
    }

    /// 供 UI 预览/测试注入假数据（不影响正式接管流程）。
    public func injectForPreview(items: [ManagedStatusItem], isManaging: Bool, accessibilityGranted: Bool = true) {
        self.items = items
        self.isManaging = isManaging
        self.accessibilityGranted = accessibilityGranted
    }

    // MARK: - 接管 / 停止

    /// 启动时若上次处于接管状态且权限已授予，则自动恢复管理。
    public func restoreIfNeeded() {
        guard !isManaging, let state = MenuBarStatePersistence.load(), state.isManaging else { return }
        enable(promptIfNeeded: false)
    }

    public func enable(promptIfNeeded: Bool = true) {
        guard AXHelper.isTrusted(prompt: promptIfNeeded) else {
            accessibilityGranted = false
            lastError = "需要辅助功能权限才能管理菜单栏图标"
            return
        }
        accessibilityGranted = true
        let scanned = StatusItemScanner.scan(excludingPIDs: [Int(ProcessInfo.processInfo.processIdentifier)])
        guard !scanned.isEmpty else {
            lastError = "未发现可管理的状态栏图标"
            return
        }
        let elements = resolveElements(for: scanned)
        let persisted = MenuBarStatePersistence.load()?.items ?? []

        var newItems: [ManagedStatusItem] = []
        var newElements: [String: AXUIElement] = [:]
        for scannedItem in scanned {
            let element = elements[scannedItem.windowID]
            let title = element.flatMap { AXHelper.title(of: $0) }
            // 依据 (pid, 宽度) 匹配上次的记录，保留顺序、分区与自然位置
            let match = persisted.first { $0.pid == Int(scannedItem.pid) && abs($0.width - scannedItem.bounds.width) < 1.5 }
            let item = ManagedStatusItem(
                id: match?.id ?? UUID().uuidString,
                pid: Int(scannedItem.pid),
                ownerName: scannedItem.ownerName ?? "未知应用",
                title: title,
                width: scannedItem.bounds.width,
                naturalX: match?.naturalX ?? scannedItem.bounds.minX,
                naturalY: scannedItem.bounds.minY,
                section: match?.section ?? (scannedItem.offScreen ? .alwaysHidden : .alwaysVisible),
                isSystem: match?.isSystem ?? StatusItemScanner.systemOwnerNames.contains(scannedItem.ownerName ?? "")
            )
            newItems.append(item)
            if let element {
                newElements[item.id] = element
            }
        }
        items = newItems
        liveElements = newElements
        isManaging = true
        knownWindowIDs = Set(scanned.map { Int($0.windowID) })
        ensureChevrons()
        relayout()
        saveState()
        startWatching()
        lastError = nil
    }

    /// 重新扫描并匹配（新增/消失的图标会刷新）。
    public func refresh() {
        guard isManaging else { return }
        enable(promptIfNeeded: false)
    }

    /// 用户主动停止接管：还原 + 清状态。
    public func disable() {
        restorePositions()
        items = []
        liveElements = [:]
        isManaging = false
        hiddenSectionShown = false
        alwaysHiddenSectionShown = false
        stopWatching()
        removeChevrons()
        saveState()
    }

    /// 退出应用时还原位置（保留接管状态，下次启动自动恢复）。
    public func restorePositions() {
        for item in items {
            moveItem(item, to: CGPoint(x: item.naturalX, y: item.naturalY))
        }
        removeChevrons()
        removeMenuObservers()
    }

    // MARK: - 分区操作

    public func setItemSection(id: String, section: ItemSection) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].section = section
        applyChanges()
    }

    /// 拖拽调整显隐优先级（列表顺序即区内布局顺序，右侧优先）。
    public func moveItems(from offsets: IndexSet, to offset: Int) {
        items.move(fromOffsets: offsets, toOffset: offset)
        applyChanges()
    }

    /// 拖拽排序：把拖动中的条目实时移动到目标位置（dropEntered 渐进重排）。
    public func moveItem(id: String, to targetID: String) {
        guard id != targetID,
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = items.remove(at: from)
        items.insert(moved, at: to)
    }

    /// 拖拽结束：应用布局并持久化。
    public func applyReorder() {
        applyChanges()
    }

    /// 上下按钮微调优先级。
    public func shiftItem(id: String, offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
        applyChanges()
    }

    public func showAll() {
        for index in items.indices {
            items[index].section = .alwaysVisible
        }
        hiddenSectionShown = false
        alwaysHiddenSectionShown = false
        applyChanges()
    }

    /// 一键把非系统图标收进“始终隐藏”。
    public func hideAllNonSystem() {
        for index in items.indices where !items[index].isSystem {
            items[index].section = .alwaysHidden
        }
        applyChanges()
    }

    public func toggleSection(_ section: ItemSection) {
        switch section {
        case .hidden:
            hiddenSectionShown.toggle()
        case .alwaysHidden:
            alwaysHiddenSectionShown.toggle()
        case .alwaysVisible:
            break
        }
        applyChanges()
    }

    private func applyChanges() {
        updateChevrons()
        relayout()
        saveState()
    }

    // MARK: - 布局（Ice 式三段）

    /// 纯函数布局：自右向左 [始终显示] c1 [默认隐藏] c2 [始终隐藏]，
    /// 折叠分区的图标离屏；展开时依次排在对应分隔符左侧。
    public static func computeLayout(
        items: [ManagedStatusItem],
        rightAnchor: CGFloat,
        chevronWidth: CGFloat,
        hiddenSectionShown: Bool,
        alwaysHiddenSectionShown: Bool,
        offScreenX: CGFloat
    ) -> LayoutPlan {
        var cursor = rightAnchor
        var positions: [String: CGFloat] = [:]

        for item in items where item.section == .alwaysVisible {
            cursor -= item.width
            positions[item.id] = cursor
        }

        let hasHidden = items.contains { $0.section == .hidden }
        let hasAlwaysHidden = items.contains { $0.section == .alwaysHidden }
        let showChevron1 = hasHidden || hasAlwaysHidden
        var chevron1X: CGFloat?
        var chevron2X: CGFloat?
        if showChevron1 {
            cursor -= chevronWidth + 2
            chevron1X = cursor
        }

        for item in items where item.section == .hidden {
            if hiddenSectionShown {
                cursor -= item.width
                positions[item.id] = cursor
            } else {
                positions[item.id] = offScreenX
            }
        }

        if hasAlwaysHidden {
            cursor -= chevronWidth + 2
            chevron2X = cursor
        }

        for item in items where item.section == .alwaysHidden {
            if alwaysHiddenSectionShown {
                cursor -= item.width
                positions[item.id] = cursor
            } else {
                positions[item.id] = offScreenX
            }
        }

        return LayoutPlan(
            positions: positions,
            chevron1X: chevron1X ?? cursor,
            chevron2X: chevron2X ?? cursor,
            showChevron1: showChevron1,
            showChevron2: hasAlwaysHidden
        )
    }

    public struct LayoutPlan: Equatable {
        public var positions: [String: CGFloat]
        public var chevron1X: CGFloat
        public var chevron2X: CGFloat
        public var showChevron1: Bool
        public var showChevron2: Bool
    }

    public func relayout() {
        guard isManaging else { return }
        let anchor = rightAnchor()
        let plan = Self.computeLayout(
            items: items,
            rightAnchor: anchor,
            chevronWidth: chevronWidth,
            hiddenSectionShown: hiddenSectionShown,
            alwaysHiddenSectionShown: alwaysHiddenSectionShown,
            offScreenX: StatusItemScanner.offScreenX
        )
        for item in items {
            let x = plan.positions[item.id] ?? item.naturalX
            moveItem(item, to: CGPoint(x: x, y: item.naturalY))
        }
        moveChevron(chevron1, toX: plan.chevron1X, visible: plan.showChevron1)
        moveChevron(chevron2, toX: plan.chevron2X, visible: plan.showChevron2)
        // 展开状态下监听展开图标菜单关闭事件（自动收回）
        reinstallMenuObservers()
    }

    private func rightAnchor() -> CGFloat {
        let maxRight = items.map { $0.naturalX + $0.width }.max()
        return maxRight ?? 1200
    }

    private func moveItem(_ item: ManagedStatusItem, to point: CGPoint) {
        guard let element = liveElements[item.id] else { return }
        AXHelper.moveElement(element, to: point)
    }

    // MARK: - AX 元素解析

    private func resolveElements(for scanned: [ScannedStatusItem]) -> [CGWindowID: AXUIElement] {
        var byWindowID: [CGWindowID: AXUIElement] = [:]
        var appElements: [pid_t: AXUIElement] = [:]
        for scannedItem in scanned {
            let app = appElements[scannedItem.pid] ?? AXHelper.applicationElement(pid: scannedItem.pid)
            appElements[scannedItem.pid] = app
            for window in AXHelper.windows(ofApp: app) {
                if let windowID = AXHelper.windowID(of: window) {
                    byWindowID[windowID] = window
                }
            }
        }
        return byWindowID
    }

    // MARK: - 分隔符（两个 NSStatusItem）

    private func ensureChevrons() {
        guard chevron1 == nil else {
            updateChevrons()
            return
        }
        let item1 = NSStatusBar.system.statusItem(withLength: -1) // NSStatusItemVariableLength
        if let button = item1.button {
            button.image = NSImage(systemSymbolName: "chevron.left.2", accessibilityDescription: "展开默认隐藏的图标")
            button.image?.size = NSSize(width: 14, height: 14)
            button.target = self
            button.action = #selector(chevron1Clicked)
            button.toolTip = "展开 / 收起「默认隐藏」分区"
        }
        chevron1 = item1

        let item2 = NSStatusBar.system.statusItem(withLength: -1)
        if let button = item2.button {
            button.image = NSImage(systemSymbolName: "chevron.left.2", accessibilityDescription: "展开始终隐藏的图标")
            button.image?.size = NSSize(width: 14, height: 14)
            button.target = self
            button.action = #selector(chevron2Clicked)
            button.toolTip = "展开 / 收起「始终隐藏」分区"
        }
        chevron2 = item2
        updateChevrons()
    }

    @objc private func chevron1Clicked() {
        toggleSection(.hidden)
    }

    @objc private func chevron2Clicked() {
        toggleSection(.alwaysHidden)
    }

    private func updateChevrons() {
        let hiddenCount = items.filter { $0.section == .hidden }.count
        let alwaysHiddenCount = items.filter { $0.section == .alwaysHidden }.count
        if let button = chevron1?.button {
            button.contentTintColor = hiddenSectionShown ? .controlAccentColor : nil
            button.toolTip = hiddenSectionShown
                ? "收起「默认隐藏」分区（\(hiddenCount) 个）"
                : "展开「默认隐藏」分区（\(hiddenCount) 个）"
        }
        if let button = chevron2?.button {
            button.contentTintColor = alwaysHiddenSectionShown ? .controlAccentColor : nil
            button.toolTip = alwaysHiddenSectionShown
                ? "收起「始终隐藏」分区（\(alwaysHiddenCount) 个）"
                : "展开「始终隐藏」分区（\(alwaysHiddenCount) 个）"
        }
    }

    private func moveChevron(_ item: NSStatusItem?, toX x: CGFloat, visible: Bool) {
        guard let item, let button = item.button else { return }
        // 分区为空时隐藏对应分隔符
        button.isHidden = !visible
        guard visible, let window = button.window else { return }
        var origin = window.frame.origin
        origin.x = x
        window.setFrameOrigin(origin)
    }

    private func removeChevrons() {
        if let item = chevron1 {
            NSStatusBar.system.removeStatusItem(item)
        }
        if let item = chevron2 {
            NSStatusBar.system.removeStatusItem(item)
        }
        chevron1 = nil
        chevron2 = nil
    }

    // MARK: - 展开区菜单关闭自动收回（Ice 同款 AX 通知）

    /// 展开状态下，对展开图标挂 kAXMenuClosedNotification；菜单一关立即收回分区。
    private func reinstallMenuObservers() {
        removeMenuObservers()
        guard hiddenSectionShown || alwaysHiddenSectionShown else { return }
        let expandedItems = items.filter { item in
            let expanded = item.section == .hidden ? hiddenSectionShown
                : item.section == .alwaysHidden ? alwaysHiddenSectionShown : false
            return expanded
        }
        for item in expandedItems {
            guard let element = liveElements[item.id] else { continue }
            // 从 AX 元素读取所属进程（AXPID 属性；AXUIElementGetPID 非公开 API）
            var pidValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXPID" as CFString, &pidValue) == .success,
                  let pidNumber = pidValue as? NSNumber, pidNumber.int32Value != 0 else { continue }
            let pidValue32 = pidNumber.int32Value
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, _, notification, userData in
                guard let userData else { return }
                let controller = Unmanaged<MenuBarController>.fromOpaque(userData).takeUnretainedValue()
                if notification as String == kAXMenuClosedNotification {
                    controller.handleExpandedMenuClosed()
                }
            }
            guard AXObserverCreate(pidValue32, callback, &observer) == .success, let observer else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            let context = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(observer, element, kAXMenuOpenedNotification as CFString, context)
            AXObserverAddNotification(observer, element, kAXMenuClosedNotification as CFString, context)
            menuObservers.append(observer)
        }
    }

    private func removeMenuObservers() {
        menuObservers.removeAll()
    }

    private func handleExpandedMenuClosed() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isManaging else { return }
            guard self.hiddenSectionShown || self.alwaysHiddenSectionShown else { return }
            self.hiddenSectionShown = false
            self.alwaysHiddenSectionShown = false
            self.applyChanges()
        }
    }

    // MARK: - 图标增删自动监听

    /// 接管期间轮询窗口集合（2s，CGWindowList 轻量过滤），集合变化即自动刷新归位。
    private func startWatching() {
        stopWatching()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.watchTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    private func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func watchTick() {
        guard isManaging else {
            stopWatching()
            return
        }
        let current = Set(StatusItemScanner.scan(excludingPIDs: [Int(ProcessInfo.processInfo.processIdentifier)]).map { Int($0.windowID) })
        guard current != knownWindowIDs else { return }
        knownWindowIDs = current
        refresh()
    }

    // MARK: - 持久化

    private func saveState() {
        MenuBarStatePersistence.save(MenuBarState(items: items, isManaging: isManaging))
    }
}
