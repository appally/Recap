import Foundation
import SwiftUI
import UIKit
import Combine
import RecapModels
import RecapASR
import RecapLLM

/// 热节流门（§4.3）：serious/critical 时延后会后重计算（说话人分离/重转是最重的 CoreML 负载），
/// 保护长会议后设备。LIVE 录音/转写不中断（录音不可丢）；仅延后可重做的会后步骤。
public enum ThermalGate {
    public static func shouldDefer(thermalState: ProcessInfo.ThermalState) -> Bool {
        thermalState == .serious || thermalState == .critical
    }
    public static var shouldDeferHeavyCompute: Bool {
        shouldDefer(thermalState: ProcessInfo.processInfo.thermalState)
    }
    public static func warningText(thermalState: ProcessInfo.ThermalState) -> String? {
        switch thermalState {
        case .serious: return "设备温度较高，已延后该操作，请在降温后重试"
        case .critical: return "设备温度过高，已延后该操作，请在降温后重试"
        default: return nil
        }
    }
}

/// 会话状态机（LIVE → PROCESS → REVIEW）。
/// LIVE：优先 RecordingSession（真麦 + ASR）；失败进入可恢复错误态（禁止静默演示）。
@MainActor
public final class MeetingSession: ObservableObject {
    @Published public var phase: MeetingPhase
    @Published public var blocks: [TranscriptBlock] = []
    @Published public var elapsed: Int = 0
    @Published public var revealStep: Int = 0
    @Published public var todoCount: Int = 0
    @Published public var summary: MeetingSummary
    @Published public var statusMessage: String = ""
    @Published public var isUsingMockAudio = false
    /// LIVE 真实麦克风收音音量振幅 (0.0 ~ 1.0)。
    @Published public var liveAudioPower: Float = 0.0
    /// LIVE 引擎启动失败；供 UI 显示重试 / DEBUG 演示入口。
    @Published public var liveStartFailed = false
    /// LIVE 已暂停（停麦、停表，仍为 phase=.live；可继续 / 完成 / 删除）。
    @Published public var isLivePaused = false
    /// 会后 SpeakerKit 说话人分离进行中。
    @Published public var isDiarizing = false

    public let meeting: Meeting

    private var recording: RecordingSession?
    private var powerCancellable: AnyCancellable?
    private var streamTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    /// 会后 CoreML 重负载任务（diarization / 端侧重转写）引用，供 scenePhase 切后台时取消。
    private var postMeetingTask: Task<Void, Never>?
    /// 会后 LLM 润色任务（独立于 CoreML 的 postMeetingTask，二者可并发）。
    private var polishTask: Task<Void, Never>?
    /// #M2：暂停时捕获 stop() 定稿分段的任务；endLive 等其落地，resume 取消丢弃。
    private var pauseFlushTask: Task<Void, Never>?
    /// #6b：会后 LLM 纪要管线的后台名额；用户完成即切后台时争取时间让管线跑完。
    private var minutesBgTaskID: UIBackgroundTaskIdentifier = .invalid
    private var endingLive = false
    /// 全新会进会已自动发起开麦（防 onAppear 重入）；session 是按 meeting 创建的 @StateObject，标志位天然按会议隔离。
    private var didAutoStartLive = false
    private var liveSpeaker = Speaker(id: "asr-live", name: "转写", colorIndex: 0)
    /// LIVE 字幕合并（index / 续录偏移 / partial·segment）；UI `blocks` 由其投影。
    private var merger = LiveTranscriptMerger()
    private var lastCheckpointAt: Date?
    /// 由 View 注入：checkpoint 写完后 `modelContext.save()`。
    public var checkpointSaver: (() -> Void)?

    /// 真麦是否在跑（用于底栏错误态）。
    public var isRecordingLive: Bool { recording?.isRunning == true }

    /// 是否已开过麦（有时长/字幕）；用于区分启动台与暂停决策台。
    public var hasStartedRecording: Bool {
        meeting.durationSeconds >= 1
            || !meeting.segments.isEmpty
            || !blocks.isEmpty
            || elapsed > 0
    }

    public init(meeting: Meeting) {
        self.meeting = meeting
        self.phase = meeting.phase
        if let existing = meeting.latestSummary {
            self.summary = existing
        } else {
            self.summary = MeetingSummary(tldr: "", decisions: [], openQuestions: [])
        }
    }

    public func onAppear() {
        switch meeting.phase {
        case .live:
            loadBlocksIfNeeded()
            restoreElapsedIfNeeded()
            if recording?.isRunning == true {
                isLivePaused = false
                return
            }
            if hasStartedRecording {
                // 录过、暂停后重进：停「已暂停」，等用户点继续（不自动续录）
                enterPausedState(status: "已暂停")
            } else if !didAutoStartLive {
                // 全新会：进会即开麦，不再停在会前启动台
                didAutoStartLive = true
                startLive()
            }
        case .review:
            loadBlocksIfNeeded()
            if summary.tldr.isEmpty {
                summary = meeting.latestSummary
                    ?? MeetingSummary(tldr: blocks.isEmpty ? "暂无纪要" : "", decisions: [], openQuestions: [])
            }
            // 纠正常见脏数据：曾把整篇 Markdown 误写入 tldr
            summary = MinutesMarkdownParser.sanitizedSummary(summary)
            revealStep = 5
            todoCount = meeting.actionItems.count
        case .processing:
            // 具体恢复由 resumeOrRecoverProcessing 完成（需要持久化回调）
            loadBlocksIfNeeded()
            todoCount = meeting.actionItems.count
        }
    }

