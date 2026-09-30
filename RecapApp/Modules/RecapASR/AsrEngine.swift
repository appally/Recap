import Foundation
import RecapModels

/// 流式转写事件（LIVE 会中态消费）。
public enum AsrStreamEvent: Sendable {
    /// 实时粗稿。
    /// - 火山：累积全量文本
    /// - Fun-ASR：当前句（sentence_end=false）
    /// - SpeechAnalyzer：volatile（!isFinal）当前假设
    case partial(text: String)
    /// 定稿分段。
    /// - SpeechAnalyzer：isFinal + 同 start 覆盖 / 驱逐重叠旧键
    /// - Fun-ASR：sentence_end=true
    /// - 火山：通常不发（整场一条在 stopStreaming）
    case segment(TranscriptSegment)
}

/// ASR 引擎统一协议：批处理（会后精修）+ 流式（LIVE 边录边转）。
public protocol AsrEngine: Sendable {
    var kind: AsrEngineKind { get }

    /// 加载模型 / 校验凭证 / 建立会话前置条件。
    func prepare() async throws

    /// 批处理：转写一段单声道 Float32 PCM（通常 16k）。
    /// - Parameter onPartial: 实时粗稿回调；可忽略。
    func transcribe(samples: [Float],
                    sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult

    /// 批处理（磁盘友好）：转写 mmap 映射的 Float32 PCM `Data`。长音频时引擎可按段切片物化，
    /// 避免整文件 `[Float]` 常驻（60min≈230MB，峰值 460MB）。默认实现物化后走 `transcribe(samples:)`，
    /// 支持 mmap 流式的引擎（Fun-ASR / FluidAudio）override 以按段物化（单段 ~6MB）。
    func transcribe(audioData: Data,
                    sampleRate: Double,
                    onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult

    /// 流式：打开会话并返回事件流。随后反复 `feed`，最后 `stopStreaming`。
    func startStreaming(sampleRate: Double) async throws -> AsyncStream<AsrStreamEvent>

    /// 流式：喂入一帧/多帧 16k mono Float32。引擎内部按需分包。
    func feed(_ samples: [Float]) async throws

    /// 流式：结束会话，冲刷尾包，返回最终结果并关闭事件流。
    func stopStreaming() async throws -> TranscribeResult

    /// 卸载 / 断开，释放资源。
    func release() async

    /// 注入热词/实体提示（人名、公司、术语），供端侧 SpeechAnalyzer 的
    /// `AnalysisContext.contextualStrings` 消费。云端引擎可忽略（默认空实现）。
    func setContextualHints(_ hints: [String]) async

    /// 本引擎是否具备英文转写能力（会后语言精修的依据）：
    /// - FunASREn：是（云端英文模型）；
    /// - SpeechAnalyzer：zh-CN 与 en-US 双模块均就绪时为 true（prepare 后确定）；
    /// - FluidAudio SenseVoice：多语言模型，true；
    /// - 默认 false（fun-asr-realtime / paraformer-realtime-v2 中文模型）。
    /// 实例属性（非 kind 静态）——端侧能力随资源安装情况动态变化。
    var englishCapable: Bool { get }
}

extension AsrEngine {
    public func release() async {}

    /// 默认空实现：仅端侧 SpeechAnalyzer 用 AnalysisContext 消费热词。
    public func setContextualHints(_ hints: [String]) async {}

    /// 默认空实现：声明本流为 LIVE 长会话（FunASREngine 据此启用托管 token 的
    /// 会话滚动续期，规避 30min 到期静默断流）；批处理路径保持默认 false。
    public func setLiveMode(_ enabled: Bool) async {}

    /// 默认：中文模型不具备英文能力。
    public var englishCapable: Bool { false }

    /// 默认 false：仅 FunASR zh 实例跑在 fun-asr 多语言模型上时为 true（自动检测
    /// 天然覆盖英文，热切换无增益）。
    public var autoCoversEnglish: Bool { false }

    /// 批处理默认实现：走流式路径（start → feed → stop），避免双份发送逻辑。
    public func transcribe(samples: [Float],
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        let events = try await startStreaming(sampleRate: sampleRate)
        let consumer = Task {
            for await event in events {
                if case .partial(let text) = event {
                    onPartial?(text)
                }
            }
        }
        do {
            if !samples.isEmpty {
                try await feed(samples)
            }
            let result = try await stopStreaming()
            await consumer.value
            return result
        } catch {
            consumer.cancel()
            throw error
        }
    }

    /// 默认实现：物化为 [Float] 后走 transcribe(samples:)。未 override 的引擎（如 SpeechAnalyzer）
    /// 仍一次性物化--零回归，仅未享 mmap 省内存收益。
    public func transcribe(audioData: Data,
                           sampleRate: Double,
                           onPartial: (@Sendable (String) -> Void)?) async throws -> TranscribeResult {
        guard audioData.count >= MemoryLayout<Float>.size else {
            return TranscribeResult(segments: [], firstTokenLatencyMs: nil, chunkCount: 0)
        }
        let samples: [Float] = audioData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        return try await transcribe(samples: samples, sampleRate: sampleRate, onPartial: onPartial)
    }
}

/// actor 引擎跨隔离读取 bool 的最小锁盒：`englishCapable` 是协议要求（nonisolated 读取），
/// 但引擎内部状态在 actor 隔离区——写入方（prepare）与协议读取方跨隔离，用锁盒消除竞态。
/// 模式与 RecapCredentialProvider 的 @unchecked Sendable + NSLock 一致。
public final class EngineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    public init(_ initial: Bool = false) {
        self.value = initial
    }

    public var current: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

/// 引擎工厂。
public enum AsrEngineFactory {
    /// - Parameter language: 会话语言（resolve 贯通）。SpeechAnalyzer 据此注入双转写器
    ///   合并偏置（en 会场=置信度/粘性优先保六批成果；zh 会场=CJK 优先防英文幻觉
    ///   反杀方言中文）。
    @available(iOS 26.0, *)
    public static func make(_ kind: AsrEngineKind, language: MeetingLanguage = .zh) -> any AsrEngine {
        switch kind {
        case .speechAnalyzer:  SpeechAnalyzerEngine(bias: language == .en ? .en : .zh)
        case .funASR:          FunASREngine()
        case .funASREn:        FunASREngine(language: .en)
        case .fluidSenseVoice: FluidAudioEngine(kind: .fluidSenseVoice)
        case .customTranscription: CustomTranscriptionEngine()
        }
    }
}
