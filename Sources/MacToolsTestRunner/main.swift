import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import CoreKit
import ClipboardFeature
import MenuBarFeature
import ScrollFeature
import ScreenshotFeature
import TranslateFeature

/// 自包含测试运行器（环境无 Xcode/XCTest）：
/// `swift run MacToolsTestRunner` 执行，全部通过退出码 0。
final class TestRunner {
    private(set) var failures: [String] = []
    private(set) var passed = 0

    func expectTrue(_ condition: Bool, _ name: String) {
        if condition {
            passed += 1
            print("  ✅ \(name)")
        } else {
            failures.append(name)
            print("  ❌ \(name)")
        }
    }

    func expectEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
        expectTrue(a == b, "\(name)（\(a) == \(b)）")
    }
}

func runClipboardStoreTests(_ t: TestRunner, tempRoot: URL) {
    print("\n== ClipboardStore ==")
    let dir = tempRoot.appendingPathComponent("clip", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    func makeStore(file: URL, images: URL, limits: @escaping () -> (Int, Int)) -> ClipboardStore {
        let store = ClipboardStore(fileURL: file, imagesDirectory: images, autoSave: false)
        store.limitsProvider = limits
        return store
    }

    func item(_ text: String, pinned: Bool = false, copiedAt: Date = Date()) -> ClipboardItem {
        ClipboardItem(
            kind: .text,
            text: text,
            fingerprint: "text|\(text)",
            pinned: pinned,
            firstCopiedAt: copiedAt,
            lastCopiedAt: copiedAt
        )
    }

    // 1. 去重上移
    do {
        let store = makeStore(file: dir.appendingPathComponent("a.json"), images: dir, limits: { (100, 0) })
        let now = Date()
        store.record(item("A", copiedAt: now.addingTimeInterval(-30)))
        store.record(item("B", copiedAt: now.addingTimeInterval(-20)))
        store.record(item("A", copiedAt: now))
        t.expectEqual(store.items.count, 2, "去重后条目数")
        t.expectEqual(store.items[0].text ?? "", "A", "重复内容上移到顶部")
        t.expectEqual(store.items[0].numberOfCopies, 2, "复制次数累加")
    }

    // 2. 历史上限裁剪（固定条目保留）
    do {
        let store = makeStore(file: dir.appendingPathComponent("b.json"), images: dir, limits: { (2, 0) })
        let now = Date()
        store.record(item("old-pinned", pinned: true, copiedAt: now.addingTimeInterval(-40)))
        store.record(item("1", copiedAt: now.addingTimeInterval(-30)))
        store.record(item("2", copiedAt: now.addingTimeInterval(-20)))
        store.record(item("3", copiedAt: now))
        t.expectEqual(store.items.count, 3, "超限裁剪：固定 1 条 + 最新 2 条")
        t.expectTrue(store.items.contains { $0.text == "old-pinned" }, "固定条目不被裁剪")
        t.expectTrue(store.items.contains { $0.text == "3" }, "最新条目保留")
        t.expectTrue(!store.items.contains { $0.text == "1" }, "最旧未固定条目被裁剪")
    }

    // 3. 保留天数清理
    do {
        let store = makeStore(file: dir.appendingPathComponent("c.json"), images: dir, limits: { (100, 7) })
        let now = Date()
        store.record(item("fresh", copiedAt: now))
        store.record(item("stale", copiedAt: now.addingTimeInterval(-10 * 24 * 3600)))
        store.record(item("stale-pinned", pinned: true, copiedAt: now.addingTimeInterval(-30 * 24 * 3600)))
        store.enforceLimits()
        t.expectTrue(store.items.contains { $0.text == "fresh" }, "新条目保留")
        t.expectTrue(!store.items.contains { $0.text == "stale" }, "超过保留天数的条目被清理")
        t.expectTrue(store.items.contains { $0.text == "stale-pinned" }, "固定条目不受保留天数影响")
    }

    // 4. 持久化往返
    do {
        let file = dir.appendingPathComponent("d.json")
        let store = makeStore(file: file, images: dir, limits: { (100, 0) })
        let now = Date()
        store.record(item("persist-me", copiedAt: now))
        store.persistNowSync()
        let reloaded = ClipboardStore(fileURL: file, imagesDirectory: dir, autoSave: false)
        let items = reloaded.readFromDisk()
        t.expectEqual(items.count, 1, "重新加载条目数")
        t.expectEqual(items.first?.text ?? "", "persist-me", "重新加载内容一致")
        t.expectEqual(items.first?.pinned ?? true, false, "固定状态一致")
    }

    // 5. 固定/删除/清空
    do {
        let store = makeStore(file: dir.appendingPathComponent("e.json"), images: dir, limits: { (100, 0) })
        store.record(item("x"))
        store.record(item("y"))
        store.togglePin(store.items[0].id)
        t.expectTrue(store.items[0].pinned, "固定切换生效")
        store.clearAll(keepingPinned: true)
        t.expectEqual(store.items.count, 1, "清除未固定后仅剩固定条目")
        store.clearAll(keepingPinned: false)
        t.expectEqual(store.items.count, 0, "全部清空")
    }

    // 6. 复制回剪贴板并更新统计（使用独立命名剪贴板，不污染系统剪贴板）
    do {
        let store = makeStore(file: dir.appendingPathComponent("f.json"), images: dir, limits: { (100, 0) })
        store.record(item("copy-back", copiedAt: Date().addingTimeInterval(-5)))
        store.record(item("newer"))
        let target = store.items.first { $0.text == "copy-back" }!
        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("MacToolsTest.copy"))
        let ok = store.copyToPasteboard(target, pasteboard: testPasteboard)
        t.expectTrue(ok, "复制回剪贴板成功")
        t.expectEqual(testPasteboard.string(forType: .string) ?? "", "copy-back", "剪贴板内容正确")
        t.expectEqual(store.items[0].text ?? "", "copy-back", "复制后上移")
        t.expectEqual(store.items[0].numberOfCopies, 2, "复制后次数累加")
    }
}

func runClipboardCaptureTests(_ t: TestRunner) {
    print("\n== ClipboardMonitor ==")
    // 使用独立命名剪贴板，不污染系统剪贴板
    let testPasteboard = NSPasteboard(name: NSPasteboard.Name("MacToolsTest.capture"))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    testPasteboard.clearContents()
    testPasteboard.setString("capture-test-文本", forType: .string)
    if let captured = ClipboardMonitor.captureItem(imagesDirectory: dir, ignoredBundleIDs: [], pasteboard: testPasteboard) {
        t.expectEqual(captured.kind, .text, "文本抓取类型")
        t.expectEqual(captured.text ?? "", "capture-test-文本", "文本抓取内容")
        t.expectTrue(captured.fingerprint.hasPrefix("text|"), "文本指纹前缀")
    } else {
        t.expectTrue(false, "文本抓取成功")
    }

    // 空剪贴板不产生条目
    testPasteboard.clearContents()
    let empty = ClipboardMonitor.captureItem(imagesDirectory: dir, ignoredBundleIDs: [], pasteboard: testPasteboard)
    t.expectTrue(empty == nil, "空剪贴板返回 nil")

    // 忽略名单：带名单抓取不崩溃
    testPasteboard.setString("again", forType: .string)
    _ = ClipboardMonitor.captureItem(imagesDirectory: dir, ignoredBundleIDs: ["com.example.front"], pasteboard: testPasteboard)
    t.expectTrue(true, "带忽略名单抓取不崩溃")

    try? FileManager.default.removeItem(at: dir)
}