    /// REVIEW 态按当前底稿重跑纪要/待办（转写不变）。
    public func regenerateWithBrief(
        clearDraftTodos: @escaping () -> Void,
        persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
        persistSummary: @escaping (MeetingSummary, String) -> Void
    ) {
        loadBlocksIfNeeded()
        guard !blocks.isEmpty else {
            statusMessage = "无转写，无法重生成"
            return
        }
        revealTask?.cancel()
        clearDraftTodos()
        summary = MeetingSummary(tldr: "", decisions: [], openQuestions: [])
        todoCount = 0
        revealStep = 0
        statusMessage = meeting.briefPromptSummary == nil ? "按转写重生成…" : "按底稿重生成…"
        meeting.phase = .processing
        withAnimation(.recapSheet) { phase = .processing }
        startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
    }

    /// 重新打开卡在 processing 的会议：有纪要则收尾进 review，否则继续跑管线。
    public func resumeOrRecoverProcessing(
        persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
        persistSummary: @escaping (MeetingSummary, String) -> Void
    ) {
        guard meeting.phase == .processing || phase == .processing else { return }
        loadBlocksIfNeeded()
        todoCount = meeting.actionItems.count
        phase = .processing

        if let existing = meeting.latestSummary {
            let clean = MinutesMarkdownParser.sanitizedSummary(existing)
            if !clean.tldr.isEmpty || !clean.decisions.isEmpty || !clean.topics.isEmpty {
                summary = clean
                revealStep = 5
                statusMessage = ""
                meeting.phase = .review
                withAnimation(.recapSheet) { phase = .review }
                return
            }
        }

        // 已有进行中的揭示任务则不重复启动
        if let revealTask, !revealTask.isCancelled { return }

        if blocks.isEmpty {
            statusMessage = "无转写内容"
            finishReviewWithoutMock()
            return
        }

        startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
    }

    private func loadBlocksIfNeeded() {
        guard blocks.isEmpty else { return }
        guard !meeting.segments.isEmpty else { return }
        merger.loadCheckpoint(segments: meeting.segments)
        let speakers = meeting.speakers.isEmpty ? [liveSpeaker] : meeting.speakers
        blocks = meeting.segments.map {
            TranscriptBlock(segment: $0, speakers: speakers, isFinal: true)
        }
    }

    /// 将 merger.rows 投影到 `blocks`，尽量保留已有行的说话人。
    private func publishMergerRows() {
        let previous = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        blocks = merger.rows.map { row in
            let speaker = previous[row.id]?.speaker ?? liveSpeaker
            let total = Int(row.startSeconds.rounded())
            return TranscriptBlock(
                id: row.id,
                speaker: speaker,
                timestamp: String(format: "%d:%02d", total / 60, total % 60),
                raw: row.text,
                polished: row.text,
                isFinal: row.isFinal,
                startSeconds: row.startSeconds,
                endSeconds: row.endSeconds
            )
        }
    }

    private func adoptSegmentsAsBlocks(_ segments: [TranscriptSegment]) {
        merger.loadCheckpoint(segments: segments)
        let speakers = meeting.speakers.isEmpty ? [liveSpeaker] : meeting.speakers
        // 若已润色，按段 id 把润色文本并入 block.polished（≠ raw 时 UI 自动双行）
        let polishedById = Dictionary(
            uniqueKeysWithValues: meeting.polishedSegments.map { ($0.id, $0.text) }
        )
        blocks = segments.map { seg in
            var block = TranscriptBlock(segment: seg, speakers: speakers, isFinal: true)
            if let polished = polishedById[seg.id], !polished.isEmpty {
                block.polished = polished
            }
            return block
        }
    }

    // MARK: LIVE

    /// 收起续录：从已落盘时长 / 末段时间戳恢复计时，避免顶栏从 0:00 重来。
    private func restoreElapsedIfNeeded() {
        let fromDuration = Int(meeting.durationSeconds.rounded())
        let fromSegments = meeting.segments.map { Int($0.endSeconds.rounded()) }.max() ?? 0
        let fromBlocks = blocks.compactMap { block -> Int? in
            if let end = block.endSeconds { return Int(end.rounded()) }
            return nil
        }.max() ?? 0
        let restored = max(fromDuration, fromSegments, fromBlocks, elapsed)
        if restored > elapsed {
            elapsed = restored
        }
    }

    private func enterPausedState(status: String = "已暂停") {
        isLivePaused = true
        liveStartFailed = false
        statusMessage = status
        setIdleTimerDisabled(false)
    }

