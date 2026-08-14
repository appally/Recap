import Foundation
import RecapModels

/// 录音 → 流式 ASR 编排。UI 层通过回调消费字幕事件。
@MainActor
public final class RecordingSession: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var engineKind: AsrEngineKind?
    @Published public private(set) var statusText: String = ""
    @Published public var lastError: String?
    @Published public private(set) var currentAudioBands: AudioBands = .zero

    public var onPartial: ((String) -> Void)?
    public var onSegment: ((TranscriptSegment) -> Void)?
    public var onError: ((String) -> Void)?
    /// 音频中断开始(true)/恢复(false)。与会话层计时耦合：中断期间无 PCM，会话层据此暂停计时。
    public var onInterrupted: ((Bool) -> Void)?

    private let recorder = AudioRecorder()
    private var engine: (any AsrEngine)?
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    public init() {}

    /// 解析引擎 → prepare → 开流 → 麦克风 tap 喂入。
    /// - Parameter audioFileURL: 本地 PCM 落盘路径（与 ASR 解耦的基石）；nil 则不写文件。
    public func start(sampleRate: Double = 16000, audioFileURL: URL? = nil, contextualHints: [String] = []) async throws {
        if isRunning { _ = try? await stop() }
        lastError = nil
        statusText = "正在准备引擎…"
        await recorder.setOnAudioBands { [weak self] bands in
            Task { @MainActor in
                self?.currentAudioBands = bands
            }
        }
        await Task.yield()

        // 托管凭证(recapCloud+Pro 或 免费档):先确保 Recap 云凭证就绪。ASR 走后端签发的
        // 阿里临时 token(≤30min);warmup 失败不阻断启动,回落链(端侧/BYOK)兜底。
        // 免费档以 usage=.asr 计量,扣独立 ASR 桶(国行/非 AI 机型端侧不可用兜底)。
        if RecapCredentialProvider.shared.isActiveCloud {
            do {
                try await RecapCredentialProvider.shared.ensureFresh(usage: .asr)
            } catch {
                self.onError?("云凭证准备失败，将尝试其他引擎…")
            }
        }

        // 引擎解析放到非主线程，避免 Speech/Keychain 探测卡住首帧
        let resolved: any AsrEngine
        do {
            resolved = try await Self.withTimeout(seconds: 12) {
                // detached 脱离 MainActor（避免 Speech/Keychain 探测卡首帧），但 detached 不继承父任务取消；
                // 用 withTaskCancellationHandler 在超时取消时主动 cancel detached，防孤儿任务堆积占资源。
                let det = Task.detached(priority: .userInitiated) {
                    try await AsrEngineResolver.resolve()
                }
                return try await withTaskCancellationHandler {
                    try await det.value
                } onCancel: {
                    det.cancel()
                }
            }
        } catch is RecordingSessionError {
            throw RecordingSessionError.prepareTimeout
        }
        engine = resolved
        engineKind = resolved.kind
        statusText = "连接中…"
        await Task.yield()

        // 端侧引擎消费热词（云端引擎默认空实现，忽略）
        if !contextualHints.isEmpty {
            await resolved.setContextualHints(contextualHints)
        }

        do {
            let events: AsyncStream<AsrStreamEvent>
            do {
                events = try await Self.withTimeout(seconds: 12) {
                    try await resolved.startStreaming(sampleRate: sampleRate)
                }
            } catch is RecordingSessionError {
                throw RecordingSessionError.prepareTimeout
            }
            statusText = "录音中"
            eventTask = Task { [weak self] in
                for await event in events {
                    guard let self, !Task.isCancelled else { break }
                    switch event {
                    case .partial(let text):
                        self.onPartial?(text)
                    case .segment(let seg):
                        self.onSegment?(seg)
                    }
                }
            }

            await recorder.setOnInterrupted { [weak self] began in
                Task { @MainActor in
                    guard let self else { return }
                    // 先转发给会话层（暂停/恢复计时），再更新本地文案
                    self.onInterrupted?(began)
                    if began {
                        self.statusText = "音频被中断…"
                        self.onError?("音频被中断，结束后将尝试恢复…")
                    } else {
                        self.statusText = "录音中"
                        // 清空 UI 中断文案；若恢复失败会再次 began=true
                        self.onError?("")
                    }
                }
            }

            await recorder.setOnError { [weak self] recorderError in
                Task { @MainActor in
                    guard let self else { return }
                    let msg = recorderError.errorDescription ?? "录音写入失败"
                    self.lastError = msg
                    self.onError?(msg)
                }
            }

            let audioStream = try await recorder.start(targetSampleRate: sampleRate, fileURL: audioFileURL)
            isRunning = true
            statusText = "录音中"

            audioTask = Task { [weak self] in
                // 节奏监测：墙钟/音频 > 1.8（处理持续慢于实时）→ 诚实告警「录音处理滞后」；
                //   < 1.2 恢复则清除。云端 sender 解耦后正常永不触发；仅极端反压时让用户可见
                //   （盘上 PCM 完整，建议结束后重转）。复用 onError → statusMessage 通路。
                var lagWarned = false
                var windowStart = Date()
                var audioAccum: Double = 0
                let rate = sampleRate
                for await chunk in audioStream {
                    guard let self, !Task.isCancelled else { break }
                    // ⚠️ 必须「每帧都喂」SpeechAnalyzer——流式转写依赖连续音频流，丢帧会：
                    //   ① 饿死转写器（首条 partial 需累积数百 ms 连续音频才吐字）→ 字幕不出现；
                    //   ② 压缩其内部音频时间轴（result.range.seconds 按「已喂采样」累计，非墙钟），
                    //      破坏 start/end 与落盘 PCM 的对齐 → 会后说话人分离错位。
                    //   故「去静音幻听」不在此层做；若要做，应改在结果层（仅抑制 partial、永不
                    //   抑制 final，最坏只是「不够实时」而非「无字幕」）。见 EnergyVAD 头注释。
                    do {
                        try await self.engine?.feed(chunk)
                    } catch {
                        // 单帧失败不中断整场录音；上报 UI，仍可点「结束」
                        let msg = error.localizedDescription
                        self.lastError = msg
                        self.onError?(msg)
                    }
                    audioAccum += Double(chunk.count) / rate
                    if audioAccum >= 5.0 {
                        let ratio = Date().timeIntervalSince(windowStart) / audioAccum
                        if ratio > 1.8, !lagWarned {
                            self.onError?("录音处理滞后，字幕可能不准，建议结束后重转")
                            lagWarned = true
                        } else if ratio < 1.2, lagWarned {
                            self.onError?("")
                            lagWarned = false
                        }
                        windowStart = Date()
                        audioAccum = 0
                    }
                }
            }
        } catch {
            eventTask?.cancel()
            eventTask = nil
            audioTask?.cancel()
            audioTask = nil
            await engine?.release()
            engine = nil
            engineKind = nil
            isRunning = false
            statusText = "准备失败"
            throw error
        }
    }

    /// 停麦 → 冲刷 ASR（带超时）→ 返回最终结果。保证一定能结束。
    @discardableResult
    public func stop() async throws -> TranscribeResult {
        await recorder.stop()
        audioTask?.cancel()
        audioTask = nil

        var result = TranscribeResult(segments: [])
        if let engine {
            do {
                result = try await Self.withTimeout(seconds: 5) {
                    try await engine.stopStreaming()
                }
            } catch {
                lastError = "转写收尾超时/失败：\(error.localizedDescription)"
            }
            await engine.release()
        }
        eventTask?.cancel()
        eventTask = nil
        self.engine = nil
        isRunning = false
        statusText = "已停止"
        return result
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw RecordingSessionError.stopTimeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

public enum RecordingSessionError: Error, LocalizedError, Sendable {
    case stopTimeout
    case prepareTimeout

    public var errorDescription: String? {
        switch self {
        case .stopTimeout: return "停止转写超时"
        case .prepareTimeout: return "准备转写引擎超时（可改用 Fun-ASR 或稍后重试端侧）"
        }
    }
}
