import Foundation
import CryptoKit

/// 剪贴板条目类型。
public enum ClipboardKind: String, Codable, CaseIterable, Identifiable {
    case text
    case image
    case files

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .files: return "文件"
        }
    }

    public var symbolName: String {
        switch self {
        case .text: return "doc.text"
        case .image: return "photo"
        case .files: return "folder"
        }
    }
}

/// 单条剪贴板历史。字段设计参考 Maccy 的 Core Data 模型
/// （内容/来源应用/复制次数/首次与最近复制时间/固定标记），改为 Codable 存储。
public struct ClipboardItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public var kind: ClipboardKind
    /// 文本内容；文件类型时为绝对路径（每行一个）。
    public var text: String?
    /// 图片在 images 目录下的文件名。
    public var imageRelativePath: String?
    public var imagePixelWidth: Double?
    public var imagePixelHeight: Double?
    public var fileNames: [String]?
    /// 去重指纹：类型前缀 + 内容哈希。
    public var fingerprint: String
    public var byteSize: Int?
    public var numberOfCopies: Int
    public var pinned: Bool
    public var firstCopiedAt: Date
    public var lastCopiedAt: Date
    public var sourceAppBundleID: String?
    public var sourceAppName: String?

    public init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        text: String? = nil,
        imageRelativePath: String? = nil,
        imagePixelWidth: Double? = nil,
        imagePixelHeight: Double? = nil,
        fileNames: [String]? = nil,
        fingerprint: String,
        byteSize: Int? = nil,
        numberOfCopies: Int = 1,
        pinned: Bool = false,
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageRelativePath = imageRelativePath
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.fileNames = fileNames
        self.fingerprint = fingerprint
        self.byteSize = byteSize
        self.numberOfCopies = numberOfCopies
        self.pinned = pinned
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
    }

    public var displayTitle: String {
        switch kind {
        case .text:
            let line = text?.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                ?? text ?? ""
            return line.count > 200 ? String(line.prefix(200)) + "…" : line
        case .files:
            if let names = fileNames, !names.isEmpty {
                return names.count == 1 ? names[0] : "\(names.count) 个文件：\(names.joined(separator: "、"))"
            }
            return "文件"
        case .image:
            if let w = imagePixelWidth, let h = imagePixelHeight {
                return "图片 \(Int(w))×\(Int(h))"
            }
            return "图片"
        }
    }

    public var searchText: String {
        [text ?? "", sourceAppName ?? "", kind.label].joined(separator: " ")
    }

    public var filePaths: [String] {
        text?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
    }

    public func imageURL(in directory: URL) -> URL? {
        imageRelativePath.map { directory.appendingPathComponent($0) }
    }

    /// 生成去重指纹。
    public static func fingerprint(kind: ClipboardKind, payload: Data) -> String {
        "\(kind.rawValue)|\(sha256Hex(payload))"
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
