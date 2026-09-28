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

/// 整理态过渡舞台的真信号：驱动 ProcessStageCanvas 的步骤/文案。
/// 替代早期基于时间的假循环（Int(t)%9）——这里反映 LLM 纪要管线的真实阶段，
/// 让「处理过程信息」只活在过渡界面，而非泄露到纪要。
public enum PipelineStage: Equatable {
    case idle        // 未进入整理
    case organizing  // 管线已启动，等待首段摘要（梳理原稿）
    case generating  // 摘要流式中（提炼议题/决议/待办）
    case done        // 管线结束
    /// 会后自动重转（endLive 专属）：方言→云端 Fun-ASR；端侧→SenseVoice。文案随来源区分。
    case retranscribing(RetranscribeCause)

    /// 主句：随阶段切换，由 .id() 触发 contentTransition 平滑变形。
    public var title: String {
        switch self {
        case .idle: return "准备中"
        case .organizing: return "正在梳理语音对话原稿…"
        case .generating: return "正在提炼核心议题与关键决议…"
        case .done: return "整理完毕"
        case .retranscribing(let cause): return cause.stageTitle
        }
    }

    /// 是否处于纪要管线可询问进度的阶段（organizing/generating/会后重转）。
    public var isProcessingStage: Bool {
        switch self {
        case .organizing, .generating, .retranscribing: return true
        default: return false
        }
    }
}

/// 会后自动重转的触发来源（舞台文案据此区分，避免端侧路径误显方言话术）。
public enum RetranscribeCause: Equatable {
    case dialect    // 端侧置信度低判定方言 → 云端 Fun-ASR 精转
    case onDevice   // 实验开关 → SenseVoice 本机高保真重转
    /// Pro 质量承诺：LIVE 落到端侧（云端回落/方言）或云端中途降级 → 会后云端补精转，
    /// 兑现「纪要质量不打折」。干净的云端 LIVE 直出（精转增益≈0，却把纪要延迟一整个
    /// 精转时长——延迟也是体验）。显式选端侧的 Pro 不触发（隐私选择，音频不上云）。
    case pro
    /// 免费档云端体验：首 3 场会后云端精转（每场截前 10min 音频，3×10min=30min 恰为
    /// 免费 ASR 月桶额度）——付费前先尝到云端质量。
    case freeTrial
    /// 语言精修：分类为英文但 LIVE 引擎无英文能力（中文模型/未装 en 模块）→
    /// 会后自动换英文模型重转。零用户操作：不新增设置，靠转写统计自动判定。
    case language

    var stageTitle: String {
        switch self {
        case .dialect:    return "检测到方言口音，云端精转中…"
        case .onDevice:   return "本机高保真精转中…"
        case .pro:        return "云端高保真精转中…"
        case .freeTrial:  return "云端高保真精转中…（免费体验）"
        case .language:   return "检测到英文会议，云端英文精转中…"
        }
    }
}

/// 会后自动云端重转的触发原因（决策纯函数的输出，供单测）。
public enum AutoCloudRetranscribeReason: String, Equatable {
    case dialect
    case pro
    case freeTrial
    case language
}

/// 会话状态机（LIVE → PROCESS → REVIEW）。
/// LIVE：优先 RecordingSession（真麦 + ASR）；失败进入可恢复错误态（禁止静默演示）。
@MainActor
public final class MeetingSession: ObservableObject {
    @Published public var phase: MeetingPhase
    @Published public var blocks: [TranscriptBlock] = []
    @Published public var elapsed: Int = 0
    @Published public var revealStep: Int = 0
    /// LLM 纪要管线真实阶段（过渡舞台信号）；进 REVIEW 后不再消费。
    @Published public var pipelineStage: PipelineStage = .idle
    /// 管线首个活跃阶段的起点（问 Recap 的「还要多久」有据可答）；管线内重入不重置取最早，
    /// 落地 .review 时清零——否则二次管线（如一小时后重生成）的进度文案会虚报累计耗时。
    public private(set) var pipelineStartedAt: Date?

    /// processing 阶段问 Recap 的进度上下文：真实阶段 + 已耗时 + 时长预期。
    /// 让「还要多久」这类被建议的问题有据可答（不注入则模型只能编安抚话）。
    /// 仅在整理阶段非 nil；stage 变化触发 body 重渲染时刷新，不做秒级 tick。
    public var pipelineProgressText: String? {
        guard phase == .processing,
              pipelineStage.isProcessingStage,
              let started = pipelineStartedAt
        else { return nil }
        let elapsed = Int(Date().timeIntervalSince(started))
        let expectation: String
        switch pipelineStage {
        case .organizing: expectation = "纪要通常需要 1–3 分钟"
        case .generating: expectation = "纪要正在生成，即将完成"
        case .retranscribing: expectation = "精转耗时取决于会议时长"
        default: expectation = ""
        }
        return "\(pipelineStage.title)已进行约 \(elapsed / 60) 分 \(elapsed % 60) 秒。\(expectation)。"
    }
    @Published public var todoCount: Int = 0
    @Published public var summary: MeetingSummary
    @Published public var statusMessage: String = ""
    /// 自动云端精转未兑现的一次性说明（守卫拒绝/无字幕/超时/失败/额度尽）：LIVE 预告与
    /// processing 舞台都承诺过「云端精转」，保留原稿时须让用户知道（「永不静默也不打扰」
    /// 的不静默半边）。随纪要完成的 statusMessage 组装展示，手动重转成功即清除。
    @Published public private(set) var autoRetranscribeFallbackNote: String?
    @Published public var isUsingMockAudio = false
    /// LIVE 收音频段（低/中/高 + 整体电平，0.0~1.0），驱动顶栏声波频谱分层。
    /// 独立总线而非本类 @Published：mic tap ~12Hz 的频段数据若挂在 MeetingSession 上，
    /// 会让整个详情页 body 在录音全程每秒重算 ~12 次；现在只有声波视图观察总线。
    public let liveAudioBandBus = AudioBandBus()
    /// LIVE 引擎启动失败；供 UI 显示重试 / DEBUG 演示入口。
    @Published public var liveStartFailed = false
    /// LIVE 已暂停（停麦、停表，仍为 phase=.live；可继续 / 完成 / 删除）。
    @Published public var isLivePaused = false
    /// 会后 SpeakerKit 说话人分离进行中。
    @Published public var isDiarizing = false
    /// 说话人分离进度（0..1）；nil = 未在分离。供转写 Tab inline 进度条。
    @Published public var diarizeProgress: Double?
    /// 原稿优化进行中（供转写 Tab inline 指示）。
    @Published public var isPolishing = false
    /// REVIEW 态手动重转进行中（防重入 + 菜单禁用信号）；与 isPolishing/isDiarizing 同范式。
    /// 不复用 pipelineStage=.retranscribing：那是过渡舞台·自动方言重转信号，进 REVIEW 后不再消费。
    @Published public var isRetranscribing = false
    /// LIVE 中端侧 ASR 疑似方言口音（前段 confidence 持续偏低）→ 顶部提示「会后自动云端精转」。
    /// 一旦本会话置位即常显到 endLive；pause/resume 不复位（方言不会中途消失）。
    @Published public var liveDialectSuspected = false

    public let meeting: Meeting

    /// 录音 Live Activity 控制器（plan 054）：灵动岛/锁屏常驻「正在记录」。
    /// 任何 ActivityKit 失败静默降级，绝不影响录音主流程。
    private let recordingActivity = RecordingActivityController()

    // MARK: LIVE 声纹抽检（plan 055，flag+同意门控在 spotter 内）

    private let liveVoiceprintSpotter = LiveVoiceprintSpotter()
    /// 在场命中（chips 行）；展示名过滤（占位名/「我」）在事件处理层做。
    @Published public private(set) var livePresence: [LiveVoiceprintSpotter.PresenceEntry] = []
    /// 有净语音但画廊未命中（诚实口径：不做人数推断，UI 只说「还有未识别的声音」）。
    @Published public private(set) var livePresenceHasUnknown = false
    /// 「听起来像 TA」轻提示（每 id 每场至多一次）。
    @Published public private(set) var liveVoicePrompt: LiveVoiceprintSpotter.VoicePrompt?
    private var promptedLiveVoiceIds: Set<String> = []

    private var recording: RecordingSession?
    private var powerCancellable: AnyCancellable?
    private var streamTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    /// 会后端侧重转写任务引用，供 scenePhase 切后台时取消。与 diarizeTask 各自独立--
    /// 重转末尾会联动调度分离（scheduleDiarizationIfNeeded），分离不再覆盖重转 Task 引用，
    /// 避免未来在重转末尾插入异步代码时旧 Task 被孤儿化（无法取消）。
    private var retranscribeTask: Task<Void, Never>?
    /// 会后说话人分离任务引用，供 scenePhase 切后台时取消。
    private var diarizeTask: Task<Void, Never>?
    /// 会后 LLM 润色任务（独立于 CoreML 的重转/分离，三者可并发）。
    private var polishTask: Task<Void, Never>?
    /// P0-②：会后 diarizer idle 卸载定时器——分离结束 N 秒后释放模型常驻内存（20-40MB wired），
    /// 避免低内存机型(A14 iPad)叠加 OCR 触发 mach_vm_allocate 失败。新分离请求会取消它。
    private var diarizerUnloadTask: Task<Void, Never>?
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
    /// 周期检查点代际：force 落盘或新快照在途时递增，异步编码回填据此丢弃过期结果。
    private var checkpointGeneration = 0
    /// 检查点 save 失败上次上报时间（限频用，见 ``reportCheckpointSaveFailure()``）。
    private var lastCheckpointFailureReportAt = Date.distantPast
    /// 由 View 注入：checkpoint 写完后 `modelContext.save()`。
    public var checkpointSaver: (() -> Void)?

    /// 真麦是否在跑（用于底栏错误态）。
    public var isRecordingLive: Bool { recording?.isRunning == true }
    /// 当前 LIVE 解析出的转写引擎；仅 LIVE 中有意义，未开麦为 nil（方言判定用）。
    public var liveEngineKind: AsrEngineKind? { recording?.engineKind }

    /// 降级可见性（产品原则：永不静默也不打扰）：LIVE 落在端侧且会后**确定**会云端精转时为
    /// true——驱动结束确认弹窗的动态文案（「当前为本机转写；整理时将自动升级…」）。
    /// 录音中不再出顶部提示条（2026-09-02：技术细节不进会议现场，承诺在结束时刻才相关）。
    /// Pro 显式选端侧（非回落）不显示——音频不会上云，不能做此预告（与
    /// autoCloudRetranscribeReason 的隐私边界同口径）。
    public var showsCloudUpgradeHint: Bool {
        guard liveEngineKind == .speechAnalyzer, !liveDialectSuspected else { return false }
        if AIServiceMode.current == .recapCloud, RecapAccountStore.current.tier == .pro {
            return recording?.engineResolvedFromFallback ?? false
        }
        if AIServiceMode.current == .freeTrial {
            // 熔断暂停期不做「会后自动升级」预告——预告即承诺，不能对确定不会发生的事预告。
            return Self.cloudTrialMeetingsUsed < Self.cloudTrialMaxMeetings
                && !Self.isFreeTrialAutoPaused()
        }
        return false
    }

    /// 是否已开过麦并录到实质内容（有时长/字幕）；用于区分启动台与暂停决策台，
    /// 也用于离场/冷启动的空壳清理判定。≥3s 或任意字幕才算「录过」——
    /// 开麦 1-2 秒即走的空壳（duration=1、无字幕）不应留下草稿会议。
    public var hasStartedRecording: Bool {
        meeting.durationSeconds >= 3
            || !meeting.segments.isEmpty
            || !blocks.isEmpty
            || elapsed >= 3
    }

    /// REVIEW 态任一会后计算在飞（重转 / 分离 / 润色）。供菜单禁用镜像守卫条件。
    public var isPostMeetingComputeBusy: Bool { isRetranscribing || isDiarizing || isPolishing }

    public init(meeting: Meeting) {
        self.meeting = meeting
        self.phase = meeting.phase
        if let existing = meeting.latestSummary {
            self.summary = existing
        } else {
            self.summary = MeetingSummary(tldr: "", decisions: [], openQuestions: [])
        }
        Self.registerForDeletionLink(self, meetingID: meeting.id)
    }

    // MARK: - 删除联动（C1：删会后写已销毁模型的系统性缺口）

    /// 该会议是否仍可安全写入。删除会议后（`context.delete` 即刻置 isDeleted，save 后
    /// modelContext 置空），在飞的后台任务（分离/润色/重转/checkpoint 回填）对已销毁
    /// 模型写属性会触发 SwiftData BackingData 失效崩溃——所有「长 await 之后写回」的
    /// 点都要先过此守卫（与 HandwritingRecognitionService / MomentOCRService 同范式）。
    /// 守卫与写回之间不得有 await（MainActor 同步段不可被删除穿插）。
    private var meetingIsWritable: Bool {
        !meeting.isDeleted && meeting.modelContext != nil
    }

    /// 活跃 session 弱引用盒（按 meetingID 索引）。weak：视图释放即失效，
    /// 查表时顺带清扫空盒，不延长 session 生命周期。
    private final class WeakSessionRef {
        weak var session: MeetingSession?
        init(session: MeetingSession) { self.session = session }
    }

    private static var liveSessionsByMeeting: [UUID: [WeakSessionRef]] = [:]

    private static func registerForDeletionLink(_ session: MeetingSession, meetingID: UUID) {
        var boxes = (liveSessionsByMeeting[meetingID] ?? []).filter { $0.session != nil }
        boxes.append(WeakSessionRef(session: session))
        liveSessionsByMeeting[meetingID] = boxes
    }