func runMenuBarLayoutTests(_ t: TestRunner) {
    print("\n== MenuBarLayout（三段式） ==")

    func makeItem(id: String, width: CGFloat, naturalX: CGFloat, section: ItemSection = .alwaysVisible, system: Bool = false) -> ManagedStatusItem {
        ManagedStatusItem(id: id, pid: 100, ownerName: "App \(id)", width: width, naturalX: naturalX, naturalY: 0, section: section, isSystem: system)
    }

    // 1. 始终显示区自右向左紧凑排列，其后是分隔符1
    do {
        let items = [makeItem(id: "a", width: 40, naturalX: 1000), makeItem(id: "b", width: 20, naturalX: 900, section: .hidden)]
        let plan = MenuBarController.computeLayout(items: items, rightAnchor: 1040, chevronWidth: 26, hiddenSectionShown: false, alwaysHiddenSectionShown: false, offScreenX: -2400)
        t.expectEqual(plan.positions["a"] ?? -1, CGFloat(1000), "始终显示图标自锚点左排")
        t.expectTrue(plan.showChevron1, "存在隐藏分区时显示分隔符1")
        t.expectEqual(plan.chevron1X, CGFloat(972), "分隔符1 位于可见图标左侧（1000-26-2）")
        t.expectEqual(plan.positions["b"] ?? -1, CGFloat(-2400), "折叠态默认隐藏图标离屏")
        t.expectTrue(!plan.showChevron2, "无始终隐藏分区不显示分隔符2")
    }

    // 2. 展开默认隐藏区：图标排在分隔符1 左侧
    do {
        let items = [makeItem(id: "a", width: 40, naturalX: 1000), makeItem(id: "b", width: 20, naturalX: 900, section: .hidden)]
        let plan = MenuBarController.computeLayout(items: items, rightAnchor: 1040, chevronWidth: 26, hiddenSectionShown: true, alwaysHiddenSectionShown: false, offScreenX: -2400)
        t.expectEqual(plan.positions["b"] ?? -1, CGFloat(952), "展开态默认隐藏图标排在分隔符1 左侧（972-20）")
    }

    // 3. 三段共存 + 双分隔符 + 两分区独立展开
    do {
        let items = [
            makeItem(id: "v", width: 40, naturalX: 1000),
            makeItem(id: "h", width: 30, naturalX: 960, section: .hidden),
            makeItem(id: "ah", width: 20, naturalX: 920, section: .alwaysHidden),
        ]
        let collapsed = MenuBarController.computeLayout(items: items, rightAnchor: 1040, chevronWidth: 26, hiddenSectionShown: false, alwaysHiddenSectionShown: false, offScreenX: -2400)
        t.expectTrue(collapsed.showChevron1 && collapsed.showChevron2, "三段共存时双分隔符都显示")
        t.expectEqual(collapsed.positions["h"] ?? -1, CGFloat(-2400), "折叠态默认隐藏离屏")
        t.expectEqual(collapsed.positions["ah"] ?? -1, CGFloat(-2400), "折叠态始终隐藏离屏")

        let onlyHidden = MenuBarController.computeLayout(items: items, rightAnchor: 1040, chevronWidth: 26, hiddenSectionShown: true, alwaysHiddenSectionShown: false, offScreenX: -2400)
        t.expectEqual(onlyHidden.positions["h"] ?? -1, CGFloat(942), "仅展开默认隐藏：h 位于分隔符1 左（972-30）")
        t.expectEqual(onlyHidden.positions["ah"] ?? -1, CGFloat(-2400), "仅展开默认隐藏：始终隐藏仍离屏")

        let onlyAlways = MenuBarController.computeLayout(items: items, rightAnchor: 1040, chevronWidth: 26, hiddenSectionShown: false, alwaysHiddenSectionShown: true, offScreenX: -2400)
        t.expectEqual(onlyAlways.positions["h"] ?? -1, CGFloat(-2400), "仅展开始终隐藏：默认隐藏仍离屏")
        t.expectEqual(onlyAlways.positions["ah"] ?? -1, CGFloat(924), "仅展开始终隐藏：ah 位于分隔符2 左（分隔符2=944，944-20；折叠的 h 不占位）")
    }

    // 4. 展开全部时不重叠
    do {
        let items = [
            makeItem(id: "v", width: 40, naturalX: 1000),
            makeItem(id: "h", width: 24, naturalX: 950, section: .hidden),
            makeItem(id: "ah", width: 30, naturalX: 900, section: .alwaysHidden),
        ]
        let plan = MenuBarController.computeLayout(items: items, rightAnchor: 1040, chevronWidth: 26, hiddenSectionShown: true, alwaysHiddenSectionShown: true, offScreenX: -2400)
        let visible = items.compactMap { plan.positions[$0.id] }.sorted(by: >)
        var noOverlap = true
        for i in 0..<(visible.count - 1) where visible[i] - visible[i + 1] < 1 { noOverlap = false }
        t.expectTrue(noOverlap, "三段全部展开时图标互不重叠")
        t.expectTrue(plan.chevron2X < plan.chevron1X, "分隔符2 在分隔符1 左侧")
    }
}

func runMenuBarPersistenceTests(_ t: TestRunner, tempRoot: URL) {
    print("\n== MenuBarStatePersistence ==")
    let file = tempRoot.appendingPathComponent("menubar-state.json")
    let items = [
        ManagedStatusItem(id: "i1", pid: 42, ownerName: "Demo", title: "Wi-Fi", width: 32, naturalX: 1200, naturalY: 0, section: .alwaysHidden, isSystem: true),
        ManagedStatusItem(id: "i2", pid: 43, ownerName: "Demo2", width: 24, naturalX: 1100, naturalY: 0, section: .hidden),
        ManagedStatusItem(id: "i3", pid: 44, ownerName: "Demo3", width: 20, naturalX: 1050, naturalY: 0, section: .alwaysVisible),
    ]
    MenuBarStatePersistence.save(MenuBarState(items: items, isManaging: true), to: file)
    let loaded = MenuBarStatePersistence.load(from: file)
    t.expectTrue(loaded != nil, "状态文件可加载")
    t.expectEqual(loaded?.items.count ?? 0, 3, "状态条目数")
    t.expectEqual(loaded?.items[0].section ?? .alwaysVisible, .alwaysHidden, "分区状态保留")
    t.expectEqual(loaded?.items[0].title ?? "", "Wi-Fi", "标题保留")
    t.expectEqual(loaded?.isManaging ?? false, true, "接管状态保留")

    // 旧版数据迁移：hidden 布尔 → 分区
    let legacyJSON = """
    {"items":[{"id":"old1","pid":50,"ownerName":"Legacy","width":30,"naturalX":800,"naturalY":0,"hidden":true,"isSystem":false},
               {"id":"old2","pid":51,"ownerName":"Legacy2","width":28,"naturalX":760,"naturalY":0,"hidden":false,"isSystem":false}],
     "isManaging":true}
    """
    let legacyFile = tempRoot.appendingPathComponent("menubar-state-legacy.json")
    try? legacyJSON.data(using: .utf8)!.write(to: legacyFile)
    let migrated = MenuBarStatePersistence.load(from: legacyFile)
    t.expectTrue(migrated != nil, "旧版状态文件可迁移加载")
    t.expectEqual(migrated?.items.first { $0.id == "old1" }?.section ?? .alwaysVisible, .alwaysHidden, "旧 hidden=true 迁移为始终隐藏")
    t.expectEqual(migrated?.items.first { $0.id == "old2" }?.section ?? .alwaysHidden, .alwaysVisible, "旧 hidden=false 迁移为始终显示")
}

