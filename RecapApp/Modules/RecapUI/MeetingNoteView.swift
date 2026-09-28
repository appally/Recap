import SwiftUI
import SwiftData
import UIKit
import AVFoundation
import RecapModels
import RecapLLM
import RecapASR
import RecapPersistence
import PencilKit

/// 纪要界面（一个屏 · 三态自适应 · @Model 直驱）。
public struct MeetingNoteView: View {
    @Bindable var meeting: Meeting
    @StateObject private var session: MeetingSession
    @Environment(\.modelContext) private var modelContext
    var onDismiss: () -> Void

    @State private var showAgent = false
    @State private var agentPrefill = ""
    /// 调研入口：从待办卡 ✦ 进来时携带的目标快照（openAgent 透传给 AgentInvokeSheet 自动发起）。
    @State private var agentResearchItem: ActionItemSnapshot?
    /// 深链：打开对话窗时滚动定位到的消息 id（预留：从草稿/switcher 跳进对话）。
    @State private var agentScrollToMessage: UUID?
    @State private var showMinutesVersions = false
    /// 对话窗下拉关闭的实时位移（橡皮筋跟随）。
    @State private var agentDragOffset: CGFloat = 0
    /// 对话窗上下文快照：openAgent 先以空快照让 sheet 轻量滑入，真实整场转写在下一 runloop 填充——
    /// 避免拼大串阻塞 spring 首帧（点击卡顿 + 动效被吞的根因）。LIVE 增长时持续推送。
    @State private var agentTranscript: String = ""
    @State private var agentSegments: [TranscriptSegment] = []
    /// LIVE 边录边问的对话窗快照刷新任务（5s 节流，见 ``scheduleAgentTranscriptRefresh()``）。
    @State private var agentTranscriptRefreshTask: Task<Void, Never>?
    /// REVIEW 正文单层 Tab：转写 / 总结（默认）/ 笔记（每条模板笔记一个独立 Tab，携带笔记 id）/ 手写。
    @State private var reviewTab: ReviewTab = .summary
    @State private var pendingScrollStart: Double?
    @State private var showTemplateSelection = false
    /// 内联生成中的模板笔记（落库前纯 UI 本地态；不进 SwiftData/NoteIndex）。
    @State private var draftingNote: DraftingNoteState?
    @State private var draftingTask: Task<Void, Never>?
    @State private var noteNoKeyError: String?
    /// noteNoKeyError 成因：true=免费额度用尽（可升级 Pro 解决）；false=BYOK 未配 Key。
    @State private var noteNoKeyErrorIsQuotaExhausted = false
    /// 额度用尽触点弹出的会员升级页。
    @State private var showMembershipUpsell = false
    @State private var showEndLiveConfirm = false
    @State private var showDeleteLiveConfirm = false
    @State private var showRegenerateSheet = false
    @State private var regenerateAlsoRetranscribe = false
    @State private var showResearchDraft = false
    @State private var selectedResearchDraft: ResearchDraft?
    @State private var researchError: String?
    /// 承诺确认 hero 卡的逐条确认 sheet（plan 053）。
    @State private var showPromiseSheet = false
    /// 解散指纹的内存镜像（UserDefaults 不驱动 body 重算；init 时从 store 读初值）。
    @State private var promiseHeroDismissal: String?
    /// 会中拍照取景 Overlay（锚定到打开瞬间的会议秒）。
    @State private var showMomentCapture = false
    @State private var momentCaptureAnchor: Int = 0
    // 声纹「标记我」（Phase 3）：跨会议识别用户本人
    @State private var showVoiceprintConsent = false
    @State private var pendingMeVoiceprintId: String?
    /// 说话人纠错 sheet（plan 047）：长按转写行说话人名弹出。
    @State private var pendingSpeakerCorrection: Speaker?
    @AppStorage("recap.voiceprint.meId") private var meVoiceprintId: String = ""
    // 「发言复盘」picker：多人未标注时让用户指认自己（transient 标签驱动；可选持久 enroll）。
    @State private var showSpeakerPicker = false
    @State private var pendingSpeakerPickSkill: AgentSkill?
    /// 会中手写全屏画布（tap 动作坞手写钮打开；PKToolPicker 在其内部浮起，不挡主界面）。
    /// drawing 真相源已下沉到 LiveHandwritingCover（每笔画不再打穿本 View 巨 body）。
    @State private var showLiveHandwriting = false
    /// 会后「手写」tab 续写编辑器（drawing 真相源在 ReviewHandwritingEditorContainer 内）。
    @State private var showHandwritingEditor = false
    /// 全屏图库当前查看的会议时刻。
    @State private var galleryMoment: Moment?
    /// 完成 → 纪要的收束桥：字幕残影 + 控件退场（不入库）。
    @State private var isSettling = false
    /// REVIEW 底栏延迟滑入，避免与 Settling 抢戏。
    @State private var showReviewBottom = false
    /// LIVE：贴底才自动跟随；上滑回看后停跟，需点「回到最新」。
    @State private var isFollowingLive = true
    @State private var missedLiveBlocks = 0
    /// LIVE 顶部提示条（方言口音）短暂展示后自动收起：
    /// 预告信息只在其出现时刻告知一次（读两行字约 4s，给 6s 余量），
    /// 结束确认弹窗的动态文案兜底——「降级可见」不靠常驻色块实现。
    @State private var liveHintVisible = false
    @State private var liveHintDismissTask: Task<Void, Never>?
    /// 滚动几何中转存储（仅事件回调读写，不参与 body 渲染）：
    /// 写 @State 会让滚动逐帧打穿整个详情页 body（ProMotion 120Hz）。
    @State private var scrollBox = ScrollStateBox()
    /// 程序化 scrollTo 期间忽略几何回调，避免误判「离开底部」。
    @State private var suppressLiveFollowUpdate = false
    /// REVIEW 顶栏隐藏态：上滑阅读时隐藏标题+Tab 区，只留返回钮（极简式）。
    /// 方向驱动：下滑->隐藏、上滑/回顶->显示。仅 REVIEW 阅读态驱动。
    @State private var reviewHeaderHidden = false
    @StateObject private var audioPlayer = MeetingAudioPlayer()
    /// 回听高亮：跨块才发布（收敛 player 4Hz 进度流），播放中不再逐帧重算整页 body。
    @StateObject private var listeningHighlight = ListeningBlockHighlight()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Tab 滑动指示器：跨标签共享命名空间，选中态切换时下划线整体滑过，而非两端各自淡入淡出。
    @Namespace private var reviewTabNS
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private var researchRunner: AgentTaskRunner { AgentTaskRunner.shared }

    public init(
        meeting: Meeting,
        initialScrollStart: Double? = nil,
        initialNoteTarget: NoteTarget? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.meeting = meeting
        self.onDismiss = onDismiss
        _session = StateObject(wrappedValue: MeetingSession(meeting: meeting))
        // 精确跳转初值：noteTarget → reviewTab=.note(id) / .summary；scrollStart → reviewTab=.transcript。
        // 单一真相源（不再需要 selectedNote 配对——每条笔记自带 id）。
        if let initialNoteTarget {
            switch initialNoteTarget {
            case .note(let id):
                _reviewTab = State(initialValue: .note(id))
            case .summary:
                _reviewTab = State(initialValue: .summary)
            case .researchDraft(_), .researchTask(_):
                // 深链不会带调研目标（搜索仅产 .note/.summary）；兜底回落总结。
                _reviewTab = State(initialValue: .summary)
            }
        } else if let initialScrollStart {
            _pendingScrollStart = State(initialValue: initialScrollStart)
            _reviewTab = State(initialValue: .transcript)
        }
        // 解散态跨启动持久（plan 053）：init 直读 store，绕过 UserDefaults 不驱动重算的问题。
        _promiseHeroDismissal = State(initialValue: PromiseHeroDismissalStore.dismissedFingerprint(for: meeting.id))
    }

    private var sortedItems: [ActionItem] {
        meeting.actionItems.sorted { a, b in
            if a.isLowConfidence != b.isLowConfidence { return a.isLowConfidence && !b.isLowConfidence }
            return (a.startSeconds ?? 0) < (b.startSeconds ?? 0)
        }
    }

    // MARK: 承诺确认 hero（plan 053）

    /// 待确认承诺（draft 态）：hero 卡与确认 sheet 的同一数据源。
    private var promiseDrafts: [ActionItem] {
        meeting.actionItems.filter { $0.status == .draft }
    }

    /// 仅 review 态出现（整理/飞升流式期间不抢戏）；解散判定见 `PromiseHeroGate`。
    private var promiseHeroVisible: Bool {
        guard session.phase == .review else { return false }
        let gate = PromiseHeroGate(
            draftIDs: promiseDrafts.map(\.id),
            dismissedFingerprint: promiseHeroDismissal
        )
        return gate.isVisible
    }

    private func dismissPromiseHero() {
        let gate = PromiseHeroGate(draftIDs: promiseDrafts.map(\.id), dismissedFingerprint: nil)
        Haptics.selection()
        PromiseHeroDismissalStore.dismiss(gate.fingerprint, for: meeting.id)
        withAnimation(reduceMotion ? nil : .recapSoft) {
            promiseHeroDismissal = gate.fingerprint
        }
    }

    private var transcriptContext: String {
        if !session.blocks.isEmpty {
            return session.blocks.map { "\($0.speaker.name)：\($0.raw)" }.joined(separator: "\n")
        }
        return meeting.segments.map { seg in
            let name = meeting.speakers.first(where: { $0.id == seg.speakerId })?.name ?? "?"
            return "\(name)：\(seg.text)"
        }.joined(separator: "\n")
    }

    private var askSegments: [TranscriptSegment] {
        if !meeting.segments.isEmpty { return meeting.segments }
        return session.blocks.map {
            let start = $0.startSeconds ?? Self.parseTimestamp($0.timestamp)
            return TranscriptSegment(
                startSeconds: start,
                endSeconds: $0.endSeconds ?? start,
                speakerId: $0.speaker.id,
                text: $0.raw
            )
        }
    }

