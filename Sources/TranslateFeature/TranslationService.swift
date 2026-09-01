import CoreKit
import Foundation

// MARK: - 请求/结果

public struct TranslationQuery: Equatable {
    public let text: String
    /// nil 表示自动检测源语言。
    public let source: Language?
    public let target: Language

    public init(text: String, source: Language?, target: Language) {
        self.text = text
        self.source = source
        self.target = target
    }
}

public struct TranslationOutcome: Equatable {
    public let translatedText: String
    public let model: String
    public let attempts: Int

    public init(translatedText: String, model: String, attempts: Int) {
        self.translatedText = translatedText
        self.model = model
        self.attempts = attempts
    }
}

// MARK: - 纯逻辑（可单测）

/// 请求构造与响应解析的纯逻辑，独立于 URLSession 便于单元测试。
public enum TranslationWire {
    /// 由根地址拼出 chat/completions 端点；容忍末尾斜杠与多余的相对路径。
    public static func endpointURL(fromBase baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        let path = components.path
        if !path.hasSuffix("/chat/completions") {
            components.path = path + "/chat/completions"
        }
        return components.url
    }

    /// 组装 system/user 提示词：要求模型只输出译文，保留格式。
    public static func prompt(for query: TranslationQuery) -> (system: String, user: String) {
        let sourceName = query.source?.displayName ?? "自动检测"
        let system = """
        你是专业翻译引擎，把用户提交的文本从\(sourceName)翻译成\(query.target.displayName)。要求：
        1. 只输出译文本身，不要输出任何解释、前缀、引号或原文
        2. 保留原文的换行与段落结构
        3. 源语言为“自动检测”时先识别语言再翻译
        4. 若文本已经是目标语言，原样输出
        5. 专业术语保持行业惯例，代码片段中的标识符不翻译
        """
        return (system, query.text)
    }

    /// Chat Completions 请求体。
    public static func requestBody(model: String, query: TranslationQuery) -> [String: Any] {
        let (system, user) = prompt(for: query)
        return [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
    }

    /// 解析 Chat Completions 响应，取出译文（去首尾空白）。
    public static func parseResponse(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message?
            }
            let choices: [Choice]?
            let error: APIError?
            struct APIError: Decodable {
                let message: String?
            }
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TranslationError.emptyResponse
        }
        if let message = decoded.error?.message {
            throw TranslationError.server(status: 0, message: message)
        }
        guard let content = decoded.choices?.first?.message?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw TranslationError.emptyResponse
        }
        return content
    }

    /// HTTP 状态码 → 错误映射（附响应体里的错误信息）。
    public static func error(forStatus status: Int, body: Data?) -> TranslationError {
        // OpenAI 风格错误体：{"error": {"message": "..."}}
        struct APIErrorBody: Decodable {
            struct Detail: Decodable {
                let message: String?
            }
            let error: Detail?
        }
        let message = body.flatMap { try? JSONDecoder().decode(APIErrorBody.self, from: $0) }?.error?.message
        switch status {
        case 401, 403:
            return .unauthorized(message)
        case 429:
            return .rateLimited
        default:
            return .server(status: status, message: message)
        }
    }

    /// URLError → 错误映射。
    public static func error(forURLError error: URLError) -> TranslationError {
        switch error.code {
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancelled
        default:
            return .network(error.localizedDescription)
        }
    }
}

// MARK: - 服务层

/// AI 翻译服务：OpenAI 兼容 Chat Completions 协议，统一供截图翻译与文本翻译调用。
/// 内置超时控制、失败自动重试（指数退避）与错误友好化。
public final class TranslationService {
    private let session: URLSession

    /// 测试注入用（MockURLProtocol）。
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 单次翻译。retryable 错误按 maxRetries 自动重试（指数退避 0.6s 起）。
    public func translate(
        _ query: TranslationQuery,
        settings: TranslationSettings
    ) async throws -> TranslationOutcome {
        guard TranslationInput.isValid(query.text) else {
            throw TranslationError.inputTooLong(limit: TranslationInput.maxLength)
        }
        // 区分两类配置缺失：地址/模型为空 → 地址无效提示；非本地服务缺密钥 → 密钥提示
        let base = settings.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !model.isEmpty, let endpoint = TranslationWire.endpointURL(fromBase: base) else {
            throw TranslationError.invalidEndpoint
        }
        let key = settings.apiKey.trimmingCharacters(in: .whitespaces)
        let isLocalService = base.contains("localhost") || base.contains("127.0.0.1")
        if key.isEmpty, !isLocalService {
            throw TranslationError.apiKeyMissing
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = TimeInterval(settings.timeoutSeconds)
        request.httpBody = try JSONSerialization.data(withJSONObject: TranslationWire.requestBody(model: settings.model, query: query))

        let maxAttempts = max(1, settings.maxRetries + 1)
        var lastError: TranslationError = .network("未知错误")
        for attempt in 1...maxAttempts {
            if Task.isCancelled { throw TranslationError.cancelled }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw TranslationError.network("响应格式异常")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw TranslationWire.error(forStatus: http.statusCode, body: data)
                }
                let text = try TranslationWire.parseResponse(data)
                return TranslationOutcome(translatedText: text, model: settings.model, attempts: attempt)
            } catch let error as TranslationError {
                lastError = error
                guard error.isRetryable, attempt < maxAttempts else { throw error }
            } catch let error as URLError {
                lastError = TranslationWire.error(forURLError: error)
                guard lastError.isRetryable, attempt < maxAttempts else { throw lastError }
            } catch {
                lastError = .network(error.localizedDescription)
                guard attempt < maxAttempts else { throw lastError }
            }
            // 指数退避：0.6s、1.2s…；期间被取消则立即终止
            let delay = UInt64(600_000_000 * UInt64(attempt))
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch {
                throw TranslationError.cancelled
            }
        }
        throw lastError
    }
}