func runScrollLogicTests(_ t: TestRunner) {
    print("\n== ScrollReverser ==")

    func classify(
        isContinuous: Bool,
        touching: Int = 0,
        msSinceTouch: Int = Int.max,
        momentumNone: Bool = true,
        smoothAsMouse: Bool = false,
        previous: ScrollEventSource = .mouse
    ) -> ScrollEventSource {
        ScrollEventLogic.classify(
            isContinuous: isContinuous,
            touchingFingers: touching,
            msSinceLastTouch: msSinceTouch,
            momentumPhaseNone: momentumNone,
            treatContinuousAsMouse: smoothAsMouse,
            previous: previous
        )
    }

    func plan(source: ScrollEventSource, mouse: Bool, trackpad: Bool, horizontal: Bool) -> ScrollModification? {
        ScrollEventLogic.modification(source: source, reverseMouse: mouse, reverseTrackpad: trackpad, reverseHorizontal: horizontal)
    }

    // 1. 离散事件（传统滚轮）→ 鼠标；开启鼠标反转时命中垂直反转
    do {
        t.expectEqual(classify(isContinuous: false), .mouse, "离散滚动判为鼠标")
        let result = plan(source: .mouse, mouse: true, trackpad: false, horizontal: false)
        t.expectTrue(result != nil, "鼠标滚轮命中反转")
        t.expectEqual(result?.negateVertical ?? false, true, "鼠标滚轮反转垂直方向")
        t.expectEqual(result?.negateHorizontal ?? true, false, "默认只反转垂直方向")
    }

    // 2. 鼠标反转关闭时不反转
    do {
        t.expectTrue(plan(source: .mouse, mouse: false, trackpad: true, horizontal: true) == nil, "鼠标反转关闭后离散事件原样放行")
    }

    // 3. 连续事件 + 两指触摸中 → 触控板；默认（不反转触控板）保持自然滚动
    do {
        let source = classify(isContinuous: true, touching: 2, msSinceTouch: 50, momentumNone: false)
        t.expectEqual(source, .trackpad, "两指触摸中的连续事件判为触控板")
        t.expectTrue(plan(source: .trackpad, mouse: true, trackpad: false, horizontal: false) == nil, "触控板默认保持自然滚动不受影响")
    }

    // 4. 触控板开启后反转，且与鼠标互不影响
    do {
        let result = plan(source: .trackpad, mouse: false, trackpad: true, horizontal: false)
        t.expectTrue(result != nil, "触控板开启后命中反转")
        t.expectEqual(result?.negateVertical ?? false, true, "触控板反转垂直方向")
        t.expectTrue(plan(source: .mouse, mouse: false, trackpad: true, horizontal: false) == nil, "触控板开启不影响鼠标配置")
    }

    // 5. 妙控鼠标/平滑滚轮：连续事件但无两指触摸、无惯性相位 → 判为鼠标
    do {
        let source = classify(isContinuous: true, touching: 0, msSinceTouch: 1000, momentumNone: true)
        t.expectEqual(source, .mouse, "连续但无触摸无惯性相位判为鼠标（妙控鼠标/平滑滚轮）")
        t.expectTrue(plan(source: source, mouse: true, trackpad: false, horizontal: false) != nil, "平滑滚轮命中鼠标反转（此前误判触控板导致不生效）")
    }

    // 6. 信息不足（惯性中、无触摸记录）沿用上次判定
    do {
        t.expectEqual(
            classify(isContinuous: true, touching: 0, msSinceTouch: 300, momentumNone: false, previous: .trackpad),
            .trackpad, "惯性阶段信息不足沿用上次判定（触控板）"
        )
        t.expectEqual(
            classify(isContinuous: true, touching: 0, msSinceTouch: 300, momentumNone: false, previous: .mouse),
            .mouse, "惯性阶段信息不足沿用上次判定（鼠标）"
        )
    }

    // 7. 进阶：平滑滚轮强制按鼠标处理（优先级高于触摸启发式）
    do {
        t.expectEqual(
            classify(isContinuous: true, touching: 2, msSinceTouch: 10, momentumNone: false, smoothAsMouse: true),
            .mouse, "平滑滚轮选项强制连续事件按鼠标处理"
        )
    }

    // 8. 横向滚动选项
    do {
        let result = plan(source: .mouse, mouse: true, trackpad: false, horizontal: true)
        t.expectEqual(result?.negateHorizontal ?? false, true, "开启横向选项后同时反转水平方向")
    }

    // 9. 引擎偏好快照 + 未启动状态
    do {
        let reverser = ScrollReverser()
        t.expectEqual(reverser.isRunning, false, "引擎初始未运行")
        reverser.updatePreferences(reverseMouse: true, reverseTrackpad: false, reverseHorizontal: false, treatContinuousAsMouse: false)
        if !AXHelper.isTrusted() {
            let started = reverser.start()
            t.expectEqual(started, false, "无辅助功能权限时拒绝启动（不崩溃）")
            t.expectEqual(reverser.isRunning, false, "无权限时保持未运行")
        } else {
            t.expectTrue(AXHelper.isTrusted(), "辅助功能已授权")
            _ = reverser.start()
            t.expectEqual(reverser.isRunning, true, "有权限时启动成功")
            reverser.stop()
            t.expectEqual(reverser.isRunning, false, "停止后恢复未运行")
        }
        reverser.destroy()
    }
    // 10. 设置持久化：默认值 + 跨实例恢复
    do {
        let suiteName = "MacToolsTest.scroll"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let first = SettingsStore(defaults: suite)
        t.expectEqual(first.scrollReverseEnabled, false, "总开关默认关闭")
        t.expectEqual(first.scrollReverseMouse, true, "鼠标反转默认开启")
        t.expectEqual(first.scrollReverseTrackpad, false, "触控板反转默认关闭")
        t.expectEqual(first.scrollReverseHorizontal, false, "横向反转默认关闭")
        t.expectEqual(first.scrollTreatSmoothWheelAsMouse, false, "平滑滚轮进阶选项默认关闭")
        first.scrollReverseEnabled = true
        first.scrollReverseMouse = false
        first.scrollReverseTrackpad = true
        first.scrollReverseHorizontal = true
        first.scrollTreatSmoothWheelAsMouse = true
        let second = SettingsStore(defaults: suite)
        t.expectEqual(second.scrollReverseEnabled, true, "总开关持久化恢复")
        t.expectEqual(second.scrollReverseMouse, false, "鼠标偏好持久化恢复")
        t.expectEqual(second.scrollReverseTrackpad, true, "触控板偏好持久化恢复")
        t.expectEqual(second.scrollReverseHorizontal, true, "横向偏好持久化恢复")
        t.expectEqual(second.scrollTreatSmoothWheelAsMouse, true, "平滑滚轮进阶选项持久化恢复")
        suite.removePersistentDomain(forName: suiteName)
    }
    // 11. 一次性迁移：旧版误判期间被翻反的偏好恢复默认语义
    do {
        let suiteName = "MacToolsTest.scrollMigration"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        // 模拟旧版用户：为绕过误判翻成了“反转触控板、不反转鼠标”
        suite.set(false, forKey: "scroll.reverseMouse")
        suite.set(true, forKey: "scroll.reverseTrackpad")
        let migrated = SettingsStore(defaults: suite)
        t.expectEqual(migrated.scrollReverseMouse, true, "迁移：鼠标反转恢复开启")
        t.expectEqual(migrated.scrollReverseTrackpad, false, "迁移：触控板反转恢复关闭")
        // 迁移只做一次：之后的用户选择不再被改写
        migrated.scrollReverseMouse = false
        let again = SettingsStore(defaults: suite)
        t.expectEqual(again.scrollReverseMouse, false, "迁移只执行一次，后续偏好不被改写")
        suite.removePersistentDomain(forName: suiteName)
    }
}