    /// 删除会议前调用：取消该会议 session 在飞的会后计算（分离/润色/重转，含 processing 主链）。
    /// CoreML 推理不响应取消，任务在当前推理块结束后退出——真正的崩溃防线是各
    /// perform* 写回前的 `meetingIsWritable` 守卫；取消只是省 CPU/云端配额。
    static func cancelPostMeetingCompute(for meetingID: UUID) {
        let boxes = (liveSessionsByMeeting[meetingID] ?? []).filter { $0.session != nil }
        liveSessionsByMeeting[meetingID] = boxes
        for box in boxes {
            box.session?.cancelAllPostMeetingCompute()
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
        // 释放旧管线后台任务名额（旧 task 的 defer 会再 end 一次，幂等 no-op）；否则新管线
        // beginMinutesBackgroundTask 见旧 ID 仍有效而跳过，导致新管线无后台保护。
        self.endMinutesBackgroundTask()
        clearDraftTodos()
        summary = MeetingSummary(tldr: "", decisions: [], openQuestions: [])
        todoCount = 0
        revealStep = 0
        statusMessage = meeting.briefPromptSummary == nil ? "按转写重生成…" : "按底稿重生成…"
        meeting.phase = .processing
        withAnimation(.recapSheet) { phase = .processing }
        startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
    }

    /// REVIEW：重新生成纪要的全流程入口（确认弹窗勾选「同时重新转写」时调用）。
    /// 串行编排：云端重转 → 等润色完成 → 重跑纪要管线。重转/润色失败则回 REVIEW，不双扣 LLM 额度。
    /// diarize 不阻塞纪要（纪要只用 speaker.name）；管线提交后由 commitAISummary 自动 schedule。
    public func regenerateWithRetranscribe(
        clearDraftTodos: @escaping () -> Void,
        persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
        persistSummary: @escaping (MeetingSummary, String) -> Void
    ) {
        loadBlocksIfNeeded()
        guard !blocks.isEmpty,
              !isRetranscribing, !isDiarizing, !isPolishing else {
            statusMessage = "有会后任务进行中，请稍后再试"
            return
        }
        // 复用 regenerateWithBrief 的前置清理（释放旧管线名额 / 清 draft / 进 processing）。
        revealTask?.cancel()
        self.endMinutesBackgroundTask()
        clearDraftTodos()
        summary = MeetingSummary(tldr: "", decisions: [], openQuestions: [])
        todoCount = 0
        revealStep = 0
        statusMessage = "重转中…"
        meeting.phase = .processing
        withAnimation(.recapSheet) { phase = .processing }
        // 同步置位（performRetranscribe 的契约：flag 由调用方置，此处只兜底清零；
        // 漏置会让 isPostMeetingComputeBusy 守卫在整段重转期间失真——processImportedAudio 是对的样板）
        isRetranscribing = true

        // 登记 MinutesTaskRegistry：processing 态离场重进（重建 session）时
        // resumeOrRecoverProcessing 据此「等旧编排退出」而非再起一条——双跑会双扣
        // ASR/LLM 配额 + 两 session 交错写 meeting.segments（checkpoint 代际 per-session 失守）。
        // 步骤 ③ startProcessing 会以新 token 登记管线任务覆盖本条目；本任务 defer 的
        // unregister 因 token 不匹配自动失效，互不干扰。
        let retranscribeToken = UUID()
        let meetingID = meeting.id
        let orchestration = Task { [weak self] in
            defer { MinutesTaskRegistry.shared.unregister(token: retranscribeToken, for: meetingID) }
            guard let self else { return }
            // ① 云端重转（不联动下游，编排方接管）
            let ok = await self.performRetranscribe(intent: .cloudFirst, chainPostProcess: false)
            if Task.isCancelled { return }
            guard ok, !self.blocks.isEmpty else {
                self.statusMessage = "重转失败，已取消重生成（可稍后重试）"
                self.finishReviewWithoutMock()
                return
            }
            // ② 等润色完成：重转已清空 polishedSegmentsData，幂等补润色，确保管线吃到干净文本。
            //    手动置位防重入；performPolish 的 defer 兜底清零；直接 await = 确定性等待。
            if self.meeting.polishedSegmentsData == nil {
                self.isPolishing = true
                await self.performPolish()
            }
            if Task.isCancelled { return }
            // ③ 重跑纪要管线（内部含 LLM 闸门；blocks 此时已带 polished）
            self.startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
        }
        retranscribeTask = orchestration
        MinutesTaskRegistry.shared.register(orchestration, token: retranscribeToken, for: meeting.id)
    }

    /// 导入音频的首转编排（结构照抄 `regenerateWithRetranscribe`，差异仅一处：允许 blocks 为空——
    /// 导入会议在首次转写前没有任何字幕）。
    /// 串行：云端重转（此处即首转）→ 幂等补润色 → 纪要管线；重转/润色失败则回 REVIEW，
    /// 不双扣 LLM 额度。diarize 不阻塞纪要；管线提交后由 commitAISummary 自动 schedule。
    public func processImportedAudio(
        clearDraftTodos: @escaping () -> Void,
        persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
        persistSummary: @escaping (MeetingSummary, String) -> Void
    ) {
        guard meeting.audioSource == .imported,
              meeting.audioPath != nil,
              blocks.isEmpty,
              !isRetranscribing, !isDiarizing, !isPolishing else { return }
        revealTask?.cancel()
        self.endMinutesBackgroundTask()
        clearDraftTodos()
        summary = MeetingSummary(tldr: "", decisions: [], openQuestions: [])
        todoCount = 0
        revealStep = 0
        statusMessage = "转写导入的音频…"
        meeting.phase = .processing
        withAnimation(.recapSheet) { phase = .processing }

        // 同步置位防重入（045 B8 的教训）：堵住「Task 尚未起跑、flag 仍 false」的竞态窗口。
        isRetranscribing = true
        // 登记 registry（同 regenerateWithRetranscribe）：重进时旧首转在飞 → 等待而非双跑
        // （导入首转双跑 = 双倍烧 ASR 桶 + 新 session blocks 为空再起一条云端转写）。
        let retranscribeToken = UUID()
        let meetingID = meeting.id
        let orchestration = Task { [weak self] in
            defer { MinutesTaskRegistry.shared.unregister(token: retranscribeToken, for: meetingID) }
            guard let self else { return }
            // 首转前语言未知（默认 zh）——记录初始值，供下方「语言自愈」判定。
            let wasEnglish = self.meeting.language == .en
            // ① 首转 = 云端重转（不联动下游，编排方接管）
            let ok = await self.performRetranscribe(intent: .cloudFirst, chainPostProcess: false)
            if Task.isCancelled { return }
            guard ok, !self.blocks.isEmpty else {
                self.statusMessage = "转写失败，可稍后在会议页手动重试"
                self.finishReviewWithoutMock()
                return
            }
            // ①.5 语言自愈：导入的英文音频首转走了中文模型（首转时语言未知）→ 乱码；
            // 转写完成已重算语言，若判定为英文且此前未知，立即用英文模型再精转一次。
            // 零用户操作：导入即自动正确，与 LIVE 场次的会后语言精修同语义。
            if !wasEnglish, self.meeting.language == .en, !Task.isCancelled {
                RecapLog.session.info("processImportedAudio: 检测到英文导入音频，英文模型精转…")
                let repaired = await self.performRetranscribe(intent: .cloudFirst, chainPostProcess: false)
                guard repaired, !self.blocks.isEmpty else {
                    self.statusMessage = "转写失败，可稍后在会议页手动重试"
                    self.finishReviewWithoutMock()
                    return
                }
            }
            // ② 幂等补润色：确保纪要管线吃到干净文本（同 regenerateWithRetranscribe ②）
            if self.meeting.polishedSegmentsData == nil {
                self.isPolishing = true
                await self.performPolish()
            }
            if Task.isCancelled { return }
            // ③ 纪要管线（内部含 LLM 闸门；blocks 此时已带 polished）
            self.startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
        }
        retranscribeTask = orchestration
        MinutesTaskRegistry.shared.register(orchestration, token: retranscribeToken, for: meeting.id)
    }

    /// 重新打开卡在 processing 的会议：有纪要则收尾进 review，否则继续跑管线。
    /// - Parameter clearDraftTodos: 重跑管线前清空本场 draft 待办——管线可能在
    ///   `persistTodos` 落库后、`commitAISummary` 前被杀/失败，DB 留有 draft 待办但无纪要；
    ///   不清理则重跑会插入第二批相同待办（重复）。
    public func resumeOrRecoverProcessing(
        clearDraftTodos: @escaping () -> Void,
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
                pipelineStartedAt = nil
                meeting.phase = .review
                withAnimation(.recapSheet) { phase = .review }
                return
            }
        }

        // 已有进行中的揭示任务则不重复启动
        if let revealTask, !revealTask.isCancelled { return }

        // 另一 session 的管线仍在跑（用户结束 → 回首页 → 快速重进：旧视图过渡期仍存活）：
        // 等旧管线退出后按结果收尾（有纪要进 review，无则补跑），绝不再起一条——
        // 双管线会双扣 LLM 额度 + 重复待办 + 互覆 meeting.segments。
        if let running = MinutesTaskRegistry.shared.runningTask(for: meeting.id) {
            statusMessage = "上一轮整理仍在进行…"
            revealTask = Task { [weak self] in
                await running.value
                guard let self, !Task.isCancelled else { return }
                self.finishAfterRegistryPipeline(
                    clearDraftTodos: clearDraftTodos,
                    persistTodos: persistTodos,
                    persistSummary: persistSummary
                )
            }
            return
        }

        if blocks.isEmpty {
            // 导入会议的首转：音频在盘但尚无字幕——走导入编排而非「无转写内容」退出。
            if meeting.audioSource == .imported, meeting.audioPath != nil {
                clearDraftTodos()
                processImportedAudio(
                    clearDraftTodos: clearDraftTodos,
                    persistTodos: persistTodos,
                    persistSummary: persistSummary
                )
                return
            }
            statusMessage = "无转写内容"
            finishReviewWithoutMock()
            return
        }

