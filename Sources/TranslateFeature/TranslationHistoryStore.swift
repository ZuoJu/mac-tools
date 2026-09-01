import Combine
import CoreKit
import Foundation

/// 翻译历史存储：内存态 + JSON 落盘（AppPaths.translationHistoryFile）。
/// 新纪录插到最前，超出上限自动裁剪最旧的记录。
public final class TranslationHistoryStore: ObservableObject {
    @Published public private(set) var records: [TranslationRecord] = []

    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "com.mactools.translation-io", qos: .utility)
    private let autoSave: Bool
    /// 上限提供方（组合根注入设置），nil 时使用默认 100。
    public var limitsProvider: (() -> Int)?

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

    public init(fileURL: URL = AppPaths.translationHistoryFile, autoSave: Bool = true) {
        self.fileURL = fileURL
        self.autoSave = autoSave
    }

    // MARK: - 读写

    public func load() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let loaded = self.readFromDisk()
            DispatchQueue.main.async {
                self.records = loaded
                self.enforceLimit()
            }
        }
    }

    public func readFromDisk() -> [TranslationRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([TranslationRecord].self, from: data) else { return [] }
        return decoded
    }

    private func persist() {
        guard autoSave else { return }
        let snapshot = records
        let encoder = self.encoder
        let fileURL = self.fileURL
        ioQueue.async {
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    private func enforceLimit() {
        let limit = limitsProvider?() ?? 100
        if records.count > limit {
            records = Array(records.prefix(limit))
        }
    }

    // MARK: - 记录

    /// 新增历史（最新在最前）。与已有记录完全相同（文本+语言对）则移旧置顶刷新。
    public func add(_ record: TranslationRecord) {
        if let index = records.firstIndex(where: {
            $0.sourceText == record.sourceText
                && $0.targetLanguage == record.targetLanguage
                && $0.sourceLanguage == record.sourceLanguage
        }) {
            records.remove(at: index)
        }
        records.insert(record, at: 0)
        enforceLimit()
        persist()
    }

    /// 删除指定记录。
    public func delete(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    /// 按索引集合删除（List onDelete 配套）。必须逆序移除，
    /// 升序遍历会因数组位移删到错误条目。
    public func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where records.indices.contains(index) {
            records.remove(at: index)
        }
        persist()
    }

    /// 清空全部历史。
    public func clearAll() {
        records.removeAll()
        persist()
    }
}
