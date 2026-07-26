import Foundation
import SwiftData

/// BYOK 模型配置：预置 DeepSeek/Qwen/GLM/Kimi/Claude/Gemini/OpenAI/自定义。
/// API Key 不入库，只存 Keychain account 引用（绝不进 UserDefaults/日志/源码）。
@Model
final class LLMProviderConfig {
    @Attribute(.unique) var id: UUID
    var name: String               // "DeepSeek"
    var baseURL: String            // "https://api.deepseek.com"
    var model: String              // "deepseek-v4-flash"
    var keychainAccount: String    // Keychain key 引用
    var supportsThinking: Bool     // DeepSeek V4 thinking 模型
    var isDefault: Bool
    var createdAt: Date

    init(id: UUID = UUID(),
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
enum LLMPresets {
    static let deepSeekName = "DeepSeek"
    static let deepSeekBaseURL = "https://api.deepseek.com"
    static let deepSeekFlash = "deepseek-v4-flash"   // 日常/会中问答/短任务
    static let deepSeekPro = "deepseek-v4-pro"       // 纪要/待办/调研(thinking)
    static let deepSeekKeychainAccount = "llm.deepseek.apikey"
}