func runHotKeyTests(_ t: TestRunner) {
    print("\n== HotKeyManager ==")

    // 1. 默认组合与 Maccy 的 ⌘⇧V 错开
    let combo = KeyCombo.defaultClipboard
    t.expectEqual(combo.display, "⌥⇧V", "默认组合为 ⌥⇧V（避开 Maccy 的 ⌘⇧V）")

    // 2. 组合判定：命中
    var event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)
    event?.flags = [.maskAlternate, .maskShift]
    t.expectTrue(
        KeyCombo.shouldFire(keyCode: 9, flagsRaw: event?.flags.rawValue ?? 0, wantKeyCode: combo.keyCode, wantModifiers: combo.carbonModifiers),
        "⌥⇧V 按键命中默认组合"
    )

    // 3. 不同按键不命中
    t.expectTrue(
        !KeyCombo.shouldFire(keyCode: 11, flagsRaw: event?.flags.rawValue ?? 0, wantKeyCode: combo.keyCode, wantModifiers: combo.carbonModifiers),
        "不同按键不命中"
    )

    // 4. 修饰键不同不命中（⌘⇧V ≠ ⌥⇧V，与 Maccy 互不干扰）
    event?.flags = [.maskCommand, .maskShift]
    t.expectTrue(
        !KeyCombo.shouldFire(keyCode: 9, flagsRaw: event?.flags.rawValue ?? 0, wantKeyCode: combo.keyCode, wantModifiers: combo.carbonModifiers),
        "修饰键不同不命中"
    )

    // 5. 多按 Fn 等额外修饰键时不命中（fn 位 = 0x00800000）
    event?.flags = [.maskAlternate, .maskShift, CGEventFlags(rawValue: 0x0080_0000)]
    t.expectTrue(
        !KeyCombo.shouldFire(keyCode: 9, flagsRaw: event?.flags.rawValue ?? 0, wantKeyCode: combo.keyCode, wantModifiers: combo.carbonModifiers),
        "附加 Fn 时精确匹配不命中"
    )

    // 6. Carbon 系统热键注册（免权限、全局生效）。用 F19 组合避免与
    //    正在运行的正式实例（⌥⇧V）抢占同一组合导致注册失败。
    let manager = HotKeyManager.shared
    let testCombo = KeyCombo(keyCode: 80, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧F19")
    manager.register(id: "test.combo", combo: testCombo)
    t.expectTrue(manager.lastRegistrationSucceeded, "Carbon 系统热键注册成功（无需任何权限）")
    t.expectTrue(manager.isRegistered, "isRegistered 发布为 true")

    // 7. 暂停期间注销热键（录制快捷键时防自我吞键），恢复后重新注册
    manager.setPaused(true)
    t.expectTrue(!manager.isRegistered, "暂停后热键不再注册")
    manager.setPaused(false)
    t.expectTrue(manager.isRegistered && manager.lastRegistrationSucceeded, "恢复后热键重新注册")
    // 录制未完成就切到其他应用：视图仍在，但全局注册必须恢复。
    manager.setPaused(true)
    NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApplication.shared)
    t.expectTrue(!manager.isPaused && manager.isRegistered, "录制期间切到后台自动恢复全局热键")
    // 返回设置页时不应重新进入暂停，也不应因重复失活通知取消注册。
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: NSApplication.shared)
    t.expectTrue(!manager.isPaused && manager.lastRegistrationSucceeded, "反复切换前后台保持热键注册")
    manager.unregister(id: "test.combo")
    t.expectTrue(!manager.isRegistered, "注销后无注册组合")
}

