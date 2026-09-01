import Foundation

/// 集中管理应用数据目录与文件路径。
public enum AppPaths {
    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("MacTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var clipboardImages: URL {
        directory("clipboard-images")
    }

    public static var clipboardHistoryFile: URL {
        root.appendingPathComponent("clipboard-history.json")
    }

    public static var menuBarStateFile: URL {
        root.appendingPathComponent("menu-bar-state.json")
    }

    public static var translationHistoryFile: URL {
        root.appendingPathComponent("translation-history.json")
    }

    private static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
