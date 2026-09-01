import Foundation

// MARK: - 语言

/// 翻译目标/源语言。displayName 供界面与 AI 提示词使用。
public struct Language: Codable, Hashable, Identifiable {
    public let code: String
    public let displayName: String

    public init(code: String, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public var id: String { code }
}

/// 常用语言目录（界面选择 + 提示词用中文名，模型识别效果好）。
public enum LanguageCatalog {
    public static let auto = Language(code: "auto", displayName: "自动检测")

    public static let all: [Language] = [
        Language(code: "zh-Hans", displayName: "简体中文"),
        Language(code: "zh-Hant", displayName: "繁体中文"),
        Language(code: "en", displayName: "英语"),
        Language(code: "ja", displayName: "日语"),
        Language(code: "ko", displayName: "韩语"),
        Language(code: "fr", displayName: "法语"),
        Language(code: "de", displayName: "德语"),
        Language(code: "es", displayName: "西班牙语"),
        Language(code: "ru", displayName: "俄语"),
        Language(code: "pt", displayName: "葡萄牙语"),
        Language(code: "it", displayName: "意大利语"),
        Language(code: "th", displayName: "泰语"),
        Language(code: "vi", displayName: "越南语"),
        Language(code: "ar", displayName: "阿拉伯语"),
        Language(code: "id", displayName: "印尼语"),
    ]

    public static func language(forCode code: String) -> Language? {
        all.first { $0.code == code }
    }

    /// 源语言选择：自动检测 + 全部语言。
    public static var sourceOptions: [Language] { [auto] + all }

    /// 目标语言选择：全部语言（目标必须是确定语言）。
    public static var targetOptions: [Language] { all }
}

// MARK: - 历史记录

/// 一条翻译历史：原文、译文、语言对与时间戳，本地 JSON 落盘。
public struct TranslationRecord: Codable, Equatable, Identifiable {
    public let id: UUID
    public let sourceText: String
    public let translatedText: String
    /// "auto" 表示当时自动检测。
    public let sourceLanguage: String
    public let targetLanguage: String
    public let createdAt: Date
    /// 来源：截图 OCR 或手动输入。
    public let fromScreenshot: Bool

    public init(
        id: UUID = UUID(),
        sourceText: String,
        translatedText: String,
        sourceLanguage: String,
        targetLanguage: String,
        createdAt: Date = Date(),
        fromScreenshot: Bool = false
    ) {
        self.id = id
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.createdAt = createdAt
        self.fromScreenshot = fromScreenshot
    }

    public var sourceLanguageName: String {
        sourceLanguage == LanguageCatalog.auto.code
            ? LanguageCatalog.auto.displayName
            : (LanguageCatalog.language(forCode: sourceLanguage)?.displayName ?? sourceLanguage)
    }

    public var targetLanguageName: String {
        LanguageCatalog.language(forCode: targetLanguage)?.displayName ?? targetLanguage
    }
}

// MARK: - 输入校验

public enum TranslationInput {
    /// 单次翻译的输入长度上限（字符）。
    public static let maxLength = 5000

    /// 校验输入文本：超长返回 false。
    public static func isValid(_ text: String) -> Bool {
        text.count <= maxLength
    }

    /// 裁剪到上限（界面预览/保护性截断用）。
    public static func clipped(_ text: String) -> String {
        String(text.prefix(maxLength))
    }
}

// MARK: - 错误

/// 翻译流程错误：统一映射为对用户友好的中文描述。
public enum TranslationError: Error, Equatable {
    /// 未配置 API 密钥。
    case apiKeyMissing
    /// 服务地址无效。
    case invalidEndpoint
    /// 请求超时。
    case timeout
    /// 密钥无效或无权限（401/403）。
    case unauthorized(String?)
    /// 触发服务端限流（429），重试后仍失败。
    case rateLimited
    /// 服务端错误（5xx）或未知状态码。
    case server(status: Int, message: String?)
    /// 网络异常（断网、DNS 等）。
    case network(String)
    /// 响应解析失败或译文为空。
    case emptyResponse
    /// 截图中未识别到文字。
    case noTextInImage
    /// OCR 识别失败。
    case ocrFailed(String)
    /// 输入超过长度限制。
    case inputTooLong(limit: Int)
    /// 已取消。
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "尚未配置 API 密钥：请到「设置 → 翻译」填写翻译服务的 API Key"
        case .invalidEndpoint:
            return "服务地址无效：请检查「设置 → 翻译」中的 API 地址（一般以 /v1 结尾）"
        case .timeout:
            return "请求超时：网络较慢或服务无响应，请稍后重试，或在设置中调大超时时间"
        case .unauthorized(let detail):
            let reason = detail.flatMap { "（\($0)）" } ?? ""
            return "API 密钥无效或无权限\(reason)：请核对密钥与所选服务商是否匹配"
        case .rateLimited:
            return "请求过于频繁被限流：请稍等片刻再试"
        case .server(let status, let message):
            let reason = message.map { "：\($0)" } ?? ""
            return "翻译服务返回错误（\(status)）\(reason)"
        case .network(let detail):
            return "网络异常\(detail.isEmpty ? "" : "（\(detail)）")：请检查网络连接后重试"
        case .emptyResponse:
            return "服务未返回有效译文：请重试或更换模型"
        case .noTextInImage:
            return "截图中未识别到文字：请确认截取区域内包含清晰文字"
        case .ocrFailed(let detail):
            return "文字识别失败\(detail.isEmpty ? "" : "（\(detail)）")：请重试或换一个更清晰的区域"
        case .inputTooLong(let limit):
            return "输入超过长度限制（最多 \(limit) 字符）：请分段翻译"
        case .cancelled:
            return "已取消翻译"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .timeout, .rateLimited, .network:
            return true
        case .server(let status, _):
            return status >= 500
        default:
            return false
        }
    }
}
