import AppKit
import CoreKit
import Foundation

/// 剪贴板历史存储：内存态模型 + JSON 落盘（防抖），图片单独存文件。
/// 数据结构对齐 Maccy（去重上移、固定保留、复制次数、保留策略）。
public final class ClipboardStore: ObservableObject {
    @Published public private(set) var items: [ClipboardItem] = []

    /// 返回 (历史上限, 保留天数)；由组合根注入设置。
    public var limitsProvider: (() -> (maxItems: Int, retentionDays: Int))?

    public let imagesDirectory: URL

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.mactools.clipboard-io", qos: .utility)
    private let cache = NSCache<NSString, NSImage>()
    private var pendingSave: DispatchWorkItem?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(
        fileURL: URL = AppPaths.clipboardHistoryFile,
        imagesDirectory: URL = AppPaths.clipboardImages,
        autoSave: Bool = true
    ) {
        self.fileURL = fileURL
        self.imagesDirectory = imagesDirectory
        self.autoSave = autoSave
        cache.countLimit = 40
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    /// 测试时可关闭异步落盘。
    let autoSave: Bool

    // MARK: - 加载

    public func load() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.readFromDisk()
            DispatchQueue.main.async {
                self.items = loaded
                self.enforceLimits()
                self.cleanupOrphanImages()
            }
        }
    }

    public func readFromDisk() -> [ClipboardItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([ClipboardItem].self, from: data) else { return [] }
        return decoded
    }

    // MARK: - 记录

    /// 记录一条新复制；若与已有条目重复则去重上移（Maccy 行为）。
    public func record(_ item: ClipboardItem) {
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            var existing = items[index]
            existing.numberOfCopies += 1
            existing.lastCopiedAt = item.lastCopiedAt
            existing.sourceAppBundleID = item.sourceAppBundleID
            existing.sourceAppName = item.sourceAppName
            // 重复的图片落盘文件直接清理
            if let newPath = item.imageRelativePath, newPath != existing.imageRelativePath {
                removeImageFile(relativePath: newPath)
            }
            if existing.pinned {
                items[index] = existing
            } else {
                items.remove(at: index)
                items.insert(existing, at: 0)
            }
        } else {
            items.insert(item, at: 0)
        }
        enforceLimits()
        scheduleSave()
    }

    // MARK: - 条目操作

    public func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        scheduleSave()
    }

    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let path = items[index].imageRelativePath {
            removeImageFile(relativePath: path)
        }
        items.remove(at: index)
        scheduleSave()
    }

    public func clearAll(keepingPinned: Bool) {
        let kept = keepingPinned ? items.filter(\.pinned) : []
        let keptPaths = Set(kept.compactMap(\.imageRelativePath))
        for path in Set(items.compactMap(\.imageRelativePath)).subtracting(keptPaths) {
            removeImageFile(relativePath: path)
        }
        items = kept
        scheduleSave()
    }

    /// 应用清理策略：保留天数 + 历史上限（固定条目始终保留）。
    /// 被裁剪的图片条目同步删除落盘文件，避免孤儿文件累积。
    public func enforceLimits() {
        let limits = limitsProvider?() ?? (maxItems: 500, retentionDays: 0)
        var removedImagePaths: Set<String> = []
        if limits.retentionDays > 0,
           let cutoff = Calendar.current.date(byAdding: .day, value: -limits.retentionDays, to: Date()) {
            for item in items where !item.pinned && item.lastCopiedAt < cutoff {
                if let path = item.imageRelativePath { removedImagePaths.insert(path) }
            }
            items.removeAll { !$0.pinned && $0.lastCopiedAt < cutoff }
        }
        if limits.maxItems > 0 {
            var kept: [ClipboardItem] = []
            var unpinnedKept = 0
            for item in items {
                if item.pinned {
                    kept.append(item)
                } else if unpinnedKept < limits.maxItems {
                    kept.append(item)
                    unpinnedKept += 1
                } else if let path = item.imageRelativePath {
                    removedImagePaths.insert(path)
                }
            }
            if kept.count != items.count { items = kept }
        }
        for path in removedImagePaths {
            removeImageFile(relativePath: path)
        }
    }

    // MARK: - 复制回剪贴板

    /// 把历史条目重新写入剪贴板，并更新统计（上移 + 次数 + 时间）。
    @discardableResult
    public func copyToPasteboard(_ item: ClipboardItem, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        var succeeded = false
        switch item.kind {
        case .text:
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
                succeeded = true
            }
        case .files:
            let urls = item.filePaths.map { NSURL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls)
                succeeded = true
            }
        case .image:
            if let data = imageData(for: item) {
                pasteboard.setData(data, forType: .png)
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
                succeeded = true
            }
        }
        guard succeeded, let index = items.firstIndex(where: { $0.id == item.id }) else { return succeeded }
        items[index].numberOfCopies += 1
        items[index].lastCopiedAt = Date()
        if !items[index].pinned {
            let moved = items.remove(at: index)
            items.insert(moved, at: 0)
        }
        scheduleSave()
        return succeeded
    }

    // MARK: - 图片

    public func image(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image, let path = item.imageRelativePath else { return nil }
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let image = NSImage(contentsOf: imagesDirectory.appendingPathComponent(path))
        if let image {
            cache.setObject(image, forKey: path as NSString, cost: max(image.tiffRepresentation?.count ?? 0, 1))
        }
        return image
    }

    public func imageData(for item: ClipboardItem) -> Data? {
        guard item.kind == .image, let path = item.imageRelativePath else { return nil }
        return try? Data(contentsOf: imagesDirectory.appendingPathComponent(path))
    }

    func cleanupOrphanImages() {
        let referenced = Set(items.compactMap(\.imageRelativePath))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        for file in files where !referenced.contains(file) && file.hasSuffix(".png") {
            removeImageFile(relativePath: file)
        }
    }

    // MARK: - 持久化

    private func scheduleSave() {
        guard autoSave else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.items
            let encoder = self.encoder
            let url = self.fileURL
            self.ioQueue.async {
                if let data = try? encoder.encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 同步落盘（测试用）。
    public func persistNowSync() {
        let data = (try? encoder.encode(items)) ?? Data("[]".utf8)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func removeImageFile(relativePath: String) {
        try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(relativePath))
    }
}