func runHotKeyConflictTests(_ t: TestRunner) {
    print("\n== HotKeyConflict ==")

    let a = KeyCombo(keyCode: 1, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧S")
    let aCopy = KeyCombo(keyCode: 1, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧S")
    let b = KeyCombo(keyCode: 35, carbonModifiers: UInt32(optionKey | shiftKey), display: "⌥⇧P")

    // 1. 相同按键 + 相同修饰键 = 重复
    t.expectTrue(HotKeyConflict.isSame(a, aCopy), "相同组合判定为重复")
    t.expectTrue(!HotKeyConflict.isSame(a, b), "不同组合不判重")

    // 2. 条目查重返回名称
    let entries = [
        HotKeyConflict.Entry(name: "截图触发", combo: a),
        HotKeyConflict.Entry(name: "截图·固定", combo: b),
    ]
    t.expectEqual(HotKeyConflict.duplicate(of: a, in: entries) ?? "nil", "截图触发", "重复项返回其名称")
    t.expectTrue(HotKeyConflict.duplicate(of: KeyCombo(keyCode: 49, carbonModifiers: 0, display: "空格"), in: entries) == nil, "未注册组合无内部冲突")

    // 3. 系统快捷键冲突
    let cmdC = KeyCombo(keyCode: 8, carbonModifiers: UInt32(cmdKey), display: "⌘C")
    t.expectTrue(HotKeyConflict.systemConflict(of: cmdC) != nil, "⌘C 命中系统快捷键冲突")
    let cmdShift4 = KeyCombo(keyCode: 21, carbonModifiers: UInt32(cmdKey | shiftKey), display: "⌘⇧4")
    t.expectTrue(HotKeyConflict.systemConflict(of: cmdShift4) != nil, "⌘⇧4 命中系统截图快捷键冲突")
    t.expectTrue(HotKeyConflict.systemConflict(of: a) == nil, "⌥⇧S 无系统冲突")

    // 4. 冲突描述汇总
    let both = HotKeyConflict.describe(
        combo: KeyCombo(keyCode: 8, carbonModifiers: UInt32(cmdKey), display: "⌘C"),
        selfEntries: entries + [.init(name: "我的组合", combo: KeyCombo(keyCode: 8, carbonModifiers: UInt32(cmdKey), display: "⌘C"))],
        excludingName: "我的组合"
    )
    t.expectEqual(both.count, 1, "系统冲突单独提示（排除自身后）")
    let dupAndSystem = HotKeyConflict.describe(
        combo: KeyCombo(keyCode: 8, carbonModifiers: UInt32(cmdKey), display: "⌘C"),
        selfEntries: [.init(name: "触发截图", combo: KeyCombo(keyCode: 8, carbonModifiers: UInt32(cmdKey), display: "⌘C"))]
    )
    t.expectTrue(dupAndSystem.count >= 2, "内部重复与系统冲突同时提示")
}

func runAnnotationTests(_ t: TestRunner) {
    print("\n== Annotation ==")

    // 生成 64×64 渐变测试底图（无权限依赖）
    let width = 64, height = 64
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let colors = [CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 0, blue: 0, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 64), options: [])
    let base = context.makeImage()!

    let renderer = AnnotationRenderer(baseImage: base, size: CGSize(width: 64, height: 64))
    var pixelCache: [[UInt8]?] = [nil, nil, nil]

    func renderPixels(_ annotations: [Annotation], slot: Int) -> [UInt8]? {
        if let cached = pixelCache[slot] { return cached }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        renderer.draw(annotations: annotations, draft: nil, in: ctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        let pixelCount = width * height * 4
        let pixels = [UInt8](UnsafeBufferPointer(start: data, count: pixelCount))
        pixelCache[slot] = pixels
        return pixels
    }

    // 1. 无标注时合成 = 底图（渐变蓝在下：取位图最后一行首像素 = 图像左下角）
    if let plain = renderPixels([], slot: 0) {
        let bottomLeft = (height - 1) * width * 4
        t.expectTrue(plain[bottomLeft] < plain[bottomLeft + 2], "无标注时保持底图（左下角偏蓝）")
    } else {
        t.expectTrue(false, "底图渲染成功")
    }

    // 2. 箭头标注改变像素
    if let withArrow = renderPixels([.arrow(id: UUID(), from: CGPoint(x: 8, y: 32), to: CGPoint(x: 56, y: 32), colorIndex: 4, width: 4)], slot: 1),
       let plain = pixelCache[0] {
        var changed = 0
        for i in 0..<(width * height * 4) where abs(Int(withArrow[i]) - Int(plain[i])) > 40 { changed += 1 }
        t.expectTrue(changed > 100, "箭头标注绘制生效（\(changed) 个通道变化）")
    } else {
        t.expectTrue(false, "箭头渲染成功")
    }

    // 3. 马赛克标注改变像素
    if let withMosaic = renderPixels([.mosaic(id: UUID(), points: [CGPoint(x: 16, y: 48), CGPoint(x: 48, y: 48)], brushWidth: 20, blockSize: 12)], slot: 2),
       let plain = pixelCache[0] {
        var changed = 0
        for i in 0..<(width * height * 4) where abs(Int(withMosaic[i]) - Int(plain[i])) > 40 { changed += 1 }
        t.expectTrue(changed > 100, "马赛克标注绘制生效（\(changed) 个通道变化）")
    } else {
        t.expectTrue(false, "马赛克渲染成功")
    }

    // 4. 合成导出尺寸正确
    let composited = renderer.composite(annotations: [.stroke(id: UUID(), points: [CGPoint(x: 4, y: 4), CGPoint(x: 60, y: 60)], colorIndex: 0, width: 3)])
    t.expectEqual(Int(composited.size.width), 64, "合成图像宽度")
    t.expectEqual(Int(composited.size.height), 64, "合成图像高度")
}

func runCaptureSessionScaleTests(_ t: TestRunner) {
    print("\n== CaptureSessionScale ==")

    // 造一张 800×600 测试图
    let ctx = CGContext(
        data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    let image = NSImage(size: NSSize(width: 800, height: 600))
    image.addRepresentation(NSBitmapImageRep(cgImage: ctx.makeImage()!))
    let session = CaptureSession(image: image, captureRect: CGRect(x: 0, y: 0, width: 800, height: 600))

    // 1. 默认 1:1
    t.expectEqual(session.displayScale, CGFloat(1), "默认显示缩放为 1")
    t.expectEqual(Int(session.displaySize.width), 800, "默认显示宽度 = 图像宽度")

    // 2. fit-to-screen 缩放后显示尺寸按比例缩小
    session.displayScale = 0.5
    t.expectEqual(Int(session.displaySize.width), 400, "缩放 0.5 后显示宽度减半")
    t.expectEqual(Int(session.displaySize.height), 300, "缩放 0.5 后显示高度减半")

    // 3. 合成导出始终保持原分辨率（不受显示缩放影响）
    session.addAnnotation(.stroke(id: UUID(), points: [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100)], colorIndex: 0, width: 3))
    let composited = session.compositeImage()
    t.expectEqual(Int(composited.size.width), 800, "合成导出不随显示缩放降低分辨率")
    t.expectEqual(Int(composited.size.height), 600, "合成导出高度保持原尺寸")

    // 4. 撤销与清空标注
    session.undo()
    t.expectEqual(session.annotations.count, 0, "撤销移除标注")
    session.addAnnotation(.arrow(id: UUID(), from: .zero, to: CGPoint(x: 10, y: 10), colorIndex: 1, width: 2))
    session.clearAnnotations()
    t.expectEqual(session.annotations.count, 0, "清空移除全部标注")
}

// MARK: - 翻译模块测试

/// URLProtocol 桩：按脚本返回响应或抛错，统计请求次数（验证重试逻辑）。
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// async → 同步桥（无 XCTest 环境下运行 async 用例）。
/// Box 不能嵌在泛型函数里（Swift 限制），定义在文件作用域。
private final class AsyncResultBox: @unchecked Sendable {
    var result: Result<Any, Error>?
    let semaphore = DispatchSemaphore(value: 0)
}

func awaitSync<T: Sendable>(_ body: @escaping () async throws -> T) throws -> T {
    let box = AsyncResultBox()
    Task {
        do {
            box.result = .success(try await body())
        } catch {
            box.result = .failure(error)
        }
        box.semaphore.signal()
    }
    box.semaphore.wait()
    switch box.result! {
    case .success(let value): return value as! T
    case .failure(let error): throw error
    }
}

func runTranslationTests(_ t: TestRunner, tempRoot: URL) {
    print("\n== Translation ==")

    // 1. 语言目录：代码唯一；自动检测只出现在源语言选项
    do {
        let codes = LanguageCatalog.all.map(\.code)
        t.expectEqual(Set(codes).count, codes.count, "语言代码无重复")
        t.expectTrue(!LanguageCatalog.targetOptions.contains(LanguageCatalog.auto), "目标语言不含自动检测")
        t.expectTrue(LanguageCatalog.sourceOptions.contains(LanguageCatalog.auto), "源语言含自动检测")
        t.expectEqual(LanguageCatalog.language(forCode: "zh-Hans")?.displayName ?? "", "简体中文", "按代码查语言")
    }

    // 2. 提示词构建
    do {
        let en = LanguageCatalog.all.first { $0.code == "en" }!
        let zh = LanguageCatalog.all.first { $0.code == "zh-Hans" }!
        let auto = TranslationWire.prompt(for: TranslationQuery(text: "hello", source: nil, target: zh))
        t.expectTrue(auto.system.contains("自动检测"), "自动检测出现在 system 提示词")
        let manual = TranslationWire.prompt(for: TranslationQuery(text: "你好", source: zh, target: en))
        t.expectTrue(manual.system.contains("简体中文") && manual.system.contains("英语"), "手动语言对写入提示词")
        t.expectEqual(manual.user, "你好", "原文作为 user 消息")
        t.expectTrue(auto.system.contains("只输出译文本身"), "提示词要求只输出译文")
    }

    // 3. 端点拼接：容错末尾斜杠、已含路径、非法地址
    do {
        let a = TranslationWire.endpointURL(fromBase: "https://api.example.com/v1/")?.absoluteString ?? ""
        t.expectEqual(a, "https://api.example.com/v1/chat/completions", "末尾斜杠容错")
        let b = TranslationWire.endpointURL(fromBase: "https://api.example.com/v1")?.absoluteString ?? ""
        t.expectEqual(b, "https://api.example.com/v1/chat/completions", "标准地址拼接")
        let c = TranslationWire.endpointURL(fromBase: "https://api.example.com")?.absoluteString ?? ""
        t.expectEqual(c, "https://api.example.com/chat/completions", "无路径根地址拼接")
        t.expectTrue(TranslationWire.endpointURL(fromBase: "http locl invalid ://") == nil, "非法地址返回 nil")
    }

    // 4. 输入长度校验
    do {
        t.expectTrue(TranslationInput.isValid(String(repeating: "字", count: 5000)), "恰好 5000 字符合法")
        t.expectTrue(!TranslationInput.isValid(String(repeating: "字", count: 5001)), "5001 字符超限")
        t.expectEqual(TranslationInput.clipped(String(repeating: "字", count: 6000)).count, 5000, "裁剪到上限")
    }

    // 5. 错误：描述齐全 + 重试语义
    do {
        let samples: [TranslationError] = [
            .apiKeyMissing, .invalidEndpoint, .timeout, .unauthorized(nil), .rateLimited,
            .server(status: 500, message: nil), .network("断网"), .emptyResponse,
            .noTextInImage, .ocrFailed("x"), .inputTooLong(limit: 5000), .cancelled,
        ]
        for error in samples {
            let text = error.errorDescription ?? ""
            t.expectTrue(!text.isEmpty, "错误有中文描述（\(String(text.prefix(12)))…）")
        }
        t.expectTrue(TranslationError.timeout.isRetryable && TranslationError.rateLimited.isRetryable, "超时与限流可重试")
        t.expectTrue(!TranslationError.apiKeyMissing.isRetryable && !TranslationError.unauthorized(nil).isRetryable, "密钥错误不重试")
        t.expectTrue(TranslationError.server(status: 502, message: nil).isRetryable, "5xx 可重试")
        t.expectTrue(!TranslationError.server(status: 404, message: nil).isRetryable, "404 不重试")
    }

    // 6. 响应解析：正常 / 空内容 / 错误体
    do {
        let good = """
        {"choices":[{"message":{"role":"assistant","content":"  你好世界 \\n"}}]}
        """.data(using: .utf8)!
        t.expectEqual(try TranslationWire.parseResponse(good), "你好世界", "解析并去除首尾空白")
        let empty = """
        {"choices":[{"message":{"content":"   "}}]}
        """.data(using: .utf8)!
        t.expectTrue((try? TranslationWire.parseResponse(empty)) == nil, "空译文抛错")
        let malformed = "not json".data(using: .utf8)!
        t.expectTrue((try? TranslationWire.parseResponse(malformed)) == nil, "坏 JSON 抛错")
    } catch {
        t.expectTrue(false, "响应解析用例意外抛错：\(error)")
    }

    // 7. 状态码映射
    do {
        let body = "{\"error\":{\"message\":\"Invalid key\"}}".data(using: .utf8)
        t.expectEqual(TranslationWire.error(forStatus: 401, body: body), .unauthorized("Invalid key"), "401 → 密钥错误")
        t.expectEqual(TranslationWire.error(forStatus: 429, body: nil), .rateLimited, "429 → 限流")
        if case .server(let status, let message) = TranslationWire.error(forStatus: 503, body: body) {
            t.expectEqual(status, 503, "503 → 服务错误")
            t.expectEqual(message ?? "", "Invalid key", "错误体信息透传")
        } else {
            t.expectTrue(false, "503 映射为 server 错误")
        }
    }

    // 8. 历史存储：新增/去重置顶/上限/删除/持久化
    do {
        let file = tempRoot.appendingPathComponent("translation-history.json")
        let store = TranslationHistoryStore(fileURL: file, autoSave: false)
        var records = store.readFromDisk()
        t.expectEqual(records.count, 0, "初始无历史")
        _ = records // silence

        store.limitsProvider = { 3 }
        let now = Date()
        store.add(TranslationRecord(sourceText: "a", translatedText: "甲", sourceLanguage: "auto", targetLanguage: "zh-Hans", createdAt: now))
        store.add(TranslationRecord(sourceText: "b", translatedText: "乙", sourceLanguage: "auto", targetLanguage: "zh-Hans", createdAt: now))
        store.add(TranslationRecord(sourceText: "a", translatedText: "甲2", sourceLanguage: "auto", targetLanguage: "zh-Hans", createdAt: now))
        t.expectEqual(store.records.count, 2, "同文同语言对去重（置顶刷新）")
        t.expectEqual(store.records.first?.translatedText ?? "", "甲2", "重复记录更新内容并置顶")
        store.add(TranslationRecord(sourceText: "c", translatedText: "丙", sourceLanguage: "auto", targetLanguage: "zh-Hans", createdAt: now))
        store.add(TranslationRecord(sourceText: "d", translatedText: "丁", sourceLanguage: "auto", targetLanguage: "zh-Hans", createdAt: now))
        t.expectEqual(store.records.count, 3, "超出上限自动裁剪")
        t.expectTrue(store.records.contains { $0.sourceText == "d" }, "最新记录保留")
        t.expectTrue(!store.records.contains { $0.sourceText == "b" }, "最旧记录被裁剪")

        // 持久化往返（autoSave=false 时手动编码模拟）
        store.delete(id: store.records[1].id)
        t.expectEqual(store.records.count, 2, "按 id 删除")
        // 多索引删除：逆序移除，验证删的是选中条目而非位移后的错位条目
        let multiStore = TranslationHistoryStore(fileURL: tempRoot.appendingPathComponent("multi.json"), autoSave: false)
        for c in ["a", "b", "c", "d"] {
            multiStore.add(TranslationRecord(sourceText: c, translatedText: c, sourceLanguage: "auto", targetLanguage: "zh-Hans"))
        }
        multiStore.delete(at: IndexSet([0, 2]))
        // [d,c,b,a] 删索引 0(d)、2(b) → [c,a]；旧实现升序遍历会错删成 [c,b]
        t.expectEqual(multiStore.records.map(\.sourceText), ["c", "a"], "多索引删除不受数组位移影响（删除 d 与 b）")
        multiStore.delete(at: IndexSet([5])) // 越界索引安全忽略
        t.expectEqual(multiStore.records.count, 2, "越界索引不崩溃不误删")
        let autoStore = TranslationHistoryStore(fileURL: file, autoSave: true)
        autoStore.add(TranslationRecord(sourceText: "persist", translatedText: "持久", sourceLanguage: "en", targetLanguage: "zh-Hans"))
        // ioQueue 异步落盘，等待后重读
        Thread.sleep(forTimeInterval: 0.4)
        let reloaded = TranslationHistoryStore(fileURL: file, autoSave: false)
        t.expectEqual(reloaded.readFromDisk().first?.sourceText ?? "", "persist", "历史落盘并可重读")
        autoStore.clearAll()
        Thread.sleep(forTimeInterval: 0.4)
        t.expectEqual(reloaded.readFromDisk().count, 0, "清空后落盘为空")
    }

    // 9. 服务设置：默认值 / 预设应用 / 持久化
    do {
        let suiteName = "MacToolsTest.translate"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let first = TranslationSettings(defaults: suite)
        t.expectEqual(first.apiBaseURL, TranslationSettings.presets[0].baseURL, "默认地址取首个预设")
        t.expectEqual(first.defaultTargetCode, "zh-Hans", "默认目标语言简体中文")
        t.expectEqual(first.maxRetries, 2, "默认重试 2 次")
        first.apply(preset: TranslationSettings.presets[1])
        t.expectEqual(first.apiBaseURL, "https://api.deepseek.com/v1", "应用预设地址")
        t.expectEqual(first.model, "deepseek-chat", "应用预设模型")
        first.timeoutSeconds = 999
        first.maxRetries = -1
        t.expectEqual(first.timeoutSeconds, 120, "超时属性同步钳制（内存值合法）")
        t.expectEqual(first.maxRetries, 0, "重试属性同步钳制（内存值合法）")
        t.expectEqual(suite.integer(forKey: "translate.timeoutSeconds"), 120, "超时钳制到 120")
        t.expectEqual(suite.integer(forKey: "translate.maxRetries"), 0, "重试钳制到 0")
        let second = TranslationSettings(defaults: suite)
        t.expectEqual(second.model, "deepseek-chat", "模型持久化恢复")
        suite.removePersistentDomain(forName: suiteName)
    }

    // 10. 服务层：重试后成功 / 密钥错误快速失败 / 超时重试后抛错
    do {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let service = TranslationService(session: URLSession(configuration: config))
        let suite = UserDefaults(suiteName: "MacToolsTest.translateService")!
        suite.removePersistentDomain(forName: "MacToolsTest.translateService")
        let serviceSettings = TranslationSettings(defaults: suite)
        serviceSettings.apiKey = "sk-test"
        let zh = LanguageCatalog.all[0]

        let goodBody = """
        {"choices":[{"message":{"content":"你好"}}]}
        """.data(using: .utf8)!

        // 10.1 前两次 500，第三次成功 → 重试生效
        MockURLProtocol.requestCount = 0
        MockURLProtocol.handler = { _ in
            MockURLProtocol.requestCount <= 2 ? (500, Data()) : (200, goodBody)
        }
        let outcome = try awaitSync {
            try await service.translate(TranslationQuery(text: "hello", source: nil, target: zh), settings: serviceSettings)
        }
        t.expectEqual(outcome.translatedText, "你好", "重试后拿到译文")
        t.expectEqual(outcome.attempts, 3, "共尝试 3 次（2 次重试）")

        // 10.2 401 → 快速失败不重试
        MockURLProtocol.requestCount = 0
        MockURLProtocol.handler = { _ in (401, "{\"error\":{\"message\":\"bad key\"}}".data(using: .utf8)!) }
        do {
            _ = try awaitSync {
                try await service.translate(TranslationQuery(text: "hello", source: nil, target: zh), settings: serviceSettings)
            }
            t.expectTrue(false, "401 应当抛错")
        } catch let error as TranslationError {
            t.expectEqual(error, .unauthorized("bad key"), "401 映射为密钥错误")
        }
        t.expectEqual(MockURLProtocol.requestCount, 1, "密钥错误不重试")

        // 10.3 网络超时 → 重试后抛超时错误
        serviceSettings.maxRetries = 1
        MockURLProtocol.requestCount = 0
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try awaitSync {
                try await service.translate(TranslationQuery(text: "hello", source: nil, target: zh), settings: serviceSettings)
            }
            t.expectTrue(false, "超时应当抛错")
        } catch let error as TranslationError {
            t.expectEqual(error, .timeout, "URLError 超时映射")
        }
        t.expectEqual(MockURLProtocol.requestCount, 2, "超时可重试（1 次重试）")
        MockURLProtocol.handler = nil

        // 10.4 未配置密钥（非本地地址）→ 直接给出配置引导
        serviceSettings.apiKey = ""
        do {
            _ = try awaitSync {
                try await service.translate(TranslationQuery(text: "hi", source: nil, target: zh), settings: serviceSettings)
            }
            t.expectTrue(false, "缺密钥应当抛错")
        } catch let error as TranslationError {
            t.expectEqual(error, .apiKeyMissing, "缺密钥给出配置引导")
        } catch {
            t.expectTrue(false, "缺密钥抛 TranslationError（实际 \(error)）")
        }

        // 10.5 输入超限在发请求前拦截
        MockURLProtocol.requestCount = 0
        serviceSettings.apiKey = "sk-test"
        do {
            _ = try awaitSync {
                try await service.translate(TranslationQuery(text: String(repeating: "x", count: 5001), source: nil, target: zh), settings: serviceSettings)
            }
            t.expectTrue(false, "超限输入应当抛错")
        } catch let error as TranslationError {
            t.expectTrue(error == .inputTooLong(limit: 5000), "超限输入被拦截")
        } catch {
            t.expectTrue(false, "超限抛 TranslationError（实际 \(error)）")
        }
        t.expectEqual(MockURLProtocol.requestCount, 0, "超限不发网络请求")
        suite.removePersistentDomain(forName: "MacToolsTest.translateService")
    } catch {
        t.expectTrue(false, "服务层用例意外抛错：\(error)")
    }

    // 11. OCR：空白图像返回空文本（真实识别效果依赖屏幕内容，不做脆弱断言）
    do {
        let context = CGContext(
            data: nil, width: 60, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 30))
        let image = NSImage(size: NSSize(width: 60, height: 30))
        image.addRepresentation(NSBitmapImageRep(cgImage: context.makeImage()!))
        let text = try awaitSync { try await OCRService.recognizeText(in: image) }
        t.expectEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "", "空白图像识别为空文本")
    } catch {
        t.expectTrue(false, "OCR 用例意外抛错：\(error)")
    }
}