    /// LIVE 边录边问的对话窗快照刷新（节流 + 后台重拼）：
    /// - 逐句推送无意义——5s 节流，稳态每 5s 至多一次；对话窗已关则不刷新；
    /// - 长会议全量重拼 transcriptContext（数百 KB 字符串）+ askSegments（O(n) 数组）
    ///   移出主线程，主线程只做两次引用赋值（blocks 冷启动前数据量小，同步路径无碍）。
    private func scheduleAgentTranscriptRefresh() {
        guard agentTranscriptRefreshTask == nil else { return }
        agentTranscriptRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            agentTranscriptRefreshTask = nil
            guard showAgent, !Task.isCancelled else { return }
            let blocks = session.blocks
            if blocks.isEmpty {
                agentTranscript = transcriptContext
                agentSegments = askSegments
                return
            }
            let meetingSegments = meeting.segments
            let (text, segments): (String, [TranscriptSegment]) = await Task.detached(priority: .utility) {
                let text = blocks.map { "\($0.speaker.name)：\($0.raw)" }.joined(separator: "\n")
                let segments: [TranscriptSegment]
                if !meetingSegments.isEmpty {
                    segments = meetingSegments
                } else {
                    segments = blocks.map { block in
                        let start = block.startSeconds ?? Self.parseTimestamp(block.timestamp)
                        return TranscriptSegment(
                            startSeconds: start,
                            endSeconds: block.endSeconds ?? start,
                            speakerId: block.speaker.id,
                            text: block.raw
                        )
                    }
                }
                return (text, segments)
            }.value
            agentTranscript = text
            agentSegments = segments
        }
    }

    /// 为模板生成（`SkillNoteWriter`）构建只读 Agent 上下文（对齐 `AgentInvokeSheet` 的入参）。
    private func makeAgentToolContext() -> AgentToolContext {
        let snapshots = meeting.actionItems.map {
            ActionItemSnapshot(
                id: $0.id,
                task: $0.task,
                owner: $0.owner,
                dueText: $0.dueText,
                statusRaw: $0.status.rawValue,
                meetingTitle: meeting.title,
                isDispatched: $0.isReallyDispatched
            )
        }
        return AgentToolContext(
            meetingTitle: meeting.title,
            phase: session.phase,
            segments: askSegments,
            speakers: meeting.speakers,
            briefSources: meeting.brief?.sources ?? [],
            fallbackTranscript: transcriptContext,
            webEnabled: false,
            currentMeetingId: meeting.id,
            actionItems: snapshots,
            currentMinutes: meeting.latestSummary,
            workspace: nil
        )
    }

    public var body: some View {
        content
            // 顶栏走 safeAreaInset 而非 ZStack 浮层：ScrollView 内容自动避让（首条字幕不再依赖
            // 手动占位魔法数，Dynamic Type/文案换行天然安全）。滚动内容仍会掠过栏后方——
            // 由栏底渐变遮罩（topBarScrollFade）羽化，避免字幕与透明提示区叠印。
            .safeAreaInset(edge: .top, spacing: 0) {
                customTopBar
                    .background(topBarScrollFade)
            }
            .background(Color.recapBg.ignoresSafeArea())
        // 用 inset 而不是 ZStack 叠层，避免 ScrollView 抢走「结束」点击
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                bottomBar
            }
            .animation(settlingAnimation, value: isSettling)
            .animation(.recapPhaseBar, value: session.isLivePaused)
            .animation(.recapPhaseBar, value: session.hasStartedRecording)
            .animation(showReviewBottom ? .recapSheet : .recapBottomExit, value: showReviewBottom)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .overlay { agentOverlay }
        .onChange(of: liveHintKey) { oldKey, newKey in
            guard newKey != oldKey else { return }
            liveHintDismissTask?.cancel()
            if newKey == nil {
                withAnimation(reduceMotion ? nil : .recapNotice) { liveHintVisible = false }
                return
            }
            withAnimation(reduceMotion ? nil : .recapNotice) { liveHintVisible = true }
            liveHintDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .recapNotice) { liveHintVisible = false }
            }
        }
        .onChange(of: session.blocks.count) { _, _ in
            // LIVE 边录边问：转写增长时把新快照推给已展开的对话窗。
            // 节流 + 后台重拼（见 scheduleAgentTranscriptRefresh）：每句定稿全量重拼
            // transcriptContext（长会议数百 KB/次）在主线程是抖动源。
            guard showAgent else { return }
            scheduleAgentTranscriptRefresh()
        }
        .sheet(isPresented: $showTemplateSelection) {
            TemplateSelectionSheet(
                isPresented: $showTemplateSelection,
                meetingTitle: meeting.title,
                meeting: meeting,
                onPickSkill: { skill in
                    showTemplateSelection = false
                    startNoteDrafting(skill)
                }
            )
        }
        .sheet(isPresented: $showSpeakerPicker) {
            SpeakerPickerSheet(
                speakers: meeting.speakers,
                previews: speakerFirstUtterances(),
                onConfirm: { speaker, rememberMe in
                    handleSpeakerPick(speaker, rememberMe: rememberMe)
                }
            )
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showMinutesVersions) {
            MinutesVersionsSheet(meeting: meeting) { output in
                let bridge = ReviseMinutesBridge()
                bridge.meeting = meeting
                bridge.modelContext = modelContext
                if let result = bridge.rollback(to: output) {
                    session.summary = result.summary
                }
            }
        }
        .sheet(isPresented: $showResearchDraft) {
            if let draft = selectedResearchDraft {
                ResearchDraftSheet(
                    draft: draft,
                    onJumpToTranscript: { start in jumpToTranscript(startSeconds: start) }
                )
                .presentationBackground(Color.recapBg)
            }
        }
        .sheet(isPresented: $showPromiseSheet) {
            // 卡片装配与总结 Tab 待办区完全同一套回调（plan 053：不复制确认/分发逻辑）。
            // sheet 内触发跳转/调研/Agent 前先收起自己，避免多 sheet 抢占不弹。
            PromiseConfirmSheet(drafts: promiseDrafts, isPresented: $showPromiseSheet) { item in
                ActionItemCard(
                    item: item,
                    speakers: meeting.speakers,
                    meetingTitle: meeting.title,
                    onJumpToSource: { start in
                        showPromiseSheet = false
                        jumpToTranscript(startSeconds: start)
                    },
                    onResearchFollowUp: {
                        showPromiseSheet = false
                        startResearch(for: item)
                    },
                    hasResearchDraft: researchDraft(for: item) != nil,
                    onOpenResearchDraft: {
                        if let draft = researchDraft(for: item) {
                            showPromiseSheet = false
                            selectedResearchDraft = draft
                            showResearchDraft = true
                        }
                    },
                    hasResearchInProgress: researchInProgress(for: item) != nil,
                    onOpenResearchProgress: {
                        if let task = researchInProgress(for: item) {
                            showPromiseSheet = false
                            openResearchProgress(taskId: task.id)
                        }
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showMomentCapture) {
            MomentCaptureOverlay(
                meeting: meeting,
                anchorElapsed: momentCaptureAnchor,
                onComplete: { showMomentCapture = false }
            )
            .interactiveDismissDisabled(true)
        }
        .fullScreenCover(isPresented: $showLiveHandwriting) {
            liveHandwritingCover
        }
        .sheet(item: $galleryMoment) { moment in
            MomentGalleryView(
                moment: moment,
                onSeek: {
                    openAudioPlayer(seekTo: moment.startSeconds, autoplay: true)
                    galleryMoment = nil
                },
                onDismiss: { galleryMoment = nil }
            )
            .presentationDetents([.large])
        }
        .sheet(item: $pendingSpeakerCorrection) { speaker in
            SpeakerDetailSheet(
                speaker: speaker,
                allSpeakers: meeting.speakers,
                meeting: meeting,
                session: session,
                onAskRecap: { name in
                    // plan 051：dismiss sheet 后带 prefill 打开对话窗，autoSendInitial 自动发问；
                    // 模型经 search_meetings(名字) → get_meeting_transcript 完成跨会检索
                    // （rankerFields 已含 speaker 维度）。
                    openAgent(prefill: "上次和「\(name)」聊了什么？TA 当时答应过什么、还有哪些遗留问题没有解决？")
                }
            )
        }
        .sheet(item: $exportPayload) { payload in
            ExportActivitySheet(url: payload.url)
        }
        .alert("导出失败", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .sheet(isPresented: $showVoiceprintConsent) {
            VoiceprintConsentSheet {
                VoiceprintConsent.granted = true
                if let vp = pendingMeVoiceprintId {
                    VoiceprintGallery.shared.markAsMe(voiceprintId: vp, name: "我")
                    meVoiceprintId = vp
                }
                pendingMeVoiceprintId = nil
                showVoiceprintConsent = false
            }
            .presentationDetents([.large])
        }
        .alert("无法开始调研", isPresented: Binding(
            get: { researchError != nil },
            set: { if !$0 { researchError = nil } }
        )) {
            Button("好", role: .cancel) { researchError = nil }
        } message: {
            Text(researchError ?? "")
        }
        .alert("无法生成笔记", isPresented: Binding(
            get: { noteNoKeyError != nil },
            set: { if !$0 { noteNoKeyError = nil; noteNoKeyErrorIsQuotaExhausted = false } }
        )) {
            if noteNoKeyErrorIsQuotaExhausted {
                Button("升级 Pro") {
                    noteNoKeyError = nil
                    showMembershipUpsell = true
                }
            }
            Button("好", role: .cancel) { noteNoKeyError = nil }
        } message: {
            Text(noteNoKeyError ?? "")
        }
        .sheet(isPresented: $showMembershipUpsell) {
            NavigationStack {
                MembershipSettingsView()
            }
        }
        // alert 避开 iOS 26 confirmationDialog 的 GlassPopover 约束冲突
        .alert("结束录音？", isPresented: $showEndLiveConfirm) {
            Button("结束并整理纪要", role: .destructive) {
                endLive()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(endLiveConfirmMessage)
        }
        .alert("删除本场？", isPresented: $showDeleteLiveConfirm) {
            Button("删除", role: .destructive) {
                deleteLiveMeeting()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("录音、字幕与纪要将从本机永久删除，且无法恢复。也可在首页列表左滑删除。")
        }
        .sheet(isPresented: $showRegenerateSheet) {
            RegenerateConfirmSheet(
                hasAudio: meeting.audioPath != nil,
                alsoRetranscribe: $regenerateAlsoRetranscribe,
                onConfirm: {
                    showRegenerateSheet = false
                    if regenerateAlsoRetranscribe {
                        session.regenerateWithRetranscribe(
                            clearDraftTodos: clearDraftTodos,
                            persistTodos: persistTodos,
                            persistSummary: persistSummary
                        )
                    } else {
                        regenerateSummary()
                    }
                    regenerateAlsoRetranscribe = false
                },
                onCancel: { showRegenerateSheet = false }
            )
            .presentationDetents([.medium, .large])
        }
        .task {
            // 用 task 而非 onAppear：等视图进入层级后再启动，减少转场卡顿
            refreshListeningBoundaries()
            session.checkpointSaver = { [modelContext, weak session] in
                do {
                    try modelContext.save()
                } catch {
                    // 磁盘满等保存失败：字幕安全网已失效（进程被杀会丢本段），必须让用户知情。
                    session?.reportCheckpointSaveFailure()
                }
            }
            researchRunner.bind(modelContext: modelContext)
            session.onAppear()
            if session.phase == .review {
                showReviewBottom = true
            }
            if meeting.phase == .processing || session.phase == .processing {
                session.resumeOrRecoverProcessing(
                    clearDraftTodos: clearDraftTodos,
                    persistTodos: persistTodos,
                    persistSummary: persistSummary
                )
            }
        }
        .onChange(of: session.phase) { _, phase in
            switch phase {
            case .review:
                // 纪要落定是产品最重要的「成果交付」瞬间：一次明确的 success。
                // onChange 仅在值变化时触发，重进已 review 的会议不会重复震。
                Haptics.notify(.success)
                withAnimation(.recapSheet) { showReviewBottom = true }
                // 进 REVIEW：转写已定稿（重转/润色收尾），刷新回听高亮的块起点表。
                refreshListeningBoundaries()
            case .live:
                showReviewBottom = false
                isSettling = false
                isFollowingLive = true
                missedLiveBlocks = 0
            case .processing:
                showReviewBottom = false
                // meeting 离开 REVIEW；AgentToolContext 用旧 phase 捕获，取消进行中的笔记草稿
                draftingTask?.cancel()
                draftingNote = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            researchRunner.handleScenePhase(phase)
            switch phase {
            case .background:
                // #6a：后台取消会后 CoreML 重负载（ANE 后台可能被系统拒）；LLM 纪要管线由自身 bg task 保护
                session.cancelPostMeetingCompute()
                // LIVE：只落检查点不停麦——UIBackgroundModes=audio 保证切 App/锁屏持续录音；
                // 来电等中断由 AudioRecorder 自愈。手动暂停态不受影响。
                session.checkpointForBackgroundIfLive()
            case .active:
                // #6a：回前台重排被后台取消的会后任务（幂等：已完成/在跑均跳过）
                session.reschedulePostMeetingCompute()
            default:
                break
            }
        }
        .onDisappear { teardownOnDisappear() }
    }

    private var settlingAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.2)
            : .recapSheet
    }

    /// 整理态主句：短、疏、不喊话。
    private var processHeroTitle: String {
        MinutesPipelineSmoke.canRunMinutesPipeline ? "整理中" : "已保存"
    }

    /// 仅无可用模型/额度耗尽时给次行引导；正常处理时保持纯净专注，留给阶段动效。
    /// 按模式分文案：BYOK=真「未配置」；recapCloud 凭证空窗是瞬时态（startProcessing
    /// 会强刷重试），指引「去设置配置模型」对 Pro 用户是误导。
    private var processHeroSubtitle: String? {
        if AIServiceMode.current == .freeTrial {
            return MinutesPipelineSmoke.canRunMinutesPipeline
                ? nil
                : "免费额度已用完，可在设置中改用自备密钥（免费）"
        }
        if AIServiceMode.current == .recapCloud {
            return MinutesPipelineSmoke.canRunMinutesPipeline
                ? nil
                : "Pro 凭证准备中，将自动重试…"
        }
        return MinutesPipelineSmoke.canRunMinutesPipeline
            ? nil
            : "去设置配置模型后可生成纪要"
    }

    private var hasLocalAudio: Bool {
        guard let path = meeting.audioPath else { return false }
        return MeetingAudioStore.fileExists(storedPath: path)
    }

    // MARK: Top bar

    /// 自绘顶栏。LIVE = Transport Bar（暂停·状态簇·停止，声波居中连接）；REVIEW = 返回·标题·分享+更多。
    /// REVIEW 顶栏滚动收起判定（Safari 式方向驱动）：
    /// REVIEW 顶栏隐藏判定（方向驱动）：
    /// 回顶->显示；下滑（上滑阅读）->隐藏；上滑（回看顶部方向）->显示。
    /// 仅翻转布尔，动画交给视图层 `.animation(value:)`，滚动热路径不做 withAnimation。
    private func applyReviewHeaderHidden(offsetY: CGFloat) {
        let last = scrollBox.lastReviewScrollY
        scrollBox.lastReviewScrollY = offsetY
        // 内容尺寸突变（切 Tab 等）会让 offset 跳变，忽略这种非用户滚动的大 delta
        if abs(offsetY - last) > 150 { return }

        // 1. 回到顶部：强制显示顶栏与 Tab 栏
        if offsetY <= 0 {
            if reviewHeaderHidden {
                reviewHeaderHidden = false
            }
            return
        }

        // 2. 方向驱动（Safari 式）：隐藏 / 恢复用对称阈值 8，消除原版「易藏难显」
        //    （原隐藏 delta>6、恢复 delta>15 不对称）与 8<offsetY≤30 死区。
        let delta = offsetY - last
        if delta > 8 {
            if !reviewHeaderHidden { reviewHeaderHidden = true }   // 下滚 → 隐藏
        } else if delta < -8 {
            if reviewHeaderHidden { reviewHeaderHidden = false }    // 上滚 → 恢复
        }
    }

    /// 顶栏滚动渐隐遮罩：滚动内容掠过栏后方时，被纸色渐变从上往下逐渐放行（栏上半全遮、
    /// 下半渐透、出栏完全显现）。替代「透明区直穿」的叠印——遮罩高度天然等于栏高
    /// （safeAreaInset 自适应），无手动对齐值。
    private var topBarScrollFade: some View {
        LinearGradient(
            stops: [
                .init(color: Color.recapBg, location: 0.0),
                .init(color: Color.recapBg.opacity(0.94), location: 0.62),
                .init(color: Color.recapBg.opacity(0), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private var customTopBar: some View {
        let isLiveInteractive = session.phase == .live && !isSettling
        return VStack(spacing: Spacing.xs) {
            if session.phase == .review {
                reviewTopBar
                    .transition(.opacity)
            } else if isLiveInteractive {
                liveTransportBar
                    .transition(.opacity.combined(with: .move(edge: .top)))
                // 方言口音提示：端侧误识方言时短暂展示（出现时刻告知一次，6s 后自动收起，
                // 常驻语义由结束确认弹窗的动态文案承接——降级可见但不打扰）。
                // 云端精转预告不在此出条：录音中不暴露引擎概念（2026-09-02），承诺由
                // 结束弹窗动态文案（endLiveConfirmMessage）在真正相关的时刻承接。
                if session.liveDialectSuspected && liveHintVisible {
                    DialectHintBar()
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // 在场声纹 chips（plan 055，flag+同意门控）：「在场：王总 · 还有未识别的声音」。
                // 首个命中落地前不渲染（避免空态噪音）；暂停期间保留（人还在屋里）。
                if !session.livePresence.isEmpty || session.livePresenceHasUnknown {
                    LivePresenceChips(
                        entries: session.livePresence,
                        hasUnknown: session.livePresenceHasUnknown
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                // 「听起来像 TA」轻提示（plan 055）：每画廊条目每场至多一次
                if let prompt = session.liveVoicePrompt {
                    LiveVoicePromptBar(
                        name: prompt.name,
                        onConfirm: { session.resolveLiveVoicePrompt(voiceprintId: prompt.voiceprintId, accepted: true) },
                        onDeny: { session.resolveLiveVoicePrompt(voiceprintId: prompt.voiceprintId, accepted: false) }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .animation(reduceMotion ? nil : .recapSoft, value: reviewHeaderHidden)
        .animation(reduceMotion ? nil : .recapSoft, value: session.phase)
        .animation(reduceMotion ? nil : .recapSoft, value: isSettling)
        .animation(reduceMotion ? nil : .recapNotice, value: liveHintVisible)
        .animation(reduceMotion ? nil : .recapNotice, value: liveHintKey)
        // plan 055：在场 chips / 轻提示 进出场
        .animation(reduceMotion ? nil : .recapSoft, value: session.livePresence)
        .animation(reduceMotion ? nil : .recapSoft, value: session.liveVoicePrompt)
    }

    /// LIVE「Transport Bar」：左·状态胶囊(呼吸点+时长，点按收起) · 右·控制胶囊(暂停+停止)，两颗玻璃胶囊成对；
    /// 下方一条全宽声波带把两者视觉连成一体。无最小化钮/更多入口——退出靠点状态或下拉（抓手暗示）。
    /// 声波带行壳：单独观察频段总线，播放器频段更新只失效本视图。
    private struct LiveWaveformBandHost: View {
        @ObservedObject var bus: AudioBandBus
        let isPaused: Bool

        var body: some View {
            LiveWaveformVisualizer(
                isPaused: isPaused,
                bands: bus.bands,
                isCompact: true
            )
        }
    }

    private var liveTransportBar: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                liveTransportStatus
                Spacer(minLength: 0)
                // 暂停 + 停止 收进单根 Liquid Glass 胶囊，成对成组（不分两侧）
                liveTransportControls
            }

            // 全宽声波带：屏内唯一声波，视觉上连接左状态与右控制组。
            // 只让本视图观察频段总线（12Hz 失效面收敛到声波自身，不打穿整页 body）。
            LiveWaveformBandHost(bus: session.liveAudioBandBus, isPaused: session.isLivePaused)
            // 抓手 ↓ 已删（2026-09-01 顶部减负）：纯装饰且独占透明行，字幕回看时穿过后
            // 与其叠印；收起入口 = 点状态胶囊（a11y 标签「轻点收起」仍在）。
        }
    }

    /// Transport 控制组：暂停 + 停止 收进单根 Liquid Glass 胶囊，中间一根细分割线；
    /// 停止段淡朱砂底 + 朱砂图标，强调「结束」终态分量。运输键成对成组，不分两侧。
    private var liveTransportControls: some View {
        HStack(spacing: 0) {
            liveTopPauseButton
            Capsule()
                .fill(Color.recapInk.opacity(0.12))
                .frame(width: 1, height: 20)
            liveTopStopButton
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// Transport Bar 状态：呼吸点 + 录音时长，收进玻璃胶囊（与右侧控制胶囊同材质同高度，左右成对）。
    /// 点按 → 收起（替代最小化钮）。暂停/录音的文字色平滑插值，不硬切。
    private var liveTransportStatus: some View {
        Button {
            dismissFromTopBar()
        } label: {
            HStack(spacing: 7) {
                TransportStatusDot(isPaused: session.isLivePaused)
                Text(elapsedText(session.elapsed))
                    .font(.recapTitleS)
                    .monospacedDigit()
                    .foregroundStyle(session.isLivePaused ? Color.recapTea : Color.recapInk)
                // 会话级状态在时长右侧叠小字——暂停「已暂停」、开录过渡「准备中」，均归顶栏，内容区流末不再重复
                if session.isLivePaused {
                    Text("已暂停")
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapTea.opacity(0.85))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if isLivePreparing {
                    Text("准备中")
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapTea.opacity(0.85))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.recapPausePhase, value: session.isLivePaused)
            .animation(.recapPausePhase, value: isLivePreparing)
            .padding(.horizontal, Spacing.md)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(RecapPressStyle())
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(
            session.isLivePaused
                ? "已暂停，时长 \(elapsedText(session.elapsed))，轻点收起"
                : (isLivePreparing
                    ? "准备中，时长 \(elapsedText(session.elapsed))，轻点收起"
                    : "正在录音，时长 \(elapsedText(session.elapsed))，轻点收起")
        )
        .accessibilityHint("轻点收起到首页")
    }

    /// REVIEW 顶栏：返回 · 标题 · 右侧次级动作（分享 + 更多）。
    private var reviewTopBar: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                dismissFromTopBar()
            } label: {
                RecapToolbarIconLabel(RecapSymbol.back)
            }
            .buttonStyle(RecapPressStyle())
            .accessibilityLabel(topBarDismissAccessibilityLabel)

            Spacer(minLength: 0)
            reviewTopBarTitle
                // 上滑阅读时标题淡出（返回钮原地不动如锚）
                .opacity(reviewHeaderHidden ? 0 : 1)
            Spacer(minLength: 0)

            reviewTrailingActions
                // 隐藏时分享/更多淡出并退出命中与 VoiceOver（回顶即恢复）
                .opacity(reviewHeaderHidden ? 0 : 1)
                .allowsHitTesting(!reviewHeaderHidden)
                .accessibilityHidden(reviewHeaderHidden)
        }
    }

    /// 右侧次级动作：分享 · 更多。
    /// 分享可见 → 两键收进一根 Liquid Glass 胶囊，中间细分隔线（同 LIVE 运输键范式，成对成组）；
    /// 分享不可见（当前 Tab 不支持分享）→ 退化为单个「更多」玻璃圆钮——右半始终只一件玻璃。
    @ViewBuilder
    private var reviewTrailingActions: some View {
        if currentTabSupportsShare {
            HStack(spacing: 0) {
                reviewShareAction
                reviewMoreAction(glassed: false)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            reviewMoreAction(glassed: true)
        }
    }

    /// 分享/导出（plan 048）：总结 Tab → 复制 / .md / PDF / 长图；转写 Tab → 逐字稿 .md / SRT。
    /// 仅分享可见时出现，永远栖于胶囊内 → 裸图标（玻璃由外层胶囊提供）。
    private var reviewShareAction: some View {
        Menu {
            switch reviewTab {
            case .summary, .note:
                Button {
                    UIPasteboard.general.string = currentNoteMarkdown
                    Haptics.notify(.success)
                } label: {
                    Label("复制 Markdown", systemImage: "doc.on.doc")
                }
                Button { export(.markdown) } label: {
                    Label("导出 Markdown（.md）", systemImage: "doc.plaintext")
                }
                Button { export(.pdf) } label: {
                    Label("导出 PDF", systemImage: "doc.richtext")
                }
                Button { export(.longImage) } label: {
                    Label("导出长图", systemImage: "photo")
                }
            case .transcript:
                Button { export(.transcriptMarkdown) } label: {
                    Label("导出逐字稿（.md）", systemImage: "doc.plaintext")
                }
                Button { export(.srt) } label: {
                    Label("导出字幕（.srt）", systemImage: "captions.bubble")
                }
            case .handwriting:
                // 手写画布是图形交付物，文本导出无意义；维持隐藏（plan 048 决策）
                EmptyView()
            }
        } label: {
            RecapToolbarIconImage(RecapSymbol.share)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("分享或导出")
    }

    /// 导出格式（plan 048）。
    private enum ExportKind {
        case markdown, pdf, longImage
        case transcriptMarkdown, srt
    }

    /// 导出产物（sheet(item:) 载荷；临时文件经系统分享面板送出）。
    private struct ExportPayload: Identifiable {
        let id = UUID()
        let url: URL
    }

    @State private var exportPayload: ExportPayload?
    @State private var exportError: String?

    private func export(_ kind: ExportKind) {
        let title = meeting.title
        do {
            let url: URL
            switch kind {
            case .markdown:
                url = try MeetingExportComposer.writeTemporary(currentNoteMarkdown, fileName: "\(title).md")
            case .transcriptMarkdown:
                let polishedById = Dictionary(
                    uniqueKeysWithValues: meeting.polishedSegments.map { ($0.id, $0.text) }
                )
                let content = MeetingExportComposer.transcriptMarkdown(
                    segments: meeting.segments,
                    speakers: meeting.speakers,
                    polishedById: polishedById
                )
                url = try MeetingExportComposer.writeTemporary(content, fileName: "\(title)·逐字稿.md")
            case .srt:
                let content = MeetingExportComposer.srtContent(
                    segments: meeting.segments,
                    speakers: meeting.speakers
                )
                url = try MeetingExportComposer.writeTemporary(content, fileName: "\(title).srt")
            case .pdf:
                let data = MeetingExportRenderers.renderPDF(
                    markdown: currentNoteMarkdown,
                    title: title,
                    dateText: meeting.startedAt.formatted(.dateTime.year().month().day())
                )
                url = try MeetingExportComposer.writeTemporary(data, fileName: "\(title).pdf")
            case .longImage:
                let image = MeetingExportRenderers.renderLongImage(
                    markdown: currentNoteMarkdown,
                    title: title,
                    dateText: meeting.startedAt.formatted(.dateTime.year().month().day())
                )
                guard let data = image.pngData() else {
                    throw CocoaError(.fileWriteUnknown)
                }
                url = try MeetingExportComposer.writeTemporary(data, fileName: "\(title).png")
            }
            Haptics.notify(.success)
            exportPayload = ExportPayload(url: url)
        } catch {
            exportError = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 顶栏·暂停/继续：Transport 胶囊左段。录音态被动、声波已承担「录音中」信号，
    /// 故控制缩成顶栏玻璃胶囊的一段。
    private var liveTopPauseButton: some View {
        Button {
            // 暂停=.light（降级·收）/ 继续=.medium（再投入·放），给方向感
            Haptics.impact(session.isLivePaused ? .medium : .light)
            if session.isLivePaused {
                session.resumeLive()
            } else {
                session.pauseLive()
            }
        } label: {
            Image(systemName: session.isLivePaused ? "play.fill" : "pause.fill")
                .font(.system(size: 16, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 46, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel(session.isLivePaused ? "继续录音" : "暂停录音")
        .accessibilityHint(session.isLivePaused ? "恢复收音" : "停止收音，可继续或结束")
    }

    /// 顶栏·停止：Transport 胶囊右段。终态动作——淡朱砂底 + 朱砂图标强调其分量；仍走确认弹窗兜底。
    private var liveTopStopButton: some View {
        Button {
            Haptics.impact(.medium)
            showEndLiveConfirm = true
        } label: {
            Image(systemName: RecapSymbol.stop)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.recapCinnabar)
                .frame(width: 46, height: 36)
                .background(
                    Circle().fill(Color.recapCinnabar.opacity(0.12))
                        .frame(width: 28, height: 28)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("结束录音")
        .accessibilityHint("结束本场录音，由 AI 自动生成结构化会议纪要")
    }

    /// REVIEW 顶栏标题区：跨 Tab、随滚动常驻显示会议标题（标题只在顶栏，正文不再重复）。
    private var reviewTopBarTitle: some View {
        Text(meeting.title.isEmpty ? "未命名会议" : meeting.title)
            .font(.recapTitleS)
            .tracking(Tracking.titleS)
            .foregroundStyle(Color.recapInk)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(-1)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var content: some View {
        Group {
            if isSettling || session.phase == .processing || meeting.phase == .processing {
                processingStage
            } else {
                switch session.phase {
                case .live: liveContent
                case .processing, .review: reviewContent
                }
            }
        }
    }

    /// 当前前台窗口高度：替代已弃用且多任务不安全的 `UIScreen.main`。
    /// 取 keyWindow.bounds 而非物理屏幕——iPad Split View / Stage Manager 下随实际窗口缩放，
    /// 极光流光按比例取高才不溢出可见区域。窗口未挂载的极早期回退一个常见逻辑高度。
    private var availableWindowHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow?.bounds.height ?? 844
    }

    /// 整理态全屏极简舞台。
    private var processingStage: some View {
        ZStack(alignment: .bottom) {
            Color.recapBg
                .ignoresSafeArea()

            GeminiFluidGlowView(reduceMotion: reduceMotion, intensity: 0.85)
                .frame(height: availableWindowHeight * 0.65)
                .ignoresSafeArea(.all, edges: .bottom)

            ProcessStageCanvas(
                title: processHeroTitle,
                subtitle: processHeroSubtitle,
                ghostBlocks: [],
                reduceMotion: reduceMotion,
                showGhost: false,
                stage: session.pipelineStage
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(
            .asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .scale(scale: 0.96))
            )
        )
    }

    // MARK: LIVE

    /// 会中正文：实时字幕。手写已挪到底部动作坞（全屏 modal），不再占顶部 Tab ——
    /// 主界面无画布，PKToolPicker 不会浮起遮挡底栏。
    private var liveContent: some View {
        liveRecordingOrPausedContent
    }

    /// 会中手写全屏画布：drawing 真相源在 LiveHandwritingCover 内部（状态下沉，
    /// 每笔画只重算 cover 小子树）。打开即续写：有已存手写则载入（保存失败场景画布
    /// 不关闭，不存在被旧盘覆写的残留态）。
    private var liveHandwritingCover: some View {
        LiveHandwritingCover(
            initialDrawing: Self.storedHandwritingDrawing(for: meeting),
            onCommit: { drawing, completion in
                commitLiveHandwriting(drawing, completion: completion)
            }
        )
    }

    /// 会后手写编辑器初始/续写笔迹：有已存手写则载入，否则空白。
    private static func storedHandwritingDrawing(for meeting: Meeting) -> PKDrawing {
        if let note = meeting.handwritingNote,
           let stored = HandwritingStore.load(storedPath: note.drawingRelativePath) {
            return stored
        }
        return PKDrawing()
    }

    /// 保存当前手写：1:1 upsert——取本场已有 HandwritingNote 或新建，覆盖落盘，存盘后异步重识别。
    /// completion(true) = 落盘成功（cover 可关闭）；false = 失败（cover 保持打开，笔迹待重试）。
    private func commitLiveHandwriting(_ drawing: PKDrawing, completion: @escaping (Bool) -> Void) {
        guard !drawing.strokes.isEmpty else { completion(true); return }
        // 取或建：一场会议仅一条。
        let note: HandwritingNote
        if let existing = meeting.handwritingNote {
            note = existing
        } else {
            note = HandwritingNote(drawingRelativePath: "", meeting: meeting)
            meeting.handwritingNote = note
            modelContext.insert(note)
        }
        // 落盘（覆盖写；失败则路径留空，识别仍可走内存 drawing）。编码+写盘移出主线程。
        note.recognizedText = nil
        note.title = nil
        HandwritingRecognitionService.shared.extractIfAbsent(for: note, drawing: drawing)
        Task { @MainActor in
            do {
                note.drawingRelativePath = try await HandwritingStore.saveOffMain(
                    drawing, meetingId: meeting.id)
                completion(true)
            } catch {
                session.statusMessage = "手写保存失败：存储空间不足或写入失败，笔迹已保留在画布，请重试"
                completion(false)
            }
            try? modelContext.save()
        }
    }

    private var liveRecordingOrPausedContent: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                // 最新在底（时间序：旧→新、上→下，与会后 REVIEW 转写及一切实时字幕的认知
                // 习惯一致；2026-09-09 回退「最新在顶」实验——倒序阅读、新句在头部插入把
                // 整段历史往下顶，均反直觉）。defaultScrollAnchor(.bottom)：初始锚底 +
                // 内容增长时系统保持贴底（用户上滑脱离底部后不强拉），且最新草稿行的
                // partial 增高发生在尾部，贴底由系统吸收、无需 scrollTo 逐块钉底。
                // scrollTo 仅保留给「回到最新」按钮与初始定位（锚点在视口内时有效）。
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // 顶部避让已由 safeAreaInset(edge: .top) 承担；这里只留首条内容的
                        // 呼吸间距（随内容滚走）。
                        Color.clear.frame(height: Spacing.md)

                        // 仅暂停后且真有待办时提示；启动台 / 录音中不出现
                        if session.isLivePaused && session.hasStartedRecording && session.todoCount > 0 {
                            AgentPresenceBar(todoCount: session.todoCount)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, Spacing.md)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                        }

                        ForEach(session.blocks) { block in
                            let isLast = block.id == session.blocks.last?.id
                            SpeakerBlockView(
                                block: block,
                                isCurrent: isLast && !block.isFinal,
                                showLiveMeter: liveShowsListeningIndicator && isLast,
                                // LIVE 减噪：时间戳归 REVIEW 回听锚点；「正在说话」由未定稿
                                // 行尾的朱砂 ▎游标 + opacity 差单一承载。
                                showsTimestamp: false
                            )
                            .id(block.id)
                            .padding(.horizontal, Spacing.xl)
                        }

                        // 状态行（异常/暂停/演示才出字）与最新字幕同侧收尾。
                        liveStreamFooter
                            .padding(.leading, Spacing.xl + 2 + Spacing.md) // 与字幕文字栏对齐（竖条 + 间距）
                            .padding(.trailing, Spacing.xl)
                            .padding(.top, session.blocks.isEmpty ? Spacing.sm : 0)

                        // 流末恒定锚点：「回到最新」按钮 scrollTo 的目标（不能把 id 挂在 footer
                        // 上——statusMessage 为空时 footer 是 EmptyView，id 随之消失）。恒定
                        // Color.clear + 呼吸高度；避让本体由 safeAreaInset(edge: .bottom) 承担。
                        Color.clear
                            .frame(height: Spacing.xxl)
                            .id("live-stream-end")

                        if session.liveStartFailed {
                            liveFailureActions
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, Spacing.xxl)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    max(0, geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height)
                } action: { _, distance in
                    scrollBox.liveDistanceFromBottom = distance
                    guard !suppressLiveFollowUpdate else { return }
                    updateLiveFollowFromDistance(distance)
                }
                .onScrollPhaseChange { _, phase in
                    guard phase == .idle, !suppressLiveFollowUpdate else { return }
                    updateLiveFollowFromDistance(scrollBox.liveDistanceFromBottom)
                }
                .onChange(of: session.blocks.count) { oldCount, newCount in
                    if isFollowingLive {
                        scrollLiveToLatest(proxy: proxy)
                    } else if newCount > oldCount {
                        // 贴底自愈：onScrollGeometryChange 只在计算值变化时回调，scrollTo
                        // 抑制窗口内的贴底事实可能漏跑跟随判定（distance 恒 0 不再触发）——
                        // 「回到最新」浮钮与 missed 计数会在已贴底时残留。scrollBox 里的
                        // distance 由每次几何回调先行写入（guard 之前），此处兜底恢复。
                        if scrollBox.liveDistanceFromBottom < 48 {
                            isFollowingLive = true
                            missedLiveBlocks = 0
                        } else {
                            missedLiveBlocks += newCount - oldCount
                        }
                    }
                }
                .onAppear {
                    isFollowingLive = true
                    missedLiveBlocks = 0
                }

                if !isFollowingLive && !session.blocks.isEmpty {
                    jumpToLatestLiveButton(proxy: proxy)
                        .padding(.bottom, Spacing.md)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // 「回到最新」浮钮属行内状态提示出入场：用 recapNotice（可配 move 位移），
            // 而非 recapPhaseBar——后者契约是「仅 opacity 无位移」。
            .animation(.recapNotice, value: isFollowingLive)
            .animation(reduceMotion ? nil : .recapSonicMorph, value: session.blocks.isEmpty)
            // 待办在场条出现/消失：随暂停/恢复滑入淡出（行内流布局）
            .animation(reduceMotion ? nil : .recapNotice, value: session.isLivePaused)
        }
    }

    private func updateLiveFollowFromDistance(_ distance: CGFloat) {
        let nearBottom = distance < 48
        if nearBottom {
            if !isFollowingLive {
                isFollowingLive = true
                missedLiveBlocks = 0
            }
        } else if isFollowingLive {
            isFollowingLive = false
        }
    }

    private func scrollLiveToLatest(proxy: ScrollViewProxy) {
        guard session.blocks.last != nil else { return }
        suppressLiveFollowUpdate = true
        // 锚定流末恒定锚点（Color.clear，见 LazyVStack 尾部）：底部避让由
        // safeAreaInset(edge: .bottom) 承担，锚点高度即与底栏的呼吸间距。
        if reduceMotion {
            proxy.scrollTo("live-stream-end", anchor: .bottom)
        } else {
            withAnimation(.recapLiveFollow) {
                proxy.scrollTo("live-stream-end", anchor: .bottom)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            suppressLiveFollowUpdate = false
            scrollBox.liveDistanceFromBottom = 0
            isFollowingLive = true
            missedLiveBlocks = 0
        }
    }

    private func jumpToLatestLiveButton(proxy: ScrollViewProxy) -> some View {
        GlassEffectContainer {
            Button {
                Haptics.impact(.light)
                isFollowingLive = true
                missedLiveBlocks = 0
                scrollLiveToLatest(proxy: proxy)
            } label: {
                HStack(spacing: 6) {
                    Text(missedLiveBlocks > 0 ? "回到最新 · \(missedLiveBlocks)" : "回到最新")
                        .font(.recapMeta.weight(.semibold))
                    Image(systemName: RecapSymbol.scrollToLatest)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.recapInk)
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, 10)
            }
            .buttonStyle(RecapPressStyle())
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityLabel(missedLiveBlocks > 0 ? "回到最新，有 \(missedLiveBlocks) 条新字幕" : "回到最新")
        }
    }

    /// 流末：有字幕时波形跟当前行。异常/暂停才出短句。
    private var liveStreamFooter: some View {
        Group {
            if !liveStatusLabel.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    if !session.blocks.isEmpty && liveShowsListeningIndicator {
                        LiveDots()
                    }
                    Text(liveStatusLabel)
                        .font(.recapMeta.weight(.medium))
                        .tracking(Tracking.caption)
                        .foregroundStyle(liveStatusColor)
                        .animation(.recapPausePhase, value: session.isLivePaused)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(liveFooterAccessibilityLabel)
            }
        }
    }

    private var topBarDismissAccessibilityLabel: String {
        if session.phase == .live && !isSettling { return "暂停并收起" }
        return "返回"
    }

    /// 开录过渡态：引擎初始化中。会话级状态，归顶栏状态胶囊（同「已暂停」），不进内容区流末。
    private var isLivePreparing: Bool {
        !session.isLivePaused
            && !session.liveStartFailed
            && !session.isUsingMockAudio
            && session.statusMessage == "正在准备…"
    }

    /// 异常 / 暂停 / 演示才出字；正常收音不写「正在收音」。
    private var liveStatusLabel: String {
        if session.isUsingMockAudio { return "演示字幕" }
        // 暂停态「已暂停」已上提至顶栏状态胶囊，流末不再重复（避免双写）
        if session.isLivePaused { return "" }
        // 开录过渡态「正在准备…」同归顶栏，流末不出字（避免内容区闪现）
        if isLivePreparing { return "" }
        if session.liveStartFailed {
            return session.statusMessage.isEmpty ? "转写引擎启动失败" : session.statusMessage
        }
        return session.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var liveShowsListeningIndicator: Bool {
        !session.isLivePaused
            && !session.liveStartFailed
            && !session.isUsingMockAudio
            && session.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var liveFooterAccessibilityLabel: String {
        let time = elapsedText(session.elapsed)
        if liveStatusLabel.isEmpty {
            return liveShowsListeningIndicator ? "正在收音，已录制 \(time)" : "已录制 \(time)"
        }
        return "\(liveStatusLabel)，已录制 \(time)"
    }

    private var liveStatusColor: Color {
        if session.isLivePaused || session.liveStartFailed { return Color.recapOchre }
        if !session.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Color.recapOchre
        }
        return Color.recapTea
    }

    /// 当前活跃的 LIVE 顶部提示条标识。nil = 无提示。
    /// 驱动 ``liveHintVisible`` 的出入与 6s 自动收起。
    private var liveHintKey: String? {
        if session.liveDialectSuspected { return "dialect" }
        return nil
    }

    private var endLiveConfirmMessage: String {
        // 会后云端精转预告（原 LIVE 常驻提示条收编至此）：预告信息真正相关的时刻是结束时刻。
        var lines: [String] = []
        if session.liveDialectSuspected {
            lines.append("检测到方言口音，实时字幕可能不准；整理时将自动用云端重新精转。")
        } else if session.showsCloudUpgradeHint {
            lines.append("当前为本机转写；整理时将自动升级为云端高保真转写。")
        }
        if session.blocks.isEmpty {
            lines.append("还没有字幕。结束将停止录音并进入整理。")
        } else {
            lines.append("将停止录音并开始整理纪要，此操作不可撤销。")
        }
        return lines.joined(separator: "\n\n")
    }

    /// #5：当前麦克风权限被拒 → 失败态给「打开设置」入口，避免死路。
    private var liveMicPermissionDenied: Bool {
        AVAudioApplication.shared.recordPermission != .granted
    }

    private var liveFailureActions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if liveMicPermissionDenied {
                Text("麦克风权限未开启，请在系统设置中允许后返回重试")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("打开设置")
                        .font(.recapHeading)
                        .foregroundStyle(Color.recapInk)
                }
            }
            Button("重试转写引擎") {
                session.retryLiveRecording()
            }
            .font(.recapHeading)
            .foregroundStyle(Color.recapInk)
            #if DEBUG
            Button("改用演示字幕（DEBUG）") {
                session.startExplicitDemoLive()
            }
            .font(.recapMeta.weight(.medium))
            .foregroundStyle(Color.recapTea)
            #endif
        }
    }

    // MARK: PROCESS / REVIEW

    private var reviewContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // 顶部避让已由 safeAreaInset(edge: .top) 承担（原 reviewTopClear 占位删除）；
                    // 这里只留 Tab 区与顶栏的呼吸间距。
                    Color.clear.frame(height: Spacing.md)

                    // 上滑阅读时整条 Tab 区退场（极简式），只留顶栏返回钮
                    reviewTabBar
                        .frame(maxHeight: reviewHeaderHidden ? 0 : nil, alignment: .top)
                        .opacity(reviewHeaderHidden ? 0 : 1)
                        .clipped()
                        .allowsHitTesting(!reviewHeaderHidden)
                        .accessibilityHidden(reviewHeaderHidden)

                    // 会后任务 inline 进度：仅转写 Tab、进行中时贴顶显示（不随滚动、不污染其他 Tab）
                    Group {
                        if reviewTab == .transcript, session.isDiarizing || session.isPolishing || session.isRetranscribing {
                            PostMeetingProgressRow(
                                isDiarizing: session.isDiarizing,
                                diarizeProgress: session.diarizeProgress,
                                isPolishing: session.isPolishing,
                                isRetranscribing: session.isRetranscribing
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.recapSoft, value: session.isDiarizing)
                    .animation(.recapSoft, value: session.isPolishing)
                    .animation(.recapSoft, value: session.isRetranscribing)

                    LazyVStack(alignment: .leading, spacing: Spacing.xxl) {
                        // revealStep==0：标题只在顶栏；有内容后再在正文展开
                        if !session.statusMessage.isEmpty,
                           session.revealStep >= 1 || session.phase == .review {
                            Text(session.statusMessage)
                                .font(.recapMeta)
                                .foregroundStyle(Color.recapOchre)
                        }
                        switch reviewTab {
                        case .transcript: transcriptBody.transition(tabContentSwap)
                        case .summary:    summaryNoteView.transition(tabContentSwap)
                        case .note(_):    noteTabContent.transition(tabContentSwap)
                        case .handwriting: handwritingTabContent.transition(tabContentSwap)
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.md)
                    // 底部避让已由 safeAreaInset(edge: .bottom) 承担（原 144pt 补偿删除）；
                    // 这里只留滚到底时正文与输入栏的呼吸间距。
                    .padding(.bottom, Spacing.xxl)
                }
            }
            .scrollContentBackground(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y
                } action: { _, offsetY in
                    applyReviewHeaderHidden(offsetY: offsetY)
                }
                .onScrollPhaseChange { _, phase in
                    // 静止回顶兜底：确保停在顶部时顶栏一定显示（方向判定可能漏掉回弹到顶）
                    if phase == .idle, reviewHeaderHidden, scrollBox.lastReviewScrollY <= 0 {
                        reviewHeaderHidden = false
                    }
                }
                .onChange(of: pendingScrollStart) { _, start in
                    guard let start, reviewTab == .transcript else { return }
                    scrollTranscript(proxy: proxy, startSeconds: start)
                }
                .onChange(of: reviewTab) { _, tab in
                    guard tab == .transcript else { return }
                    // 进转写 Tab 即回听场景：确保高亮起点表与当前转写一致（重转/润色后可能已变）。
                    refreshListeningBoundaries()
                    guard let start = pendingScrollStart else { return }
                    scrollTranscript(proxy: proxy, startSeconds: start)
                }
                .onChange(of: session.blocks) { _, _ in
                    // 用户停留在转写 Tab 期间原地完成重转/润色/分离（不切 Tab）：blocks 换代后
                    // 起点表必须跟上，否则播放高亮按旧 start 映射到已不存在的 block id（错位/消失）。
                    guard reviewTab == .transcript, session.phase == .review else { return }
                    refreshListeningBoundaries()
                }
                .onAppear {
                    // 首帧补滚：onChange 不在首次进入触发，外部注入 initialScrollStart 时需主动滚一次
                    if let start = pendingScrollStart, reviewTab == .transcript {
                        scrollTranscript(proxy: proxy, startSeconds: start)
                    }
                }
                .onChange(of: session.isDiarizing) { was, now in
                    // 分离结束且已写入 spk*：切到转写，结果只在那里可见
                    guard was, !now else { return }
                    guard meeting.speakers.contains(where: { $0.id.hasPrefix("spk") }) else { return }
                    withAnimation(.recapSoft) { reviewTab = .transcript }
                }
            }
            // 笔记 Tab 生成中：底部叠极光流光（与整理态 processingStage 同款 GeminiFluidGlowView），
            // 示意 AI 正在产出。置于背景层（ScrollView 内容在上、文字可读），allowsHitTesting(false) 不挡交互。
            .background(alignment: .bottom) {
                if showNoteDraftingGlow {
                    GeminiFluidGlowView(reduceMotion: reduceMotion, intensity: 0.7)
                        .frame(height: availableWindowHeight * 0.42)
                        .ignoresSafeArea(.all, edges: .bottom)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .recapSoft, value: reviewHeaderHidden)
            // 失败草稿无「取消」出口：用户切走即视为放弃，清掉失败态草稿（运行中草稿切走不动，保留后台流式）
            .onChange(of: reviewTab) { _, newTab in
                guard let note = draftingNote, note.error != nil else { return }
                var stillOnDraft = false
                if case .note(let active) = newTab { stillOnDraft = active == note.id }
                if !stillOnDraft {
                    withAnimation(reduceMotion ? nil : .recapSoft) { draftingNote = nil }
                }
            }
    }

    /// 手写笔记 Tab（会后）：一场会议仅一条。空态引导「开始书写」；有则展示原笔迹 + 识别文字，可「继续书写」续写。
    private var handwritingTabContent: some View {
        Group {
            if let note = meeting.handwritingNote {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        HStack(alignment: .top, spacing: Spacing.md) {
                            // 原笔迹缩略图（从磁盘 load；仅一条，同步 load 可接受）
                            if let drawing = HandwritingStore.load(storedPath: note.drawingRelativePath) {
                                Image(uiImage: drawing.image(
                                    from: drawing.bounds.isEmpty
                                        ? CGRect(x: 0, y: 0, width: 1, height: 1)
                                        : drawing.bounds,
                                    scale: UITraitCollection.current.displayScale
                                ))
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            Text(verbatim: (note.recognizedText?.isEmpty == false)
                                 ? note.recognizedText!
                                 : (note.recognizedText == nil ? "识别中…" : "（未识别到文字）"))
                                .font(.recapBodyS)
                                .foregroundStyle(Color.recapInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.recapPaper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))

                        reviewHandwritingAddButton
                            .padding(.top, Spacing.md)
                    }
                    .padding(.horizontal, Spacing.md)
                }
            } else {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.recapTea.opacity(0.75))
                    Text("用 Apple Pencil 写下的笔记会出现在这里")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                    reviewHandwritingAddButton
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.xxxl)
            }
        }
        .fullScreenCover(isPresented: $showHandwritingEditor) {
            handwritingReviewEditor
        }
    }

    /// 开始 / 续写手写按钮：1:1——续写笔迹由编辑器容器打开时从磁盘载入（真相源在容器内）。
    private var reviewHandwritingAddButton: some View {
        let hasNote = meeting.handwritingNote != nil
        return Button {
            Haptics.impact(.light)
            showHandwritingEditor = true
        } label: {
            Label(hasNote ? "继续书写" : "开始书写", systemImage: "square.and.pencil")
                .font(.recapHeading)
                .foregroundStyle(Color.recapInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
        }
        .buttonStyle(.plain)
    }

    /// 会后手写编辑器：全屏画布 + 取消/保存（drawing 真相源在容器内，保存成功才关闭）。
    private var handwritingReviewEditor: some View {
        ReviewHandwritingEditorContainer(
            initialDrawing: Self.storedHandwritingDrawing(for: meeting),
            onCommit: { drawing, completion in
                commitReviewHandwriting(drawing, completion: completion)
            }
        )
    }

    /// 保存会后手写：1:1 upsert——取本场已有 HandwritingNote 或新建，覆盖落盘 + 重识别。
    /// completion(true) = 落盘成功（编辑器可关闭）；false = 失败（保持打开，笔迹待重试）。
    private func commitReviewHandwriting(_ drawing: PKDrawing, completion: @escaping (Bool) -> Void) {
        guard !drawing.strokes.isEmpty else { completion(true); return }
        let note: HandwritingNote
        if let existing = meeting.handwritingNote {
            note = existing
        } else {
            note = HandwritingNote(drawingRelativePath: "", meeting: meeting)
            meeting.handwritingNote = note
            modelContext.insert(note)
        }
        // 编码+写盘移出主线程（对齐 commitLiveHandwriting）。
        note.recognizedText = nil
        note.title = nil
        HandwritingRecognitionService.shared.extractIfAbsent(for: note, drawing: drawing)
        Task { @MainActor in
            do {
                note.drawingRelativePath = try await HandwritingStore.saveOffMain(
                    drawing, meetingId: meeting.id)
                completion(true)
            } catch {
                session.statusMessage = "手写保存失败：存储空间不足或写入失败，笔迹已保留，请重试"
                completion(false)
            }
            try? modelContext.save()
        }
    }

    private func scrollTranscript(proxy: ScrollViewProxy, startSeconds: Double) {
        let id = TranscriptAnchor.blockId(forStartSeconds: startSeconds, segments: meeting.segments)
            ?? reviewTranscriptBlocks.min(by: {
                abs(Self.parseTimestamp($0.timestamp) - startSeconds)
                    < abs(Self.parseTimestamp($1.timestamp) - startSeconds)
            })?.id
        guard let id else {
            pendingScrollStart = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.recapSoft) { proxy.scrollTo(id, anchor: .center) }
            pendingScrollStart = nil
        }
    }

    private var reviewTranscriptBlocks: [TranscriptBlock] {
        if !session.blocks.isEmpty { return session.blocks }
        return meeting.segments.map { TranscriptBlock(segment: $0, speakers: meeting.speakers) }
    }

    nonisolated private static func parseTimestamp(_ ts: String) -> Double {
        let parts = ts.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return Double(parts[0] * 60 + parts[1])
    }

    private var titleMeta: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            TextField("未命名会议", text: $meeting.title)
                .font(.recapTitle)
                .foregroundStyle(Color.recapInk)
                .textFieldStyle(.plain)
                .submitLabel(.done)
            titleMetaLine
        }
    }

    /// Process 期只读标题，避免「还在整理就让改名」。
    private var titleMetaReadonly: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(meeting.title.isEmpty ? "未命名会议" : meeting.title)
                .font(.recapTitleS)
                .foregroundStyle(Color.recapInk)
            titleMetaLine
        }
        .accessibilityElement(children: .combine)
    }

    private var titleMetaLine: some View {
        HStack(spacing: Spacing.sm) {
            Text("\(meeting.dateText) · \(meeting.durationText)")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            if let location = meeting.locationDisplay {
                Text("·")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.75))
                Image(systemName: "location")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                Text(location)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            if meeting.summaryVersionCount > 1,
               let v = meeting.latestSummaryOutput?.version {
                Button {
                    showMinutesVersions = true
                } label: {
                    Text("v\(v)")
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.recapInk.opacity(0.12), in: Capsule())
                }
                .buttonStyle(RecapPressStyle())
                .accessibilityLabel("纪要版本历史")
            }
        }
    }

    // MARK: Notes tab（笔记层）

    /// 单层 Tab 栏：转写 / 手写 / 总结 / 笔记∨。复用「H1 + 墨色下划线」视觉语言，
    /// sticky 挂在正文顶部，扁平化原「来源/笔记」二分（去掉一层认知负担）。
    private var reviewTabBar: some View {
        // 横向滚动流体分段胶囊：每条模板笔记为一个独立平级 Tab
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    reviewTabButton("转写", .transcript).id(ReviewTab.transcript)
                    reviewTabButton("手写", .handwriting).id(ReviewTab.handwriting)
                    reviewTabButton("总结", .summary).id(ReviewTab.summary)
                    // 每条笔记一个独立平级 Tab（oldest-first，最新在最右）；草稿 slot 与落定 slot 同 id 同位，
                    // 落定时由 noteTabButton 接管 draftingNoteTabButton，matchedGeometry 指示器不跳。
                    ForEach(noteTabItems) { slot in
                        Group {
                            if let drafting = draftingNote, drafting.id == slot.id {
                                draftingNoteTabButton(drafting)
                            } else {
                                noteTabButton(slot)
                            }
                        }
                        .id(ReviewTab.note(slot.id))
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                    // 调研草稿 / 进行中任务：少数情况、开 sheet，收纳进尾部小菜单（common case 不出现）
                    if !researchItems.isEmpty {
                        researchOverflowButton
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    }
                    reviewNewNoteButton
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.sm)
            }
            .onChange(of: reviewTab) { _, tab in
                withAnimation(.recapSoft) { proxy.scrollTo(tab) }
            }
        }
    }

    private func reviewTabButton(_ title: String, _ tab: ReviewTab) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.recapSoft) { reviewTab = tab }
        } label: {
            tabLabel(title, isActive: reviewTab == tab, showChevron: false)
        }
        .buttonStyle(RecapTabPressStyle())
        // a11y：SwiftUI 无 isTab trait；选中态用 .isSelected 暴露给 VoiceOver（Button 自带 isButton）。
        .accessibilityAddTraits(reviewTab == tab ? .isSelected : [])
    }

    /// 笔记 Tab 流式生成中（draftingNote 存在、未失败、且当前在 .note Tab）：
    /// 底部流光与底栏 AI 输入框互斥——此时显示流光、隐藏输入框，
    /// 让流光成为唯一的「处理中」反馈，避免输入框与生成态争抢底部空间。
    private var showNoteDraftingGlow: Bool {
        guard case .note = reviewTab, let note = draftingNote else { return false }
        return note.error == nil
    }

    /// 当前 reviewTab 是否指向某条笔记 id（笔记 Tab / 生成中草稿 Tab 的选中态判定）。
    private func isActiveNote(_ id: UUID) -> Bool {
        if case .note(let active) = reviewTab { return active == id }
        return false
    }

    /// 一条已落定模板笔记的平级 Tab：复用「H1 + 墨色下划线」视觉；长按可删。
    @ViewBuilder
    private func noteTabButton(_ slot: NoteTabSlot) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.recapSoft) { reviewTab = .note(slot.id) }
        } label: {
            tabLabel(slot.title, isActive: isActiveNote(slot.id), showChevron: false)
        }
        .buttonStyle(RecapTabPressStyle())
        .contextMenu {
            Button(role: .destructive) {
                deleteNote(id: slot.id)
            } label: {
                Label("删除笔记", systemImage: "trash")
            }
        }
    }

    /// 生成中草稿 Tab（未落库）：标题 = 模板名，选中态随 draftingNote 绑定；不可点（已选中）。
    @ViewBuilder
    private func draftingNoteTabButton(_ drafting: DraftingNoteState) -> some View {
        tabLabel(drafting.skill.name, isActive: isActiveNote(drafting.id), showChevron: false)
    }

    /// 调研草稿 / 进行中任务的尾部收纳菜单：开 sheet，不占笔记 Tab 位（common case 不出现）。
    @ViewBuilder
    private var researchOverflowButton: some View {
        Menu {
            ForEach(researchItems) { item in
                Button {
                    openNote(item.target)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        } label: {
            tabLabel("调研", isActive: false, showChevron: true)
        }
    }

    /// 常驻「＋ 笔记」新建入口：无论已有几条笔记，始终位于笔记标签右侧。
    /// 避免首个笔记生成后新建入口被「笔记∨」吞进下拉、用户找不到再添加的路径。
    private var reviewNewNoteButton: some View {
        Button {
            Haptics.impact(.light)
            showTemplateSelection = true
        } label: {
            tabLabel("＋ 笔记", isActive: false, showChevron: false)
        }
        .buttonStyle(RecapTabPressStyle())
        .disabled(draftingNote != nil)
        .accessibilityLabel("新建笔记")
    }

    /// Tab 标签：流体磨砂胶囊底板（Fluid Segmented Capsule）。
    /// 选中态由 matchedGeometryEffect 驱动平滑滑动，辅以细微阴影与单像素微边框。
    @ViewBuilder
    private func tabLabel(_ title: String, isActive: Bool, showChevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.recapBodyS.weight(isActive ? .semibold : .medium))
                .tracking(Tracking.titleS)
                .foregroundStyle(isActive ? Color.recapInk : Color.recapTea.opacity(0.85))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isActive ? Color.recapInk : Color.recapTea.opacity(0.85))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            if isActive {
                Capsule(style: .continuous)
                    .fill(Color.recapPaper)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.recapInk.opacity(0.08), lineWidth: 0.6)
                    )
                    .shadow(color: Color.recapShadow.opacity(0.8), radius: 4, x: 0, y: 1.5)
                    .matchedGeometryEffect(id: "reviewTabIndicator", in: reviewTabNS)
            } else {
                Capsule(style: .continuous)
                    .fill(Color.clear)
            }
        }
    }

    /// 总结笔记：整理态隐藏 AI 声明，保持纯净舞台；完成后展开声明与正文（会议标题已常驻顶栏，正文不再重复）。
    private var summaryNoteView: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            summaryBody
            if session.revealStep >= 1 || session.phase == .review {
                // 声明置于内容之后：先读正文，再用 AI 免责收尾，界面更干净。
                AILightDisclaimer()
            }
        }
    }

    /// 模板产物笔记（.note）：笔记标题 + markdown 正文（`AskMarkdownText` 页面级渲染）+ 末尾 AI 声明。
    @ViewBuilder
    private func noteInlineView(_ id: UUID) -> some View {
        if let payload = meeting.outputs.first(where: { $0.id == id })?.notePayload {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text(payload.title)
                    .font(.recapTitle)
                    .foregroundStyle(Color.recapInk)
                if payload.skillId == "mindmap" {
                    MindmapInlineCard(source: payload.body, title: payload.title)
                } else {
                    AskMarkdownText(source: payload.body, isStreaming: false)
                }
                // 声明置于内容之后：先读正文，再用 AI 免责收尾，界面更干净。
                AILightDisclaimer()
            }
        } else {
            // 笔记被删除等异常情况，回退总结
            summaryNoteView
        }
    }

    /// 笔记 Tab 正文：生成中（draftingNote）优先流式渲染；否则落定笔记 inline；未选回退空态。
    /// 两分支统一 `.id("note-stream")`：让 SwiftUI 在 drafting→落定 切换时合并子树，
    /// 保留 `AskMarkdownText` 的 @State/防抖（标题 = skill.name 落定后不变，仅状态行淡出 + isStreaming 翻转）。
    @ViewBuilder
    private var noteTabContent: some View {
        if let note = draftingNote {
            DraftingNoteView(
                state: note,
                onRetry: {
                    guard let skill = draftingNote?.skill else { return }
                    draftingNote = nil
                    startNoteDrafting(skill)
                }
            )
            .id("note-stream")
        } else if case .note(let id) = reviewTab {
            noteInlineView(id)
                .id("note-stream")
        } else {
            noteEmptyState
        }
    }

    /// 笔记 Tab 空态：无模板笔记时引导生成（进 .note Tab 必经 openNote，此处兜底）。
    private var noteEmptyState: some View {
        VStack(spacing: Spacing.sm) {
            Text("还没有模板笔记")
                .font(.recapTitleS)
                .foregroundStyle(Color.recapTea)
            Button {
                showTemplateSelection = true
            } label: {
                Text("生成对外纪要 / 思维导图…")
                    .font(.recapHeading)
                    .foregroundStyle(Color.recapInk)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
    }

    /// 平铺笔记 Tab 槽位：本场所有 `.note` 产物，每条一个独立平级 Tab。
    /// oldest-first 排序 → 最新一条落在笔记区段最右（紧邻「＋ 笔记」），符合「刚生成的在最右」。
    /// 正在流式生成时，同模板的旧稿被临时滤除，避免出现两个同名 Tab（草稿 Tab 单独流式展示）。
    private var noteTabItems: [NoteTabSlot] {
        var slots = meeting.outputs
            .filter { $0.kind == .note && $0.promptHash != draftingNote?.skill.id }
            .sorted { $0.createdAt < $1.createdAt }
            .map { NoteTabSlot(id: $0.id, title: $0.notePayload?.title ?? "笔记") }
        // 生成中草稿作为末位 slot（落定后由真实笔记以同 id 同位替换，
        // matchedGeometry 指示器全程不跳）。contains 守卫防 save() 与清草稿之间的瞬态重复。
        if let drafting = draftingNote, !slots.contains(where: { $0.id == drafting.id }) {
            slots.append(NoteTabSlot(id: drafting.id, title: drafting.skill.name))
        }
        return slots
    }

    /// 调研草稿 / 进行中任务（开 sheet，收纳进尾部 research Menu；非模板笔记）。
    private var researchItems: [NoteItem] {
        allNoteItems.filter { item in
            if case .researchDraft = item.target { return true }
            if case .researchTask = item.target { return true }
            return false
        }
    }

    /// 本场所有笔记（switcher 下拉用；总结恒置顶）。
    private var allNoteItems: [NoteItem] {
        NoteIndex.notes(
            from: meeting,
            runningTaskId: researchRunner.isBusy ? researchRunner.current?.id : nil
        )
    }

    /// 当前笔记的可分享 markdown（总结走 `shareMarkdown`；.note 走标题+正文）。
    private var currentNoteMarkdown: String {
        switch reviewTab {
        case .note(let id):
            if let payload = meeting.outputs.first(where: { $0.id == id })?.notePayload {
                return "# \(payload.title)\n\n\(payload.body)"
            }
            return shareMarkdown
        case .summary, .transcript, .handwriting:
            return shareMarkdown
        }
    }

    /// 分享钮在总结/笔记/转写 Tab 出现。转写 Tab 自 plan 048 起给出真实交付物
    /// （带说话人逐字稿 .md / SRT 字幕），消除了 001 时代「点了分享却静默给出总结」的
    /// 不对称——那条隐藏规则随之解除（plans/048 记录了推翻理由）。手写画布是图形，维持隐藏。
    private var currentTabSupportsShare: Bool {
        switch reviewTab {
        case .summary, .note, .transcript: return true
        case .handwriting: return false
        }
    }

    /// 调研入口（尾部 research Menu 调用）：调研草稿 / 进行中任务 → 打开既有 sheet。
    /// 总结 / 模板笔记的切换已由各自平级 Tab 按钮直接写 reviewTab，不经此路径。
    private func openNote(_ target: NoteTarget) {
        switch target {
        case .summary, .note(_):
            // 不经此路径（Tab 按钮直接切换）；保留分支仅为穷尽性
            break
        case .researchDraft(let id):
            if let draft = meeting.outputs.first(where: { $0.id == id })?.researchDraftPayload {
                Haptics.selection()
                selectedResearchDraft = draft
                showResearchDraft = true
            }
        case .researchTask(let id):
            openResearchProgress(taskId: id)
        }
    }

    /// 删除一条模板笔记：移除 AIOutput + 回落 reviewTab（还有笔记 → 首条 newest，否则总结）。
    private func deleteNote(id: UUID) {
        guard let output = meeting.outputs.first(where: { $0.id == id }) else { return }
        Haptics.impact(.medium)
        modelContext.delete(output)
        // 手动移除关系项，确保 ForEach 立即重算（对齐 Moments 级联的手动防御惯例）
        meeting.outputs.removeAll { $0.id == id }
        try? modelContext.save()
        // 回落到「最新一条笔记」——noteTabItems 现为 oldest-first，直接取 createdAt 最大的，
        // 不依赖排序方向，避免改动排序时这里悄悄反转。
        let next = meeting.outputs
            .filter { $0.kind == .note }
            .max(by: { $0.createdAt < $1.createdAt })
        withAnimation(.recapSoft) {
            reviewTab = next.map { .note($0.id) } ?? .summary
        }
    }

    /// 在笔记 Tab 内联流式生成模板笔记：选模板后立即关 sheet → 进 drafting 态 →
    /// 流式冒字 → 落库后自然替换为真实笔记（标题不变，过渡平滑）。失败/取消留可恢复入口。
    private func startNoteDrafting(_ skill: AgentSkill, meSpeakerLabel: String? = nil) {
        // 预检密钥——set draftingNote 之前拦截，避免空卡闪烁
        guard MinutesPipelineSmoke.canRunMinutesPipeline else {
            let isQuota = AIServiceMode.current == .freeTrial
            noteNoKeyErrorIsQuotaExhausted = isQuota
            noteNoKeyError = isQuota
                ? "免费额度已用完，可在设置中改用自备密钥（免费）再生成笔记。"
                : "未配置可用的大模型密钥，请先在设置里配置。"
            return
        }
        // 防连点：已有草稿则忽略（失败态重试由 onRetry 先清空再进入）
        guard draftingNote == nil else { return }
        // 「发言复盘」+ 多人 + 未标记我 → 先让用户指认自己（picker）。已带 meSpeakerLabel（picker 回调）时跳过。
        if meSpeakerLabel == nil,
           skill.id == "speech-coach",
           meeting.speakers.count > 1,
           meVoiceprintId.trimmingCharacters(in: .whitespaces).isEmpty {
            pendingSpeakerPickSkill = skill
            showSpeakerPicker = true
            return
        }
        draftingTask?.cancel()
        // stable-id：复用同模板已有笔记 id（刷新路径）否则新生成；落库沿用同一 id，
        // 使草稿→落定 ForEach slot 的 .id 不变，顶栏 matchedGeometry 指示器不跳变。
        let existingId = meeting.outputs.first { $0.kind == .note && $0.promptHash == skill.id }?.id
        let noteId = existingId ?? UUID()
        withAnimation(.recapSoft) {
            draftingNote = DraftingNoteState(id: noteId, skill: skill)
            reviewTab = .note(noteId)
        }
        draftingTask = Task { @MainActor in
            do {
                try await SkillNoteWriter.generate(
                    skill: skill,
                    context: makeAgentToolContext(),
                    meeting: meeting,
                    modelContext: modelContext,
                    preferredId: noteId,
                    meSpeakerLabel: meSpeakerLabel,
                    onProgress: { progress in
                        // onProgress 是 @Sendable、来自非主线程——跳 MainActor（对齐既有调用点）
                        Task { @MainActor in
                            guard draftingNote?.id == noteId else { return }   // 防过期回调串扰
                            if !progress.partialText.isEmpty {
                                draftingNote?.partialText = progress.partialText
                                // 正文已流出：保留 toolSteps 供淡出，不再更新状态行
                            } else if !progress.toolLines.isEmpty {
                                draftingNote?.toolSteps = collapsedToolSteps(progress.toolLines)
                            } else if let s = progress.status {
                                draftingNote?.statusLine = s
                            }
                        }
                    }
                )
                // 落定：preferredId == noteId（刷新返回 existing.id，新建返回 preferredId），
                // reviewTab 已就位无需再切；只清草稿态，真实笔记 slot 同 id 同位接管。
                withAnimation(.recapSoft) { draftingNote = nil }
            } catch is CancellationError {
                withAnimation(.recapSoft) { draftingNote = nil }
            } catch AgentSkillRunnerError.emptyOutput {
                draftingNote?.error = "未产出内容，请重试或换个模板"
            } catch {
                draftingNote?.error = error.localizedDescription
            }
        }
    }

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            if session.revealStep == 0 {
                processingHero
            }
            // 承诺确认 hero（plan 053）：整理结束第一眼是承诺，不是正文。
            if session.phase == .review, promiseHeroVisible {
                PromiseHeroCard(
                    count: promiseDrafts.count,
                    previews: promiseDrafts.prefix(3).map { item in
                        PromiseHeroCard.PromisePreviewRow(
                            id: item.id,
                            task: item.task,
                            meta: [item.owner, item.dueText]
                                .compactMap { $0 }
                                .filter { !$0.isEmpty }
                                .joined(separator: " · ")
                        )
                    },
                    onOpen: { showPromiseSheet = true },
                    onDismiss: { dismissPromiseHero() }
                )
                .id("summary-promise-hero")
                .transition(revealTransition(isPrimary: true))
            }
            // 稳定 id：避免流式每次改文触发 insertion transition 叠出两张卡
            // 首段可轻上移；后续段只 fade，避免连续瀑布感
            if session.revealStep >= 1, !session.summary.tldr.isEmpty {
                TldrCard(text: session.summary.tldr)
                    .id("summary-tldr")
                    .transition(revealTransition(isPrimary: true))
                    .contextMenu { recapCopyButton("复制摘要", fragment: tldrMarkdown) }
            }
            if session.revealStep >= 2, !session.summary.topics.isEmpty {
                topicsSection
                    .id("summary-topics")
                    .transition(revealTransition(isPrimary: false))
                    .contextMenu { recapCopyButton("复制本节", fragment: topicsMarkdown) }
            } else if session.revealStep >= 1, let brief = meeting.brief, !brief.agenda.isEmpty {
                agendaSection(brief)
                    .id("summary-agenda")
                    .transition(revealTransition(isPrimary: session.summary.tldr.isEmpty))
                    .contextMenu { recapCopyButton("复制本节", fragment: agendaMarkdown(brief)) }
            }
            if session.revealStep >= 1, let brief = meeting.brief, !brief.openItems.isEmpty {
                openItemsSection(brief)
                    .id("summary-open-items")
                    .transition(revealTransition(isPrimary: false))
                    .contextMenu { recapCopyButton("复制本节", fragment: openItemsMarkdown(brief)) }
            }
            if session.revealStep >= 3, !session.summary.decisions.isEmpty {
                decisionSection
                    .id("summary-decisions")
                    .transition(revealTransition(isPrimary: false))
                    .contextMenu { recapCopyButton("复制本节", fragment: decisionsMarkdown) }
            }
            if session.revealStep >= 4 {
                todoSection
                    .id("summary-todos")
                    .transition(revealTransition(isPrimary: false))
                    .contextMenu { recapCopyButton("复制本节", fragment: todosMarkdown) }
            }
            if session.revealStep >= 5, !session.summary.openQuestions.isEmpty {
                openQuestionSection
                    .id("summary-questions")
                    .transition(revealTransition(isPrimary: false))
                    .contextMenu { recapCopyButton("复制本节", fragment: openQuestionsMarkdown) }
            }
        }
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "list.bullet.indent", "议题纪要", color: Color.recapInk, count: session.summary.topics.count)
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ForEach(Array(session.summary.topics.enumerated()), id: \.offset) { _, topic in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(topic.title)
                            .font(.recapHeading)
                            .tracking(Tracking.heading)
                            .foregroundStyle(Color.recapInk)
                        ForEach(Array(topic.bullets.enumerated()), id: \.offset) { _, bullet in
                            bulletRow(bullet, color: Color.recapInk, ink: Color.recapInk)
                        }
                    }
                }
            }
        }
    }

    private func agendaSection(_ brief: MeetingBrief) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "list.bullet.rectangle", "对照议程", color: Color.recapInk, count: brief.agenda.count)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(brief.agenda.sorted(by: { $0.order < $1.order })) { item in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Text("\(item.order)")
                            .font(.recapMono)
                            .foregroundStyle(Color.recapInk)
                            .frame(width: 18, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.recapBodyS)
                                .foregroundStyle(Color.recapInk)
                            if let owner = item.ownerHint, !owner.isEmpty {
                                Text(owner)
                                    .font(.recapMeta)
                                    .foregroundStyle(Color.recapTea)
                            }
                        }
                    }
                }
            }
        }
    }

    private func openItemsSection(_ brief: MeetingBrief) -> some View {
        let open = brief.openItems.filter { $0.resolution == "open" }.count
        let closed = brief.openItems.filter { $0.resolution == "closed" }.count
        return VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "arrow.triangle.2.circlepath", "上场遗留", color: Color.recapOchre, count: brief.openItems.count)
            Text("开放 \(open) · 已闭环 \(closed)")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(brief.openItems) { item in
                    Button {
                        toggleOpenItem(item.id)
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.sm) {
                            Text(item.resolution == "closed" ? "✓" : "○")
                                .font(.recapMeta.weight(.semibold))
                                .foregroundStyle(item.resolution == "closed" ? Color.recapInk : Color.recapOchre)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                    .font(.recapBodyS)
                                    .foregroundStyle(item.resolution == "closed" ? Color.recapTea : Color.recapInk)
                                    .strikethrough(item.resolution == "closed", color: Color.recapTea)
                                if let owner = item.ownerHint, !owner.isEmpty {
                                    Text(owner)
                                        .font(.recapMeta)
                                        .foregroundStyle(Color.recapTea)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func toggleOpenItem(_ id: UUID) {
        guard let brief = meeting.brief else { return }
        var items = brief.openItems
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        Haptics.selection()
        items[idx].resolution = items[idx].resolution == "closed" ? "open" : "closed"
        brief.openItems = items
        brief.rebuildPromptSummary()
        try? modelContext.save()
    }

    private func revealTransition(isPrimary: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        if isPrimary {
            return .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 8)),
                removal: .opacity
            )
        }
        return .opacity
    }

    /// Tab 正文互换过渡：纯 opacity 交叉淡入。刻意不加位移/缩放——
    /// 转写↔总结内容高度差很大，在 ScrollView 内叠加位移会引发高度跳变；
    /// 仅淡入让切换柔和不硬切，位移反馈交给顶栏滑动指示器承担。
    /// reduceMotion 安全：opacity 本身无运动。
    private var tabContentSwap: AnyTransition { .opacity }

    private var processingHero: some View {
        ProcessStageCanvas(
            title: processHeroTitle,
            subtitle: processHeroSubtitle,
            ghostBlocks: Array(session.blocks.suffix(4)),
            reduceMotion: reduceMotion,
            showGhost: true,
            stage: session.pipelineStage
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: 420)
        .transition(
            .asymmetric(
                insertion: .opacity,
                removal: .opacity.combined(with: .offset(y: -12))
            )
        )
    }

    private var decisionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "sparkles", "关键决议", color: Color.recapInk)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(session.summary.decisions.enumerated()), id: \.offset) { _, d in
                    bulletRow(d, color: Color.recapInk, ink: Color.recapInk)
                }
            }
        }
    }

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "checkmark.square.fill", "待办事项", color: Color.recapInk, count: sortedItems.count)
            ForEach(Array(sortedItems.enumerated()), id: \.element.id) { index, item in
                ActionItemCard(
                    item: item,
                    speakers: meeting.speakers,
                    meetingTitle: meeting.title,
                    onJumpToSource: { start in jumpToTranscript(startSeconds: start) },
                    onResearchFollowUp: { startResearch(for: item) },
                    hasResearchDraft: researchDraft(for: item) != nil,
                    onOpenResearchDraft: {
                        if let draft = researchDraft(for: item) {
                            selectedResearchDraft = draft
                            showResearchDraft = true
                        }
                    },
                    hasResearchInProgress: researchInProgress(for: item) != nil,
                    onOpenResearchProgress: {
                        if let task = researchInProgress(for: item) {
                            openResearchProgress(taskId: task.id)
                        }
                    }
                )
                .staggerAppear(index: index, reduceMotion: reduceMotion)
            }
        }
    }

    private func researchDraft(for item: ActionItem) -> ResearchDraft? {
        let task = meeting.agentTasks
            .filter { $0.actionItemId == item.id && $0.draftOutputId != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
        guard let id = task?.draftOutputId else { return nil }
        return meeting.outputs.first(where: { $0.id == id })?.researchDraftPayload
    }

    private func researchInProgress(for item: ActionItem) -> AgentTask? {
        meeting.agentTasks
            .filter {
                $0.actionItemId == item.id
                    && [.queued, .running, .suspended, .awaitingApproval].contains($0.state)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private func startResearch(for item: ActionItem) {
        researchRunner.bind(modelContext: modelContext)
        // 该待办已有调研在跑 / 挂起 → 重开对话窗续看（runner live mirror 在单例上存活）
        if researchInProgress(for: item) != nil {
            agentResearchItem = nil
            agentScrollToMessage = nil
            openAgent()
            return
        }
        // 闸门（与 runner 内部互为兜底）：BYOK 缺 key / 限频
        if AIServiceMode.current == .byok, !MinutesPipelineSmoke.canRunMinutesPipeline {
            researchError = "未配置可用的大模型密钥"
            return
        }
        let recent = meeting.agentTasks.filter { $0.actionItemId == item.id }.map(\.createdAt)
        guard AgentTaskRateLimit.canStart(recentCreatedAts: recent) else {
            researchError = "今日该待办调研次数已达上限（24 小时内最多 3 次）"
            return
        }
        agentScrollToMessage = nil
        agentResearchItem = ActionItemSnapshot(
            id: item.id,
            task: item.task,
            owner: item.owner,
            dueText: item.dueText,
            statusRaw: item.status.rawValue,
            meetingTitle: meeting.title,
            isDispatched: item.isReallyDispatched
        )
        openAgent()
    }

    private func openResearchProgress(taskId: UUID) {
        researchRunner.bind(modelContext: modelContext)
        // 进行中 / 挂起的调研已统一进对话窗：重开即由 attach 绑定 runner live mirror 续看。
        agentResearchItem = nil
        agentScrollToMessage = nil
        openAgent()
    }

    /// 草稿气泡「结构化视图」chip / 待办卡草稿入口：呈现 ResearchDraftSheet。
    private func openResearchDraftOutput(_ id: UUID) {
        if let draft = meeting.outputs.first(where: { $0.id == id })?.researchDraftPayload {
            selectedResearchDraft = draft
            showResearchDraft = true
        }
    }

    private func clearDraftTodosForRegen() {
        let drafts = meeting.actionItems.filter { $0.status == .draft }
        for item in drafts {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    // MARK: - 可分享的 Markdown 片段
    // 单一格式真相源：整篇 `shareMarkdown` 与分区「复制本节」共用这批构造器，
    // 待办行复用 `ActionItem.clipboardLine`，避免格式分叉。

    private var tldrMarkdown: String {
        let tldr = session.summary.tldr
        return tldr.isEmpty ? "" : tldr
    }

    private var topicsMarkdown: String {
        let topics = session.summary.topics
        guard !topics.isEmpty else { return "" }
        var lines: [String] = ["## 议题纪要"]
        for topic in topics {
            lines.append("### \(topic.title)")
            for b in topic.bullets { lines.append("- \(b)") }
        }
        return lines.joined(separator: "\n")
    }

    private var decisionsMarkdown: String {
        let decisions = session.summary.decisions
        guard !decisions.isEmpty else { return "" }
        return (["## 关键决议"] + decisions.map { "- \($0)" }).joined(separator: "\n")
    }

    private var todosMarkdown: String {
        guard !sortedItems.isEmpty else { return "" }
        return (["## 待办事项"] + sortedItems.map(\.clipboardLine)).joined(separator: "\n")
    }

    private var openQuestionsMarkdown: String {
        let qs = session.summary.openQuestions
        guard !qs.isEmpty else { return "" }
        return (["## 未决问题"] + qs.map { "- \($0)" }).joined(separator: "\n")
    }

    /// 对照议程片段（仅分区复制用，不进整篇 `shareMarkdown`，保持原有整篇输出范围）。
    private func agendaMarkdown(_ brief: MeetingBrief) -> String {
        guard !brief.agenda.isEmpty else { return "" }
        var lines: [String] = ["## 对照议程"]
        for item in brief.agenda.sorted(by: { $0.order < $1.order }) {
            var line = "\(item.order). \(item.title)"
            if let owner = item.ownerHint, !owner.isEmpty { line += "（\(owner)）" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// 上场遗留片段（仅分区复制用）。
    private func openItemsMarkdown(_ brief: MeetingBrief) -> String {
        guard !brief.openItems.isEmpty else { return "" }
        var lines: [String] = ["## 上场遗留"]
        for item in brief.openItems {
            var line = "- \(item.text)"
            if let owner = item.ownerHint, !owner.isEmpty { line += "（\(owner)）" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private var shareMarkdown: String {
        var parts: [String] = ["# \(meeting.title)"]
        parts.append(contentsOf: [
            tldrMarkdown,
            topicsMarkdown,
            decisionsMarkdown,
            todosMarkdown,
            openQuestionsMarkdown
        ].filter { !$0.isEmpty })
        return parts.joined(separator: "\n\n")
    }

    private func jumpToTranscript(startSeconds: Double) {
        pendingScrollStart = startSeconds
        withAnimation(.recapSoft) { reviewTab = .transcript }
        if hasLocalAudio {
            openAudioPlayer(seekTo: startSeconds, autoplay: true)
        }
    }

    /// 转写页内嵌播放卡进入即预载本地录音；否则 `togglePlayPause` 因 `isReady==false` 静默失效。
    private func ensureAudioLoaded() {
        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path),
              !audioPlayer.isReady else { return }
        audioPlayer.load(storedPath: path)
    }

    private func openAudioPlayer(seekTo: Double? = nil, autoplay: Bool = false) {
        ensureAudioLoaded()
        if let seekTo {
            audioPlayer.seek(to: seekTo)
        }
        if autoplay {
            audioPlayer.play()
        }
    }

    private var listeningBlockId: String? {
        listeningHighlight.listeningBlockId
    }

    /// 刷新回听高亮的块起点表 + 绑定播放器（转写内容变化后调用）。
    private func refreshListeningBoundaries() {
        listeningHighlight.bind(player: audioPlayer)
        listeningHighlight.updateBlocks(
            reviewTranscriptBlocks.map { ($0.id, blockStartSeconds($0)) }
        )
    }

    private func blockStartSeconds(_ block: TranscriptBlock) -> Double {
        block.startSeconds ?? Self.parseTimestamp(block.timestamp)
    }

    private var openQuestionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "questionmark.circle.fill", "未决问题", color: Color.recapOchre)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(session.summary.openQuestions.enumerated()), id: \.offset) { _, q in
                    bulletRow(q, color: Color.recapOchre, ink: Color.recapTea)
                }
            }
        }
    }

    private func bulletRow(_ text: String, color: Color, ink: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Circle().fill(color).frame(width: 5, height: 5).padding(.top, 7)
            Text(text)
                .font(.recapBodyS)
                .lineSpacing(Leading.body)
                .tracking(Tracking.body)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(systemImage: String, _ text: String, color: Color, count: Int? = nil) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.recapTitleS)
                .tracking(Tracking.titleS)
                .foregroundStyle(Color.recapInk)
            if let c = count {
                Text("\(c)")
                    .font(.recapCaption)
                    .monospacedDigit()
                    .foregroundStyle(Color.recapTea)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(light: 0xF1F3F5, dark: 0x22252A), in: Capsule())
            }
            Spacer()
        }
    }

    // MARK: - 「发言复盘」picker

    /// 每位说话人的首句预览（session.blocks 一遍扫描，polished→raw，prefix 40）——让用户认出自己。
    private func speakerFirstUtterances() -> [String: String] {
        var firstLine: [String: String] = [:]
        for block in session.blocks {
            let text = (block.polished.isEmpty ? block.raw : block.polished)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if firstLine[block.speaker.id] == nil {
                firstLine[block.speaker.id] = String(text.prefix(40))
            }
        }
        return firstLine
    }

    /// picker 选定：transient 标签立即驱动生成（不等同意）；勾选「记住我」则顺带持久 enroll（非阻断）。
    private func handleSpeakerPick(_ speaker: Speaker, rememberMe: Bool) {
        // 反馈校准（Step 4a）：用户手动从 picker 指认 = 系统未自动命中的漏并信号 → 放宽阈值。
        VoiceprintFeedback.shared.recordManualAssign()
        // 持久 enroll：仅 FluidAudio(voiceprintId 非空) + 勾选。复用既有同意门（pendingMeVoiceprintId/showVoiceprintConsent）。
        if rememberMe, let vp = speaker.voiceprintId, !vp.isEmpty {
            if VoiceprintConsent.granted {
                VoiceprintGallery.shared.markAsMe(voiceprintId: vp, name: "我")
                meVoiceprintId = vp
            } else {
                pendingMeVoiceprintId = vp
                showVoiceprintConsent = true
            }
        }
        // 当场标签驱动生成（立即；同意是只影响未来的副作用，不阻断本场反思）。
        guard let skill = pendingSpeakerPickSkill else { return }
        pendingSpeakerPickSkill = nil
        startNoteDrafting(skill, meSpeakerLabel: speaker.name)
    }

    /// 「标记为我自己」：经声纹同意门后，把该说话人的 voiceprintId 登记为「我」（跨会议复用）。
    private func handleMarkMe(_ block: TranscriptBlock) {
        guard let vp = block.speaker.voiceprintId, !vp.isEmpty else { return }
        if VoiceprintConsent.granted {
            VoiceprintGallery.shared.markAsMe(voiceprintId: vp, name: "我")
            meVoiceprintId = vp
        } else {
            pendingMeVoiceprintId = vp
            showVoiceprintConsent = true
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // 音频播放控制卡片：仅有本地录音时显示；进入即预载，避免 play 静默失效
            // （「转写」标题已由 sticky reviewTabBar 承担，正文不再重复 H1）
            if hasLocalAudio {
                AudioPlayerCard(
                    player: audioPlayer,
                    onSeek15Back: {
                        audioPlayer.seek(to: max(0, audioPlayer.currentTime - 15))
                    },
                    onSeek15Forward: {
                        audioPlayer.seek(to: min(audioPlayer.duration, audioPlayer.currentTime + 15))
                    },
                    onSpeedToggle: {
                        Haptics.impact(.light)
                        let next: Float = {
                            switch audioPlayer.rate {
                            case 1.0: return 1.5
                            case 1.5: return 2.0
                            default: return 1.0
                            }
                        }()
                        audioPlayer.setRate(next)
                    }
                )
                .onAppear { ensureAudioLoaded() }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()
                .background(Color.recapTea.opacity(0.12))

            // 逐字稿内容流
            let listeningId = listeningBlockId
            ForEach(timelineRows) { row in
                switch row.kind {
                case .block(let block):
                    SpeakerBlockView(
                        block: block,
                        isCurrent: false,
                        isListening: listeningId == block.id,
                        isMe: !meVoiceprintId.isEmpty && block.speaker.voiceprintId == meVoiceprintId,
                        onSeek: hasLocalAudio
                            ? { openAudioPlayer(seekTo: blockStartSeconds(block), autoplay: true) }
                            : nil,
                        // 声纹身份可用（FluidDiarizer 路径，voiceprintId 非空）才提供「标记我」入口；
                        // SpeakerKit 路径 voiceprintId 恒 nil——handleMarkMe 会静默 return，
                        // 可点的死按钮毫无反馈，不如降级为纯文本（长按「纠正发言人」仍有解释文案）。
                        onMarkMe: (block.speaker.voiceprintId?.isEmpty == false)
                            ? { handleMarkMe(block) }
                            : nil,
                        onSpeakerInfo: { pendingSpeakerCorrection = block.speaker }
                    )
                    .id(row.id)
                case .moment(let moment):
                    MomentCardView(
                        moment: moment,
                        onSeek: hasLocalAudio
                            ? { openAudioPlayer(seekTo: moment.startSeconds, autoplay: true) }
                            : nil,
                        onOpen: { galleryMoment = moment }
                    )
                    .id(row.id)
                }
            }
        }
        .animation(reduceMotion ? nil : .recapSoft, value: hasLocalAudio)
    }

    /// 逐字稿时间轴的合并行：转写分段 + 会议时刻，按 startSeconds 交织排序。
    private struct TimelineRow: Identifiable {
        enum Kind {
            case block(TranscriptBlock)
            case moment(Moment)
        }
        let id: String
        let start: Double
        let kind: Kind
    }

    private var timelineRows: [TimelineRow] {
        var rows: [TimelineRow] = []
        for block in reviewTranscriptBlocks {
            rows.append(TimelineRow(id: block.id, start: blockStartSeconds(block), kind: .block(block)))
        }
        for moment in meeting.moments {
            rows.append(TimelineRow(id: "moment-\(moment.id.uuidString)",
                                    start: moment.startSeconds,
                                    kind: .moment(moment)))
        }
        return rows.sorted { $0.start < $1.start }
    }

    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        if isSettling {
            // 占位保持布局稳定；仅淡出，无位移（高频底栏路径保持克制）
            liveActionDock
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            switch session.phase {
            case .live:
                // 失败态无录音可锚定，动作坞让位给正文失败操作
                if session.liveStartFailed {
                    EmptyView()
                } else {
                    liveActionDock
                        .transition(.opacity)
                }
            case .processing:
                EmptyView()
            case .review:
                if showReviewBottom, !showNoteDraftingGlow {
                    reviewBottom
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }
            }
        }
    }

    /// LIVE 底部动作坞：拍照 · 手写(iPad) · 问AI —— 收进单根居中 Liquid Glass 胶囊，细分割线分段，
    /// 各自 tap → 打开一个 overlay（相机取景 / 手写画布 / AI 对话窗），交互模式统一。
    /// 主界面无画布 → PKToolPicker 不会遮挡此处。
    private var liveActionDock: some View {
        HStack {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                cameraLiveBottomButton
                liveDockDivider
                if UIDevice.current.userInterfaceIdiom == .pad {
                    handwritingLiveBottomButton
                    liveDockDivider
                }
                askLiveBottomButton
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .contentShape(Rectangle())
    }

    /// 动作坞胶囊内的分段分割线。
    private var liveDockDivider: some View {
        Capsule()
            .fill(Color.recapInk.opacity(0.12))
            .frame(width: 1, height: 28)
    }

    /// 动作坞分段图标：胶囊内统一皮肤（纯图标，材质由外层胶囊承担，不再各自套 glass 圆）。
    private func liveDockIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.recapInk.opacity(0.72))
            .frame(width: 64, height: 52)
            .contentShape(Rectangle())
    }

    /// 打开 AI 对话窗：底栏胶囊淡出、对话窗从底部 spring 滑起、compose 聚焦键盘只升一次。
    /// prefill 恒空 → AgentInvokeSheet 落到 focus 分支，键盘不中断。
    private func openAgent() {
        openAgent(prefill: "")
    }

    /// 带预填变体（plan 051）：非空 prefill → AgentInvokeSheet `autoSendInitial` 自动发一轮
    /// （人物视图「上次和 TA 聊了什么」等带上下文入口）。
    private func openAgent(prefill: String) {
        Haptics.impact(.soft)
        agentPrefill = prefill
        // 先以空快照翻转 showAgent：sheet 用空 context 轻量构造，spring 首帧得以正常提交。
        agentTranscript = ""
        agentSegments = []
        // 复位下拉位移：关闭时保留拖拽位置以平滑滑出（见 closeAgent），此处清零供本次入场。
        agentDragOffset = 0
        withAnimation(.recapSheet) { showAgent = true }
        // 真实整场转写延迟到下一 runloop 拼接，不阻塞滑入首帧；填充后 sheet 的
        // onChange(of: transcriptContext) → syncLiveContext 自动接管 LIVE 同步。
        Task { @MainActor in
            agentTranscript = transcriptContext
            agentSegments = askSegments
        }
    }

    /// 关闭 AI 对话窗：表面滑出，backdrop 收起。
    private func closeAgent() {
        // 不在此归零 agentDragOffset：让 .move(edge:.bottom) 从当前下拉位置继续向下滑出。
        // 若与退场同帧把 offset 拉回 0，会产生「先上跳 ~120pt 再下滑」的位移打架。
        // 复位放到下次 openAgent，不影响本次滑出。
        withAnimation(.recapBottomExit) {
            showAgent = false
        }
        agentPrefill = ""
        agentResearchItem = nil
        agentScrollToMessage = nil
    }

    /// Grabber 下拉手势：向下才响应、橡皮筋跟随；过阈值或快速下拉则关闭，否则回弹。
    private var agentDragGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                guard v.translation.height > 0 else { return }
                agentDragOffset = v.translation.height * 0.85
            }
            .onEnded { v in
                let threshold: CGFloat = 120
                let flick = v.predictedEndTranslation.height > 320
                if v.translation.height > threshold || flick {
                    closeAgent()
                } else {
                    withAnimation(.recapSoft) { agentDragOffset = 0 }
                }
            }
    }

    /// LIVE「问 Recap」：图标入口，同样走滑入。
    private func askRecap() {
        openAgent()
    }

    /// 右下：问 Recap —— 全站统一固定槽位（含启动台）。
    private var askLiveBottomButton: some View {
        Button { askRecap() } label: {
            liveDockIcon(RecapSymbol.ask)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("提问")
        .accessibilityHint(
            session.hasStartedRecording
                ? "开会走神时补课，不影响录音"
                : "可先问议程或资料，再开始录音"
        )
    }

    /// 底部动作坞·手写（仅 iPad）：打开全屏画布续写本场手写（续写载入在 cover 内完成）。
    private var handwritingLiveBottomButton: some View {
        Button {
            Haptics.impact(.soft)
            showLiveHandwriting = true
        } label: {
            liveDockIcon(RecapSymbol.handwrite)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("手写笔记")
        .accessibilityHint("打开全屏画布随手记，不打断录音")
    }

    /// 底部动作坞·拍照：记录此刻，锚定到当前秒。
    private var cameraLiveBottomButton: some View {
        Button {
            Haptics.impact(.soft)
            momentCaptureAnchor = session.elapsed
            showMomentCapture = true
        } label: {
            liveDockIcon(RecapSymbol.camera)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("记录此刻")
        .accessibilityHint("拍下白板或此刻，锚定到录音当前秒，不打断录音")
    }

    /// AI 对话窗 overlay：对话窗从底部平滑滑起、键盘不中断。
    ///
    /// 三层（自底向上）：① backdrop 暗化，盖住仍驻留的 reviewBottom；
    /// ② AgentInvokeSheet 表面（从底部 spring 滑入）；③ grabber 下拉命中区（不抢 ScrollView 滚动）。
    /// 对话窗 overlay：毛玻璃 backdrop + 半高悬浮卡片（顶部圆角+投影，露出纪要边缘），
    /// 强化「悬浮在纪要之上」的心智。ZStack 常驻：backdrop opacity 0↔1 由 .animation 驱动渐变；
    /// sheet .move 在稳定容器内播放。空闲态 backdrop opacity 0 + allowsHitTesting(false)，几乎零成本。
    @ViewBuilder private var agentOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                // ① Backdrop：顶部轻 dim（透出纪要、建立「悬浮其上」的透视）→ 卡片边缘加重（配合投影强化浮起空气感）。
                LinearGradient(
                    stops: [
                        .init(color: Color.recapInk.opacity(0.12), location: 0.0),
                        .init(color: Color.recapInk.opacity(0.20), location: 0.12),
                        .init(color: Color.recapInk.opacity(0.20), location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(showAgent ? 1 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(showAgent)
                .onTapGesture { closeAgent() }

                // ①.5 底部完全挡板：不透明 recapBg 贴满 Sheet 底部到物理底边线，100% 挡住背后
                if showAgent {
                    Color.recapBg
                        .frame(maxWidth: .infinity)
                        .frame(height: proxy.size.height * 0.9)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
                        .offset(y: agentDragOffset)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                        .allowsHitTesting(false)

                    // ② Agent 表面：半高浮起卡片（顶部露出纪要边缘 + 圆角 + 投影 = 独立悬浮层）
                    AgentInvokeSheet(
                        meeting: meeting,
                        phase: session.phase,
                        transcriptContext: agentTranscript,
                        segments: agentSegments,
                        speakers: meeting.speakers,
                        meetingTitle: meeting.title,
                        actionItems: meeting.actionItems,
                        minutesSummary: meeting.latestSummary,
                        briefSummary: meeting.briefPromptSummary,
                        briefSources: meeting.brief?.sources ?? [],
                        momentsSummary: meeting.momentsPromptSummary,
                        handwritingSummary: meeting.handwritingPromptSummary,
                        hasStartedRecording: session.hasStartedRecording,
                        isLivePaused: session.isLivePaused,
                        pipelineProgressText: session.pipelineProgressText,
                        linkedMeetingTitle: meeting.brief?.sources.first(where: { $0.kind == .linkedMeeting })?.title,
                        onJumpToTranscript: { start in
                            jumpToTranscript(startSeconds: start)
                        },
                        onMinutesUpdated: { summary in
                            session.summary = summary
                        },
                        initialInput: agentPrefill,
                        autoSendInitial: true,
                        initialResearchItem: agentResearchItem,
                        initialScrollToMessageID: agentScrollToMessage,
                        onOpenDraft: { id in openResearchDraftOutput(id) },
                        isPresented: $showAgent
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: proxy.size.height * 0.9)
                    .overlay(alignment: .top) {
                        // grabber 下拉命中区（贴卡片顶部 30pt；grabber 视觉由 AgentInvokeSheet 顶部占位）
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, maxHeight: 30)
                            .gesture(agentDragGesture)
                            .accessibilityHidden(true)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
                    .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: -6)
                    .offset(y: agentDragOffset)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                }
            }
            .animation(showAgent ? .recapSheet : .recapBottomExit, value: showAgent)
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    /// 会后底栏：全局虹彩悬浮 Ask Bar——对话=横切工具，对「当前正在看的内容」提问。
    /// placeholder 随 Tab 语义切换（转写/总结/此笔记），不割裂「边看边问」。
    private var reviewBottom: some View {
        AgentAskBar(placeholder: askPlaceholder, onTap: openAgent)
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.sm)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: Color.recapBg, location: 0.0),
                        .init(color: Color.recapBg.opacity(0.95), location: 0.45),
                        .init(color: Color.recapBg.opacity(0.0), location: 1.0)
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .ignoresSafeArea(edges: .bottom)
            )
            // 对话窗滑起时淡出底栏胶囊，避免与升起的对话窗重影
            .opacity(showAgent ? 0 : 1)
    }

    /// AskBar 文案随当前 Tab 切换：让"对话=对当前内容提问"的心智显式化。
    private var askPlaceholder: String {
        switch reviewTab {
        case .transcript: return "对这段转写提问"
        case .summary:    return "对这份总结提问"
        case .note(_):    return "对此笔记提问"
        case .handwriting: return "对手写笔记提问"
        }
    }

    /// 更多：润色 / 重转写 / 删除等低频动作（删除也可在首页列表左滑/长按）。
    /// `glassed: true` = 独立玻璃圆钮（分享不可见时）；`false` = 胶囊内裸图标（分享可见时，玻璃由外层胶囊提供）。
    private func reviewMoreAction(glassed: Bool) -> some View {
        Menu {
            // 重新生成纪要：默认按当前转写（+底稿）轻量重跑管线；弹窗可勾选「同时重转」走云端全流程。
            if session.phase == .review, !session.blocks.isEmpty {
                Button {
                    showRegenerateSheet = true
                } label: {
                    Label("重新生成纪要", systemImage: "arrow.clockwise")
                }
                .disabled(session.isPostMeetingComputeBusy)
            }
            // 重新转写：云端优先（paraformer-realtime-v2），无凭证端侧兜底；不暴露引擎名。
            if session.phase == .review, meeting.audioPath != nil {
                Button {
                    session.retranscribeFromDiskCloudFirst()
                    withAnimation(.recapSoft) { reviewTab = .transcript }
                } label: {
                    Label("重新转写", systemImage: "waveform")
                }
                .disabled(session.isPostMeetingComputeBusy)
            }
            Button(role: .destructive) {
                showDeleteLiveConfirm = true
            } label: {
                Label("删除本场", systemImage: RecapSymbol.delete)
            }
        } label: {
            if glassed {
                RecapToolbarIconLabel(RecapSymbol.more)
            } else {
                RecapToolbarIconImage(RecapSymbol.more)
            }
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("更多")
        .accessibilityHint("删除本场等操作")
    }

    /// 重新生成纪要确认弹窗：默认轻量重跑，可勾选「同时重新转写」走云端全流程。
    private struct RegenerateConfirmSheet: View {
        let hasAudio: Bool
        @Binding var alsoRetranscribe: Bool
        let onConfirm: () -> Void
        let onCancel: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("重新生成纪要")
                            .font(.recapTitleS)
                            .foregroundStyle(Color.recapInk)
                        Text("基于当前转写重跑总结与待办")
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                    }
                    Spacer()
                    Button { onCancel() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.recapTea)
                            .frame(width: 32, height: 32)
                            .background(Color.recapTea.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Spacing.xl)

                Text("将替换当前的总结与未分发的待办（已分发到提醒事项的待办不受影响），此操作不可撤销。")
                    .font(.recapBody)
                    .foregroundStyle(Color.recapTea)
                    .padding(.horizontal, Spacing.xl)
                    .fixedSize(horizontal: false, vertical: true)

                if hasAudio {
                    Button {
                        alsoRetranscribe.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.md) {
                            Image(systemName: alsoRetranscribe ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(alsoRetranscribe ? Color.recapInk : Color.recapTea)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("同时重新转写音频")
                                    .font(.recapHeading)
                                    .foregroundStyle(Color.recapInk)
                                Text("更慢（数分钟），额外扣转写额度；转写更准后纪要也更准。")
                                    .font(.recapMeta)
                                    .foregroundStyle(Color.recapTea)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(Spacing.md)
                        .background(
                            Color.recapPaper,
                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.xl)
                } else {
                    Text("本场无本地录音，无法重新转写；将基于现有转写重生成。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea.opacity(0.9))
                        .padding(.horizontal, Spacing.xl)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    onConfirm()
                } label: {
                    Text("重新生成")
                        .font(.recapTitleS)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.recapInk, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.lg)
            }
            .padding(.top, Spacing.md)
            .background(Color.recapBg.ignoresSafeArea())
        }
    }

    private func endLive() {
        Haptics.impact(.soft)
        withAnimation(settlingAnimation) {
            isSettling = true
        }
        // 管线立刻开跑；UI 先走 Settling 桥再露出纪要层
        session.endLive(persistTodos: persistTodos, persistSummary: persistSummary)
        // 管线已并行；hold 只服务过渡感知，勿空等超过半秒
        let holdNs: UInt64 = reduceMotion ? 220_000_000 : 450_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: holdNs)
            withAnimation(.recapSoft) {
                isSettling = false
            }
        }
    }

    private func dismissFromTopBar() {
        Haptics.impact(.light)
        if !session.hasStartedRecording {
            // 未录到内容（进会即走 / 引擎启动失败）：收起即清场，不留空壳打扰首页
            deleteLiveMeeting()
            return
        }
        if session.phase == .live, !isSettling {
            session.pauseLive()
        }
        onDismiss()
    }

    private func deleteLiveMeeting() {
        draftingTask?.cancel()
        draftingNote = nil
        session.pauseOrTeardownForDisappear()
        MeetingDeletion.delete(meeting, in: modelContext)
        onDismiss()
    }

    /// onDisappear 收尾：取消草稿任务、停播放器、暂停/拆除录音；并清理从未开麦的 LIVE 空壳会议
    /// （系统返回手势不走 dismissFromTopBar，会漏掉「进会即走/引擎失败/权限被拒」的空壳草稿清理）。
    /// 已录内容(livePaused)有 hasStartedRecording=true 保留；dismissFromTopBar 已删的重复 delete 幂等无副作用。
    private func teardownOnDisappear() {
        draftingTask?.cancel()
        session.pauseOrTeardownForDisappear()
        audioPlayer.stop()
        if meeting.phase == .live, !session.hasStartedRecording {
            MeetingDeletion.delete(meeting, in: modelContext)
        }
    }

    private func persistTodos(_ items: [TodoListPayload.Item]) {
        // 幂等双保险：跨管线 run 去重（崩溃后重跑 / 双 session 竞态）——
        // 同 (task, owner) 的 draft 待办已存在则跳过，避免重复插入。
        let existing = Set(
            meeting.actionItems
                .filter { $0.status == .draft }
                .map { "\($0.task)|\($0.owner ?? "")" }
        )
        for item in items {
            let key = "\(item.task)|\(item.owner ?? "")"
            if existing.contains(key) { continue }
            // 锚定会议开始时刻而非 .now：「今天/明天/周五」以开会那天为准——跨午夜会议
            // 与数天后重跑管线（幂等补跑）都不会整体漂移一天。
            let due = item.due_text.flatMap { DueTextParser.parse($0, reference: meeting.startedAt) }
            let anchored = item.start_seconds
                ?? TranscriptAnchor.startSeconds(
                    evidenceQuote: item.evidence_quote,
                    in: meeting.segments
                )
            // HITL：一律 draft，低置信由 UI 灰显「待确认」
            modelContext.insert(ActionItem(
                task: item.task,
                owner: item.owner,
                ownerSource: item.owner_source.flatMap(OwnerSource.init(rawValue:)),
                due: due,
                confidence: item.confidence,
                evidenceQuote: item.evidence_quote,
                startSeconds: anchored,
                status: .draft,
                meeting: meeting
            ))
        }
        try? modelContext.save()
    }

    private func persistSummary(_ summary: MeetingSummary, _ raw: String) {
        if let data = try? JSONEncoder().encode(summary) {
            modelContext.insert(AIOutput(
                kind: .summary,
                payloadData: data,
                modelId: session.pendingSummaryModelId,
                promptHash: "minutes-v3",
                version: (meeting.latestSummaryOutput?.version ?? 0) + 1,
                meeting: meeting
            ))
            try? modelContext.save()
            pruneSummaryVersions(keep: 5)
        }
    }

    /// 摘要版本只增不删：每次重生成/修改/回滚都追加一条 AIOutput，高频用户线性累积
    /// （`latestSummaryOutput` 还是全量 filter+max）。保留最近 `keep` 版，更旧的删除。
    private func pruneSummaryVersions(keep: Int) {
        let outputs = meeting.outputs
            .filter { $0.kind == .summary }
            .sorted { $0.version > $1.version }
        guard outputs.count > keep else { return }
        for stale in outputs.dropFirst(keep) {
            modelContext.delete(stale)
        }
        try? modelContext.save()
    }

    /// 重新生成纪要：按当前转写（+底稿）重跑管线；旧 draft 待办清空，生成新版本。
    private func regenerateSummary() {
        Haptics.impact(.soft)
        session.regenerateWithBrief(
            clearDraftTodos: clearDraftTodos,
            persistTodos: persistTodos,
            persistSummary: persistSummary
        )
    }

    /// 清空本场 draft 待办（重新生成前调用，避免与新生成的待办重复；保留用户已分发的非 draft 项）。
    private func clearDraftTodos() {
        for item in meeting.actionItems where item.status == .draft {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func elapsedText(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// REVIEW 正文单层 Tab：扁平化「来源/笔记」二分为一排。每条模板笔记 = 一个独立 `.note(id)` 平级 Tab。
private enum ReviewTab: Hashable {
    case transcript       // 转写 + 录音 + 现场
    case summary          // 总结（默认选中 · 最高频路径）
    case note(UUID)       // 模板笔记：携带 AIOutput(.note) id；每条笔记独立平级 Tab
    case handwriting      // 手写笔记（Apple Pencil，会中记录 / 会后回看）
}

/// 一条已落定模板笔记的 Tab 槽位（平铺 Tab 栏用；id = AIOutput(.note) 的 id）。
private struct NoteTabSlot: Identifiable {
    let id: UUID
    let title: String
}

// MARK: - Process stage (整理态舞台)

/// 整理舞台：海獭 Mascot 悬浮 + 多重弥散极光 + Gemini 底部流光动效 + 逐字稿飞升 + 动态处理步骤。
/// 风格简洁、干净、高级（参考主流 AI 助手应用）。Reduce Motion 时静帧优雅呈现。
/// 会后任务 inline 进度：贴在转写 Tab 顶部，不随滚动、不污染总结/笔记 Tab。
/// 与 P0「成功静默」配合：进行中给一丝反馈；完成后此条消失，结果由说话人标签 / 优化稿呈现。
private struct PostMeetingProgressRow: View {
    let isDiarizing: Bool
    let diarizeProgress: Double?  // 0..1
    let isPolishing: Bool
    let isRetranscribing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var label: String {
        if isRetranscribing {
            return "正在重转写…"
        }
        if isDiarizing {
            if let p = diarizeProgress, p > 0.04 {
                return "识别说话人 · \(Int(p * 100))%"
            }
            return "正在识别说话人…"
        }
        return "正在优化原稿…"
    }

    private var fillFactor: Double {
        isDiarizing ? max(0.04, diarizeProgress ?? 0.04) : 1
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.recapInk)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 0.35 : 1)
                Text(label)
                    .font(.recapMeta.weight(.medium))
                    .foregroundStyle(Color.recapTea)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.recapInk.opacity(0.06))
                    Capsule().fill(Color.recapInk.opacity(0.75))
                        .frame(width: geo.size.width * fillFactor)
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
        .onAppear {
            // reduceMotion：进度点停满opacity静默，不脉动（进度条填充仍正常显示进度）。
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct ProcessStageCanvas: View {
    let title: String
    let subtitle: String?
    let ghostBlocks: [TranscriptBlock]
    let reduceMotion: Bool
    var showGhost: Bool = true
    var stage: PipelineStage = .idle

    @State private var appeared = false

    var body: some View {
        // 注意外层不再包 TimelineView：闭包不消费 context.date，只是把静态舞台以 30fps 空转
        // 重求值（ghost 字符流自带 TimelineView，才是动画源）。
        stageStack()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let anim: Animation = reduceMotion
                ? .easeOut(duration: 0.2)
                : .spring(response: 0.5, dampingFraction: 0.85)
            withAnimation(anim) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    private func stageStack() -> some View {
        VStack(spacing: Spacing.xl) {
            Spacer(minLength: 0)

            if showGhost, !ghostBlocks.isEmpty {
                TranscriptStreamFlowView(ghostBlocks: ghostBlocks, reduceMotion: reduceMotion)
            }

            signalCore()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessibilityLabelText: String {
        if let subtitle, !subtitle.isEmpty { return "\(title)，\(subtitle)" }
        return title
    }

    // atmosphere 已移除 —— 大面积 Gemini 渐变光晕已在 stageStack 底层提供足够的视觉氛围

    // MARK: - Core (海獭 Mascot + 流光轨 + 动态文案)

    private func signalCore() -> some View {
        // 单行当前阶段文案：去「梳理原稿」胶囊，只随真实阶段切一句。
        VStack(spacing: Spacing.xs) {
            Text(dynamicStatusTitle)
                .font(.recapTitleS)
                .tracking(0.8)
                .foregroundStyle(Color.recapInk.opacity(0.92))
                .multilineTextAlignment(.center)
                .id(dynamicStatusTitle)
                .transition(.opacity.combined(with: .offset(y: 4)))

            // 仅「无可用模型」引导态给次行；正常处理只留单行阶段文案。
            if let subtitleText = dynamicStatusSubtitle {
                Text(subtitleText)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .multilineTextAlignment(.center)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .padding(.horizontal, Spacing.xxl)
    }

    // MARK: - Copy Helper (阶段驱动的动态文案)

    /// 真实阶段永远优先：无 Key（「已保存」）时会后重转/整理链仍在跑——几分钟的云端精转
    /// 不能被静态「已保存」遮蔽成死屏（用户只看到「已保存 去设置配置模型」以为卡住）。
    /// 仅 idle/done 等无真实阶段的窗口才回落到传入 title（已保存 / 整理中）。
    private var dynamicStatusTitle: String {
        if stage.isProcessingStage { return stage.title }
        if !title.isEmpty { return title }
        return stage.title
    }

    private var dynamicStatusSubtitle: String? {
        // 正常处理（有 Key）只留单行阶段文案；仅在无 Key 等需要引导时给次行。
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return nil
    }
}

/// 贴底 AI 问答入口（电光青蓝绿胶囊）——点击即平滑进入对话窗。
///
/// 与 AgentInvokeSheet 的 compose 栏同构（同一 `aiComposeBarStyle`），让「底栏发问 → 对话窗回答」
/// 读作一条连续的 AI 表面。色系电光青·蓝·翠，与 LIVE 推理绿光晕(GeminiFluidGlowView)的青色端同谱。
private struct AgentAskBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let placeholder: String
    let onTap: () -> Void

    var body: some View {
        Button {
            Haptics.impact(.soft)
            onTap()
        } label: {
            HStack(spacing: Spacing.sm) {
                Text(placeholder)
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapTea.opacity(0.7))
                    .lineLimit(1)

                Spacer(minLength: 0)

                // 暗色待命发送钮（与 AgentInvokeSheet 空态同款）；进入对话窗后再聚焦输入。
                Image(systemName: RecapSymbol.send)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.recapTea)
                    .frame(width: 30, height: 30)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            // 显式命中形状：label 含 Spacer 大片空白，Button 默认只命中「渲染了内容的区域」
            // （左侧文字），导致点击右半（空白 + 发送钮）无反应。Capsule 与背景同形，整条胶囊均可触发。
            .contentShape(Capsule())
        }
        .buttonStyle(RecapPressStyle())
        .aiComposeBarStyle(focused: false, reduceMotion: reduceMotion)
        .accessibilityLabel("提问")
        .accessibilityHint("进入对话，对当前内容提问")
    }
}

/// 极简风格音频播放卡片
private struct AudioPlayerCard: View {
    @ObservedObject var player: MeetingAudioPlayer
    var onSeek15Back: () -> Void
    var onSeek15Forward: () -> Void
    var onSpeedToggle: () -> Void

    private func formatTime(_ s: TimeInterval) -> String {
        let total = max(0, Int(s))
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hrs, mins, secs)
    }

    private var speedLabel: String {
        switch player.rate {
        case 1.5: return "1.5x"
        case 2.0: return "2x"
        default: return "1x"
        }
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            // Line 1: Time
            HStack {
                Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                    .font(.recapMono)
                    .foregroundStyle(Color.recapTea)

                Spacer(minLength: 0)
            }

            // Line 2: Waveform bar
            AudioWaveformView(
                progress: player.duration > 0 ? player.currentTime / player.duration : 0
            )
            .frame(height: 36)

            // Line 3: 4 Control Buttons
            HStack(spacing: 0) {
                // 1. Play / Pause
                Button {
                    player.togglePlayPause()
                } label: {
                    Circle()
                        .fill(Color(light: 0xEEEEF0, dark: 0x1F2329))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.recapInk)
                        )
                }
                .frame(maxWidth: .infinity)

                // 2. Skip 15s Back
                Button {
                    onSeek15Back()
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.recapInk)
                }
                .frame(maxWidth: .infinity)

                // 3. Skip 15s Forward
                Button {
                    onSeek15Forward()
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(Color.recapInk)
                }
                .frame(maxWidth: .infinity)

                // 4. Speed & AI Enhance
                Button {
                    onSpeedToggle()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10))
                        Text(speedLabel)
                            .font(.recapMeta.weight(.semibold))
                    }
                    .foregroundStyle(Color.recapInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(light: 0xF1F3F5, dark: 0x22252A), in: Capsule())
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// 极简音频波形视图
private struct AudioWaveformView: View {
    var progress: Double = 0.0

    var body: some View {
        GeometryReader { geo in
            let count = 45
            let barWidth: CGFloat = 2.5
            let spacing = (geo.size.width - (CGFloat(count) * barWidth)) / CGFloat(count - 1)

            HStack(alignment: .center, spacing: max(1, spacing)) {
                ForEach(0..<count, id: \.self) { index in
                    let ratio = Double(index) / Double(count)
                    let isPlayed = ratio <= progress
                    let height = heightForBar(index: index, total: count, maxHeight: geo.size.height)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(isPlayed ? Color.recapInk : Color.recapTea.opacity(0.3))
                        .frame(width: barWidth, height: height)
                }
            }
        }
    }

    private func heightForBar(index: Int, total: Int, maxHeight: CGFloat) -> CGFloat {
        let seed = sin(Double(index) * 0.4) * cos(Double(index) * 0.7)
        let normalized = (abs(seed) * 0.75) + 0.25
        return CGFloat(normalized) * maxHeight
    }
}

/// 真实麦克风收音动态声波场
/// isCompact=true：有字幕时收缩为顶部常驻细带（~18pt），收音反馈不断；false：空场丰满大波形当主角。
/// 同一组件靠 isCompact 插值 frame/柱宽/文案显隐，避免 if/else 硬切。
/// 柱高 = 钟形包络 × (时间相位波动 · 音量增益) + 基底：时间相位保活（拾音弱/模拟器下也有呼吸），
/// audioPower 调制幅度（说话时显著放大）。与 LiveDots 同源，避免纯 power 驱动在信号弱时变成死水。
/// Transport Bar 状态点：恒为圆形——录音中朱砂柔呼吸，暂停时缩至赭石小点；
/// 颜色/尺寸随 isPaused 平滑插值，不做形状硬切（避免周期性跳变）。
private struct TransportStatusDot: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // TimelineView 驱动呼吸相位，暂停 / reduceMotion 时停摆——彻底消除 repeatForever 与
        // isPaused 两动画抢同一 scaleEffect/opacity 的冲突（原版暂停瞬间抖动的根因）。
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused || reduceMotion)) { context in
            let phase = reduceMotion ? 0.0 : sin(context.date.timeIntervalSinceReferenceDate * 2.2) * 0.5 + 0.5
            ZStack {
                // 颜色拆两层交叉淡入：避免朱砂 ↔ 茶跨色相在 RGB 中点过渡发脏（漏-1）。
                Circle().fill(Color.recapTea).opacity(isPaused ? 0.55 : 0)
                Circle()
                    .fill(Color.recapCinnabar)
                    .opacity(isPaused ? 0 : (reduceMotion ? 1.0 : 0.78 + phase * 0.22))
                    .scaleEffect(reduceMotion ? 1.0 : 1.0 + phase * 0.15)
            }
            .frame(width: 7, height: 7)
            .scaleEffect(isPaused ? 0.85 : 1.0)
        }
        .animation(.recapPausePhase, value: isPaused)
    }
}

