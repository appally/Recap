import Foundation
import SwiftData

/// BYOK 模型配置：预置 DeepSeek/Qwen/GLM/Kimi/Claude/Gemini/OpenAI/自定义。
/// API Key 不入库，只存 Keychain account 引用（绝不进 UserDefaults/日志/源码）。
@Model
public final class LLMProviderConfig {
    @Attribute(.unique) public var id: UUID
    public var name: String               // "DeepSeek"
    public var baseURL: String            // "https://api.deepseek.com"
    public var model: String              // "deepseek-v4-flash"
    public var keychainAccount: String    // Keychain key 引用
    public var supportsThinking: Bool     // DeepSeek V4 thinking 模型
    public var isDefault: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(),
                name: String,
                baseURL: String,
                model: String,
                keychainAccount: String,
                supportsThinking: Bool = false,
                isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.keychainAccount = keychainAccount
        self.supportsThinking = supportsThinking
        self.isDefault = isDefault
        self.createdAt = Date()
    }
}

/// 预置模型常量（Phase 1 默认 DeepSeek V4）。
/// 放在 Models：Persistence 播种默认配置时无需依赖 RecapLLM。
public enum LLMPresets {
    public static let deepSeekName = "DeepSeek"
    public static let deepSeekBaseURL = "https://api.deepseek.com"
    public static let deepSeekFlash = "deepseek-v4-flash"   // 日常/会中问答/短任务
    public static let deepSeekPro = "deepseek-v4-pro"       // 纪要/待办/调研(thinking)
    /// 与 `LLMProviderTemplate.deepseek.keychainAccount` 对齐。
    public static let deepSeekKeychainAccount = "llm.deepseek.apikey"
}

/// 外部工具 API Keychain account（联网搜索等；绝不硬编码密钥）。
public enum ToolPresets {
    /// AnySearch BYOK（`Authorization: Bearer`）。
    public static let anySearchKeychainAccount = "tools.anysearch.apikey"
    /// Jina Reader 可选 Key（`Authorization: Bearer`）；无 Key 走匿名额度。
    public static let jinaKeychainAccount = "tools.jina.reader.apikey"
}

/// ASR 凭证 Keychain account / 常量（引擎读取，绝不硬编码密钥）。
public enum ASRPresets {
    // 阿里百炼 Fun-ASR（主云端）
    public static let funApiKeyAccount = "asr.fun.apikey"
    public static let funRealtimeModel = "fun-asr-realtime"
    /// 旧域名仍可用，用户只需 API Key，无需 WorkspaceId。
    public static let funRealtimeWSURL = "wss://dashscope.aliyuncs.com/api-ws/v1/inference/"

    // 火山 Seed-ASR（可选备）
    public static let volcAppKeyAccount = "asr.volc.appKey"
    public static let volcAccessKeyAccount = "asr.volc.accessKey"
    public static let volcResourceId = "volc.seedasr.sauc.duration"
}