// MARK: - 入口

// 端到端模式（--e2e-scroll）：启动真实 ScrollReverser 引擎，注入离散滚动
// 事件，断言“识别为鼠标 + 已反转”计数增长。验证 tap 线程、手势 tap、分类
// 与改写的完整集成链路。前提：运行进程具备辅助功能权限（受信任父进程的
// 子进程继承授权；正式 .app 需要在系统设置中授权）。
if CommandLine.arguments.contains("--e2e-scroll") {
    final class E2ELog {
        static var passed = 0
        static var failures: [String] = []
        static func check(_ condition: Bool, _ name: String) {
            if condition {
                passed += 1
                print("  ✅ \(name)")
            } else {
                failures.append(name)
                print("  ❌ \(name)")
            }
        }
    }

    print("== ScrollReverser 端到端（真实事件注入） ==")
    let e2eReverser = ScrollReverser()
    e2eReverser.updatePreferences(
        reverseMouse: true,
        reverseTrackpad: false,
        reverseHorizontal: false,
        treatContinuousAsMouse: false
    )
    guard e2eReverser.start() else {
        print("引擎启动失败：\(e2eReverser.lastError ?? "未知")（本环境无辅助功能权限时跳过端到端）")
        exit(0)
    }
    E2ELog.check(e2eReverser.isRunning, "引擎在授权环境下启动成功")

    func intVal(_ snapshot: [String: Any], _ key: String) -> Int {
        (snapshot[key] as? Int) ?? (snapshot[key] as? UInt64).map(Int.init) ?? 0
    }

    let before = e2eReverser.debugSnapshot()
    // 注入 5 个 +1 行离散滚动事件（传统滚轮形态）
    for _ in 0..<5 {
        if let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0) {
            event.post(tap: .cghidEventTap)
        }
        usleep(120_000)
    }
    usleep(800_000)
    let after = e2eReverser.debugSnapshot()
    let mouseDelta = intVal(after, "mouseEvents") - intVal(before, "mouseEvents")
    let trackpadDelta = intVal(after, "trackpadEvents") - intVal(before, "trackpadEvents")
    let reversedDelta = intVal(after, "reversedEvents") - intVal(before, "reversedEvents")
    print("  事件计数变化：鼠标 +\(mouseDelta) · 触控板 +\(trackpadDelta) · 已反转 +\(reversedDelta)")
    E2ELog.check(mouseDelta >= 5, "注入的离散事件被引擎捕获并识别为鼠标")
    E2ELog.check(reversedDelta >= 5, "识别为鼠标的事件按偏好完成反转")
    E2ELog.check(trackpadDelta == 0, "无两指触摸的连续/离散事件不误判为触控板")
    e2eReverser.stop()
    e2eReverser.destroy()
    print("通过 \(E2ELog.passed) 项，失败 \(E2ELog.failures.count) 项")
    exit(E2ELog.failures.isEmpty ? 0 : 1)
}