private struct LiveWaveformVisualizer: View {
    let isPaused: Bool
    let bands: AudioBands
    var isCompact: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 录音↔暂停 平滑插值（0 录音中 · 1 已暂停）。幅度下沉 + 整体淡出，颜色不硬切。
    @State private var pausedBlend = 0.0

    private var barCount: Int { isCompact ? 24 : 32 }
    private var maxAmp: CGFloat { isCompact ? 10 : 44 }
    private var base: CGFloat { isCompact ? 3 : 4 }
    private var cap: CGFloat { isCompact ? 16 : 48 }

    var body: some View {
        VStack(spacing: isCompact ? Spacing.xs : Spacing.md) {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
                let t = reduceMotion ? 0.0 : context.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in
                    drawBars(ctx: ctx, size: size, t: t)
                }
            }
            .frame(height: isCompact ? 18 : 52)
            .opacity(0.4 + 0.6 * (1 - pausedBlend))

            // 引导文案仅丰满态显示；紧凑态淡出（由容器层 .animation(value: blocks.isEmpty) 驱动）
            if !isCompact {
                Text(isPaused ? "录音已暂停 · 可恢复录音或点按「完成」生成纪要" : "正在倾听中 · 开始讲话字幕实时呈现")
                    .font(.recapMeta.weight(.medium))
                    .foregroundStyle(Color.recapTea.opacity(0.85))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, isCompact ? Spacing.sm : Spacing.xl)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .recapSonicMorph, value: isCompact)
        .onAppear { pausedBlend = isPaused ? 1 : 0 }
        .onChange(of: isPaused) { _, paused in
            if reduceMotion {
                pausedBlend = paused ? 1 : 0
            } else {
                withAnimation(.recapPausePhase) { pausedBlend = paused ? 1 : 0 }
            }
        }
    }

    // MARK: - 绘制（单层 crisp 柱。2026-08-16 重做：旧版 bloom/halo/亮芯三层辉光在 3pt 柱距下
    // 交叠成雾，被判「不干净不高级」。高级感来自克制——细柱 · 等距留白 · 墨灰单色无辉光；
    // 朱砂让位状态点与 FAB：红=状态/动作，灰=仪表）
    private func drawBars(ctx: GraphicsContext, size: CGSize, t: Double) {
        let count = barCount
        let barWidth: CGFloat = isCompact ? 2.2 : 2.5
        let gap: CGFloat = isCompact ? 3.8 : 4.5
        let totalW = CGFloat(count) * barWidth + CGFloat(max(0, count - 1)) * gap
        let originX = (size.width - totalW) * 0.5
        let midY = size.height * 0.5

        for i in 0..<count {
            let h = barHeight(for: i, count: count, t: t)
            let rect = CGRect(
                x: originX + CGFloat(i) * (barWidth + gap),
                y: midY - h * 0.5,
                width: barWidth,
                height: max(h, barWidth)   // 柱高低于柱宽时退化为圆点（暂停沉底形态）
            )
            ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth * 0.5),
                     with: .color(Color.recapTea))
        }
    }

    /// 单根柱高：钟形包络 × (主体波动 + 高频 shimmer) + 基底。
    /// 主体由 low+mid 驱动（元音让中段鼓起），shimmer 由 high 驱动（擦音让边缘起细纹），
    /// 暂停向基底平滑下沉（pausedBlend 插值）。reduceMotion 走静态钟形。
    private func barHeight(for index: Int, count: Int, t: Double) -> CGFloat {
        let center = Double(count - 1) / 2
        let centerDist = abs(Double(index) - center) / max(center, 1)
        let bellFactor = cos(centerDist * .pi * 0.42)

        let activeClamped: CGFloat
        if reduceMotion {                                            // 静态钟形，无时间动画
            activeClamped = min(cap, max(base, bellFactor * maxAmp * 0.45 + base))
        } else {
            let phase = t * 1.8 + Double(index) * 0.55
            let body = 0.5 + 0.5 * sin(phase)                        // 0~1
            // 主体增益：low/mid 非线性放大（人声常处低位）+ high 轻度掺入（擦音仍可见），
            // 安静保底呼吸、元音显著鼓起；不再叠高频 shimmer——快相位毛刺即「脏」
            let lm = pow(Double(bands.low) * 0.55 + Double(bands.mid) * 0.30 + Double(bands.high) * 0.15, 0.8)
            let bodyGain = isCompact ? (0.4 + 0.6 * lm) : (0.28 + 0.72 * lm)
            let h = body * bodyGain * bellFactor * Double(maxAmp) + Double(base)
            activeClamped = min(cap, max(base, CGFloat(h)))
        }
        return activeClamped + (base - activeClamped) * CGFloat(pausedBlend)
    }
}

