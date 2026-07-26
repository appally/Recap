import Foundation
import RecapModels

/// 录音 → 流式 ASR 编排。UI 层通过回调消费字幕事件。
@MainActor
public final class RecordingSession: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var engineKind: AsrEngineKind?
    @Published public private(set) var statusText: String = ""
    @Published public var lastError: String?

    public var onPartial: ((String) -> Void)?
    public var onSegment: ((TranscriptSegment) -> Void)?
    public var onError: ((String) -> Void)?

    private let recorder = AudioRecorder()
    private var engine: (any AsrEngine)?
    private var audioTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// LIVE VAD 门控（CPU 能量门限）；flag 关时为 nil → 恒喂 ASR（回归原行为）。
    private var vad: EnergyVAD?

    public init() {}

    /// 解析引擎 → prepare → 开流 → 麦克风 tap 喂入。
    /// - Parameter audioFileURL: 本地 PCM 落盘路径（与 ASR 解耦的基石）；nil 则不写文件。
    public func start(sampleRate: Double = 16000, audioFileURL: URL? = nil, contextualHints: [String] = []) async throws {
        if isRunning { _ = try? await stop() }
        lastError = nil
        statusText = "正在准备引擎…"
        await Task.yield()

        // 引擎解析放到非主线程，避免 Speech/Keychain 探测卡住首帧
        let resolved: any AsrEngine
        do {
            resolved = try await Self.withTimeout(seconds: 12) {
                try await Task.detached(priority: .userInitiated) {
                    try await AsrEngineResolver.resolve()
                }.value
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

            let audioStream = try await recorder.start(targetSampleRate: sampleRate, fileURL: audioFileURL)
            vad = ASRFeatureFlags.vadGateEnabled ? EnergyVAD() : nil
            isRunning = true
            statusText = "录音中"

            audioTask = Task { [weak self] in
                for await chunk in audioStream {
                    guard let self, !Task.isCancelled else { break }
                    // VAD 门控：静音帧不喂 ASR（落盘 PCM / elapsed 时间轴不受影响，仅省 ASR 算力 + 去幻听）
                    if !self.vadShouldFeed(chunk) { continue }
                    do {
                        try await self.engine?.feed(chunk)
                    } catch {
                        // 单帧失败不中断整场录音；上报 UI，仍可点「结束」
                        let msg = error.localizedDescription
                        self.lastError = msg
                        self.onError?(msg)
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

    /// VAD 门控判定：flag 关 / `vad` 为 nil → 恒喂（回归原行为）；否则走能量+过零率状态机。
    private func vadShouldFeed(_ chunk: [Float]) -> Bool {
        vad?.shouldFeed(chunk) ?? true
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
