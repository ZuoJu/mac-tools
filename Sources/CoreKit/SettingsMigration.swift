import Foundation

/// 应用改名（MenuBarSuite → MacTools）的一次性数据迁移：
/// 1. 旧 UserDefaults 域（com.menubarsuite.app）的全部自有键拷贝到新标准域；
/// 2. 旧数据目录（Application Support/MacTools 前身）整体改名。
/// 必须在组合根访问任何设置/路径之前调用。
public enum AppMigration {
    public static let legacyDefaultsDomain = "com.menubarsuite.app"
    private static let migrationFlag = "mactools.migratedFromMenuBarSuite"

    public static func migrateIfNeeded() {
        let standard = UserDefaults.standard
        guard !standard.bool(forKey: migrationFlag) else { return }
        defer { standard.set(true, forKey: migrationFlag) }

        // 1. 设置域拷贝：只拷新域尚不存在的键，跳过系统注入键
        if let legacy = UserDefaults(suiteName: legacyDefaultsDomain) {
            let existing = standard.dictionaryRepresentation()
            let legacyPairs: [String: Any] = legacy.dictionaryRepresentation()
            for (key, value) in legacyPairs {
                guard !key.hasPrefix("Apple"), !key.hasPrefix("NS"),
                      !key.hasPrefix("PK"), !key.hasPrefix("mactools."),
                      existing[key] == nil else { continue }
                standard.set(value, forKey: key)
            }
        }

        // 2. 数据目录整体搬家（剪贴板历史、翻译历史、菜单栏状态等）
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let legacyDir = base.appendingPathComponent("MenuBarSuite", isDirectory: true)
            let newDir = base.appendingPathComponent("MacTools", isDirectory: true)
            if fm.fileExists(atPath: legacyDir.path), !fm.fileExists(atPath: newDir.path) {
                try? fm.moveItem(at: legacyDir, to: newDir)
            }
        }
    }
}