// MARK: - Drafting note (笔记 Tab 生成中流式态)

/// 笔记 Tab 内联生成中的纯 UI 本地态（落库前不进 SwiftData/NoteIndex）。
/// `Equatable` 让 SwiftUI 廉价 diff（高频 onProgress 只触发 struct diff；
/// 昂贵的 Markdown 解析由 `AskMarkdownText` 内部 50ms 防抖兜底）。
private struct DraftingNoteState: Equatable, Identifiable {
    let id: UUID                 // 创建时一次性；SwiftUI diff 锚点 + 防过期回调串扰
    let skill: AgentSkill
    var partialText: String = "" // 流式累积正文
    var toolSteps: [String] = [] // 近期工具步骤原始串（按 tool 前缀折叠、末 3 条），展示时清洗去前缀
    var statusLine: String?      // 无 tool 步骤时的初始/预算状态行
    var error: String?           // 非 nil → 失败分支（仅重试）
}

/// 弱化版 AI 声明：与总结（`summaryNoteView`）一致的居中小字，替代笔记层的 ochre 色块。
/// 生成态（`DraftingNoteView`）与落定态（`noteInlineView`）共用，配合外层 `.id("note-stream")`
/// 同骨架，让流式→落定过渡平滑（声明样式不跳变）。
private struct AILightDisclaimer: View {
    var body: some View {
        Text("内容由 AI 生成，仅供参考")
            .font(.recapMeta)
            .foregroundStyle(Color.recapTea.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.bottom, Spacing.xs)
    }
}