    /// 会中暂停：停麦停表，留在 LIVE，展示继续 / 完成 / 删除。
    public func pauseLive() {
        guard phase == .live || meeting.phase == .live else { return }
        persistLiveCheckpoint()
        checkpointSaver?()
        streamTask?.cancel()
        clockTask?.cancel()
        revealTask?.cancel()
        endingLive = false
        setIdleTimerDisabled(false)

        let recordingToFlush = recording
        recording = nil
        // 摘除回调：flush 结果由 pauseFlushTask 显式应用，避免迟到回调在 resume 抬高
        // timelineOffset 后以错误的绝对时间落回 merger（resume 会取消此 task 丢弃结果）。
        recordingToFlush?.onPartial = nil
        recordingToFlush?.onSegment = nil
        recordingToFlush?.onError = nil
        recordingToFlush?.onInterrupted = nil

        // #M2：捕获 stop() 的定稿分段并入 merger，避免 pause→complete 丢末段；
        //   finalizeTrailingDraft 兜底未进 flush 的末句草稿。
        pauseFlushTask?.cancel()
        pauseFlushTask = Task { [weak self] in
            guard let self else { return }
            if let r = recordingToFlush, r.isRunning {
                let result = try? await r.stop()
                if Task.isCancelled { return }
                if let result, !result.segments.isEmpty {
                    self.applyPauseFlush(result)
                }
            }
            if Task.isCancelled { return }
            self.merger.finalizeTrailingDraft()
            self.publishMergerRows()
            self.checkpointIfNeeded(force: true)
        }
        enterPausedState(status: "已暂停")
    }

    /// #M2：把暂停时 stop() 的定稿分段并入 merger（用当前未抬高的 timelineOffset）。
    private func applyPauseFlush(_ result: TranscribeResult) {
        for seg in result.segments { merger.applySegment(seg) }
        publishMergerRows()
    }

    /// 从暂停态恢复收音。
    public func resumeLive() {
        guard phase == .live || meeting.phase == .live else { return }
        // #M2：用户选择继续，丢弃暂停 flush（旧 stop 仍在后台释放引擎，结果不再需要）
        pauseFlushTask?.cancel()
        pauseFlushTask = nil
        isLivePaused = false
        liveStartFailed = false
        startLive()
    }