        // 重跑前清残留 draft 待办（崩溃/失败可能已落库但无纪要），保证幂等
        clearDraftTodos()
        startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
    }

    /// 等旧 session 的管线（registry 登记）退出后：有纪要直接收尾进 review；无产出则补跑一次。
    private func finishAfterRegistryPipeline(
        clearDraftTodos: @escaping () -> Void,
        persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
        persistSummary: @escaping (MeetingSummary, String) -> Void
    ) {
        // 等待的旧管线被删除取消后，await 返回会继续走到这里——已删会议不再写 phase/落盘。
        guard meetingIsWritable else { return }
        if let existing = meeting.latestSummary {
            let clean = MinutesMarkdownParser.sanitizedSummary(existing)
            if !clean.tldr.isEmpty || !clean.decisions.isEmpty || !clean.topics.isEmpty {
                summary = clean
                revealStep = 5
                statusMessage = ""
                todoCount = meeting.actionItems.count
                pipelineStartedAt = nil
                meeting.phase = .review
                withAnimation(.recapSheet) { phase = .review }
                checkpointSaver?()
                return
            }
        }
        // 旧管线未产出（失败/取消）：清残留 draft 后补跑一次
        clearDraftTodos()
        startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
    }

    private func loadBlocksIfNeeded() {
        guard blocks.isEmpty else { return }
        guard !meeting.segments.isEmpty else { return }
        merger.loadCheckpoint(segments: meeting.segments)
        blocks = blocks(from: meeting.segments)
    }

    /// 从 segments 构造 blocks（isFinal 全定稿），按段 id 合并 polished 文本。
    /// 与 `adoptSegmentsAsBlocks` 共用：保证「热路径（同 session）与冷路径（重进/重启）」
    /// 都吃到润色稿——旧实现 loadBlocksIfNeeded 不带 polished，重进 REVIEW 后转写 Tab 与
    /// 纪要管线会静默回退到 raw。
    private func blocks(from segments: [TranscriptSegment]) -> [TranscriptBlock] {
        let speakers = meeting.speakers.isEmpty ? [liveSpeaker] : meeting.speakers
        // 若已润色，按段 id 把润色文本并入 block.polished（≠ raw 时转写行切到优化稿单行）
        let polishedById = Dictionary(
            uniqueKeysWithValues: meeting.polishedSegments.map { ($0.id, $0.text) }
        )
        return segments.map { seg in
            var block = TranscriptBlock(segment: seg, speakers: speakers, isFinal: true)
            if let polished = polishedById[seg.id], !polished.isEmpty {
                block.polished = polished
            }
            return block
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
                endSeconds: row.endSeconds,
                confidence: row.confidence
            )
        }
    }

    private func adoptSegmentsAsBlocks(_ segments: [TranscriptSegment]) {
        merger.loadCheckpoint(segments: segments)
        blocks = blocks(from: segments)
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
        // Live Activity 同步暂停态（plan 054）：手动暂停与暂停后重进共用此出口
        recordingActivity.pause()
    }

    // MARK: LIVE 声纹抽检事件（plan 055）

    private func handleLiveVoiceprintEvent(_ event: LiveVoiceprintSpotter.Event) {
        switch event {
        case .matched(let id, let name):
            guard !livePresence.contains(where: { $0.voiceprintId == id }) else { return }
            let displayable = LiveVoiceprintSpotter.isDisplayableName(name)
            if displayable {
                livePresence.append(.init(voiceprintId: id, name: name))
            }
            // 轻提示仅展示名（占位名/「我」没有可确认的信息量，静默忽略）
            if displayable, !promptedLiveVoiceIds.contains(id) {
                promptedLiveVoiceIds.insert(id)
                liveVoicePrompt = .init(voiceprintId: id, name: name)
            }
            pushLiveActivitySpeakerSummary()
        case .unknownVoice:
            livePresenceHasUnknown = true
            pushLiveActivitySpeakerSummary()
        }
    }

    /// 「听起来像 TA」的「是/不是」。否 = 负样本（本场不再匹配该 id + 日志供阈值校准）。
    public func resolveLiveVoicePrompt(voiceprintId: String, accepted: Bool) {
        guard liveVoicePrompt?.voiceprintId == voiceprintId else { return }
        liveVoicePrompt = nil
        if accepted {
            RecapLog.session.info("LIVE 声纹在场确认「是」: \(voiceprintId, privacy: .public)")
        } else {
            RecapLog.session.info("LIVE 声纹在场否决「不是」（负样本，供阈值校准）: \(voiceprintId, privacy: .public)")
            livePresence.removeAll { $0.voiceprintId == voiceprintId }
            Task { [liveVoiceprintSpotter] in await liveVoiceprintSpotter.deny(voiceprintId: voiceprintId) }
        }
        pushLiveActivitySpeakerSummary()
    }

    /// 054 软集成：在场变化同步到灵动岛（LA 未起/不可用时控制器内部 no-op）。
    private func pushLiveActivitySpeakerSummary() {
        var parts = livePresence.map(\.name)
        if livePresenceHasUnknown { parts.append("还有未识别的声音") }
        recordingActivity.setSpeakerSummary(parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    /// 会中暂停：停麦停表，留在 LIVE，展示继续 / 完成 / 删除。
    public func pauseLive() {
        guard phase == .live || meeting.phase == .live else { return }
        persistLiveCheckpoint()
        checkpointSaver?()
        streamTask?.cancel()
        clockTask?.cancel()
        revealTask?.cancel()
        // 停止旧 session 音量订阅：recording 即将置 nil，但 stop() 前其 tap 仍产出音量帧，
        // 不取消会导致暂停态 UI 音量条持续跳动。
        powerCancellable?.cancel()
        powerCancellable = nil
        endingLive = false
        setIdleTimerDisabled(false)
        liveEpoch += 1

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

    /// App 切后台：立即落一次字幕检查点（防极端情况进程被回收丢字幕），但**不停麦**——
    /// Info.plist 已声明 UIBackgroundModes=audio，AVAudioSession(.playAndRecord) 活跃期间
    /// 进程不会被挂起，锁屏/切 App 持续录音（对齐权限文案承诺的「锁屏后台持续录制」）。
    /// 来电等中断由 AudioRecorder 的 interruption/routeChange/engineConfig 三路自愈负责，
    /// 不经此路径；手动暂停后切后台维持暂停态（用户已显式停麦，不越权重启）。
    public func checkpointForBackgroundIfLive() {
        guard phase == .live || meeting.phase == .live else { return }
        persistLiveCheckpoint()
        checkpointSaver?()
    }

    private func startLive() {
        // 开麦让路：取消挂起的 FluidDiarizer ANE 预编译（与端侧 ASR 推理争 ANE；
        // 编译已开跑则不可中断，只能让其自然跑完）。
        FluidDiarizer.cancelPrefetch()
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

    /// ASR 热词（plan 050 扩容）：底稿实体（人名/公司/术语）→ 本场说话人名 →
    /// 声纹画廊跨会议名（047 纠错后持久）→ 用户全局常用词。
    /// 端侧 SA contextualStrings 直接收；云端 fun-asr-realtime 经 input.context（≤400 字符）。
    private var liveContextualHints: [String] {
        var hints = meeting.brief?.entityHints ?? []
        for s in meeting.speakers where !s.name.isEmpty && !hints.contains(s.name) {
            hints.append(s.name)
        }
        if VoiceprintConsent.granted {
            for s in VoiceprintGallery.shared.snapshot() {
                // 过滤引擎数字 id 兜底名与「我」：无转写价值的占位
                let n = s.name.trimmingCharacters(in: .whitespaces)
                guard n.count >= 2, n != "我", !n.allSatisfy(\.isNumber),
                      !hints.contains(n) else { continue }
                hints.append(n)
            }
        }
        for w in UserVocabulary.words where !hints.contains(w) {
            hints.append(w)
        }
        return Array(hints.prefix(100))
    }

    private func startRecordingOrMock() async {
        liveStartFailed = false
        // 等离场后台停录落地再开新麦：同一 PCM 文件绝不允许双写（旧句柄残余写与新句柄交错
        // 会损坏母带，致会后重转/分离/回放读到坏数据）。
        if let t = teardownStopTask {
            teardownStopTask = nil
            await t.value
        }
        // 暂停 flush 同理：resume 已 cancel 其 UI 应用，但底层 stop() 不响应协作取消、
        // 必然跑完才关文件句柄——await 它落地，防止旧 recorder 句柄与新 recorder 双写。
        if let f = pauseFlushTask {
            pauseFlushTask = nil
            await f.value
        }
        let epoch = liveEpoch
        let session = RecordingSession()
        // plan 055：LIVE 声纹抽检旁路（spotter 内部三道闸，未启用时 ingest 零开销）
        session.voiceprintSpotter = liveVoiceprintSpotter
        await liveVoiceprintSpotter.setOnEvent { [weak self] event in
            Task { @MainActor in self?.handleLiveVoiceprintEvent(event) }
        }
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

            try await session.start(audioFileURL: audioURL, contextualHints: liveContextualHints,
                                    language: meeting.language.engineLanguage)
            // 录音母带已落盘：排除 iCloud 备份（230MB/小时级，见 BackupExclusion）。
            BackupExclusion.excludeMeetingAudio(meetingId: meeting.id)
            // 启动期间被暂停/结束/离场/新启动重入：epoch 已变或 session 已非当前会话，
            // 丢弃迟到的 start 成功回调——旧实现仅查 isLivePaused，pause 发生在 guard 之后
            // 会错误复位暂停态并续接旧引擎；重入场景（准备期锁屏→回前台自动 startLive）
            // 旧任务迟到返回时 recording 已指向新会话，无条件置 nil 会砸掉新会话的
            // 最后强引用（引擎随 dealloc 静默死亡，UI 正常但麦克风停采）。
            guard epoch == liveEpoch, !self.isLivePaused, self.recording === session else {
                _ = try? await session.stop()
                if self.recording === session { self.recording = nil }
                return
            }
            powerCancellable = session.$currentAudioBands
                .receive(on: DispatchQueue.main)
                .sink { [weak self] bands in
                    MainActor.assumeIsolated {
                        self?.liveAudioBandBus.bands = bands
                    }
                }
            isUsingMockAudio = false
            liveStartFailed = false
            isLivePaused = false
            // 引擎名不进字幕行；仅在状态栏短暂可查
            statusMessage = ""
            setIdleTimerDisabled(true)
            // Live Activity：录音真正起跑后才常驻（plan 054）；resume 复用同一 activity 只翻暂停态。
            // elapsed 含续录前累计（restoreElapsedIfNeeded 抬过表）。
            recordingActivity.startRecording(elapsed: TimeInterval(elapsed))
            // LIVE 声纹抽检随录音起跑（plan 055）；未启用/无画廊时惰性关闭。
            await liveVoiceprintSpotter.beginSession()
        } catch {
            // 竞态防护（P1）：迟到失败不得动新会话的 recording/UI——无条件置 nil 同样砸引用。
            guard self.recording === session else {
                RecapLog.session.error("startLive 迟到失败（已被新启动接管，不影响当前会话）: \(error.localizedDescription, privacy: .public)")
                return
            }
            recording = nil
            isUsingMockAudio = false
            liveStartFailed = true
            // #4：启动失败时停表，避免失败态时钟空走、时长虚高（重试时 startLive 会重启时钟）
            clockTask?.cancel()
            RecapLog.session.error("startLive 引擎启动失败: \(error.localizedDescription, privacy: .public)")
            if !isLivePaused {
                // 消费 resolver 的四态细分原因（端侧不可用 / 缺云端凭证 / 缺中文资源），
                // 给可操作引导而非笼统「检查权限」——大部分首录失败并非权限问题。
                if let resolveErr = error as? AsrResolveError,
                   let detail = resolveErr.errorDescription, !detail.isEmpty {
                    statusMessage = detail
                } else if case SpeechAnalyzerEngineError.unavailable = error {
                    // 机型/系统不支持端侧转写（如国行无 Apple Intelligence）：不是麦克风权限问题，
                    // 给准确可操作的引导，而非误导用户去翻权限设置。
                    statusMessage = "此设备不支持端侧转写（需 Apple Intelligence 机型），请在设置中改用云端引擎或稍后重试。"
                } else if let saeErr = error as? SpeechAnalyzerEngineError,
                          let detail = saeErr.errorDescription, !detail.isEmpty {
                    statusMessage = detail
                } else if let funErr = error as? FunASRError,
                          let detail = funErr.errorDescription, !detail.isEmpty {
                    // wss 层失败（task-failed 含 403/quota、task-start 超时等）文案已是
                    // 中文可读——凭证签发层的透传已修，这里是引擎层的最后一环，
                    // 兜底文案会把付费/配额问题误导成「检查麦克风权限」。
                    statusMessage = detail
                } else {
                    statusMessage = "录音启动失败，请检查麦克风权限或稍后重试"
                }
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
            // 空源不写 statusMessage：该分支会被导入首转失败 / 空转写 / regenerate 失败等
            // 场景连带调度到——「没有可标注的转写分段」会覆盖「转写失败，可稍后重试」
            // 等更重要的提示。静默返回，日志留痕。
            RecapLog.session.info("diarizeFromDisk: 无转写分段，跳过自动分离（不覆盖既有提示）")
            return
        }

        isDiarizing = true
        diarizeProgress = 0
        defer {
            isDiarizing = false
            diarizeProgress = nil
            // P0-②：分离结束（含取消/失败）后启动 idle 卸载计时；N 秒内再次 schedule 则被取消。
            scheduleDiarizerIdleUnload()
        }

        do {
            // 超时预算：按时长比例（pyannote RTF 未知，给 3×）。放门**外**，同重转写。
            let audioDuration = MeetingAudioStore.durationSeconds(storedPath: path) ?? 1800
            let budget = audioDuration * 3 + 300
            let preserve = meeting.speakers.filter { !$0.id.hasPrefix("asr-") }
            // 自动分离静默进行：进度/成功不写 statusMessage（不打扰纪要阅读），
            // 结果由 spk* 标签淡入 + 自动切到转写 Tab 呈现；仅失败/可重试才出面。
            let outcome = try await withThrowingTimeout(seconds: budget) {
                try await DiarizationService.diarizeMeeting(
                    audioPath: path,
                    segments: source,
                    numberOfSpeakers: numberOfSpeakers,
                    preserveSpeakerNames: preserve,
                    progress: { [weak self] fraction in
                        Task { @MainActor in self?.diarizeProgress = fraction }
                    }
                )
            }
            let labeled = outcome.segments.filter { ($0.speakerId ?? "").hasPrefix("spk") }.count
            // 删除竞态：分离是分钟级推理，期间会议可能已从首页删除（cascade 不含本任务句柄）
            guard meetingIsWritable else { return }
            meeting.segments = outcome.segments
            meeting.speakers = outcome.speakers
            adoptSegmentsAsBlocks(outcome.segments)
            persistTranscriptCheckpoint()
            checkpointSaver?()
            if labeled == 0 {
                statusMessage = "检出 \(outcome.speakers.count) 位说话人，但未能标注原稿（可重试）"
            }
        } catch is CancellationError {
            // 自动分离被取消（切后台/离开 REVIEW）：静默，不打扰纪要
        } catch InferenceTimeoutError.exceeded {
            statusMessage = "说话人分离超时，请稍后重试"
        } catch {
            // 说话人分离是可选增强：模型加载/网络等失败不阻断原稿与纪要，
            // 仅给一句柔和提示，避免把原始 CoreML 错误（含英文 + 沙盒路径）直接抛给用户。
            statusMessage = "说话人自动标记暂不可用，原稿与纪要不受影响"
        }
    }

    /// blocks → 持久化分段。按 startSeconds 排序输出：merger 行序=到达序（SpeechAnalyzer
    /// 拆句残留的晚到早段 append 在尾），LIVE 检查点若原样落盘会把乱序写进库——
    /// REVIEW 时间轴展示虽有兜底排序，回听高亮的边界表与后续按序消费的路径没有。
    /// 尾部草稿行（墙钟 start）排在音频轴定稿之后（墙钟 ≥ 音频轴），稳定排序保位。
    /// internal 供 @testable 单测（同 shouldRejectRetranscribe 先例）。
    nonisolated static func segments(from blocks: [TranscriptBlock]) -> [TranscriptSegment] {
        blocks
            .map { block -> (Double, TranscriptSegment) in
                let start = block.startSeconds ?? parseTimestamp(block.timestamp)
                // 未标注说话人（fallback "?" / LIVE 转写 "asr-live"）输出 speakerId: nil——
                // 把假 id 写成真值会污染持久化：diarize 守卫按 spk* 前缀判定虽能放行，
                // 但其他按「speakerId 非 nil」消费的路径会误判为已标注。
                let sid = block.speaker.id
                let effectiveSpeakerId = (sid == "?" || sid == "asr-live") ? nil : sid
                return (start, TranscriptSegment(
                    startSeconds: start,
                    endSeconds: block.endSeconds ?? start,
                    speakerId: effectiveSpeakerId,
                    text: block.raw,
                    confidence: block.confidence
                ))
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    /// 重转引擎解析意图：跟随偏好 / 云端优先（不向用户暴露引擎名）。
    /// 历史上的 `kind(AsrEngineKind)` 指名路径已删（052 P2-4）：cloudFirst 的回落链
    /// （Fun-ASR → SpeechAnalyzer → SenseVoice）已覆盖「指名端侧重转」的全部真实场景
    /// （无网/额度尽/非 AI 机型），专设菜单项冗余。
    private enum RetranscribeIntent { case auto, cloudFirst }

    /// 「重新转写」单一入口：云端优先（托管档实际跑 paraformer-realtime-v2），无凭证端侧兜底；
    /// 不向用户暴露引擎名。完成后自动联动润色 + 分离。
    public func retranscribeFromDiskCloudFirst() {
        guard !isRetranscribing, !isDiarizing, !isPolishing else { return }
        isRetranscribing = true
        retranscribeTask = Task { [weak self] in
            _ = await self?.performRetranscribe(intent: .cloudFirst, chainPostProcess: true)
        }
    }

    /// 托管档重转前确保 ASR token 就绪：缓存有效则复用（同今）；缓存空则强刷=触发网关 ASR 桶扣减/403。
    /// BYOK 跳过（自备 key，不经网关）。返回 nil=就绪；非 nil=面向用户的失败文案（额度耗尽/网络）。
    /// - Parameter lang: 英文会议请求英文模型 token（网关按 X-Recap-Lang 下发 asr_model）。
    private func ensureASRTokenForRetranscribe(lang: MeetingLanguage = .zh) async -> String? {
        guard RecapCredentialProvider.shared.isActiveCloud else { return nil }
        if (try? RecapCredentialProvider.shared.current(lang: lang)) != nil { return nil }
        do {
            try await RecapCredentialProvider.shared.ensureFresh(force: true, usage: .asr, lang: lang)
            return nil
        } catch {
            return Self.quotaFailureMessage(error)
        }
    }

    /// 网关签发失败文案:委托 RecapCredentialError.userMessage(解析 403 body 区分验证/额度,按 tier 兜底),
    /// 避免 Pro 用户在重转写路径看到误导性的「免费额度已用完」。
    private static func quotaFailureMessage(_ error: Error) -> String {
        (error as? RecapCredentialError)?.userMessage ?? "凭证准备失败，请检查网络后重试"
    }

    // MARK: - 说话人纠错（plan 047：纠错一次 → 跨会议终身生效）

    /// 重命名说话人：画廊层写回（voiceprintId 键，重跑分离后名字跟人走）+ 本场即时生效。
    /// 无 voiceprintId（SpeakerKit 路径/旧数据）仅改本场显示名。
    public func renameSpeaker(_ speaker: Speaker, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let vp = speaker.voiceprintId, VoiceprintConsent.granted {
            VoiceprintGallery.shared.rename(voiceprintId: vp, name: trimmed)
        }
        meeting.speakers = meeting.speakers.map {
            $0.id == speaker.id
                ? Speaker(id: $0.id, name: trimmed, colorIndex: $0.colorIndex, voiceprintId: $0.voiceprintId)
                : $0
        }
        republishBlocksAfterSpeakerChange()
        checkpointSaver?()
    }

    /// 合并说话人（「这两位是同一个人」）：本场段级 speakerId 重映射 + 画廊 embedding 合并，
    /// 下场会议起合并身份自动生效。保留 target 的名字与色环。
    public func mergeSpeaker(_ source: Speaker, into target: Speaker) {
        guard source.id != target.id else { return }
        if let sv = source.voiceprintId, let tv = target.voiceprintId,
           sv != tv, VoiceprintConsent.granted {
            VoiceprintGallery.shared.merge(sourceId: sv, intoId: tv, keepName: target.name)
        }
        meeting.segments = meeting.segments.map { seg in
            guard seg.speakerId == source.id else { return seg }
            return TranscriptSegment(
                id: seg.id,
                startSeconds: seg.startSeconds,
                endSeconds: seg.endSeconds,
                speakerId: target.id,
                text: seg.text,
                confidence: seg.confidence,
                isOverlapped: seg.isOverlapped
            )
        }
        meeting.speakers = meeting.speakers.filter { $0.id != source.id }
        republishBlocksAfterSpeakerChange()
        checkpointSaver?()
    }

    /// 说话人变更后从 segments 重建 blocks（同步 UI 显示名/色环）。
    private func republishBlocksAfterSpeakerChange() {
        adoptSegmentsAsBlocks(meeting.segments)
    }

    /// - Parameter chainPostProcess: true（默认）= 完成后自动联动润色 + 分离；false = 编排方自行接管
    ///   （如 `regenerateWithRetranscribe` 需在润色后串接纪要管线）。
    /// - Returns: true = 成功产出新转写并已 adopt 为 blocks；false = 取消/失败/无录音等。
    /// 重转结果覆盖判定：旧稿已有实质内容（≥200 字）而新结果不足其 60% 字数时拒收——
    /// 网络故障/中途 403 会让云端分块重转静默跳段，返回部分结果；覆盖即丢字幕。
    /// 与 endLive 的「保留更完整一侧」同范式。
    /// 三条重转路径（手动/方言云端/端侧升级）共用；internal 供 RecapUITests 回归。
    nonisolated static func shouldRejectRetranscribe(
        new: [TranscriptSegment], old: [TranscriptSegment]
    ) -> Bool {
        let oldChars = old.reduce(0) { $0 + $1.text.count }
        guard oldChars >= 200 else { return false }
        let newChars = new.reduce(0) { $0 + $1.text.count }
        return newChars * 10 < oldChars * 6
    }

    /// freeTrial 精转结果的拼接：云端稿（只转前 capSeconds）+ LIVE 中 ≥capSeconds 的尾段。
    /// 时间轴天然有序（new 全在 0..<cap，tail 全在 ≥cap）。internal 供 RecapUITests 回归。
    nonisolated static func splicedFreeTrialSegments(
        new: [TranscriptSegment], old: [TranscriptSegment], capSeconds: Double
    ) -> [TranscriptSegment] {
        new + old.filter { $0.startSeconds >= capSeconds }
    }

    /// 重转拒收的量化诊断串：拒绝只有带上字数/时长/比值，才能事后定性「网络残稿」
    /// 「临界误杀」还是「原稿虚胖」。internal 供 RecapUITests 回归。
    nonisolated static func retranscribeRejectMetrics(new: [TranscriptSegment], old: [TranscriptSegment]) -> String {
        func chars(_ segs: [TranscriptSegment]) -> Int { segs.reduce(0) { $0 + $1.text.count } }
        func spanSeconds(_ segs: [TranscriptSegment]) -> Int { segs.last.map { Int($0.endSeconds.rounded()) } ?? 0 }
        let oldChars = chars(old), newChars = chars(new)
        let ratio = oldChars > 0 ? Int((Double(newChars) / Double(oldChars) * 100).rounded()) : 0
        return "old=\(oldChars)c/\(spanSeconds(old))s new=\(newChars)c/\(spanSeconds(new))s ratio=\(ratio)%"
    }

    private func performRetranscribe(intent: RetranscribeIntent,
                                     chainPostProcess: Bool = true) async -> Bool {
        // flag 由调用方同步置位；此处兜底清零（含 thermal/无录音/取消/超时/失败所有路径）。
        defer { isRetranscribing = false }
        let thermal = ProcessInfo.processInfo.thermalState
        if ThermalGate.shouldDefer(thermalState: thermal) {
            statusMessage = ThermalGate.warningText(thermalState: thermal) ?? "设备温度高，重转已延后"
            return false
        }
        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path) else {
            statusMessage = "没有可重转的本地录音"
            return false
        }
        // 托管档配额闸门：缓存空则强刷 ASR token（触发网关 ASR 桶扣减/403）；BYOK 跳过。
        // 英文会议按语言请求英文模型 token + 引擎。
        let language = meeting.language
        if let msg = await ensureASRTokenForRetranscribe(lang: language.engineLanguage) {
            statusMessage = msg
            return false
        }
        statusMessage = "重转中…"

        // 失败/取消路径兜底释放引擎（成功路径手动 release 后清空此引用）
        var preparedEngine: (any AsrEngine)?
        defer {
            if let e = preparedEngine { Task { await e.release() } }
        }

        do {
            if Task.isCancelled {
                statusMessage = "已取消"
                return false
            }
            let audioData = try MeetingAudioStore.loadMappedData(storedPath: path)
            let sampleCount = audioData.count / MemoryLayout<Float>.size
            guard sampleCount > 0 else {
                statusMessage = "本地录音为空"
                return false
            }
            if Task.isCancelled {
                statusMessage = "已取消"
                return false
            }
            let engine: any AsrEngine
            switch intent {
            case .auto:           engine = try await AsrEngineResolver.resolve(language: language.engineLanguage)
            case .cloudFirst:     engine = try await AsrEngineResolver.resolveCloudFirst(language: language)
            }
            preparedEngine = engine
            let hints = liveContextualHints
            if !hints.isEmpty { await engine.setContextualHints(hints) }

            // 超时预算：RTF>2× 即判失败（plan 024「RTF<1 通过」标准）。放门**外**——超时后当前
            // chunk 推理可能仍跑完（CoreML 不响应取消），期间门保持占用、不与下次推理并发 → 不触发 #661。
            let audioDuration = Double(sampleCount) / MeetingAudioStore.sampleRate
            let budget = audioDuration * 2 + 300
            let result = try await withThrowingTimeout(seconds: budget) {
                try await engine.transcribe(
                    audioData: audioData,
                    sampleRate: MeetingAudioStore.sampleRate,
                    onPartial: nil
                )
            }
            await engine.release()
            preparedEngine = nil
            // 删除竞态：重转是分钟级（云端/端侧），期间会议可能已删除——不可再读/写 meeting
            guard meetingIsWritable else { return false }
            // 拒收「部分成功」：云端分块重试耗尽后的段被静默跳过，返回的残缺结果若直接
            // 整表覆盖，会把原本更完整的转写抹掉且不可恢复。显著更短（<60% 字数）即保留旧稿。
            if Self.shouldRejectRetranscribe(new: result.segments, old: meeting.segments) {
                RecapLog.session.info("manual-retranscribe: 重转结果显著少于原转写，保留原稿 [\(Self.retranscribeRejectMetrics(new: result.segments, old: self.meeting.segments), privacy: .public) audio=\(Int(audioDuration), privacy: .public)s]")
                statusMessage = "重转结果不完整（网络波动），已保留原转写，可稍后重试"
                return false
            }
            let speakers = meeting.speakers.isEmpty ? [liveSpeaker] : meeting.speakers
            meeting.segments = result.segments
            // 重转产生新 raw，旧 polished 不再对应：清空，稍后联动重新润色
            meeting.polishedSegmentsData = nil
            meeting.polishedModelId = nil
            // 重转改写文本 → 重算语言（云端英文/端侧双模块直出可能改变分类）。
            meeting.language = TranscriptLanguageClassifier.classify(result.segments)
            if meeting.speakers.isEmpty {
                meeting.speakers = speakers
            }
            adoptSegmentsAsBlocks(result.segments)
            autoRetranscribeFallbackNote = nil   // 手动重转已兑现新稿，此前的未兑现说明作废
            checkpointSaver?()
            // 有字幕的「重转完成」静默：转写内容已刷新；仅异常（无字幕）出面
            if result.segments.isEmpty { statusMessage = "重转完成（无字幕）" }
            // 提前清零放行下游联动：否则 polishTranscript 的 !isRetranscribing 守卫会挡掉联动润色。
            // defer 末尾再清一次，幂等无害。
            isRetranscribing = false
            if chainPostProcess {
                schedulePolishIfNeeded()   // ①③ 联动：新 raw → 自动润色
                // 重转改变了分段边界 / 时间戳，旧 spk 标签已失效 → 联动重新分离。
                // 旧段已被无 speakerId 的新段替换，scheduleDiarizationIfNeeded 的「已标注」守卫会放行。
                scheduleDiarizationIfNeeded()
            }
            return true
        } catch is CancellationError {
            // 取消静默
            return false
        } catch InferenceTimeoutError.exceeded {
            statusMessage = "重转过慢/超时，请稍后重试"
            return false
        } catch RecapCredentialError.issueFailed(let status, _) where status == 403 {
            statusMessage = "免费额度已用完，可在设置中改用自备密钥（免费）继续"
            return false
        } catch {
            RecapLog.session.error("重转失败: \(error.localizedDescription, privacy: .public)")
            statusMessage = "重转失败，请检查网络或稍后重试"
            return false
        }
    }

    /// 会中英文检测的会后复核（纯函数，供单测）。返回 true = 双信号齐备，可把语言抬到
    /// .en 触发 `.language` 精修（P0-3：检测本身只有文本证据——方言乱稿罗马化可误触，
    /// 必须有第二信号佐证才允许放大）：
    /// - 切换成功过（switchElapsed 非 nil）→ 切换后文本由 fun-asr 逐句自动检测产出、
    ///   可信：判 .en 才佐证；切后样本不足（<120 有效字符）信会中两连窗口检测。
    /// - 切换被拦（switchElapsed == nil）→ 用最近 tailSeconds 尾巴文本复核——尾巴正是
    ///   命中检测的英文窗口，头部 CJK 乱稿不再误导全文分类；无有效样本不佐证
    ///   （宁可漏放行——方言/常规路径兜底，也不误放大成整场英文）。
    nonisolated static func liveEnglishCorroborated(liveDetectedEnglish: Bool,
                                                    switchElapsed: Double?,
                                                    segments: [TranscriptSegment],
                                                    tailSeconds: Double = 180) -> Bool {
        guard liveDetectedEnglish else { return false }
        func classifiedLanguage(of segs: [TranscriptSegment]) -> MeetingLanguage? {
            let joined = segs.map(\.text).joined()
            let filtered = joined.filter { !$0.isWhitespace && !$0.isPunctuation }
            guard filtered.count >= 120 else { return nil }
            return TranscriptLanguageClassifier.classify(text: joined)
        }
        if let switchElapsed {
            let post = segments.filter { $0.startSeconds >= switchElapsed - 1 }
            if let lang = classifiedLanguage(of: post) { return lang == .en }
            return true   // 切后样本不足：切换本身已是强证据，信两连窗口
        }
        guard let maxEnd = segments.map(\.endSeconds).max() else { return false }
        let tail = segments.filter { $0.endSeconds >= maxEnd - tailSeconds }
        return classifiedLanguage(of: tail) == .en
    }

    /// 会后自动云端重转决策（纯函数，供单测）。原则：纪要产物质量不打折，但延迟也是体验——
    /// 凡有质量缺口必补，干净场次不重复烧时间：
    /// - Pro：LIVE 落到端侧且属**回落**（auto 偏好，云端准备失败）→ `.pro` 无条件精转
    ///   （方言判定对 Pro 不再是闸门）；LIVE 云端但中途降级（断连/滞后/中断）→ `.pro` 补精转；
    ///   干净云端 LIVE → nil（直出纪要零延迟）；**显式选端侧** → 不触发（隐私选择，音频不上云，
    ///   除非方言判定命中走 `.dialect` 既有语义）。
    /// - 免费档首 3 场（freeTrial 模式且计数未用完）→ `.freeTrial`（每场截前 10min）。
    /// - 语言精修：会中检测英文且会后复核通过（liveEnglishCorroborated——切换后文本/
    ///   尾巴文本第二信号佐证；头部旧稿可能是 CJK 乱码会误导整场文本分类，不能依赖
    ///   `language == .en` 闸门）；或分类为英文且 LIVE 引擎无英文能力。
    /// - 混说精修：中英混说 + 托管云端中文模型（paraformer 官方明示「中英混说除外」）→
    ///   `.language` 用 fun-asr-realtime 重转（多语言混说正是其长项）。BYOK 本就是 fun-asr，不烧。
    /// - 其余：方言判定照旧（免费/BYOK 语义不变）。
    nonisolated static func autoCloudRetranscribeReason(
        engineKind: AsrEngineKind?,
        fellBackFromCloud: Bool,
        liveDegraded: Bool,
        proHosted: Bool,
        freeTrialEligible: Bool,
        dialectVerdict: DialectDetector.Verdict,
        language: MeetingLanguage = .zh,
        liveEnglishCapable: Bool = false,
        liveDetectedEnglish: Bool = false
    ) -> AutoCloudRetranscribeReason? {
        if proHosted {
            if fellBackFromCloud, engineKind == .speechAnalyzer { return .pro }
            if liveDegraded, engineKind == .funASR { return .pro }
        } else if freeTrialEligible {
            return .freeTrial
        }
        if liveDetectedEnglish {
            return .language
        }
        if language == .en, !liveEnglishCapable {
            return .language
        }
        if language == .mixed, engineKind == .funASR, proHosted {
            return .language
        }
        if dialectVerdict == .retranscribe {
            return .dialect
        }
        return nil
    }

    /// 免费档云端体验已用场次（设备本地计数；仅成功完成精转才计数，失败不烧体验机会）。
    private static let cloudTrialUsedKey = "recap.cloudTrial.meetingsUsed"
    private static var cloudTrialMeetingsUsed: Int {
        get { UserDefaults.standard.integer(forKey: cloudTrialUsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: cloudTrialUsedKey) }
    }
    /// 免费档云端体验总场次上限（每场截前 10min，3×10min=30min 恰为免费 ASR 月桶）。
    private static let cloudTrialMaxMeetings = 3
    /// 免费档单场体验的精转音频上限（秒）。
    private static let cloudTrialAudioCapSeconds: Double = 600

    /// 自动云端精转未兑现的用户文案（进 review 后随 statusMessage 一次性展示）。
    static let cloudRetranscribeFallbackText = "云端精转未完成，本场已用本机转写"

    /// 免费档自动云端精转熔断：服务端按实耗扣月桶（30min），本地「成功才计数」防不住
    /// 网络劣化期的重复白烧（每场 ~19MB 裸 PCM 上行 + 实耗秒数，最坏零展示烧穿整桶）。
    /// 连续 2 次未兑现 → 暂停自动尝试 7 天（成功即复位）；手动重转不受限。
    private static let cloudTrialRejectCountKey = "recap.cloudTrial.consecutiveRejects"
    private static let cloudTrialAutoPauseUntilKey = "recap.cloudTrial.autoPauseUntil"
    private static let cloudTrialRejectFuse = 2
    private static let cloudTrialPauseDays: Double = 7

    /// 自动尝试是否处于熔断暂停期。internal 供 RecapUITests 回归（注入 defaults/now）。
    /// MainActor 静态（读 UserDefaults 即时值）：调用点（hint 预告/endLive 判定/测试）全在主 actor。
    static func isFreeTrialAutoPaused(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        guard let until = defaults.object(forKey: cloudTrialAutoPauseUntilKey) as? TimeInterval else { return false }
        return now < Date(timeIntervalSince1970: until)
    }

    /// 记一次自动精转未兑现（守卫拒绝/无字幕/超时/失败——真正烧了实耗的路径；token
    /// 不可用与 403 不计：前者未起转写，后者服务端已在封顶）。达到阈值进入熔断。
    static func recordFreeTrialRetranscribeMiss(defaults: UserDefaults = .standard) {
        let count = defaults.integer(forKey: cloudTrialRejectCountKey) + 1
        defaults.set(count, forKey: cloudTrialRejectCountKey)
        if count >= cloudTrialRejectFuse {
            let until = Date().addingTimeInterval(cloudTrialPauseDays * 86_400).timeIntervalSince1970
            defaults.set(until, forKey: cloudTrialAutoPauseUntilKey)
        }
    }

    /// 成功兑现即复位熔断计数与暂停期。
    static func resetFreeTrialRetranscribeMisses(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: cloudTrialRejectCountKey)
        defaults.removeObject(forKey: cloudTrialAutoPauseUntilKey)
    }

    /// 会后自动云端重转（endLive 专属：方言 / Pro 质量承诺 / 免费体验 / 语言精修四合一）：
    /// 判定命中即用云端引擎重转 PCM 替换原转写，纪要随后用新文本生成（无需重跑）。
    /// 英文会议按语言选择英文模型与凭证（网关 X-Recap-Lang 下发对应 asr_model）。
    /// 失败/不命中/无凭证均降级放行，不阻断纪要。
    private func maybeAutoCloudRetranscribe(engineKind: AsrEngineKind?,
                                            fellBackFromCloud: Bool,
                                            liveDegraded: Bool,
                                            liveEnglishCapable: Bool,
                                            liveDetectedEnglish: Bool = false) async -> Bool {
        let proHosted = AIServiceMode.current == .recapCloud && RecapAccountStore.current.tier == .pro
        let freeTrialEligible = AIServiceMode.current == .freeTrial
            && Self.cloudTrialMeetingsUsed < Self.cloudTrialMaxMeetings
            && !Self.isFreeTrialAutoPaused()
        // 会中英文检测的会后复核（P0-3）：见 liveEnglishCorroborated 注释。复核不过，
        // 方言判定等常规路径照常参与——误判不再无条件压过 .dialect。
        let corroboratedEn = Self.liveEnglishCorroborated(
            liveDetectedEnglish: liveDetectedEnglish,
            switchElapsed: liveEnglishSwitchElapsed,
            segments: meeting.segments
        )
        let detectedLanguage: MeetingLanguage = (corroboratedEn && meeting.language != .en) ? .en : meeting.language
        let reason = Self.autoCloudRetranscribeReason(
            engineKind: engineKind,
            fellBackFromCloud: fellBackFromCloud,
            liveDegraded: liveDegraded,
            proHosted: proHosted,
            freeTrialEligible: freeTrialEligible,
            dialectVerdict: DialectDetector.verdict(engineKind: engineKind, segments: meeting.segments),
            language: detectedLanguage,
            liveEnglishCapable: liveEnglishCapable,
            liveDetectedEnglish: corroboratedEn
        )
        guard let reason else { return false }

        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path) else {
            RecapLog.session.info("auto-cloud-retranscribe: 无本地录音，跳过")
            return false
        }
        // 配额闸门（修旧 bug：此前 warmup `ensureFresh()` 无参 → 默认 usage=.llm，误扣免费档
        // LLM 桶）：缓存 token 剩余 >60s 复用不触发网关不扣额；空/失效才签发（扣 ASR 桶）。
        // 403（额度尽）静默保留原稿（自动路径不打扰）。
        // 英文会议请求英文模型 token（网关按 X-Recap-Lang 下发 asr_model）。
        let language = detectedLanguage
        if let msg = await ensureASRTokenForRetranscribe(lang: language.engineLanguage) {
            RecapLog.session.info("auto-cloud-retranscribe(\(reason.rawValue, privacy: .public)): ASR token 不可用，保留原稿（\(msg, privacy: .public)）")
            autoRetranscribeFallbackNote = Self.cloudRetranscribeFallbackText   // 预告已做出，未兑现须可见
            return false
        }

        pipelineStage = .retranscribing(reason == .dialect ? .dialect
                                        : (reason == .freeTrial ? .freeTrial
                                            : (reason == .language ? .language : .pro)))
        markPipelineStarted()
        var preparedEngine: (any AsrEngine)?
        defer { if let e = preparedEngine { Task { await e.release() } } }
        do {
            if Task.isCancelled { return false }
            let loaded = try MeetingAudioStore.loadMappedData(storedPath: path)
            // 免费体验：截前 10min（3 场合计 ≤30min = 免费 ASR 月桶，服务端零改动）。
            let audioData: Data
            if reason == .freeTrial {
                let capBytes = Int(Self.cloudTrialAudioCapSeconds * MeetingAudioStore.sampleRate)
                    * MemoryLayout<Float>.size
                // 下标切片共享 mmap 映射（subdata 会物化 38.4MB 副本，违背 D5/D6 零拷贝意图）；
                // 切片起点为 0，下游样本索引→字节区间的换算不偏移。
                audioData = loaded.count > capBytes ? loaded[0..<capBytes] : loaded
            } else {
                audioData = loaded
            }
            let sampleCount = audioData.count / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return false }
            // 英文会议换英文模型重转（funASREn）；其余维持原引擎。
            let engine = try await AsrEngineResolver.resolve(kind: language.engineLanguage == .en ? .funASREn : .funASR)
            preparedEngine = engine
            let hints = liveContextualHints
            if !hints.isEmpty { await engine.setContextualHints(hints) }
            let audioDuration = Double(sampleCount) / MeetingAudioStore.sampleRate
            let budget = audioDuration * 2 + 300
            let result = try await withThrowingTimeout(seconds: budget) {
                try await engine.transcribe(
                    audioData: audioData,
                    sampleRate: MeetingAudioStore.sampleRate,
                    onPartial: nil
                )
            }
            await engine.release()
            preparedEngine = nil
            // 删除竞态：重转期间会议可能已删除——不可再读/写 meeting
            guard meetingIsWritable else { return false }
            guard !result.segments.isEmpty else {
                RecapLog.session.info("auto-cloud-retranscribe(\(reason.rawValue, privacy: .public)): 重转无字幕，保留原转写")
                autoRetranscribeFallbackNote = Self.cloudRetranscribeFallbackText
                if reason == .freeTrial { Self.recordFreeTrialRetranscribeMiss() }
                return false
            }
            // 拒收部分成功的残缺结果，保住原本完整的 LIVE 转写。
            // freeTrial 只转前 10min：与旧稿【前 10min 切片】比对——与整场比必然 <60%，
            // >17min 会议每场白烧 10min 云端转写且体验计数永不前进（直到月桶耗尽）。
            let oldForComparison: [TranscriptSegment]
            if reason == .freeTrial {
                oldForComparison = meeting.segments.filter { $0.startSeconds < Self.cloudTrialAudioCapSeconds }
            } else {
                oldForComparison = meeting.segments
            }
            if Self.shouldRejectRetranscribe(new: result.segments, old: oldForComparison) {
                let capNote = reason == .freeTrial ? "前\(Int(Self.cloudTrialAudioCapSeconds))s切片比对" : "全场比对"
                RecapLog.session.info("auto-cloud-retranscribe(\(reason.rawValue, privacy: .public)): 重转结果显著少于原转写，保留原稿 [\(Self.retranscribeRejectMetrics(new: result.segments, old: oldForComparison), privacy: .public) audio=\(Int(audioDuration), privacy: .public)s \(capNote, privacy: .public)]")
                autoRetranscribeFallbackNote = Self.cloudRetranscribeFallbackText
                if reason == .freeTrial { Self.recordFreeTrialRetranscribeMiss() }
                return false
            }
            // 采用：freeTrial 拼接——云端稿替换前 10min，LIVE 尾段保留（整表覆盖会把
            // 10~17min 会议的尾部静默删掉，纪要因此只覆盖前 10 分钟）；其余 reason 整表替换。
            if reason == .freeTrial {
                meeting.segments = Self.splicedFreeTrialSegments(
                    new: result.segments, old: meeting.segments,
                    capSeconds: Self.cloudTrialAudioCapSeconds)
                RecapLog.session.info("auto-cloud-retranscribe(freeTrial): 精转覆盖前 10min，LIVE 尾段保留")
            } else {
                meeting.segments = result.segments
            }
            meeting.polishedSegmentsData = nil
            meeting.polishedModelId = nil
            // 重转改写文本 → 重算语言（云端英文模型直出可能改变分类）。
            // freeTrial 时按拼接后全稿分类（含 LIVE 尾段），与 meeting.segments 同口径。
            meeting.language = TranscriptLanguageClassifier.classify(meeting.segments)
            // adopt 必须吃 meeting.segments（freeTrial=拼接稿），不能吃 result.segments
            // （仅云端前 10min）——否则 persistTranscriptCheckpoint 用 blocks 重建 segments
            // 时整表覆盖，尾段在任何地方都不复存在（blocks/merger/DB 三处只剩前 10min）。
            adoptSegmentsAsBlocks(meeting.segments)
            persistTranscriptCheckpoint()
            checkpointSaver?()
            if reason == .freeTrial {
                Self.cloudTrialMeetingsUsed += 1   // 成功才计数
                Self.resetFreeTrialRetranscribeMisses()   // 兑现即复位熔断
            }
            let finalLang = meeting.language.rawValue
            RecapLog.session.info("auto-cloud-retranscribe(\(reason.rawValue, privacy: .public)): 完成 segments=\(result.segments.count) lang=\(finalLang, privacy: .public)")
            // 不触发 polish/diarize：纪要尚未生成，由 commitAISummary/finishReviewWithoutMock 统一调度
            return true
        } catch is CancellationError {
            // 取消静默
        } catch InferenceTimeoutError.exceeded {
            // 原 statusMessage 写法是死文案：processing 态不渲染且随即被「云端整理中…」覆盖——
            // 未兑现说明改挂 fallbackNote，随纪要完成进 review 一次性可见。
            autoRetranscribeFallbackNote = Self.cloudRetranscribeFallbackText
            if reason == .freeTrial { Self.recordFreeTrialRetranscribeMiss() }
        } catch RecapCredentialError.issueFailed(let status, _) where status == 403 {
            // 自动路径：ASR 额度耗尽，保留原转写。预告已做出，未兑现须可见；
            // 额度尽不进熔断计数（服务端已在封顶）。
            RecapLog.session.info("auto-cloud-retranscribe(\(reason.rawValue, privacy: .public)): ASR 额度耗尽，保留原转写")
            autoRetranscribeFallbackNote = Self.cloudRetranscribeFallbackText
        } catch {
            RecapLog.session.error("auto-cloud-retranscribe(\(reason.rawValue, privacy: .public)) 失败，已用原转写: \(error.localizedDescription, privacy: .public)")
            autoRetranscribeFallbackNote = Self.cloudRetranscribeFallbackText
            if reason == .freeTrial { Self.recordFreeTrialRetranscribeMiss() }
        }
        return false
    }

    /// 会后端侧高保真升级（普通话路径）：LIVE 用 Apple SpeechAnalyzer 产出后，若开启实验开关，
    /// 用端侧 SenseVoice 重转 PCM 提升中文精度 + 补标点/情感。仅 .speechAnalyzer 路径触发
    /// （Pro 云端 LIVE 已是高保真，不升级；fork B：端侧优先给 Free/BYOK，Pro 保云端）。
    /// 与方言重转串联：方言重转成功则跳过；未成功（非方言/失败/额度尽）才落到本路径
    /// （行为上是方言的二道兜底，SenseVoice 亦支持 zh/yue）。失败/模型未就绪/取消均静默保留原转写，不阻断纪要。
    /// 默认关（fluidRetranscribeEnabled），真机 POC 验证 SenseVoice CoreML 质量/性能后再考虑默认开。
    private func maybeOnDeviceUpgrade(engineKind: AsrEngineKind?) async {
        guard ASRFeatureFlags.fluidRetranscribeEnabled else { return }
        guard engineKind == .speechAnalyzer else { return }  // 仅端侧 Apple LIVE 路径
        // 模型未预下载则跳过：避免 endLive 管线触发 447MB 下载阻塞纪要（用户须先在设置页预下载）
        guard FluidAudioBootstrap.modelsPreloaded else {
            RecapLog.session.info("on-device-upgrade: 端侧模型未预下载，跳过")
            return
        }

        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path) else {
            RecapLog.session.info("on-device-upgrade: 无本地录音，跳过")
            return
        }

        pipelineStage = .retranscribing(.onDevice)
        markPipelineStarted()
        // 不写 statusMessage：processing 态不渲染该字段，且 commitAISummary 进 REVIEW 时
        // 不清空——成功后会以「重转中…」残留在转写页头部。舞台标题已按来源区分，失败路径
        // 按设计静默保留原转写（实验特性，不打扰）。
        var preparedEngine: (any AsrEngine)?
        defer { if let e = preparedEngine { Task { await e.release() } } }
        do {
            if Task.isCancelled { return }
            let audioData = try MeetingAudioStore.loadMappedData(storedPath: path)
            let sampleCount = audioData.count / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }
            let engine = try await AsrEngineResolver.resolve(kind: .fluidSenseVoice)
            preparedEngine = engine
            let hints = liveContextualHints
            if !hints.isEmpty { await engine.setContextualHints(hints) }
            let audioDuration = Double(sampleCount) / MeetingAudioStore.sampleRate
            let budget = audioDuration * 2 + 300
            let result = try await withThrowingTimeout(seconds: budget) {
                try await engine.transcribe(
                    audioData: audioData,
                    sampleRate: MeetingAudioStore.sampleRate,
                    onPartial: nil
                )
            }
            await engine.release()
            preparedEngine = nil
            // 删除竞态：端侧升级重转期间会议可能已删除——不可再读/写 meeting
            guard meetingIsWritable else { return }
            guard !result.segments.isEmpty else {
                RecapLog.session.info("on-device-upgrade: 重转无字幕，保留原转写")
                return
            }
            // 同 performRetranscribe/方言路径：拒收显著变短的残缺结果——SenseVoice 大面积丢字时
            // 直接整表覆盖会毁掉更完整的 LIVE 稿（三条重转路径此前唯独这里缺这道守卫）。
            if Self.shouldRejectRetranscribe(new: result.segments, old: meeting.segments) {
                RecapLog.session.info("on-device-upgrade: 重转结果显著少于原转写，保留原稿 [\(Self.retranscribeRejectMetrics(new: result.segments, old: self.meeting.segments), privacy: .public) audio=\(Int(audioDuration), privacy: .public)s]")
                return
            }
            meeting.segments = result.segments
            meeting.polishedSegmentsData = nil
            meeting.polishedModelId = nil
            adoptSegmentsAsBlocks(result.segments)
            persistTranscriptCheckpoint()
            checkpointSaver?()
            RecapLog.session.info("on-device-upgrade: SenseVoice 重转完成 segments=\(result.segments.count)")
            // 不触发 polish/diarize：纪要尚未生成，由 commitAISummary/finishReviewWithoutMock 统一调度
        } catch is CancellationError {
            // 取消静默
        } catch InferenceTimeoutError.exceeded {
            RecapLog.session.info("on-device-upgrade: 端侧重转过慢/超时，保留原转写")
        } catch FluidAudioEngineError.assetDownloadFailed(let m) {
            // 模型未就绪/缓存被清：清预下载标记保持诚实，静默跳过（用户可在设置页重新预下载）
            FluidAudioBootstrap.modelsPreloaded = false
            RecapLog.session.info("on-device-upgrade: 端侧模型未就绪，跳过：\(m, privacy: .public)")
        } catch {
            RecapLog.session.error("on-device-upgrade 失败，保留原转写: \(error.localizedDescription, privacy: .public)")
        }
    }