// MARK: - 笔记生成过程（轨迹清洗 helpers）

/// `"search_meetings · 历史会议 3 场"` → `"历史会议 3 场"`。
/// 取首个 ` · ` 之后整段，兼容摘要自带 ` · `（如「技能 · 销售复盘」）。
private func cleanToolSummary(_ line: String) -> String {
    guard let r = line.range(of: " · ") else { return line }
    return String(line[r.upperBound...])
}

/// `"search_meetings · 历史会议 3 场"` → `"search_meetings"`；无分隔符返回 nil。
private func toolNamePrefix(_ line: String) -> String? {
    guard let r = line.range(of: " · ") else { return nil }
    return String(line[..<r.lowerBound])
}

/// 按 tool 前缀折叠：同一工具的「调用中…」→「结果」合并成一条演化行，避免脏「调用中…」残留；取末 3 条。
private func collapsedToolSteps(_ raw: [String]) -> [String] {
    var out: [String] = []
    for line in raw {
        let tool = toolNamePrefix(line)
        if let last = out.last, toolNamePrefix(last) == tool, tool != nil {
            out[out.count - 1] = line
        } else {
            out.append(line)
        }
    }
    return Array(out.suffix(3))
}

/// 笔记 Tab 生成中视图：模板名标题 + Agent 步骤淡化轨迹 → 流式正文（`AskMarkdownText` isStreaming）+ 极简「生成中」页脚。
/// 抽成独立 struct 作 diff 边界，避免高频 token 重绘整个 `MeetingNoteView`。
/// 与落定态 `noteInlineView` 同骨架（标题 = skill.name 落定后不变），配合外层 `.id("note-stream")`
/// 让 SwiftUI 合并子树：流式→落定 仅轨迹淡出 + isStreaming 翻转，正文/@State 连续不闪。
/// 生成中不显 AI 声明、不显「取消」（失败仅留「重试」，切走自清）。
private struct DraftingNoteView: View {
    let state: DraftingNoteState
    let onRetry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(state.skill.name)
                .font(.recapTitle)
                .foregroundStyle(Color.recapInk)