    private func startLive() {
        restoreElapsedIfNeeded()
        // 已有字幕再开麦：引擎时间轴从 0 起，必须抬高 absolute offset
        if !merger.rows.isEmpty {
            merger.prepareForResume()
        }
        isLivePaused = false
        startClock()
        statusMessage = "正在准备…"
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            // 先让首帧/转场画完，再跑引擎准备，避免进页卡死几秒
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self.startRecordingOrMock()
        }
    }

    /// 端侧 ASR 热词：底稿实体（人名/公司/术语）+ 已知说话人名。注入 SpeechAnalyzer。
    private var liveContextualHints: [String] {
        var hints = meeting.brief?.entityHints ?? []
        for s in meeting.speakers where !s.name.isEmpty && !hints.contains(s.name) {
            hints.append(s.name)
        }
        return Array(hints.prefix(50))
    }

    private func startRecordingOrMock() async {
        liveStartFailed = false
        let session = RecordingSession()
        session.onPartial = { [weak self] text in
            self?.applyPartial(text)
        }
        session.onSegment = { [weak self] seg in
            self?.applySegment(seg)
        }
        session.onError = { [weak self] msg in
            guard let self else { return }
            if msg.isEmpty {
                // 中断恢复：清空提示，但不盖住启动失败文案
                if !self.liveStartFailed { self.statusMessage = "" }
                return
            }
            self.statusMessage = msg
        }
        // #2：中断期间无 PCM 产出，暂停计时避免时长虚高；恢复时续上（仅当仍在 LIVE 且未手动暂停）。
        session.onInterrupted = { [weak self] began in
            guard let self else { return }
            if began {
                self.clockTask?.cancel()
            } else if self.phase == .live, !self.isLivePaused {
                self.startClock()
            }
        }
        recording = session

        do {
            // 开录即准备本地音频路径（可重转基石）；mock 不写盘
            let audioURL = try MeetingAudioStore.audioURL(meetingId: meeting.id)
            meeting.audioPath = MeetingAudioStore.relativeAudioPath(meetingId: meeting.id)
            checkpointSaver?()

            // 开录即后台记录会议地点（提示性、不阻录音；本场已有地点则跳过）
            LocationCaptureService.shared.captureIfAbsent(for: meeting) { [weak self] in
                self?.checkpointSaver?()
            }

            try await session.start(audioFileURL: audioURL, contextualHints: liveContextualHints)
            // 暂停后若用户未 resume，丢弃迟到的 start 成功回调
            guard !self.isLivePaused else {
                _ = try? await session.stop()
                self.recording = nil
                return
            }
            powerCancellable = session.$currentAudioPower
                .receive(on: DispatchQueue.main)
                .sink { [weak self] power in
                    self?.liveAudioPower = power
                }
            isUsingMockAudio = false
            liveStartFailed = false
            isLivePaused = false
            // 引擎名不进字幕行；仅在状态栏短暂可查
            statusMessage = ""
            setIdleTimerDisabled(true)
        } catch {
            recording = nil
            isUsingMockAudio = false
            liveStartFailed = true
            // #4：启动失败时停表，避免失败态时钟空走、时长虚高（重试时 startLive 会重启时钟）
            clockTask?.cancel()
            if !isLivePaused {
                statusMessage = "转写引擎启动失败：\(error.localizedDescription)"
            }
            setIdleTimerDisabled(false)
        }
    }

    /// REVIEW：会后 SpeakerKit 说话人分离，按时间重叠写回 `speakerId`。
    public func diarizeFromDisk(numberOfSpeakers: Int? = nil) async {
        guard !isDiarizing else { return }
        let thermal = ProcessInfo.processInfo.thermalState
        if ThermalGate.shouldDefer(thermalState: thermal) {
            statusMessage = ThermalGate.warningText(thermalState: thermal) ?? "设备温度高，说话人分离已延后"
            return
        }
        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path) else {
            statusMessage = "没有可分离的本地录音"
            return
        }
        // 以当前 UI 的 blocks 为准（完整）；过期的 meeting.segments 作 fallback。
        let fromBlocks = Self.segments(from: blocks)
        let fromMeeting = meeting.segments
        let source: [TranscriptSegment] = {
            if fromBlocks.isEmpty { return fromMeeting }
            if fromMeeting.isEmpty { return fromBlocks }
            let blockChars = fromBlocks.map(\.text).joined().count
            let meetingChars = fromMeeting.map(\.text).joined().count
            return blockChars >= meetingChars ? fromBlocks : fromMeeting
        }()
        guard !source.isEmpty else {
            statusMessage = "没有可标注的转写分段"
            return
        }

        isDiarizing = true
        statusMessage = "说话人分离中…"
        defer { isDiarizing = false }

        do {
            // 超时预算：按时长比例（pyannote RTF 未知，给 3×）。放门**外**，同重转写。
            let audioDuration = MeetingAudioStore.durationSeconds(storedPath: path) ?? 1800
            let budget = audioDuration * 3 + 300
            let preserve = meeting.speakers.filter { !$0.id.hasPrefix("asr-") }
            let outcome = try await withThrowingTimeout(seconds: budget) {
                try await DiarizationService.diarizeMeeting(
                    audioPath: path,
                    segments: source,
                    numberOfSpeakers: numberOfSpeakers,
                    preserveSpeakerNames: preserve,
                    progress: { [weak self] fraction in
                        Task { @MainActor in
                            guard let self, self.isDiarizing else { return }
                            let pct = Int((fraction * 100).rounded())
                            self.statusMessage = pct < 5
                                ? "准备说话人模型…"
                                : "说话人分离中… \(pct)%"
                        }
                    }
                )
            }
            let labeled = outcome.segments.filter { ($0.speakerId ?? "").hasPrefix("spk") }.count
            meeting.segments = outcome.segments
            meeting.speakers = outcome.speakers
            adoptSegmentsAsBlocks(outcome.segments)
            persistTranscriptCheckpoint()
            checkpointSaver?()
            if labeled == 0 {
                statusMessage = "检出 \(outcome.speakers.count) 位说话人，但未能标注原稿（可重试）"
            } else {
                statusMessage = "已标注 \(labeled)/\(outcome.segments.count) 段 · \(outcome.speakers.count) 位说话人"
            }
        } catch is CancellationError {
            statusMessage = "已取消"
        } catch InferenceTimeoutError.exceeded {
            statusMessage = "说话人分离超时，请稍后重试"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private static func segments(from blocks: [TranscriptBlock]) -> [TranscriptSegment] {
        blocks.map { block in
            let start = block.startSeconds ?? parseTimestamp(block.timestamp)
            return TranscriptSegment(
                startSeconds: start,
                endSeconds: block.endSeconds ?? start,
                speakerId: block.speaker.id,
                text: block.raw
            )
        }
    }

    /// REVIEW：触发本地音频重转写（后台 Task，可被 `cancelPostMeetingCompute` 取消）。
    /// - Parameter engineKind: 指定重转引擎（如 `.fluidSenseVoice` 端侧高保真）；nil 跟随用户 LIVE 偏好。
    public func retranscribeFromDisk(engineKind: AsrEngineKind? = nil) {
        postMeetingTask = Task { [weak self] in
            await self?.performRetranscribe(engineKind: engineKind)
        }
    }

    private func performRetranscribe(engineKind: AsrEngineKind?) async {
        let thermal = ProcessInfo.processInfo.thermalState
        if ThermalGate.shouldDefer(thermalState: thermal) {
            statusMessage = ThermalGate.warningText(thermalState: thermal) ?? "设备温度高，重转已延后"
            return
        }
        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path) else {
            statusMessage = "没有可重转的本地录音"
            return
        }
        statusMessage = engineKind?.isOnDevice == true ? "端侧重转中…" : "重转中…"

        // 失败/取消路径兜底释放引擎（成功路径手动 release 后清空此引用）
        var preparedEngine: (any AsrEngine)?
        defer {
            if let e = preparedEngine { Task { await e.release() } }
        }

        do {
            if Task.isCancelled {
                statusMessage = "已取消"
                return
            }
            let samples = try MeetingAudioStore.loadFloatSamples(storedPath: path)
            guard !samples.isEmpty else {
                statusMessage = "本地录音为空"
                return
            }
            if Task.isCancelled {
                statusMessage = "已取消"
                return
            }
            let engine: any AsrEngine
            if let engineKind {
                engine = try await AsrEngineResolver.resolve(kind: engineKind)
            } else {
                engine = try await AsrEngineResolver.resolve()
            }
            preparedEngine = engine
            let hints = liveContextualHints
            if !hints.isEmpty { await engine.setContextualHints(hints) }

            // 超时预算：RTF>2× 即判失败（plan 024「RTF<1 通过」标准）。放门**外**——超时后当前
            // chunk 推理可能仍跑完（CoreML 不响应取消），期间门保持占用、不与下次推理并发 → 不触发 #661。
            let audioDuration = Double(samples.count) / MeetingAudioStore.sampleRate
            let budget = audioDuration * 2 + 300
            let result = try await withThrowingTimeout(seconds: budget) {
                try await engine.transcribe(
                    samples: samples,
                    sampleRate: MeetingAudioStore.sampleRate,
                    onPartial: nil
                )
            }
            await engine.release()
            preparedEngine = nil
            let speakers = meeting.speakers.isEmpty ? [liveSpeaker] : meeting.speakers
            meeting.segments = result.segments
            // 重转产生新 raw，旧 polished 不再对应：清空，稍后联动重新润色
            meeting.polishedSegmentsData = nil
            meeting.polishedModelId = nil
            if meeting.speakers.isEmpty {
                meeting.speakers = speakers
            }
            adoptSegmentsAsBlocks(result.segments)
            checkpointSaver?()
            statusMessage = result.segments.isEmpty ? "重转完成（无字幕）" : "重转完成"
            schedulePolishIfNeeded()   // ①③ 联动：新 raw → 自动润色
        } catch is CancellationError {
            statusMessage = "已取消"
        } catch InferenceTimeoutError.exceeded {
            statusMessage = "端侧重转过慢/超时，建议改用云端或稍后重试"
        } catch {
            statusMessage = "重转失败：\(error.localizedDescription)"
        }
    }

    /// 用户显式选择演示字幕（DEBUG / 验收）；禁止在 ASR 失败路径自动调用。
    public func startExplicitDemoLive() {
        guard phase == .live else { return }
        streamTask?.cancel()
        recording = nil
        isUsingMockAudio = true
        liveStartFailed = false
        isLivePaused = false
        statusMessage = "演示字幕（非真实录音）"
        setIdleTimerDisabled(false)
        startClock()
        startMockStream()
    }

    /// LIVE 失败后重试真麦 + ASR。
    public func retryLiveRecording() {
        resumeLive()
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.elapsed += 1
                if self.elapsed % 15 == 0 {
                    self.checkpointIfNeeded(force: false)
                }
            }
        }
    }

    /// 火山等累积全量 / Fun-ASR 当前句草稿。
    private func applyPartial(_ text: String) {
        let beforeCount = merger.rows.count
        merger.applyPartial(text: text, elapsedSeconds: Double(elapsed))
        if merger.rows.count > beforeCount {
            withAnimation(.easeOut(duration: 0.18)) { publishMergerRows() }
        } else {
            publishMergerRows()
        }
    }

    /// SpeechAnalyzer / Fun-ASR 按时间戳分段更新（定稿）。
    private func applySegment(_ seg: TranscriptSegment) {
        merger.applySegment(seg)
        publishMergerRows()
        // 高频 segment 节流落盘；pause / endLive 仍 force
        checkpointIfNeeded(force: false)
    }

    private func startMockStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            for (i, blk) in DemoContent.script.enumerated() {
                if Task.isCancelled { return }
                self.merger.finalizeAll()
                let start = Double(self.elapsed)
                self.merger.applyPartial(text: blk.raw, elapsedSeconds: start)
                self.publishMergerRows()
                if [4, 5].contains(i) { self.todoCount += 1 }
                try? await Task.sleep(for: .seconds(1.8))
                guard !self.merger.rows.isEmpty else { return }
                self.merger.finalizeTrailingDraft()
                withAnimation(.recapLand) { self.publishMergerRows() }
            }
        }
    }

    private func finalizeAll() {
        merger.finalizeAll()
        publishMergerRows()
    }

    public func endLive(persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
                        persistSummary: @escaping (MeetingSummary, String) -> Void) {
        // 防重入：重复点击会 cancel 正在跑的收尾，表现为「点了没反应」
        guard phase == .live, !endingLive else { return }
        endingLive = true
        isLivePaused = false

        clockTask?.cancel()
        streamTask?.cancel()
        statusMessage = "正在收尾…"
        setIdleTimerDisabled(false)

        // 同步立刻切态，不等 stop()；否则按钮像失灵
        meeting.phase = .processing
        withAnimation(.recapSheet) { phase = .processing }

        let recordingToStop = recording
        recording = nil

        revealTask?.cancel()
        revealTask = Task { [weak self] in
            guard let self else { return }
            defer { self.endingLive = false }

            // #M2：暂停后立即完成时，等暂停 flush 落地再收尾，避免丢末段
            if let flush = self.pauseFlushTask {
                _ = await flush.value
                self.pauseFlushTask = nil
            }

            if let recordingToStop {
                do {
                    let result = try await recordingToStop.stop()
                    if !result.segments.isEmpty {
                        // 收尾结果不应比 LIVE 已展示内容更短（超时/丢段时保留更完整的一侧）
                        let stopChars = result.segments.map(\.text).joined().count
                        let liveChars = self.blocks.map(\.raw).joined().count
                        if self.blocks.isEmpty || stopChars >= liveChars {
                            // stop() 分段多为引擎相对秒；已有绝对时间轴时勿整表替换砸偏 offset
                            if self.merger.timelineOffset > 0, !self.merger.rows.isEmpty {
                                // 保留 LIVE 绝对轴；仅在字数明显更长时仍采用 stop（少见）
                                if stopChars > liveChars + 32 {
                                    self.adoptSegmentsAsBlocks(result.segments)
                                }
                            } else {
                                self.adoptSegmentsAsBlocks(result.segments)
                            }
                        }
                    }
                    if let err = recordingToStop.lastError, !err.isEmpty {
                        self.statusMessage = err
                    }
                } catch {
                    self.statusMessage = "转写收尾：\(error.localizedDescription)"
                }
            }
            self.finalizeAll()

            // endLive 已切到 processing，不能再用 live 守卫的 checkpoint
            self.persistTranscriptCheckpoint()
            self.checkpointSaver?()

            self.startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
        }
    }

    // MARK: PROCESS

    private func startProcessing(persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
                                 persistSummary: @escaping (MeetingSummary, String) -> Void) {
        // #7：空会议（无转写内容）不进 LLM 纪要管线，直接进 review，避免空跑 processing 态与无效调用
        guard !blocks.isEmpty || !meeting.segments.isEmpty else {
            RecapLog.session.info("startProcessing: 转写为空，跳过纪要管线，直接进 review")
            statusMessage = "本场无录音内容"
            finishReviewWithoutMock()
            return
        }
        if MinutesPipelineSmoke.canRunMinutesPipeline {
            RecapLog.session.info("startProcessing: 闸门通过，启动 LLM 纪要管线")
            startLLMProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
        } else {
            RecapLog.session.error("startProcessing: 闸门失败（无可用大模型密钥）→ 直接进 review，无纪要")
            statusMessage = "未配置可用的大模型密钥（设置 → 大模型）"
            finishReviewWithoutMock()
        }
    }

    private func startLLMProcessing(persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
                                    persistSummary: @escaping (MeetingSummary, String) -> Void) {
        statusMessage = "云端整理中…"
        // 注意：不要覆盖仍在跑的 endLive 收尾 task；用独立 task 承接管线
        let pipelineTask = Task { [weak self] in
            guard let self else { return }
            // #6b：争取后台时间让纪要管线跑完；管线结束（完成/失败/取消）即释放名额
            self.beginMinutesBackgroundTask()
            defer { self.endMinutesBackgroundTask() }
            var summaryText = ""
            var didCommitSummary = false
            do {
                let transcript = self.blocks.map { "\($0.speaker.name)：\($0.raw)" }
                    .joined(separator: "\n")
                let briefSummary = self.meeting.briefPromptSummary
                let momentsSummary = self.meeting.momentsPromptSummary
                let provider = try LLMProviderFactory.makeCurrent()
                RecapLog.session.info("LLM 纪要: provider=\(provider.id, privacy: .public) summary=\(provider.summaryModel, privacy: .public) todo=\(provider.defaultModel, privacy: .public) 转写\(transcript.count) 字")
                var warning: String?
                for try await event in MinutesPipeline(provider: provider).run(
                    transcript: transcript,
                    briefSummary: briefSummary,
                    momentsSummary: momentsSummary
                ) {
                    if Task.isCancelled { return }
                    switch event {
                    case .summaryDelta(let d):
                        summaryText = Self.mergeStreamText(existing: summaryText, incoming: d)
                        let draft = MinutesMarkdownParser.parse(summaryText).summary
                        self.summary = MeetingSummary(
                            tldr: draft.tldr,
                            topics: draft.topics,
                            decisions: draft.decisions,
                            openQuestions: []
                        )
                        if self.revealStep < 1, !draft.tldr.isEmpty { self.setStep(1) }
                        if self.revealStep < 2, !draft.topics.isEmpty { self.setStep(2) }
                        if self.revealStep < 3, !draft.decisions.isEmpty { self.setStep(3) }
                    case .summaryReady(let full):
                        summaryText = full
                        self.commitAISummary(raw: full, persistSummary: persistSummary)
                        didCommitSummary = true
                        self.statusMessage = warning ?? ""
                    case .todos(let items):
                        persistTodos(items)
                        self.todoCount = items.count
                        if !items.isEmpty { self.setStep(4) }
                    case .coverage(let note):
                        self.statusMessage = note
                    case .finished:
                        if !didCommitSummary {
                            if !summaryText.isEmpty {
                                self.commitAISummary(raw: summaryText, persistSummary: persistSummary)
                                self.statusMessage = warning ?? ""
                            } else {
                                self.statusMessage = warning ?? "未生成纪要"
                                self.finishReviewWithoutMock()
                            }
                        } else if self.phase != .review {
                            self.finishReviewWithoutMock()
                        }
                    case .failed(let msg):
                        warning = msg
                        self.statusMessage = msg
                        if summaryText.isEmpty, !didCommitSummary {
                            self.finishReviewWithoutMock()
                        }
                    }
                }
            } catch {
                RecapLog.session.error("纪要管线异常: \(error.localizedDescription, privacy: .public)")
                if !didCommitSummary, !summaryText.isEmpty {
                    self.commitAISummary(raw: summaryText, persistSummary: persistSummary)
                    self.statusMessage = "后续步骤失败：\(error.localizedDescription)"
                } else if !didCommitSummary {
                    self.statusMessage = error.localizedDescription
                    self.finishReviewWithoutMock()
                }
            }
        }
        revealTask = pipelineTask
    }

    /// 将模型 Markdown 拆成短标题 / tldr / 议题 / 决议 / 未决，并进入 review。
    private func commitAISummary(raw: String,
                                 persistSummary: @escaping (MeetingSummary, String) -> Void) {
        let parsed = MinutesMarkdownParser.parse(raw)
        summary = parsed.summary
        if let title = parsed.title {
            meeting.adoptGeneratedTitle(title)
        }
        persistSummary(parsed.summary, raw)
        if !parsed.summary.topics.isEmpty { setStep(2) }
        if !parsed.summary.decisions.isEmpty { setStep(3) }
        if todoCount > 0 || revealStep >= 4 { setStep(4) }
        setStep(5)
        if meeting.phase != .review { meeting.phase = .review }
        if phase != .review {
            withAnimation(.recapSheet) { phase = .review }
        }
        scheduleDiarizationIfNeeded()
        schedulePolishIfNeeded()
    }

    /// 有 Key 但管线失败且无任何纪要：进入 review，不注入演示数据。
    private func finishReviewWithoutMock() {
        if revealStep < 1 { setStep(1) }
        setStep(5)
        meeting.phase = .review
        withAnimation(.recapSheet) { phase = .review }
        scheduleDiarizationIfNeeded()
        schedulePolishIfNeeded()
    }

    /// 有本地录音且尚未标注过说话人时，会后自动跑 SpeakerKit（失败不阻断 REVIEW）。
    private func scheduleDiarizationIfNeeded() {
        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path) else { return }
        let alreadyLabeled = meeting.segments.contains { seg in
            guard let sid = seg.speakerId else { return false }
            return sid.hasPrefix("spk")
        }
        guard !alreadyLabeled else { return }
        postMeetingTask = Task { [weak self] in await self?.diarizeFromDisk() }
    }

    /// 进 REVIEW 时自动润色逐字稿（有 DeepSeek key 且未润色过）。失败不阻断 REVIEW。
    /// 与 diarization 并发：润色走 LLM、分离走 CoreML，互不抢占。
    private func schedulePolishIfNeeded() {
        guard !meeting.segments.isEmpty,
              meeting.polishedSegmentsData == nil,
              !(KeychainStore.get(LLMPresets.deepSeekKeychainAccount) ?? "").isEmpty
        else { return }
        polishTranscript()
    }

    /// 切后台 / 离开 REVIEW 时取消在跑的会后 CoreML 任务（iOS 27 #738：后台 ANE 可能被系统拒）。
    public func cancelPostMeetingCompute() {
        postMeetingTask?.cancel()
        postMeetingTask = nil
        polishTask?.cancel()
        polishTask = nil
    }

    /// #6a：回前台重排被后台取消的会后任务（幂等：已完成/在跑均跳过）。
    public func reschedulePostMeetingCompute() {
        guard phase == .review else { return }
        scheduleDiarizationIfNeeded()
        schedulePolishIfNeeded()
    }

    // MARK: - #6b Minutes pipeline background grace

    /// 争取后台时间让 LLM 纪要管线跑完（用户点完成即切后台的常见路径）。
    private func beginMinutesBackgroundTask() {
        guard minutesBgTaskID == .invalid else { return }
        minutesBgTaskID = UIApplication.shared.beginBackgroundTask(withName: "RecapMinutes") { [weak self] in
            // 系统即将挂起：释放名额；管线若未完成会被中断，下次进页/重排可补救
            Task { @MainActor in self?.endMinutesBackgroundTask() }
        }
    }

    private func endMinutesBackgroundTask() {
        guard minutesBgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(minutesBgTaskID)
        minutesBgTaskID = .invalid
    }

    /// REVIEW：触发逐字稿 LLM 润色（补标点 / 纠错别字 / 最小书面化），保段写回 polished。
    /// 不依赖端侧 ASR，任意设备 + 已配 LLM 密钥即可；raw 原文始终保留。
    public func polishTranscript() {
        polishTask = Task { [weak self] in await self?.performPolish() }
    }

    private func performPolish() async {
        let thermal = ProcessInfo.processInfo.thermalState
        if ThermalGate.shouldDefer(thermalState: thermal) {
            statusMessage = ThermalGate.warningText(thermalState: thermal) ?? "设备温度高，原稿优化已延后"
            return
        }
        let source = meeting.segments
        guard !source.isEmpty else {
            statusMessage = "没有可优化的原稿"
            return
        }
        statusMessage = "原稿优化中…"
        do {
            let provider = try await Task.detached(priority: .userInitiated) {
                try LLMProviderFactory.makeDefaultDeepSeek()
            }.value
            let polisher = TranscriptPolisher { system, user in
                provider.streamText(system: system, user: user,
                                     model: LLMPresets.deepSeekFlash, temperature: 0.1)
            }
            let polished = try await polisher.polish(source)
            meeting.polishedSegmentsData = try? JSONEncoder().encode(polished)
            meeting.polishedModelId = LLMPresets.deepSeekFlash
            adoptSegmentsAsBlocks(source)   // 重新构造 blocks，这次 polished 有值 → 双行
            checkpointSaver?()
            statusMessage = "原稿已优化"
        } catch is CancellationError {
            statusMessage = "已取消"
        } catch {
            statusMessage = "优化失败：\(error.localizedDescription)（请在设置配置 LLM 密钥）"
        }
    }

    /// 仅 DEBUG / 显式验收入口可调用；生产自动路径禁止注入演示纪要。
    public func startExplicitDemoReveal(persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
                                        persistSummary: @escaping (MeetingSummary, String) -> Void) {
        statusMessage = "演示纪要（非模型生成）"
        revealTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(0.35))
            self.summary = DemoContent.fallbackSummary
            self.meeting.adoptGeneratedTitle(DemoContent.fallbackTitle)
            self.setStep(1)
            try? await Task.sleep(for: .seconds(0.35))
            self.setStep(2) // topics
            try? await Task.sleep(for: .seconds(0.25))
            self.setStep(3) // decisions
            let demoTodos: [TodoListPayload.Item] = [
                .init(task: "出移动端评审方案", owner: "李华", owner_source: "explicit",
                      due: nil, priority: "high", confidence: 0.9,
                      evidence_quote: "那我周五之前把评审方案弄出来",
                      start_seconds: 50),
                .init(task: "确认客户报价", owner: "张明", owner_source: "inferred",
                      due: nil, priority: nil, confidence: 0.45,
                      evidence_quote: "客户的报价我再确认一下",
                      start_seconds: 62),
            ]
            if self.meeting.actionItems.isEmpty {
                persistTodos(demoTodos)
            }
            self.todoCount = max(self.todoCount, demoTodos.count)
            self.setStep(4)
            try? await Task.sleep(for: .seconds(0.25))
            persistSummary(self.summary, self.summary.tldr)
            self.setStep(5)
            self.meeting.phase = .review
            withAnimation(.recapSheet) { self.phase = .review }
            self.statusMessage = "演示纪要（非模型生成）"
        }
    }

    private func setStep(_ s: Int) {
        withAnimation(.easeOut(duration: 0.24)) { revealStep = s }
    }

    /// 将当前 blocks 写入 meeting.segments（LIVE 检查点）。
    public func persistLiveCheckpoint() {
        guard phase == .live || meeting.phase == .live else { return }
        persistTranscriptCheckpoint()
    }

    /// 无 phase 守卫：LIVE 中途、endLive 收尾、diarize 后均可落盘字幕。
    public func persistTranscriptCheckpoint() {
        guard !isUsingMockAudio || !blocks.isEmpty else { return }
        meeting.durationSeconds = Double(max(elapsed, Int(meeting.durationSeconds), 1))
        meeting.segments = Self.segments(from: blocks)
        // 说话人列表：已有 spk* 时保留；否则从 blocks 汇总
        if meeting.speakers.isEmpty || !meeting.speakers.contains(where: { $0.id.hasPrefix("spk") }) {
            let unique = blocks.map(\.speaker)
            var seen = Set<String>()
            meeting.speakers = unique.filter { seen.insert($0.id).inserted }
        }
        lastCheckpointAt = Date()
    }

    /// 离开纪要页：先落盘字幕，再停录；保留 phase=.live 与 blocks（等同暂停，可再进续录）。
    public func pauseOrTeardownForDisappear() {
        if phase == .live || meeting.phase == .live {
            persistLiveCheckpoint()
            checkpointSaver?()
            isLivePaused = true
            if statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || statusMessage == "正在准备…" {
                statusMessage = "已暂停"
            }
        }
        streamTask?.cancel()
        clockTask?.cancel()
        // 勿取消 revealTask：processing 中离场由 004/后续策略处理；此处仅停 LIVE 采集
        if phase == .live {
            revealTask?.cancel()
        }
        endingLive = false
        setIdleTimerDisabled(false)
        if let recording, recording.isRunning {
            Task { _ = try? await recording.stop() }
        }
        recording = nil
    }

    /// 真正丢弃会话（会丢未保存数据）；优先用 `pauseOrTeardownForDisappear`。
    public func reset() {
        pauseOrTeardownForDisappear()
        // 兼容旧调用：不主动清空 blocks，避免误伤
    }

    private func checkpointIfNeeded(force: Bool) {
        guard phase == .live, !blocks.isEmpty else { return }
        if !force {
            // segment 高频路径：最多约 5s 落一次；pause/end 走 force
            if let last = lastCheckpointAt, Date().timeIntervalSince(last) < 5 { return }
        }
        persistLiveCheckpoint()
        checkpointSaver?()
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private func elapsedText(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func parseTimestamp(_ text: String) -> Double {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return Double(parts[0] * 60 + parts[1])
    }

    /// 兼容 delta（增量）与 cumulative（每次回全文）两种流式形态，避免重复拼接。
    private static func mergeStreamText(existing: String, incoming: String) -> String {
        guard !incoming.isEmpty else { return existing }
        if existing.isEmpty { return incoming }
        if incoming == existing { return existing }
        if incoming.hasPrefix(existing) { return incoming }          // cumulative
        if existing.hasPrefix(incoming) { return existing }          // 乱序旧包
        if incoming.count > existing.count,
           existing.hasSuffix(String(incoming.prefix(min(24, incoming.count)))) {
            // 重叠拼接（少见）：用更长的一侧
            return incoming
        }
        return existing + incoming
    }

}