#if DEBUG
    /// 演示字幕（DEBUG 验收入口专用；Release 不编译，见 DemoContent 同款门）。
    public func startExplicitDemoLive() {
        guard phase == .live else { return }
        streamTask?.cancel()
        liveEpoch += 1
        recording = nil
        isUsingMockAudio = true
        liveStartFailed = false
        isLivePaused = false
        statusMessage = "演示字幕（非真实录音）"
        setIdleTimerDisabled(false)
        startClock()
        startMockStream()
    }
#endif

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
                // 会中语言检测（英文会议 → 切英文引擎）：低频轮询挂现有时钟，不新增任务生命周期
                if self.elapsed % 45 == 0 {
                    self.evaluateLiveLanguage()
                }
            }
        }
    }

    /// 火山等累积全量 / Fun-ASR 当前句草稿。
    /// partial 是 LIVE 最高频事件（每秒多次）：按 merger 的显式变更标记走 O(1) 增量投影，
    /// 跳过 publishMergerRows 的 previous Dictionary 构建 + 全量 map 重赋（长会议 O(n)/次，
    /// 2h 后期是主线程抖动主源之一）。segment / 检查点等路径仍走全量投影。
    private func applyPartial(_ text: String) {
        guard !text.isEmpty else { return }
        merger.applyPartial(text: text, elapsedSeconds: Double(elapsed))
        switch merger.lastMutation {
        case .tailDraftUpdated:
            publishTailDraft()
        case .appendedDraft:
            withAnimation(.easeOut(duration: 0.18)) { publishAppendedDraft() }
        case .rebuilt:
            publishMergerRows()
        }
    }

    /// partial 尾行重写的增量投影。前提不变量：blocks 是 merger.rows 的最新投影
    /// （applyPartial/applySegment 后必 publish；loadCheckpoint 走 adoptSegmentsAsBlocks 全量）。
    /// 尾行 id 一致性防御校验，不匹配（不变量被打破）即回退全量。
    private func publishTailDraft() {
        guard let row = merger.rows.last, let lastBlock = blocks.last,
              row.id == lastBlock.id, !row.isFinal else {
            return publishMergerRows()
        }
        let total = Int(row.startSeconds.rounded())
        let updated = TranscriptBlock(
            id: row.id,
            speaker: lastBlock.speaker,   // 保留已解析说话人（对齐 publishMergerRows 的 previous 语义）
            timestamp: String(format: "%d:%02d", total / 60, total % 60),
            raw: row.text,
            polished: row.text,
            isFinal: row.isFinal,
            startSeconds: row.startSeconds,
            endSeconds: row.endSeconds,
            confidence: row.confidence
        )
        if updated != lastBlock {
            blocks[blocks.count - 1] = updated
        }
    }

    /// partial 追加新草稿行的增量投影（新行不在 previous 里，说话人 = liveSpeaker，
    /// 与 publishMergerRows 全量路径语义一致）。
    private func publishAppendedDraft() {
        guard let row = merger.rows.last, row.id != blocks.last?.id else {
            return publishMergerRows()
        }
        let total = Int(row.startSeconds.rounded())
        blocks.append(TranscriptBlock(
            id: row.id,
            speaker: liveSpeaker,
            timestamp: String(format: "%d:%02d", total / 60, total % 60),
            raw: row.text,
            polished: row.text,
            isFinal: row.isFinal,
            startSeconds: row.startSeconds,
            endSeconds: row.endSeconds,
            confidence: row.confidence
        ))
    }

    /// SpeechAnalyzer / Fun-ASR 按时间戳分段更新（定稿）。
    private func applySegment(_ seg: TranscriptSegment) {
        merger.applySegment(seg)
        publishMergerRows()
        // 高频 segment 节流落盘；pause / endLive 仍 force
        checkpointIfNeeded(force: false)
        evaluateLiveDialectHint()
    }

    /// LIVE 增量方言判定：复用 DialectDetector.verdict（同款窗口/阈值/端侧门控）。
    /// 每来一个 final segment 重算前 90s 窗口；方言 → 置位 liveDialectSuspected（一场会一次）。
    /// 云端引擎 verdict 直接 .keep，不会误触发；pause/resume 不复位，避免反复闪烁。
    /// 性能：窗口只取前 90s 覆盖——一旦有段越过窗口末端，前缀内容封冻、结果恒定，
    /// 评估一次定终身（此前每个 final 都全量构造 + 全量排序，2h 会议累计秒级主线程开销）。
    private var liveDialectPrefixFrozen = false

    private func evaluateLiveDialectHint() {
        guard !liveDialectSuspected, !liveDialectPrefixFrozen else { return }
        let segs = Self.segments(from: blocks)
        if let maxEnd = segs.map(\.endSeconds).max(), maxEnd > 100 {
            // 100s > 窗口 90s+余量：本次是最后一次评估，之后窗口内容不可能再变。
            liveDialectPrefixFrozen = true
        }
        if DialectDetector.verdict(engineKind: liveEngineKind, segments: segs) == .retranscribe {
            liveDialectSuspected = true
        }
    }

    // MARK: - 会中语言检测（英文会议 → 切英文引擎续流）

    /// 英文连续命中计数（连续两次 45s 窗口 ≥85% Latin 才切，防短句/夹词抖动）。
    private var liveEnglishDetections = 0
    /// 会中检测到英文（粘性：一场一次；即便切换被门槛拦下，检测结论仍成立——
    /// endLive 经 liveEnglishCorroborated 复核通过后才强制 `.language` 精修：
    /// 头部乱稿不会误导整场语言分类，方言乱稿误判也不会再无条件放大）。
    @Published public private(set) var liveEnglishDetected = false
    /// 回头路（P0-2）：热切换后连续中文命中计数——新引擎不锁语种，中文音频会回流
    /// CJK 定稿；两连命中即切回原引擎。
    private var liveChineseDetections = 0
    /// 热切换前的引擎 kind（回头路切回目标）。nil = 本场尚无成功切换（含被门槛拦下）。
    private var livePreEnglishEngineKind: AsrEngineKind?
    /// 热切换成功时的会议时间轴位置（endLive 复核「切换后文本」的切点；nil = 切换被拦）。
    private var liveEnglishSwitchElapsed: Double?
    /// 一个来回后停机：zh/en 判定反复振荡说明信号自相矛盾——维持当前引擎到散会，
    /// 交由会后重转收口（防来回切引擎反复断流 + 烧 token）。
    private var liveEnglishRoundTripDone = false

    /// 每 45s 由 LIVE 时钟驱动：窗口=最近 3 分钟定稿行、≥120 有效字符才判。
    /// 命中两连 → 切 funASREn（paraformer 对纯英文/混说都是盲区，端侧 zh-only 同理）。
    /// 已切换后转为回头路监测（新引擎不锁语种，中文回流两连 → 切回原引擎）。
    private func evaluateLiveLanguage() {
        guard let recording, recording.isRunning else { return }
        if liveEnglishDetected {
            evaluateLiveChineseReturn(recording)
            return
        }
        guard !liveEnglishRoundTripDone, !recording.englishCapable else { return }
        let windowStart = Double(elapsed) - 180
        let text = merger.rows
            .filter { $0.isFinal && $0.endSeconds >= windowStart }
            .map(\.text)
            .joined()
        let filtered = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard filtered.count >= 120 else { return }
        guard TranscriptLanguageClassifier.classify(text: text) == .en else {
            liveEnglishDetections = 0
            return
        }
        liveEnglishDetections += 1
        RecapLog.session.info("LIVE 语言检测 en 命中 \(self.liveEnglishDetections)/2（chars=\(filtered.count, privacy: .public)）")
        guard liveEnglishDetections >= 2 else { return }
        liveEnglishDetected = true
        Task { await switchLiveEngineToEnglish() }
    }

    /// 引擎热切换（检测两连命中后调用一次）。门槛：
    /// - 显式选端侧 = 隐私选择，不上云（与 endLive 兜底重转同红线）；
    /// - 免费档端侧在跑时不上云（成本红线：会后 10min 精转已够体验）；但 LIVE 本就在云端
    ///   （国行兜底 paraformer）时切 en 是零边际成本的质量修正，放行。
    private func switchLiveEngineToEnglish() async {
        guard let recording, recording.isRunning else { return }
        // BYOK zh 跑在 fun-asr 多语言模型上：自动检测已覆盖英文，切换 = 同模型重启
        // 白断流数秒——跳过（检测结论保留，会后复核通过仍可走 en 批量精转收口）。
        if recording.autoCoversEnglish {
            RecapLog.session.info("LIVE 语言切换跳过：当前引擎自动检测已覆盖英文（fun-asr 多语言）")
            return
        }
        guard ASRPreference.current != .speechAnalyzer else {
            RecapLog.session.info("LIVE 语言切换跳过：显式端侧偏好（隐私选择，音频不上云），会后语言精修兜底")
            return
        }
        guard AIServiceMode.current != .freeTrial || recording.engineKind == .funASR else {
            RecapLog.session.info("LIVE 语言切换跳过：免费档端侧在跑（不产生云端 LIVE 计费），会后语言精修兜底")
            return
        }
        guard AsrEngineResolver.hasFunCredentials else {
            RecapLog.session.info("LIVE 语言切换跳过：无云端凭证，会后语言精修兜底")
            return
        }
        let previousKind = recording.engineKind
        statusMessage = "检测到英文会议，切换英文转写…"
        let ok = await recording.switchEngine(to: .funASREn) { [weak self] in
            // 新引擎相对时间从 0 重启：抬高 merger 偏移，把后续 en 段映射到旧内容之后
            self?.merger.prepareForResume()
        }
        if ok {
            // 语言暂定 en（续录/检测闸门据此走 en 路径）。可撤销：新引擎 LIVE 不锁
            // 语种，中文回流两连即切回并重分类（evaluateLiveChineseReturn）；会后
            // 复核（liveEnglishCorroborated）亦以切换后文本为准。
            livePreEnglishEngineKind = previousKind
            liveEnglishSwitchElapsed = Double(elapsed)
            meeting.language = .en
            checkpointSaver?()
            RecapLog.session.info("LIVE 已切换英文引擎（LIVE 不锁语种），回头路监测中")
        }
        statusMessage = ""
    }

    /// 回头路（P0-2）：热切换后每 45s 复评——新引擎（fun-asr 自动检测）若持续产出
    /// 中文定稿（两连窗口判 zh），说明「英文会议」是方言罗马化乱稿误判：切回原引擎
    /// + 撤销英文粘性 + 语言按全文重分类。一个来回后停机防振荡。注意必须在
    /// englishCapable 短路之外运行（funASRez 恒 true，短路则中文回流永远无人看）。
    private func evaluateLiveChineseReturn(_ recording: RecordingSession) {
        guard !liveEnglishRoundTripDone,
              livePreEnglishEngineKind != nil,
              recording.engineKind == .funASREn else { return }
        let windowStart = Double(elapsed) - 180
        let text = merger.rows
            .filter { $0.isFinal && $0.endSeconds >= windowStart }
            .map(\.text)
            .joined()
        let filtered = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard filtered.count >= 120 else { return }
        guard TranscriptLanguageClassifier.classify(text: text) == .zh else {
            liveChineseDetections = 0
            return
        }
        liveChineseDetections += 1
        RecapLog.session.info("LIVE 回头路 zh 命中 \(self.liveChineseDetections)/2（chars=\(filtered.count, privacy: .public)）")
        guard liveChineseDetections >= 2 else { return }
        liveEnglishRoundTripDone = true
        Task { await switchLiveEngineBackToChinese() }
    }

    /// 切回热切换前的引擎（回头路执行体，中文回流两连后调用一次）。
    private func switchLiveEngineBackToChinese() async {
        guard let recording, recording.isRunning,
              let target = livePreEnglishEngineKind, target != .funASREn else { return }
        statusMessage = "检测到中文会议，切回中文转写…"
        let ok = await recording.switchEngine(to: target) { [weak self] in
            self?.merger.prepareForResume()
        }
        if ok {
            // 英文粘性撤销 + 语言按当前全文重分类（不再沿用切换时的 .en 暂定）。
            liveEnglishDetected = false
            liveEnglishDetections = 0
            liveChineseDetections = 0
            let finalText = merger.rows.filter(\.isFinal).map(\.text).joined()
            meeting.language = TranscriptLanguageClassifier.classify(text: finalText)
            checkpointSaver?()
            RecapLog.session.info("LIVE 已切回 \(target.rawValue, privacy: .public)，语言重判 lang=\(self.meeting.language.rawValue, privacy: .public)")
        }
        statusMessage = ""
    }