            if let error = state.error {
                failureCard(error)
            } else if state.partialText.isEmpty {
                // 首字未到：Agent 执行中 → 近期步骤淡化轨迹（已完成暗、当前呼吸点）
                agentTrace
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                // 正文流出：轨迹淡出、正文淡入 + 极简页脚（标题已是 skill 名，不重复模板名）
                AskMarkdownText(source: state.partialText, isStreaming: true)
                generationFooter
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .recapSoft, value: state.partialText.isEmpty)
        .animation(reduceMotion ? nil : .recapSoft, value: state.toolSteps)
    }

    /// Agent 执行轨迹：近期工具步骤纵向排列；当前（末）步呼吸点 + 高亮，已完成步静态暗点 + 淡化。
    /// 文案清洗掉 `toolName · ` 技术前缀，只留人话摘要（「历史会议 3 场」「已读网页」…）。
    private var agentTrace: some View {
        let steps = state.toolSteps
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(steps.enumerated()), id: \.element) { idx, raw in
                let isCurrent = idx == steps.count - 1
                HStack(spacing: 8) {
                    if isCurrent {
                        PulsingDot()
                    } else {
                        Circle()
                            .fill(Color.recapInk.opacity(0.25))
                            .frame(width: 6, height: 6)
                    }
                    Text(cleanToolSummary(raw))
                        .font(.recapMeta.weight(isCurrent ? .medium : .regular))
                        .foregroundStyle(isCurrent ? Color.recapTea : Color.recapTea.opacity(0.75))
                        .lineLimit(1)
                }
            }
            if steps.isEmpty {
                // 首步未到：兜底单行（无步骤亦不空场）
                HStack(spacing: 8) {
                    PulsingDot()
                    Text(state.statusLine ?? "正在用「\(state.skill.name)」生成…")
                        .font(.recapMeta.weight(.medium))
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(steps.isEmpty
            ? "正在生成笔记"
            : "正在生成笔记，当前：\(cleanToolSummary(steps.last!))")
    }

    /// 正文流式中的极简页脚：呼吸点 + 「生成中」。
    private var generationFooter: some View {
        HStack(spacing: 6) {
            PulsingDot()
            Text("生成中")
                .font(.recapMeta.weight(.medium))
                .foregroundStyle(Color.recapTea)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在生成笔记")
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("生成失败")
                .font(.recapHeading)
                .foregroundStyle(Color.recapOchre)
            Text(message)
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            HStack {
                Spacer()
                Button {
                    Haptics.impact(.light)
                    onRetry()
                } label: {
                    Text("重试")
                        .font(.recapHeading)
                        .foregroundStyle(Color.recapInk)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.top, Spacing.xs)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.recapOchre.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("生成失败，\(message)，可重试")
    }
}

/// 呼吸圆点（与 `PostMeetingProgressRow` 同源的呼吸节奏，克制的过程反馈）。
private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.recapInk)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 0.35 : 1)
            .onAppear {
                // reduceMotion：停在稳态满opacity（pulse=false→1），不脉动；与全屏其余动效一致。
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