let runner = TestRunner()
let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolsTests-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

runClipboardStoreTests(runner, tempRoot: tempRoot)
runClipboardCaptureTests(runner)
runMenuBarLayoutTests(runner)
runMenuBarPersistenceTests(runner, tempRoot: tempRoot)
runScrollLogicTests(runner)
runHotKeyTests(runner)
do {
    let domain = "MacToolsTest.shortcuts.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = SettingsStore(defaults: defaults)
    runner.expectTrue(settings.featureHotKeys.isEmpty, "新增快捷键默认不占用组合")
    let combo = KeyCombo(keyCode: 17, carbonModifiers: UInt32(controlKey | optionKey | shiftKey), display: "⌃⌥⇧T")
    settings.setHotKey(combo, for: .trackpadToggle)
    let reloaded = SettingsStore(defaults: defaults)
    runner.expectEqual(reloaded.featureHotKeys[FeatureShortcut.trackpadToggle.rawValue], combo, "快捷键重启后保留")
    reloaded.setHotKey(nil, for: .trackpadToggle)
    runner.expectTrue(SettingsStore(defaults: defaults).featureHotKeys.isEmpty, "清除快捷键会持久化")
    runner.expectEqual(Set(FeatureShortcut.allCases.map(\.id)).count, FeatureShortcut.allCases.count, "全部功能快捷键具有独立标识")
}
runTrackpadTests(runner)
runHotKeyConflictTests(runner)
runAnnotationTests(runner)
runCaptureSessionScaleTests(runner)
func runMainMenuTests(_ t: TestRunner) {
    print("\n== AppMenus ==")
    // 文本框 ⌘V/⌘C 等键等效依赖编辑菜单项：验证结构完整
    let menu = AppMenus.makeMainMenu(onOpenSettings: {})
    let editMenu = menu.items.first { $0.submenu?.title == "编辑" }?.submenu
    t.expectTrue(editMenu != nil, "主菜单包含「编辑」菜单")

    var actions: [String: Selector] = [:]
    for item in editMenu?.items ?? [] {
        if !item.keyEquivalent.isEmpty {
            actions[item.keyEquivalent] = item.action
        }
    }
    t.expectEqual(actions["v"] ?? #selector(NSApplication.hide(_:)), #selector(NSText.paste(_:)), "⌘V 绑定粘贴（密钥等文本框可快捷粘贴）")
    t.expectEqual(actions["c"] ?? #selector(NSApplication.hide(_:)), #selector(NSText.copy(_:)), "⌘C 绑定拷贝")
    t.expectEqual(actions["x"] ?? #selector(NSApplication.hide(_:)), #selector(NSText.cut(_:)), "⌘X 绑定剪切")
    t.expectEqual(actions["a"] ?? #selector(NSApplication.hide(_:)), #selector(NSText.selectAll(_:)), "⌘A 绑定全选")
    t.expectTrue(actions["z"] != nil, "⌘Z 绑定撤销")

    // 设置项回调可达（target 存活且选择器正确）
    final class SettingsProbe {
        var called = false
    }
    let probe = SettingsProbe()
    let probeMenu = AppMenus.makeMainMenu(onOpenSettings: { probe.called = true })
    let appMenu = probeMenu.items.first { $0.submenu?.title == "MacTools" }?.submenu
    let settingsItem = appMenu?.items.first { $0.title == "设置…" }
    t.expectTrue(settingsItem != nil, "应用菜单包含「设置…」")
    t.expectEqual(settingsItem?.keyEquivalent ?? "", ",", "设置项 ⌘, 键等效")
    if let item = settingsItem, let target = item.target as? NSObject {
        target.perform(item.action, with: nil)
        t.expectTrue(probe.called, "设置项回调被触发（菜单 target 存活）")
    } else {
        t.expectTrue(false, "设置项 target 存活并可执行")
    }
}

runTranslationTests(runner, tempRoot: tempRoot)
runMainMenuTests(runner)

try? FileManager.default.removeItem(at: tempRoot)

print("\n==============================")
print("通过 \(runner.passed) 项，失败 \(runner.failures.count) 项")
if !runner.failures.isEmpty {
    for failure in runner.failures {
        print("  ❌ \(failure)")
    }
    exit(1)
}
print("✅ 全部测试通过")
exit(0)