#if DEBUG
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
#endif

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
        // Live Activity 先于一切收尾工作撤下（plan 054）：防重入守卫之后立即执行，
        // 避免收尾链耗时期间锁屏仍显示「正在记录」
        recordingActivity.end()
        // 声纹抽检随录音停止（plan 055）：在场/提示清场，spotter 释缓冲
        livePresence = []
        livePresenceHasUnknown = false
        liveVoicePrompt = nil
        promptedLiveVoiceIds = []
        Task { [liveVoiceprintSpotter] in await liveVoiceprintSpotter.endSession() }

        clockTask?.cancel()
        streamTask?.cancel()
        powerCancellable?.cancel()
        powerCancellable = nil
        statusMessage = "正在收尾…"
        setIdleTimerDisabled(false)

        // 收尾窗口安全网：切态前先同步落一次 checkpoint——`stop()` 带 5s 超时，
        // 若此窗口内进程被杀，至少保住用户点「完成」瞬间的字幕与时长
        // （旧实现要等 stop 完成才写，且 phase 已切 .processing 使节流守卫不再兜底）。
        persistLiveCheckpoint()
        checkpointSaver?()

        // 同步立刻切态，不等 stop()；否则按钮像失灵
        meeting.phase = .processing
        withAnimation(.recapSheet) { phase = .processing }
        liveEpoch += 1

        let recordingToStop = recording
        recording = nil

        revealTask?.cancel()
        // C1 第七路径：收尾链（含分钟级自动云端重转）先于管线起跑——管线登记 registry 之前
        // 的窗口内删除会议，registry 无条目可取消。起跑即登记（token 语义：管线起跑时
        // 重新 register 覆盖，本链 defer 的旧 token 不会误抹管线条目）。
        let revealToken = UUID()
        let meetingID = meeting.id
        let revealChain = Task { [weak self] in
            // defer 先于 guard：session 释放也要 unregister，否则 registry 留死条目。
            defer { MinutesTaskRegistry.shared.unregister(token: revealToken, for: meetingID) }
            guard let self else { return }
            defer { self.endingLive = false }

            // 暂停离场后直接「完成」：旧 stop 可能仍在后台写盘，先等它落地再读文件/收尾，
            // 否则 mmap 读到的文件大小不含末段（静默截断），且映射后追加有 SIGBUS 隐患。
            if let t = self.teardownStopTask {
                self.teardownStopTask = nil
                _ = await t.value
            }

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
                                // 续录：stop() 仅含本段相对秒，整表替换会砸偏 offset、丢会前历史。
                                if stopChars > liveChars + 32 {
                                    // stop() 明显更全（少见）：整体采用
                                    self.adoptSegmentsAsBlocks(result.segments)
                                } else {
                                    // 否则经 merger 逐条并入：applySegment 自动 +timelineOffset 映射绝对轴
                                    // + overlap 去重，补齐 trailing partial 的末段定稿（原整丢 stop() 会丢末段定稿）。
                                    for seg in result.segments {
                                        self.merger.applySegment(seg)
                                    }
                                    self.publishMergerRows()
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
                    RecapLog.session.error("转写收尾失败: \(error.localizedDescription, privacy: .public)")
                    self.statusMessage = "转写收尾失败，已保留实时字幕"
                }
            }
            self.finalizeAll()

            // C1 第七路径：收尾期间（stop 数秒 + 自动重转分钟级）会议可能已删除——
            // 此后 checkpoint/language/重转/管线全部写库，统一在此早退（资源收尾已完成）。
            guard self.meetingIsWritable else { return }

            // endLive 已切到 processing，不能再用 live 守卫的 checkpoint
            self.persistTranscriptCheckpoint()
            self.checkpointSaver?()
            // LIVE 方言提示随结束收起（phase 已切 processing，UI 门控本就不显示；此处复位保险）
            self.liveDialectSuspected = false

            // 语言自动判定（零用户操作）：统计转写 CJK/Latin 占比 → 驱动语言精修与 LLM 输出语言。
            let classified = TranscriptLanguageClassifier.classify(self.meeting.segments)
            if self.meeting.language != classified {
                self.meeting.language = classified
                self.checkpointSaver?()
            }
            RecapLog.session.info("endLive 语言判定 lang=\(self.meeting.language.rawValue, privacy: .public)")

            // 自动云端重转（四合一：方言 / Pro 质量承诺 / 免费体验 / 语言精修；失败/不命中降级放行）
            // 串联次序：云端重转优先，成功即跳过端侧；未成功（不命中/失败/额度尽）才落
            // SenseVoice 端侧升级——后者是前者的二道兜底，两者不会都跑。
            let cloudRetranscribed = await self.maybeAutoCloudRetranscribe(
                engineKind: recordingToStop?.engineKind,
                fellBackFromCloud: recordingToStop?.engineResolvedFromFallback ?? false,
                liveDegraded: recordingToStop?.lastError != nil,
                liveEnglishCapable: recordingToStop?.englishCapable ?? false,
                liveDetectedEnglish: self.liveEnglishDetected
            )
            if !cloudRetranscribed {
                await self.maybeOnDeviceUpgrade(engineKind: recordingToStop?.engineKind)
            }
            // 会中语言检测状态复位（下一场/演示不携带）
            self.liveEnglishDetected = false
            self.liveEnglishDetections = 0
            self.liveChineseDetections = 0
            self.livePreEnglishEngineKind = nil
            self.liveEnglishSwitchElapsed = nil
            self.liveEnglishRoundTripDone = false

            self.startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
        }
        MinutesTaskRegistry.shared.register(revealChain, token: revealToken, for: meetingID)
        revealTask = revealChain
    }

    // MARK: PROCESS

    /// 最近一次纪要生成实际使用的 summary 模型 id；落库 AIOutput.modelId 时读取，
    /// 避免硬编码（Pro 云 / 免费档 / BYOK 各异）。startLLMProcessing 创建 provider 时写入；
    /// provider 创建失败（catch 路径）保留默认值。
    public private(set) var pendingSummaryModelId: String = LLMPresets.deepSeekPro

    /// 流式草稿节流状态：上次全量解析时间。逐 delta 全量解析 + 重赋 @Published summary 会随
    /// 流式长度 O(n²) 重渲；限频出草稿，最终态由 commitAISummary 全量兜底。
    private var lastSummaryDraftAt: Date?
    private static let summaryDraftThrottle: TimeInterval = 0.12

    /// 转写行时间戳前缀：优先用 startSeconds 生成 mm:ss（相对会议开始），缺省回退 timestamp 字符串。
    /// 让 todo 提取的 start_seconds 有据可依，不再依赖子串回退或幻觉。
    private static func transcriptTimestamp(_ block: TranscriptBlock) -> String {
        if let s = block.startSeconds {
            let total = Int(s.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return block.timestamp
    }

    /// 解析当前草稿文本 -> 更新 @Published summary + 推进 revealStep（由流式节流调用）。
    /// 单事务收束：summary + 多级 revealStep 旧码各起一个 withAnimation 事务，首个含
    /// tldr/topics/decisions 的草稿帧同 tick 最多 5 次发布 4 个事务——流式期间每 120ms
    /// 一次，让在屏 glassEffect 视图一帧多更（"tried to update multiple times per frame"）。
    /// 阶梯语义不变（revealStep 单调推进），只是共享同一动画事务。首个草稿帧的
    /// `.generating` 阶段推进也并入（裸赋值与事务同帧双提交是残留的一帧多更源）。
    private func applySummaryDraft(_ text: String, enteringGenerating: Bool = false) {
        let draft = MinutesMarkdownParser.parse(text).summary
        withAnimation(.easeOut(duration: 0.24)) {
            if enteringGenerating { self.pipelineStage = .generating }
            self.summary = MeetingSummary(
                tldr: draft.tldr,
                topics: draft.topics,
                decisions: draft.decisions,
                openQuestions: []
            )
            if self.revealStep < 1, !draft.tldr.isEmpty { self.revealStep = 1 }
            if self.revealStep < 2, !draft.topics.isEmpty { self.revealStep = 2 }
            if self.revealStep < 3, !draft.decisions.isEmpty { self.revealStep = 3 }
        }
    }

    private func startProcessing(persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
                                 persistSummary: @escaping (MeetingSummary, String) -> Void) {
        // C1 第七路径：endLive 收尾链/凭证强刷重入都可能晚于删除到达——删除后不进任何管线与写回。
        guard meetingIsWritable else { return }
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
        } else if AIServiceMode.current == .freeTrial {
            // 免费档闸门未过(token 未就绪或额度耗尽):强刷一次,成功则重跑管线;仍失败=耗尽,提示升级。
            RecapLog.session.info("startProcessing: freeTrial gate miss, force-refresh credential")
            statusMessage = "正在准备免费额度…"
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await RecapCredentialProvider.shared.ensureFresh(force: true)
                    self.startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
                } catch {
                    // 区分 403 额度耗尽与网络/签发失败：离线用户不能被误报成「额度耗尽」误导升级。
                    self.statusMessage = Self.quotaFailureMessage(error)
                    self.finishReviewWithoutMock()
                }
            }
        } else if AIServiceMode.current == .recapCloud, RecapAccountStore.current.tier == .pro {
            // Pro token 瞬时未就绪(冷启动/续签空窗):强刷一次,成功则重跑管线;仍失败进 review。
            RecapLog.session.info("startProcessing: recapCloud(Pro) gate miss, force-refresh credential")
            statusMessage = "正在准备 Pro 凭证…"
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await RecapCredentialProvider.shared.ensureFresh(force: true)
                    self.startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
                } catch {
                    self.statusMessage = "Pro 凭证准备失败，请检查网络后重试"
                    self.finishReviewWithoutMock()
                }
            }
        } else if AIServiceMode.current == .recapCloud, RecapAccountStore.current.tier != .pro {
            // Pro 失效但 mode 仍停在 recapCloud(降级漂移态):自愈回落免费档并重跑。
            // 根因兜底在 MembershipStore.refreshEntitlements 降级同步;此处关闭启动竞态/旧版本残留,
            // 避免静默跳过纪要 + 误报"未配置可用的大模型密钥"。重跑后命中 freeTrial 分支强刷凭证。
            RecapLog.session.info("startProcessing: recapCloud+非Pro 漂移态,回落免费档重跑")
            AIServiceMode.current = .freeTrial
            startProcessing(persistTodos: persistTodos, persistSummary: persistSummary)
        } else {
            RecapLog.session.error("startProcessing: 闸门失败（无可用大模型密钥）→ 直接进 review，无纪要")
            statusMessage = "未配置可用的大模型密钥（设置 → 大模型）"
            finishReviewWithoutMock()
        }
    }

    /// 管线首个活跃阶段打点（重转→梳理串联时取最早，耗时口径对用户更诚实）。
    private func markPipelineStarted() {
        if pipelineStartedAt == nil { pipelineStartedAt = Date() }
    }

    private func startLLMProcessing(persistTodos: @escaping ([TodoListPayload.Item]) -> Void,
                                    persistSummary: @escaping (MeetingSummary, String) -> Void) {
        statusMessage = "云端整理中…"
        markPipelineStarted()
        pipelineStage = .organizing
        // 注意：不要覆盖仍在跑的 endLive 收尾 task；用独立 task 承接管线
        // registryToken 在 Task 创建前生成，同一传入 defer 与 register：旧 Task 的 defer 因
        // token 不匹配不会抹掉新 Task 条目（P1-A 删除竞态写入加固）。
        let registryToken = UUID()
        let pipelineTask = Task { [weak self] in
            guard let self else { return }
            // #6b：争取后台时间让纪要管线跑完；管线结束（完成/失败/取消）即释放名额
            self.beginMinutesBackgroundTask()
            defer {
                self.endMinutesBackgroundTask()
                MinutesTaskRegistry.shared.unregister(token: registryToken, for: self.meeting.id)
            }
            var summaryText = ""
            var didCommitSummary = false
            do {
                // 每行带 [mm:ss] 时间戳（相对会议开始），让 todo 的 start_seconds 有据可依，
                // 不再依赖 TranscriptAnchor 子串回退或 LLM 幻觉。切块按行边界，前缀不破坏 chunking。
                let transcript = self.blocks.map { "[\(Self.transcriptTimestamp($0))] \($0.speaker.name)：\($0.feedText)" }
                    .joined(separator: "\n")
                let briefSummary = self.meeting.briefPromptSummary
                let momentsSummary = self.meeting.momentsPromptSummary
                let handwritingSummary = self.meeting.handwritingPromptSummary
                // P1-D: token-based 模式(recapCloud/免费档)开跑前确保凭证新鲜——2026-09-10 起
                // LLM 直联中转、凭证只承担配额闸门/滴灌锚点(ASR 仍用网关 token),但开跑前
                // 过一遍 issue 仍有计量意义。BYOK 持久密钥无需刷新；
                // 刷新失败(网络)不阻断——退回 makeCurrent，仍可用旧缓存或抛 notReady 走 catch。
                if AIServiceMode.current != .byok {
                    try? await RecapCredentialProvider.shared.ensureFresh()
                }
                let provider = try LLMProviderFactory.makeCurrent()
                self.pendingSummaryModelId = provider.summaryModel
                RecapLog.session.info("LLM 纪要: provider=\(provider.id, privacy: .public) summary=\(provider.summaryModel, privacy: .public) todo=\(provider.defaultModel, privacy: .public) 转写\(transcript.count) 字")
                var warning: String?
                // map-reduce 缺段警示（coverage）：并入 warning 统一组装——单独写 statusMessage
                // 会被 .summaryReady 的 composedReviewStatus(warning) 覆盖，缺段在 REVIEW 全程不可见。
                var coverageNote: String?
                func combinedWarning() -> String? {
                    let parts = [warning, coverageNote].compactMap { note -> String? in
                        guard let note, !note.isEmpty else { return nil }
                        return note
                    }
                    return parts.isEmpty ? nil : parts.joined(separator: "；")
                }
                for try await event in MinutesPipeline(provider: provider).run(
                    transcript: transcript,
                    briefSummary: briefSummary,
                    momentsSummary: momentsSummary,
                    handwritingSummary: handwritingSummary,
                    scenario: TemplateScenario.infer(title: self.meeting.title),
                    language: self.meeting.language
                ) {
                    if Task.isCancelled { return }
                    switch event {
                    case .summaryDelta(let d):
                        // 首段摘要到达 → 进入「生成纪要」阶段：赋值并入下方节流草稿事务
                        //（首个 delta 恒过节流，阶段推进时机不变；裸赋值与草稿事务同帧
                        // 双提交会让在屏 glassEffect 视图一帧多更）。
                        let enteringGenerating = self.pipelineStage != .generating
                        summaryText = Self.mergeStreamText(existing: summaryText, incoming: d)
                        // 节流：逐 delta 全量解析 + 重赋 @Published summary 会随流式长度 O(n²) 重渲。
                        // 限频 ~120ms 出草稿；最终态由 .summaryReady / .finished 的 commitAISummary 全量兜底。
                        let now = Date()
                        if self.lastSummaryDraftAt.map({ now.timeIntervalSince($0) >= Self.summaryDraftThrottle }) ?? true {
                            self.lastSummaryDraftAt = now
                            self.applySummaryDraft(summaryText, enteringGenerating: enteringGenerating)
                        }
                    case .summaryReady(let full):
                        summaryText = full
                        self.commitAISummary(raw: full, persistSummary: persistSummary)
                        didCommitSummary = true
                        self.statusMessage = self.composedReviewStatus(combinedWarning())
                    case .todos(let items):
                        persistTodos(items)
                        // 同 applySummaryDraft：todoCount + revealStep 合一事务，避免同帧多事务。
                        withAnimation(.easeOut(duration: 0.24)) {
                            self.todoCount = items.count
                            if !items.isEmpty, self.revealStep < 4 { self.revealStep = 4 }
                        }
                    case .coverage(let note):
                        coverageNote = note
                        self.statusMessage = note
                    case .finished:
                        if !didCommitSummary {
                            if !summaryText.isEmpty {
                                self.commitAISummary(raw: summaryText, persistSummary: persistSummary)
                                self.statusMessage = self.composedReviewStatus(combinedWarning())
                            } else {
                                self.statusMessage = self.composedReviewStatus(combinedWarning(), fallback: "未生成纪要")
                                self.finishReviewWithoutMock()
                            }
                        } else if self.phase != .review {
                            self.finishReviewWithoutMock()
                        }
                    case .failed(let msg):
                        warning = msg
                        self.statusMessage = self.composedReviewStatus(msg)
                        if summaryText.isEmpty, !didCommitSummary {
                            self.finishReviewWithoutMock()
                        }
                    }
                }
            } catch {
                // 取消（含删除会议触发的 cancel）时不写回部分结果，避免把纪要复活到已删除的会议
                if Task.isCancelled { return }
                RecapLog.session.error("纪要管线异常: \(error.localizedDescription, privacy: .public)")
                if !didCommitSummary, !summaryText.isEmpty {
                    self.commitAISummary(raw: summaryText, persistSummary: persistSummary)
                    self.statusMessage = self.composedReviewStatus("纪要已生成，部分后续步骤未完成（可重试）")
                } else if !didCommitSummary {
                    self.statusMessage = self.composedReviewStatus("纪要生成失败，请检查网络或大模型密钥后重试")
                    self.finishReviewWithoutMock()
                }
            }
        }
        revealTask = pipelineTask
        // 句柄随详情页释放后不可达；额外登记到全局表，供首页删除时按 id 取消管线
        MinutesTaskRegistry.shared.register(pipelineTask, token: registryToken, for: meeting.id)
    }

    /// 纪要收尾的 statusMessage 组装：管线警告（或兜底文案）＋ 自动云端精转未兑现的
    /// 一次性说明（fallbackNote）。「不静默」半边的唯一出口，避免散落各处再漂移。
    private func composedReviewStatus(_ warning: String?, fallback: String = "") -> String {
        var parts: [String] = []
        if let warning, !warning.isEmpty {
            parts.append(warning)
        } else if !fallback.isEmpty {
            parts.append(fallback)
        }
        if let note = autoRetranscribeFallbackNote, !note.isEmpty {
            parts.append(note)
        }
        return parts.joined(separator: "；")
    }

    /// 将模型 Markdown 拆成短标题 / tldr / 议题 / 决议 / 未决，并进入 review。
    private func commitAISummary(raw: String,
                                 persistSummary: @escaping (MeetingSummary, String) -> Void) {
        // 防御：管线外路径（未来直调）同样受删除守卫约束；管线路径本就不该在删除后到达。
        guard meetingIsWritable else { return }
        // 写回安全由 startLLMProcessing 的 catch（Task.isCancelled 不写回）+ MinutesTaskRegistry
        // 删除时前置 cancel 保证：管线与删除同在 MainActor 串行，cancel 早于 context.delete。
        let parsed = MinutesMarkdownParser.parse(raw)
        if AIServiceMode.current == .freeTrial { FreeTrialQuota.incrementUsed() }
        persistSummary(parsed.summary, raw)
        // 单事务收束：旧码同 tick 连发 setStep(2/3/4/5)+phase 四五个事务，中间值从未渲染
        // 却让在屏 glassEffect 视图一帧多更。净效果不变——连续 setStep 的最终值恒为 5
        //（2/3/4 的条件在覆盖序下不改变结局），revealStep 与 phase 共享 recapSheet 过场。
        // summary/标题的裸赋值一并并入：事务外赋值与过场同帧双提交是上一轮收束的漏网。
        withAnimation(.recapSheet) {
            summary = parsed.summary
            if let title = parsed.title {
                meeting.adoptGeneratedTitle(title)
            }
            revealStep = 5
            if meeting.phase != .review { meeting.phase = .review }
            if phase != .review { phase = .review }
        }
        pipelineStartedAt = nil
        // phase 改 .review 立即落盘：管线可能在用户离屏后跑完（bg task），
        // 若后续无润色/分离触发 save，DB 会停留 .processing，首页一直显示「处理中」。
        checkpointSaver?()
        scheduleDiarizationIfNeeded()
        schedulePolishIfNeeded()
    }

    /// 有 Key 但管线失败且无任何纪要：进入 review，不注入演示数据。
    private func finishReviewWithoutMock() {
        // C1 第七路径：凭证强刷 catch 分支可能晚于删除到达——已删会议不写 phase/触发会后调度。
        guard meetingIsWritable else { return }
        // 单事务收束（同 commitAISummary）：catch 路径的 statusMessage 与本函数的
        // revealStep/phase 原先分属 2-3 个事务同帧到达，一帧多更。旧码先 setStep(1) 再
        // setStep(5)，中间值从未渲染，直接一步到位。
        withAnimation(.recapSheet) {
            revealStep = 5
            meeting.phase = .review
            phase = .review
        }
        pipelineStartedAt = nil
        checkpointSaver?()
        scheduleDiarizationIfNeeded()
        schedulePolishIfNeeded()
    }

    /// 有本地录音且尚未标注过说话人时，会后自动跑 SpeakerKit（失败不阻断 REVIEW）。
    private func scheduleDiarizationIfNeeded() {
        // 重转在飞时不另起分离：重转会重排分段、清分离标签，并发会浪费 + 触发 #661 CoreML 串行竞争。
        // 重转完成后会自行经 performRetranscribe 末尾的联动重新调度，不丢。
        guard !isRetranscribing else { return }
        // P0-②：有新分离意图，取消待执行的 idle 卸载（避免卸载后又立刻重新加载模型）。
        diarizerUnloadTask?.cancel()
        diarizerUnloadTask = nil
        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path) else { return }
        let alreadyLabeled = meeting.segments.contains { seg in
            guard let sid = seg.speakerId else { return false }
            return sid.hasPrefix("spk")
        }
        guard !alreadyLabeled else { return }
        diarizeTask = Task { [weak self] in await self?.diarizeFromDisk() }
    }

    /// P0-②：分离结束后延时卸载 diarizer 模型。N 秒内若再次 `scheduleDiarizationIfNeeded`
    /// 则取消本计时。卸载走 `unload()`（整体置 nil managerBox），非 `cleanup()`（半释放陷阱）。
    private func scheduleDiarizerIdleUnload(after seconds: TimeInterval = 150) {
        diarizerUnloadTask?.cancel()
        diarizerUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performDiarizerIdleUnload()
        }
    }

    /// 真正卸载：双保险——MeetingSession 侧确认无在飞分离，Diarizer actor 侧 `isInferring`
    /// 仍会兜底等待推理完成。idle 路径（默认 150s）分离必已结束，故此处基本直通。
    /// CAM++ embedder 同批（匹配推理与分离同源闲置）。
    private func performDiarizerIdleUnload() async {
        guard !isDiarizing else { return }
        await DiarizationService.activeDiarizer.unload()
        await CampPlusEmbedderProvider.shared.unload()
    }

    /// 进 REVIEW 时自动润色逐字稿（未润色过）。失败不阻断 REVIEW。
    /// 与 diarization 并发：润色走 LLM、分离走 CoreML，互不抢占。
    /// 闸门与 performPolish 同口径（ensureCanRun 在其内部）：DeepSeek keychain 条件是
    /// 润色仅支持 BYOK 时代的遗留，会把云档/免费档/非 DeepSeek BYOK 全挡在会后自动
    /// 润色之外——而导入与「重转+重生成」路径直调 performPolish 反而能润，行为分裂。
    private func schedulePolishIfNeeded() {
        guard !meeting.segments.isEmpty,
              meeting.polishedSegmentsData == nil
        else { return }
        polishTranscript()
    }

    /// 切后台 / 离开 REVIEW 时取消在跑的会后 CoreML 任务（iOS 27 #738：后台 ANE 可能被系统拒）。
    /// processing 主链除外：retranscribeTask 在 processing 态承载导入首转 /「重转+重生成」
    /// 编排——取消后无恢复路径（回前台 reschedule 只覆盖 review），页面永卡「整理中」，
    /// 重进页面从头重转、按实耗重复烧云端配额。#6a 针对的是 REVIEW 态计算任务；
    /// processing 主链改由进程级事件兜底（后台冻结回前台续跑；被杀则重进页面恢复）。
    public func cancelPostMeetingCompute() {
        if phase != .processing {
            retranscribeTask?.cancel()
            retranscribeTask = nil
        }
        diarizeTask?.cancel()
        diarizeTask = nil
        polishTask?.cancel()
        polishTask = nil
        // P0-②：离开 REVIEW/切后台时 diarizer 不再用，卸载释放 wired 内存（20-40MB）。
        // 安全：Diarizer actor 的 isInferring 会先等待在飞推理完成，再 cleanup（#unload-race）。
        diarizerUnloadTask?.cancel()
        diarizerUnloadTask = nil
        Task {
            await DiarizationService.activeDiarizer.unload()
            // CAM++ embedder 同批卸载（CoreML 常驻，游离于 diarizer 三件套之外会漏释放）
            await CampPlusEmbedderProvider.shared.unload()
        }
    }

    /// 删除会议前调用（静态按 id 反查入口）：全量取消，包括 processing 主链——写回安全由
    /// 各写点 meetingIsWritable 守卫保证，此处取消负责不烧后续 CPU/云端配额/LLM 轮次。
    public func cancelAllPostMeetingCompute() {
        retranscribeTask?.cancel()
        retranscribeTask = nil
        diarizeTask?.cancel()
        diarizeTask = nil
        polishTask?.cancel()
        polishTask = nil
        diarizerUnloadTask?.cancel()
        diarizerUnloadTask = nil
        Task {
            await DiarizationService.activeDiarizer.unload()
            // CAM++ embedder 同批卸载（CoreML 常驻，游离于 diarizer 三件套之外会漏释放）
            await CampPlusEmbedderProvider.shared.unload()
        }
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
    /// 成功/取消静默：进行中由转写 Tab inline 进度（isPolishing）呈现，完成由优化稿单行呈现；
    /// 仅失败写 statusMessage。用户主动入口由调用方切到转写 Tab 以见 inline 进度。
    public func polishTranscript() {
        // 防重入：不与在飞润色/重转并发（重转会清 polished 并重排，运行中润色纯属浪费 + 数据竞争）。
        guard !isPolishing, !isRetranscribing else { return }
        // 同步置位：堵住「两次点击间 Task 尚未起跑」的竞态窗口。
        isPolishing = true
        polishTask = Task { [weak self] in await self?.performPolish() }
    }

    private func performPolish() async {
        // flag 由 polishTranscript 同步置位；此处兜底清零（含 thermal/空 source/取消/失败所有路径）。
        defer { isPolishing = false }
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
        // 配额闸门（与纪要管线同构）：免费档缓存空则强刷=触发网关 LLM 桶扣减/403；BYOK/Cloud 未配置给文案。
        let gate = await MinutesPipelineSmoke.ensureCanRun()
        guard gate.available else {
            statusMessage = gate.message ?? "原稿优化不可用"
            return
        }
        do {
            let provider = try await Task.detached(priority: .userInitiated) {
                try LLMProviderFactory.makeDefaultDeepSeek()
            }.value
            // 模型名与 Agent 传输层同源：云档用网关下发的 qwen 模型（显式传 deepSeek 名
            // 会打到 dashscope 端点 400，云端档润色整体不可用）；BYOK DeepSeek 才是 flash。
            let polishModel = AgentTransportFactory.modelName(
                for: LLMSelection.selectedTemplate, role: .quick)
            // 润色语言跟随转写语言（英文会议走英文润色 prompt，避免中文提示词强扭英文文本）。
            let polisher = TranscriptPolisher { system, user in
                provider.streamText(system: system, user: user,
                                     model: polishModel, temperature: 0.1)
            }
            let polished = try await polisher.polish(source, hints: liveContextualHints, language: meeting.language)
            // 删除竞态：润色是分钟级 LLM 流式，期间会议可能已删除——不可再写 meeting
            guard meetingIsWritable else { return }
            meeting.polishedSegmentsData = try? JSONEncoder().encode(polished)
            meeting.polishedModelId = polishModel
            // 用「当前」meeting.segments 重建，而非开跑时的 source 快照：polish 与 diarization 并发，
            // source 可能在 LLM 期间被 diarization 写入 speakerId 前抓取；用 source 会用过期无 speaker
            // 的快照覆盖已分离的说话人。diarization 只给同 id 段加 speakerId、不改结构，故取当前安全。
            adoptSegmentsAsBlocks(meeting.segments)   // 重新构造 blocks，这次 polished 有值 → 优化稿单行
            checkpointSaver?()
            // 免费档扣本地 UX 计数（与 commitAISummary 一致；权威在网关签发）
            if AIServiceMode.current == .freeTrial { FreeTrialQuota.incrementUsed() }
            // 成功静默：优化稿已自然呈现，转写 Tab inline 进度收尾即隐
        } catch is CancellationError {
            // 取消静默（用户切走 / 后台取消）
        } catch {
            RecapLog.session.error("原稿优化失败: \(error.localizedDescription, privacy: .public)")
            statusMessage = "原稿优化失败，请检查网络或大模型密钥后重试"
        }
    }

#if DEBUG
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
                      due_text: "周五", confidence: 0.9,
                      evidence_quote: "那我周五之前把评审方案弄出来",
                      start_seconds: 50),
                .init(task: "确认客户报价", owner: "张明", owner_source: "inferred",
                      due_text: nil, confidence: 0.45,
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
#endif

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
        // 递增代际：作废所有在飞的异步周期检查点。所有直写方（pause/endLive/diarize/重转回填）
        // 都经本函数，若不递增，在飞检查点的旧快照完成回调可通过代际校验，用 T0 快照
        // 覆盖刚写入的方言重转/分离结果（UI 显示新稿、DB 是旧稿，重进会议即回退）。
        checkpointGeneration += 1
        meeting.durationSeconds = Double(max(elapsed, Int(meeting.durationSeconds), 1))
        meeting.segments = Self.segments(from: blocks)
        // 说话人列表：已有 spk* 时保留；否则从 blocks 汇总（过滤 fallback "?" / "asr-live"，
        // 避免把未标注占位写成真实说话人）
        if meeting.speakers.isEmpty || !meeting.speakers.contains(where: { $0.id.hasPrefix("spk") }) {
            let unique = blocks.map(\.speaker).filter { $0.id != "?" && $0.id != "asr-live" }
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
        powerCancellable?.cancel()
        powerCancellable = nil
        // 勿取消 revealTask：processing 中离场由 004/后续策略处理；此处仅停 LIVE 采集
        if phase == .live {
            revealTask?.cancel()
        }
        endingLive = false
        setIdleTimerDisabled(false)
        liveEpoch += 1
        if let recording, recording.isRunning {
            // 后台停录：不阻塞离场；结果由 teardownStopTask 串行化——新开麦/endLive 会先 await 它，
            // 避免同一 PCM 文件双写损坏母带（旧句柄残余写 + 新句柄 seekToEnd 追加交错）。
            teardownStopTask = Task {
                _ = try? await recording.stop()
            }
        }
        recording = nil
    }

    /// 离场/切后台后台停录的任务：新开麦 / endLive 读盘前必须等它落地——
    /// 同一 audio.pcm 若被两个 FileHandle 交错写（旧句柄残余写 + 新句柄追加）会损坏母带。
    private var teardownStopTask: Task<Void, Never>?
    /// LIVE 引擎启动代际：pause/endLive/teardown 递增。startRecordingOrMock 在
    /// `session.start` 返回后校验代际，丢弃暂停/结束之后才到达的迟到成功回调
    /// （旧实现仅靠 isLivePaused 守卫，pause 发生在 guard 之后会错误复位 isLivePaused=false
    /// 并续接已被停止的旧引擎 →「假录音」）。
    private var liveEpoch: Int = 0

    /// 真正丢弃会话（会丢未保存数据）；优先用 `pauseOrTeardownForDisappear`。
    public func reset() {
        pauseOrTeardownForDisappear()
        // 兼容旧调用：不主动清空 blocks，避免误伤
    }

    private func checkpointIfNeeded(force: Bool) {
        guard phase == .live, !blocks.isEmpty else { return }
        if force {
            // 作废在飞的异步周期检查点，force 永远落最新数据。
            checkpointGeneration += 1
            persistLiveCheckpoint()
            checkpointSaver?()
            return
        }
        // segment 高频路径：最多约 10s 落一次（5s 与 10s 对崩溃恢复的丢字差异可忽略）。
        // 全量 JSON encode 移出主线程——长会议数千段时，10s 一次的主线程 encode 是卡顿源；
        // pause / endLive 仍走上面的 force 同步落盘，末段不丢、顺序有保证。
        if let last = lastCheckpointAt, Date().timeIntervalSince(last) < 10 { return }
        lastCheckpointAt = Date()
        checkpointGeneration += 1
        let generation = checkpointGeneration
        let blocksSnapshot = blocks
        Task { [weak self] in
            let payload = await Task.detached(priority: .utility) { () -> (Data, [TranscriptSegment])? in
                let segments = Self.segments(from: blocksSnapshot)
                guard let data = try? JSONEncoder().encode(segments) else { return nil }
                return (data, segments)
            }.value
            guard !Task.isCancelled, let self, generation == self.checkpointGeneration,
                  self.phase == .live, self.meetingIsWritable,
                  let (data, segments) = payload else { return }
            self.meeting.durationSeconds = Double(max(self.elapsed, Int(self.meeting.durationSeconds), 1))
            self.meeting.adoptPreencodedSegments(data, decoded: segments)
            if self.meeting.speakers.isEmpty
                || !self.meeting.speakers.contains(where: { $0.id.hasPrefix("spk") }) {
                let unique = blocksSnapshot.map(\.speaker).filter { $0.id != "?" && $0.id != "asr-live" }
                var seen = Set<String>()
                self.meeting.speakers = unique.filter { seen.insert($0.id).inserted }
            }
            self.checkpointSaver?()
        }
    }

    /// 字幕检查点落库失败上报（60s 限频）：磁盘满时安全网已失效——进程被杀会丢本段字幕，
    /// 必须让用户知情（对齐 AudioRecorder `.diskWriteFailed` 的上报取向），而非静默吞掉。
    public func reportCheckpointSaveFailure() {
        guard Date().timeIntervalSince(lastCheckpointFailureReportAt) > 60 else { return }
        lastCheckpointFailureReportAt = Date()
        statusMessage = "字幕自动保存失败：存储空间不足或写入失败，请尽快结束录音并手动保存"
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private func elapsedText(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    /// nonisolated：纯函数，被 nonisolated `segments(from:)` 调用（方言检测后台路径）。
    nonisolated private static func parseTimestamp(_ text: String) -> Double {
        // 纯函数（DateFormatter 局部创建）：供 nonisolated segments(from:) 后台编码路径调用。
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

/// LIVE 声波频段总线：mic tap 约 12Hz 推送，只让声波视图观察（属性级失效面收敛到单视图），
/// 不再作为 MeetingSession 的 @Published 打穿整个详情页 body。
@MainActor
public final class AudioBandBus: ObservableObject {
    @Published public var bands: AudioBands = .zero
}
