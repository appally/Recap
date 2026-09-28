import Foundation
import SwiftData
import OSLog

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
    /// 云端档(Pro/免费)LLM 模型的客户端兜底默认——仅当网关 /v1/issue 未下发 llm_model 时用。
    /// 权威来源是网关 wrangler.jsonc 的 LLM_MODEL(现 qwen-plus-2025-12-01 钉快照:别名已冻结,
    /// 新款 qwen3.X-plus 涨 2.5-4 倍,裸别名有被重指涨价款的静默成本风险),各路径统一读 cred.llmModel;
    /// 此常量只作防御性兜底,值须与网关 LLM_MODEL 保持一致,否则会请求到白名单外的模型 -> 403。
    /// 2026-09-10 起托管 LLM 直联中转(hostedRelayModel),此常量仅剩 /v1/issue 解码兜底职责,
    /// 不再有运行时请求消费方。
    public static let cloudDefaultModel = "qwen-plus-2025-12-01"
    /// 托管档(Pro/免费)LLM 出口（plan 056，2026-09-28 起）：客户端不再持有共享中转 Key——
    /// /v1/issue 下发短期 relay_token + relay_base，LLM 请求经网关 /v1/relay 代理转发，
    /// 真实中转 Key 只存 Workers secret（开源红线：Key 出二进制）。
    /// 模型仍由此常量发送，网关会强制改写为 LLM_RELAY_MODEL（双保险——托管模型由网关独占决定）；
    /// auto/* 路由系（中转内部故障转移；单前缀如 aug/ 上游挂了直接 502，勿用）：
    /// auto/glm 实测路由 glm-5.2，流式 + 强制 tool_choice（待办提取）均验证可用；
    /// keepalive 空 delta 与 reasoning_content 由 OpenAICompatibleProvider 天然容忍。
    public static let hostedRelayModel = "auto/glm"
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
    /// 英文会议的云端模型：fun-asr-realtime 本身即多语言（自动语种检测，带句级时间戳、
    /// 支持热词），与 zh 同模型——百炼无英文专用实时模型（官方清单只有 v2/v1/8k 系列
    /// Paraformer + fun-asr + qwen3-asr[无时间戳]；线上实测 paraformer-realtime-en-v1
    /// 为 ModelNotFound，2026-08-23 探针/文档双确认）。保留独立常量以区分语言意图。
    public static let funRealtimeEnModel = "fun-asr-realtime"
    /// 旧域名仍可用，用户只需 API Key，无需 WorkspaceId。
    public static let funRealtimeWSURL = "wss://dashscope.aliyuncs.com/api-ws/v1/inference/"
}

/// 集中式 os.Logger 入口：摘要 / LLM 链路用它记录关键节点，让"静默失败"可观测。
/// 失败原因会写进 Console（subsystem = bundle id），Xcode 调试或 Mac 的 Console.app 可查。
public enum RecapLog {
    public static let minutes = Logger(subsystem: RecapLog.subsystem, category: "Minutes")
    public static let provider = Logger(subsystem: RecapLog.subsystem, category: "LLMProvider")
    public static let session = Logger(subsystem: RecapLog.subsystem, category: "MeetingSession")

    private static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "com.recap.app"
    }
}
