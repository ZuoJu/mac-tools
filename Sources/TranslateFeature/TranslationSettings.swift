import Foundation

/// AI 翻译服务配置（UserDefaults 持久化，仅保存在本机）。
/// 兼容 OpenAI Chat Completions 协议：OpenAI / DeepSeek / 智谱 GLM /
/// Moonshot / 本地 Ollama 等均可直连。
public final class TranslationSettings: ObservableObject {
    /// 服务商预设：一键填入地址与推荐模型。
    public struct ProviderPreset: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let baseURL: String
        public let model: String

        public init(id: String, name: String, baseURL: String, model: String) {
            self.id = id
            self.name = name
            self.baseURL = baseURL
            self.model = model
        }
    }

    public static let presets: [ProviderPreset] = [
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        .init(id: "zhipu", name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-flash"),
        .init(id: "moonshot", name: "Moonshot", baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k"),
        .init(id: "ollama", name: "Ollama（本地）", baseURL: "http://localhost:11434/v1", model: "qwen2.5:7b"),
    ]

    private enum Keys {
        static let baseURL = "translate.apiBaseURL"
        static let apiKey = "translate.apiKey"
        static let model = "translate.model"
        static let defaultTarget = "translate.defaultTarget"
        static let timeoutSeconds = "translate.timeoutSeconds"
        static let maxRetries = "translate.maxRetries"
        static let historyLimit = "translate.historyLimit"
    }

    private let defaults: UserDefaults

    /// API 根地址，一般以 /v1 结尾（自动补齐缺失的斜杠与路径）。
    @Published public var apiBaseURL: String { didSet { defaults.set(apiBaseURL, forKey: Keys.baseURL) } }
    /// API 密钥（仅保存在本机 UserDefaults；本地 Ollama 可留空）。
    @Published public var apiKey: String { didSet { defaults.set(apiKey, forKey: Keys.apiKey) } }
    /// 模型名。
    @Published public var model: String { didSet { defaults.set(model, forKey: Keys.model) } }
    /// 默认目标语言代码。
    @Published public var defaultTargetCode: String { didSet { defaults.set(defaultTargetCode, forKey: Keys.defaultTarget) } }
    /// 请求超时（秒），5 ~ 120。钳制同时改内存值，保证 UI 立即显示合法范围。
    @Published public var timeoutSeconds: Int {
        didSet {
            let clamped = min(max(timeoutSeconds, 5), 120)
            if clamped != timeoutSeconds {
                timeoutSeconds = clamped
                return // 赋值触发下一轮 didSet，此时已合法
            }
            defaults.set(clamped, forKey: Keys.timeoutSeconds)
        }
    }
    /// 失败自动重试次数，0 ~ 3。
    @Published public var maxRetries: Int {
        didSet {
            let clamped = min(max(maxRetries, 0), 3)
            if clamped != maxRetries {
                maxRetries = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.maxRetries)
        }
    }
    /// 历史记录上限，20 ~ 500。
    @Published public var historyLimit: Int {
        didSet {
            let clamped = min(max(historyLimit, 20), 500)
            if clamped != historyLimit {
                historyLimit = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.historyLimit)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiBaseURL = defaults.string(forKey: Keys.baseURL)
            ?? Self.presets[0].baseURL
        apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        model = defaults.string(forKey: Keys.model)
            ?? Self.presets[0].model
        defaultTargetCode = defaults.string(forKey: Keys.defaultTarget) ?? "zh-Hans"
        timeoutSeconds = defaults.object(forKey: Keys.timeoutSeconds) as? Int ?? 30
        maxRetries = defaults.object(forKey: Keys.maxRetries) as? Int ?? 2
        historyLimit = defaults.object(forKey: Keys.historyLimit) as? Int ?? 100
    }

    /// 应用服务商预设（地址 + 推荐模型，不动密钥）。
    public func apply(preset: ProviderPreset) {
        apiBaseURL = preset.baseURL
        model = preset.model
    }

    /// 当前是否具备发起翻译的最低配置。
    public var isConfigured: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
