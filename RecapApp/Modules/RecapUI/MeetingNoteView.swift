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
    @State private var showMinutesVersions = false
    /// 对话窗下拉关闭的实时位移（橡皮筋跟随）。
    @State private var agentDragOffset: CGFloat = 0
    /// 对话窗上下文快照：openAgent 先以空快照让 sheet 轻量滑入，真实整场转写在下一 runloop 填充——
    /// 避免拼大串阻塞 spring 首帧（点击卡顿 + 动效被吞的根因）。LIVE 增长时持续推送。
    @State private var agentTranscript: String = ""
    @State private var agentSegments: [TranscriptSegment] = []
    /// REVIEW 正文单层 Tab：转写 / 总结（默认）/ 笔记（模板产物，下拉切换）。
    @State private var reviewTab: ReviewTab = .summary
    /// 笔记 Tab 当前指向的模板笔记（仅 reviewTab == .note 时生效）。
    @State private var selectedNote: NoteTarget = .summary
    @State private var pendingScrollStart: Double?
    @State private var showTemplateSelection = false
    /// 内联生成中的模板笔记（落库前纯 UI 本地态；不进 SwiftData/NoteIndex）。
    @State private var draftingNote: DraftingNoteState?
    @State private var draftingTask: Task<Void, Never>?
    @State private var noteNoKeyError: String?
    @State private var showEndLiveConfirm = false
    @State private var showDeleteLiveConfirm = false
    @State private var showResearchProgress = false
    @State private var showResearchDraft = false
    @State private var selectedResearchDraft: ResearchDraft?
    @State private var researchError: String?
    @State private var orphanResearchMessage: String?
    /// 会中拍照取景 Overlay（锚定到打开瞬间的会议秒）。
    @State private var showMomentCapture = false
    @State private var momentCaptureAnchor: Int = 0
    /// 手写画布当前笔画（真相源在父 View，modal 关闭/重开不丢笔画）。
    @State private var liveDrawing: PKDrawing = PKDrawing()
    /// 会中手写预览：停笔 1.5s 后异步识别，画布上方渐进出文字（不落库）。
    @State private var liveRecognizedPreview: String = ""
    @State private var liveRecognizeTask: Task<Void, Never>?
    /// 会中手写全屏画布（tap 动作坞手写钮打开；PKToolPicker 在其内部浮起，不挡主界面）。
    @State private var showLiveHandwriting = false
    /// 打开手写瞬间的会议秒 —— HandwritingNote 锚点（对齐相机 momentCaptureAnchor）。
    @State private var handwritingAnchor: Double = 0
    /// 会后「手写」tab 续写编辑器。
    @State private var showHandwritingEditor = false
    @State private var reviewDrawing: PKDrawing = PKDrawing()
    /// 全屏图库当前查看的会议时刻。
    @State private var galleryMoment: Moment?
    /// 完成 → 纪要的收束桥：字幕残影 + 控件退场（不入库）。
    @State private var isSettling = false
    /// REVIEW 底栏延迟滑入，避免与 Settling 抢戏。
    @State private var showReviewBottom = false
    /// LIVE：贴底才自动跟随；上滑回看后停跟，需点「回到最新」。
    @State private var isFollowingLive = true
    @State private var missedLiveBlocks = 0
    @State private var liveDistanceFromBottom: CGFloat = 0
    /// 程序化 scrollTo 期间忽略几何回调，避免误判「离开底部」。
    @State private var suppressLiveFollowUpdate = false
    @StateObject private var audioPlayer = MeetingAudioPlayer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private var researchRunner: AgentTaskRunner { AgentTaskRunner.shared }

    public init(meeting: Meeting, onDismiss: @escaping () -> Void = {}) {
        self.meeting = meeting
        self.onDismiss = onDismiss
        _session = StateObject(wrappedValue: MeetingSession(meeting: meeting))
    }

    private var sortedItems: [ActionItem] {
        meeting.actionItems.sorted { a, b in
            if a.isLowConfidence != b.isLowConfidence { return a.isLowConfidence && !b.isLowConfidence }
            return (a.startSeconds ?? 0) < (b.startSeconds ?? 0)
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
        VStack(spacing: 0) {
            customTopBar
            content
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
        .onChange(of: session.blocks.count) { _, _ in
            // LIVE 边录边问：转写增长时把新快照推给已展开的对话窗（首帧已错开，此处非动画期，同步可接受）。
            guard showAgent else { return }
            agentTranscript = transcriptContext
            agentSegments = askSegments
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
        .sheet(isPresented: $showResearchProgress) {
            ResearchProgressSheet(
                runner: researchRunner,
                isPresented: $showResearchProgress,
                onOpenDraft: {
                    if let draft = researchRunner.latestDraft {
                        selectedResearchDraft = draft
                    } else if let id = researchRunner.current?.draftOutputId,
                              let draft = meeting.outputs.first(where: { $0.id == id })?.researchDraftPayload {
                        selectedResearchDraft = draft
                    }
                    showResearchDraft = selectedResearchDraft != nil
                }
            )
            .presentationBackground(Color.recapBg)
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
        .alert("无法开始调研", isPresented: Binding(
            get: { researchError != nil },
            set: { if !$0 { researchError = nil } }
        )) {
            Button("好", role: .cancel) { researchError = nil }
        } message: {
            Text(researchError ?? "")
        }
        .alert("调研未在运行", isPresented: Binding(
            get: { orphanResearchMessage != nil },
            set: { if !$0 { orphanResearchMessage = nil } }
        )) {
            Button("好", role: .cancel) { orphanResearchMessage = nil }
        } message: {
            Text(orphanResearchMessage ?? "")
        }
        .alert("无法生成笔记", isPresented: Binding(
            get: { noteNoKeyError != nil },
            set: { if !$0 { noteNoKeyError = nil } }
        )) {
            Button("好", role: .cancel) { noteNoKeyError = nil }
        } message: {
            Text(noteNoKeyError ?? "")
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
        .task {
            // 用 task 而非 onAppear：等视图进入层级后再启动，减少转场卡顿
            session.checkpointSaver = { [modelContext] in
                try? modelContext.save()
            }
            researchRunner.bind(modelContext: modelContext)
            session.onAppear()
            if session.phase == .review {
                showReviewBottom = true
            }
            if meeting.phase == .processing || session.phase == .processing {
                session.resumeOrRecoverProcessing(
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
            case .active:
                // #6a：回前台重排被后台取消的会后任务（幂等：已完成/在跑均跳过）
                session.reschedulePostMeetingCompute()
            default:
                break
            }
        }
        .onDisappear {
            draftingTask?.cancel()
            session.pauseOrTeardownForDisappear()
            audioPlayer.stop()
        }
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

    /// 仅无 Key 时给次行；有 Key 时不说话，留给动效。
    private var processHeroSubtitle: String? {
        MinutesPipelineSmoke.canRunMinutesPipeline
            ? nil
            : "去设置配置模型后可生成纪要"
    }

    private var hasLocalAudio: Bool {
        guard let path = meeting.audioPath else { return false }
        return MeetingAudioStore.fileExists(storedPath: path)
    }

    // MARK: Top bar

    /// 自绘顶栏。LIVE = Transport Bar（暂停·状态簇·停止，声波居中连接）；REVIEW = 返回·标题·分享+更多。
    private var customTopBar: some View {
        let isLiveInteractive = session.phase == .live && !isSettling
        return VStack(spacing: Spacing.xs) {
            if session.phase == .review {
                reviewTopBar
            } else if isLiveInteractive {
                liveTransportBar
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    /// LIVE「Transport Bar」：暂停(左) · 状态簇[呼吸点+时长+声波](中·点按收起) · 停止(右)。
    /// 声波做连接两端控制的视觉组织；无最小化钮/更多入口——退出靠点状态簇或下拉（抓手暗示）。
    private var liveTransportBar: some View {
        VStack(spacing: Spacing.xs) {
            HStack(alignment: .center, spacing: 0) {
                liveTopPauseButton
                Spacer(minLength: Spacing.md)
                liveTransportCenter
                Spacer(minLength: Spacing.md)
                liveTopStopButton
            }

            // 极轻抓手：暗示「下拉 / 点按收起」，替代原左上最小化钮
            Image(systemName: RecapSymbol.dismissDown)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.recapInk.opacity(0.22))
        }
    }

    /// Transport Bar 中央状态簇：呼吸点 + 录音时长 + 紧凑声波。点按 → 收起（替代最小化钮）。
    private var liveTransportCenter: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                TransportStatusDot(isPaused: session.isLivePaused)
                Text(elapsedText(session.elapsed))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(session.isLivePaused ? Color.recapTea : Color.recapInk)
            }
            PlaudLiveWaveformVisualizer(
                isPaused: session.isLivePaused,
                audioPower: session.liveAudioPower,
                isCompact: true
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { dismissFromTopBar() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.isLivePaused
            ? "已暂停，时长 \(elapsedText(session.elapsed))，轻点收起"
            : "正在录音，时长 \(elapsedText(session.elapsed))，轻点收起")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { dismissFromTopBar() }
    }

    /// REVIEW 顶栏：返回 · 标题 · 分享 + 更多。
    private var reviewTopBar: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                dismissFromTopBar()
            } label: {
                Image(systemName: RecapSymbol.back)
                    .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                    .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                    .contentShape(Circle())
            }
            .buttonStyle(RecapPressStyle())
            .accessibilityLabel(topBarDismissAccessibilityLabel)

            Spacer(minLength: 0)
            reviewTopBarTitle
            Spacer(minLength: 0)

            ShareLink(item: currentNoteMarkdown, subject: Text(meeting.title)) {
                Image(systemName: RecapSymbol.share)
                    .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                    .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                    .contentShape(Circle())
            }
            .buttonStyle(RecapPressStyle())

            meetingMoreMenu
        }
    }

    /// 顶栏·暂停/继续（紧凑圆钮；原底部大 hero 迁此）。录音界面被点最多次，但录音态被动、
    /// 声波胶囊已承担「录音中」信号，故缩成顶栏小钮可接受。
    private var liveTopPauseButton: some View {
        Button {
            Haptics.impact(.light)
            if session.isLivePaused {
                session.resumeLive()
            } else {
                session.pauseLive()
            }
        } label: {
            Image(systemName: session.isLivePaused ? "play" : "pause")
                .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                .contentShape(Circle())
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel(session.isLivePaused ? "继续录音" : "暂停录音")
        .accessibilityHint(session.isLivePaused ? "恢复收音" : "停止收音，可继续或结束")
    }

    /// 顶栏·停止（紧凑圆钮）。终态动作，仍走 showEndLiveConfirm 确认弹窗兜底。
    private var liveTopStopButton: some View {
        Button {
            Haptics.impact(.medium)
            showEndLiveConfirm = true
        } label: {
            Image(systemName: RecapSymbol.stop)
                .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                .contentShape(Circle())
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("结束录音")
        .accessibilityHint("结束本场录音，由 AI 自动生成结构化会议纪要")
    }

    /// REVIEW 顶栏标题区：跨 Tab、随滚动常驻显示会议标题（标题只在顶栏，正文不再重复）。
    private var reviewTopBarTitle: some View {
        Text(meeting.title.isEmpty ? "未命名会议" : meeting.title)
            .font(.system(size: 16, weight: .semibold))
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

    /// 整理态全屏极简舞台。
    private var processingStage: some View {
        ZStack(alignment: .bottom) {
            Color.recapBg
                .ignoresSafeArea()

            GeminiFluidGlowView(reduceMotion: reduceMotion)
                .frame(height: UIScreen.main.bounds.height * 0.65)
                .ignoresSafeArea(.all, edges: .bottom)

            ProcessStageCanvas(
                title: processHeroTitle,
                subtitle: processHeroSubtitle,
                ghostBlocks: Array(session.blocks.suffix(5)),
                reduceMotion: reduceMotion,
                showGhost: true,
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

    /// 会中手写全屏画布（PKToolPicker 在其内部浮起；「完成」置于顶部，躲开底部工具箱）。
    /// drawing 真相源为本 View 的 @State liveDrawing，modal 关闭/重开笔画结构性保留。
    private var liveHandwritingCover: some View {
        VStack(spacing: 0) {
            // 顶部栏：锚点提示 + 完成（置于顶部，远离底部 PKToolPicker）
            HStack(spacing: Spacing.sm) {
                Text("手写 · 锚定 \(elapsedText(Int(handwritingAnchor)))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    Haptics.impact(.light)
                    commitLiveHandwriting(anchorSeconds: handwritingAnchor)
                    showLiveHandwriting = false
                } label: {
                    Text("完成")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs)
                }
                .buttonStyle(RecapPressStyle())
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.sm)

            if !liveRecognizedPreview.isEmpty {
                Text(liveRecognizedPreview)
                    .font(.recapRaw)
                    .foregroundStyle(Color.recapTea)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xs)
                    .transition(.opacity)
            }

            HandwritingCanvasView(drawing: $liveDrawing)
                .background(Color.recapPaper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.recapPaper)
        .animation(.recapSoft, value: liveRecognizedPreview.isEmpty)
        .onChange(of: liveDrawing) { _, newDrawing in
            scheduleLiveHandwritingPreview(newDrawing)
        }
    }

    /// 停笔 debounce 预览识别：每次 drawing 变化重置 1.5s 计时，停笔后异步识别填预览。
    private func scheduleLiveHandwritingPreview(_ drawing: PKDrawing) {
        liveRecognizeTask?.cancel()
        guard !drawing.strokes.isEmpty else {
            liveRecognizedPreview = ""
            return
        }
        liveRecognizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            liveRecognizedPreview = await HandwritingRecognitionService.shared.previewText(for: drawing)
        }
    }

    /// 保存当前手写：落盘 stroke.pencilkit + 落库 HandwritingNote + 异步识别，然后清空画布。
    /// anchorSeconds = 打开手写瞬间（对齐相机 momentCaptureAnchor），而非提交瞬间。
    private func commitLiveHandwriting(anchorSeconds: Double) {
        guard !liveDrawing.strokes.isEmpty else { return }
        let note = HandwritingNote(
            drawingRelativePath: "",
            startSeconds: anchorSeconds,
            meeting: meeting
        )
        // 落盘（失败则路径留空，识别仍可走内存 drawing）。
        note.drawingRelativePath = (try? HandwritingStore.save(
            liveDrawing, meetingId: meeting.id, noteId: note.id)) ?? ""
        // 若已有 debounce 预览结果，直接用（省一次 OCR）；否则走异步幂等识别。
        let preview = liveRecognizedPreview
        if !preview.isEmpty {
            note.recognizedText = String(preview.prefix(2_000))
            note.title = preview.split(separator: "\n").first.map(String.init)
        }
        modelContext.insert(note)
        try? modelContext.save()
        if note.recognizedText == nil {
            HandwritingRecognitionService.shared.extractIfAbsent(for: note, drawing: liveDrawing)
        }
        liveRecognizeTask?.cancel()
        liveRecognizedPreview = ""
        liveDrawing = PKDrawing()   // 清空，准备下一段
    }

    private var liveRecordingOrPausedContent: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // 仅暂停后且真有待办时提示；启动台 / 录音中不出现
                        if session.isLivePaused && session.hasStartedRecording && session.todoCount > 0 {
                            AgentPresenceBar(todoCount: session.todoCount)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.top, Spacing.sm)
                                .padding(.bottom, Spacing.md)
                        } else {
                            Color.clear.frame(height: Spacing.md)
                        }

                        // 声波已上移至顶栏 Transport Bar（屏内唯一一条，避免双声波抢戏）


                        ForEach(session.blocks) { block in
                            let isLast = block.id == session.blocks.last?.id
                            SpeakerBlockView(
                                block: block,
                                isCurrent: isLast && !block.isFinal,
                                showLiveMeter: liveShowsListeningIndicator && isLast
                            )
                            .id(block.id)
                            .padding(.horizontal, Spacing.xl)
                        }

                        liveStreamFooter
                            .padding(.leading, Spacing.xl + 2 + Spacing.md) // 与字幕文字栏对齐（竖条 + 间距）
                            .padding(.trailing, Spacing.xl)
                            .padding(.top, session.blocks.isEmpty ? Spacing.sm : 0)
                            .padding(.bottom, Spacing.xxl)
                            .id("live-stream-end")

                        // 底部避让留白：滚到底时让最后一条字幕与悬浮底栏（主控/完成/问 Recap）
                        // 拉开呼吸间距，避免被遮挡；同时作为自动跟随 scrollTo 的锚点。
                        Color.clear
                            .frame(height: Spacing.huge)
                            .id("live-bottom-inset")

                        if session.liveStartFailed {
                            liveFailureActions
                                .padding(.horizontal, Spacing.xl)
                                .padding(.bottom, Spacing.xxl)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    max(0, geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height)
                } action: { _, distance in
                    liveDistanceFromBottom = distance
                    guard !suppressLiveFollowUpdate else { return }
                    updateLiveFollowFromDistance(distance)
                }
                .onScrollPhaseChange { _, phase in
                    guard phase == .idle, !suppressLiveFollowUpdate else { return }
                    updateLiveFollowFromDistance(liveDistanceFromBottom)
                }
                .onChange(of: session.blocks.count) { oldCount, newCount in
                    if isFollowingLive {
                        scrollLiveToLatest(proxy: proxy)
                    } else if newCount > oldCount {
                        missedLiveBlocks += newCount - oldCount
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
            .animation(.recapPhaseBar, value: isFollowingLive)
            .animation(reduceMotion ? nil : .recapSonicMorph, value: session.blocks.isEmpty)
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
        // 锚定底部避让留白（而非最后一条字幕）：最新字幕随 footer 上移，与悬浮底栏拉开呼吸间距，
        // 避免 scrollTo(.bottom) 在 safeAreaInset 边界处把末段压到底栏背后。
        if reduceMotion {
            proxy.scrollTo("live-bottom-inset", anchor: .bottom)
        } else {
            withAnimation(.recapLiveFollow) {
                proxy.scrollTo("live-bottom-inset", anchor: .bottom)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            suppressLiveFollowUpdate = false
            liveDistanceFromBottom = 0
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
                        .font(.system(size: 13, weight: .semibold, design: .default))
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
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .tracking(0.3)
                        .foregroundStyle(liveStatusColor)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(liveFooterAccessibilityLabel)
            }
        }
    }

    private var liveEmptyPrompt: String {
        if session.isLivePaused {
            // 暂停后空字幕的边角提示
            return "可继续，或点右侧完成"
        }
        return "开始讲话，字幕会出现在这里"
    }

    private var topBarDismissAccessibilityLabel: String {
        if session.phase == .live && !isSettling { return "暂停并收起" }
        return "返回"
    }

    /// 异常 / 暂停 / 演示才出字；正常收音不写「正在收音」。
    private var liveStatusLabel: String {
        if session.isUsingMockAudio { return "演示字幕" }
        if session.isLivePaused {
            // 暂停态始终显「已暂停」，不被迟到/陈旧 statusMessage 盖住（pauseLive 已摘除回调）
            guard session.hasStartedRecording else { return "" }
            return "已暂停"
        }
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

    private var endLiveConfirmMessage: String {
        if session.blocks.isEmpty {
            return "还没有字幕。结束将停止录音并进入整理。"
        }
        return "将停止录音并开始整理纪要，此操作不可撤销。"
    }

    /// #5：当前麦克风权限被拒 → 失败态给「打开设置」入口，避免死路。
    private var liveMicPermissionDenied: Bool {
        AVAudioApplication.shared.recordPermission != .granted
    }

    private var liveFailureActions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if liveMicPermissionDenied {
                Text("麦克风权限未开启，请在系统设置中允许后返回重试")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.recapTea)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("打开设置")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.recapCeladon)
                }
            }
            Button("重试转写引擎") {
                session.retryLiveRecording()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.recapCeladon)
            #if DEBUG
            Button("改用演示字幕（DEBUG）") {
                session.startExplicitDemoLive()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.recapTea)
            #endif
        }
    }

    // MARK: PROCESS / REVIEW

    private var reviewContent: some View {
        VStack(spacing: 0) {
            reviewTabBar
            // 会后任务 inline 进度：仅转写 Tab、进行中时贴顶显示（不随滚动、不污染其他 Tab）
            Group {
                if reviewTab == .transcript, session.isDiarizing || session.isPolishing {
                    PostMeetingProgressRow(
                        isDiarizing: session.isDiarizing,
                        diarizeProgress: session.diarizeProgress,
                        isPolishing: session.isPolishing
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.recapSoft, value: session.isDiarizing)
            .animation(.recapSoft, value: session.isPolishing)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.xxl) {
                        // revealStep==0：标题只在顶栏；有内容后再在正文展开
                        if !session.statusMessage.isEmpty,
                           session.revealStep >= 1 || session.phase == .review {
                            Text(session.statusMessage)
                                .font(.recapMeta)
                                .foregroundStyle(Color.recapOchre)
                        }
                        switch reviewTab {
                        case .transcript: transcriptBody
                        case .summary:    summaryNoteView
                        case .note:       noteTabContent
                        case .handwriting: handwritingTabContent
                        }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, 130)
                }
                .scrollContentBackground(.hidden)
                .onChange(of: pendingScrollStart) { _, start in
                    guard let start, reviewTab == .transcript else { return }
                    scrollTranscript(proxy: proxy, startSeconds: start)
                }
                .onChange(of: reviewTab) { _, tab in
                    guard tab == .transcript, let start = pendingScrollStart else { return }
                    scrollTranscript(proxy: proxy, startSeconds: start)
                }
                .onChange(of: session.isDiarizing) { was, now in
                    // 分离结束且已写入 spk*：切到转写，结果只在那里可见
                    guard was, !now else { return }
                    guard meeting.speakers.contains(where: { $0.id.hasPrefix("spk") }) else { return }
                    withAnimation(.recapSoft) { reviewTab = .transcript }
                }
            }
        }
    }

    /// 手写笔记 Tab（会后）：列出本场手写记录（原笔迹缩略图 + 时间 + 识别文字），可续写新建。
    private var handwritingTabContent: some View {
        Group {
            if meeting.handwritingNotes.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "pencil.tip.crop.circle")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.recapTea.opacity(0.6))
                    Text("会中用 Apple Pencil 写下的笔记会出现在这里")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                    reviewHandwritingAddButton
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.xxxl)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        ForEach(meeting.handwritingNotes.sorted { $0.startSeconds < $1.startSeconds }) { note in
                            HStack(alignment: .top, spacing: Spacing.md) {
                                // 原笔迹缩略图（从磁盘 load；手写记录少，同步 load 可接受，P2 可改异步）
                                if let drawing = HandwritingStore.load(storedPath: note.drawingRelativePath) {
                                    Image(uiImage: drawing.image(
                                        from: drawing.bounds.isEmpty
                                            ? CGRect(x: 0, y: 0, width: 1, height: 1)
                                            : drawing.bounds,
                                        scale: UIScreen.main.scale
                                    ))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 64, height: 64)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    Text(note.sourceTime)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.recapTea)
                                    Text(verbatim: (note.recognizedText?.isEmpty == false)
                                         ? note.recognizedText!
                                         : (note.recognizedText == nil ? "识别中…" : "（未识别到文字）"))
                                        .font(.recapRaw)
                                        .foregroundStyle(Color.recapInk)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(Spacing.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.recapPaper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                            .contextMenu {
                                Button("删除", role: .destructive) {
                                    deleteHandwritingNote(note)
                                }
                            }
                        }
                        reviewHandwritingAddButton
                            .padding(.top, Spacing.md)
                    }
                    .padding(.horizontal, Spacing.md)
                }
            }
        }
        .fullScreenCover(isPresented: $showHandwritingEditor) {
            handwritingReviewEditor
        }
    }

    /// 续写笔记按钮（会后新建手写）。
    private var reviewHandwritingAddButton: some View {
        Button {
            Haptics.impact(.light)
            reviewDrawing = PKDrawing()
            showHandwritingEditor = true
        } label: {
            Label("续写笔记", systemImage: "square.and.pencil")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapCeladon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
        }
        .buttonStyle(.plain)
    }

    /// 会后手写编辑器：全屏画布 + 取消/保存。
    private var handwritingReviewEditor: some View {
        NavigationStack {
            HandwritingCanvasView(drawing: $reviewDrawing)
                .background(Color.recapPaper)
                .navigationTitle("手写笔记")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { showHandwritingEditor = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") { commitReviewHandwriting() }
                            .disabled(reviewDrawing.strokes.isEmpty)
                    }
                }
        }
    }

    /// 保存会后手写（startSeconds 兜底会议时长——会后续记无实时锚）。
    private func commitReviewHandwriting() {
        guard !reviewDrawing.strokes.isEmpty else { return }
        let note = HandwritingNote(
            drawingRelativePath: "",
            startSeconds: meeting.durationSeconds,
            meeting: meeting
        )
        note.drawingRelativePath = (try? HandwritingStore.save(
            reviewDrawing, meetingId: meeting.id, noteId: note.id)) ?? ""
        modelContext.insert(note)
        try? modelContext.save()
        HandwritingRecognitionService.shared.extractIfAbsent(for: note, drawing: reviewDrawing)
        reviewDrawing = PKDrawing()
        showHandwritingEditor = false
    }

    /// 删除一条手写笔记（清模型 + 删 stroke.pencilkit 文件目录）。
    private func deleteHandwritingNote(_ note: HandwritingNote) {
        if let url = try? HandwritingStore.resolveURL(storedPath: note.drawingRelativePath) {
            // 删整个 <noteId>/ 目录（含 stroke.pencilkit）
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        modelContext.delete(note)
        try? modelContext.save()
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

    private static func parseTimestamp(_ ts: String) -> Double {
        let parts = ts.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return 0 }
        return Double(parts[0] * 60 + parts[1])
    }

    private var titleMeta: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            TextField("未命名会议", text: $meeting.title)
                .font(.recapH1)
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
                .font(.recapH1)
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
                    .foregroundStyle(Color.recapTea.opacity(0.6))
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
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.recapCeladon)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.recapCeladon.opacity(0.12), in: Capsule())
                }
                .buttonStyle(RecapPressStyle())
                .accessibilityLabel("纪要版本历史")
            }
        }
    }

    // MARK: Notes tab（笔记层）

    /// 单层 Tab 栏：转写 / 总结 / 笔记∨。复用「H1 + 墨色下划线」视觉语言，
    /// sticky 挂在正文顶部，扁平化原「来源/笔记」二分（去掉一层认知负担）。
    private var reviewTabBar: some View {
        HStack(spacing: 28) {
            reviewTabButton("转写", .transcript)
            reviewTabButton("总结", .summary)
            // 有笔记（含生成中草稿）时挂切换器；「＋ 笔记」独立常驻其右，新建入口永不藏进下拉
            if hasAnyNote {
                reviewNoteSwitcherButton
            }
            reviewNewNoteButton
            reviewTabButton("手写", .handwriting)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
    }

    private func reviewTabButton(_ title: String, _ tab: ReviewTab) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.recapSoft) { reviewTab = tab }
        } label: {
            tabLabel(title, isActive: reviewTab == tab, showChevron: false)
        }
        .buttonStyle(.plain)
    }

    /// 是否存在任何笔记标签（已落定 或 生成中本地草稿）：决定切换器是否显示。
    /// 含 draftingNote 是为了让首个笔记生成中也保有「笔记 Tab 选中态」下划线，而非孤零零的禁用按钮。
    private var hasAnyNote: Bool {
        !templateNoteItems.isEmpty || draftingNote != nil
    }

    /// 笔记切换器：下拉切换本场已落定的模板笔记（不含新建——新建走右侧常驻入口）。
    @ViewBuilder
    private var reviewNoteSwitcherButton: some View {
        Menu {
            ForEach(templateNoteItems) { item in
                Button {
                    openNote(item.target)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        } label: {
            tabLabel(currentNoteTabTitle, isActive: reviewTab == .note, showChevron: true)
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
        .buttonStyle(.plain)
        .disabled(draftingNote != nil)
        .accessibilityLabel("新建笔记")
    }

    /// Tab 标签：标题 + 可选下拉箭头，底部 24×2.5 墨色下划线指示选中态。
    @ViewBuilder
    private func tabLabel(_ title: String, isActive: Bool, showChevron: Bool) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? Color.recapInk : Color.recapTea)
                if showChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isActive ? Color.recapInk : Color.recapTea)
                }
            }
            Rectangle()
                .fill(isActive ? Color.recapInk : Color.clear)
                .frame(width: 24, height: 2.5)
                .cornerRadius(1)
        }
    }

    /// 笔记∨ Tab 标签标题：选中模板笔记时显模板名，否则「笔记」。
    private var currentNoteTabTitle: String {
        if let draftingNote {
            return draftingNote.skill.name
        }
        if case .note(let id) = selectedNote {
            return meeting.outputs.first(where: { $0.id == id })?.notePayload?.title ?? "笔记"
        }
        return "笔记"
    }

    /// 总结笔记：整理态隐藏 AI 声明，保持纯净舞台；完成后展开声明与正文（会议标题已常驻顶栏，正文不再重复）。
    private var summaryNoteView: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if session.revealStep >= 1 || session.phase == .review {
                Text("内容由 AI 生成，仅供参考")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.recapTea.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
                    .padding(.bottom, Spacing.xs)
            }

            summaryBody
        }
    }

    /// 模板产物笔记（.note）：ochre AI 声明 + 笔记标题 + markdown 正文（`AskMarkdownText` 页面级渲染）。
    @ViewBuilder
    private func noteInlineView(_ id: UUID) -> some View {
        if let payload = meeting.outputs.first(where: { $0.id == id })?.notePayload {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                AIDisclaimerBanner()
                Text(payload.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.recapInk)
                if payload.skillId == "mindmap" {
                    MindmapInlineCard(source: payload.body, title: payload.title)
                } else {
                    AskMarkdownText(source: payload.body, isStreaming: false)
                }
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
                onCancel: {
                    draftingTask?.cancel()
                    draftingNote = nil
                },
                onRetry: {
                    guard let skill = draftingNote?.skill else { return }
                    draftingNote = nil
                    startNoteDrafting(skill)
                }
            )
            .id("note-stream")
        } else if case .note(let id) = selectedNote {
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.recapTea)
            Button {
                showTemplateSelection = true
            } label: {
                Text("生成对外纪要 / 思维导图…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.recapCeladon)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
    }

    /// 笔记∨ 下拉项：本场所有笔记排除「总结」（总结已是平级 Tab，不再收入模板下拉）。
    private var templateNoteItems: [NoteItem] {
        allNoteItems.filter { item in
            if case .summary = item.target { return false }
            return true
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
        switch selectedNote {
        case .note(let id):
            if let payload = meeting.outputs.first(where: { $0.id == id })?.notePayload {
                return "# \(payload.title)\n\n\(payload.body)"
            }
            return shareMarkdown
        case .summary, .researchDraft, .researchTask:
            return shareMarkdown
        }
    }

    /// switcher 下拉点选：总结/笔记 → inline 切换；调研草稿 / 进行中任务 → 打开既有 sheet。
    private func openNote(_ target: NoteTarget) {
        switch target {
        case .summary:
            Haptics.selection()
            withAnimation(.recapSoft) {
                selectedNote = .summary
                reviewTab = .summary
            }
        case .note(let id):
            Haptics.selection()
            withAnimation(.recapSoft) {
                selectedNote = .note(id)
                reviewTab = .note
            }
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

    /// 在笔记 Tab 内联流式生成模板笔记：选模板后立即关 sheet → 进 drafting 态 →
    /// 流式冒字 → 落库后自然替换为真实笔记（标题不变，过渡平滑）。失败/取消留可恢复入口。
    private func startNoteDrafting(_ skill: AgentSkill) {
        // 预检密钥——set draftingNote 之前拦截，避免空卡闪烁
        guard MinutesPipelineSmoke.canRunMinutesPipeline else {
            noteNoKeyError = "未配置可用的大模型密钥，请先在设置里配置。"
            return
        }
        // 防连点：已有草稿则忽略（失败态重试由 onRetry 先清空再进入）
        guard draftingNote == nil else { return }
        draftingTask?.cancel()
        let noteId = UUID()
        draftingNote = DraftingNoteState(id: noteId, skill: skill)
        withAnimation(.recapSoft) { reviewTab = .note }
        draftingTask = Task { @MainActor in
            do {
                let id = try await SkillNoteWriter.generate(
                    skill: skill,
                    context: makeAgentToolContext(),
                    meeting: meeting,
                    modelContext: modelContext,
                    onProgress: { progress in
                        // onProgress 是 @Sendable、来自非主线程——跳 MainActor（对齐既有调用点）
                        Task { @MainActor in
                            guard draftingNote?.id == noteId else { return }   // 防过期回调串扰
                            if !progress.partialText.isEmpty {
                                draftingNote?.partialText = progress.partialText
                                draftingNote?.statusLine = nil
                            } else if let s = progress.status {
                                draftingNote?.statusLine = s
                            } else if let last = progress.toolLines.last {
                                draftingNote?.statusLine = last
                            }
                        }
                    }
                )
                // 同事务落定——标题同 skill.name 不变，SwiftUI 合并子树
                withAnimation(.recapSoft) {
                    selectedNote = .note(id)
                    draftingNote = nil
                }
            } catch is CancellationError {
                draftingNote = nil
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
            // 稳定 id：避免流式每次改文触发 insertion transition 叠出两张卡
            // 首段可轻上移；后续段只 fade，避免连续瀑布感
            if session.revealStep >= 1, !session.summary.tldr.isEmpty {
                TldrCard(text: session.summary.tldr)
                    .id("summary-tldr")
                    .transition(revealTransition(isPrimary: true))
            }
            if session.revealStep >= 2, !session.summary.topics.isEmpty {
                topicsSection
                    .id("summary-topics")
                    .transition(revealTransition(isPrimary: false))
            } else if session.revealStep >= 1, let brief = meeting.brief, !brief.agenda.isEmpty {
                agendaSection(brief)
                    .id("summary-agenda")
                    .transition(revealTransition(isPrimary: session.summary.tldr.isEmpty))
            }
            if session.revealStep >= 1, let brief = meeting.brief, !brief.openItems.isEmpty {
                openItemsSection(brief)
                    .id("summary-open-items")
                    .transition(revealTransition(isPrimary: false))
            }
            if session.revealStep >= 3, !session.summary.decisions.isEmpty {
                decisionSection
                    .id("summary-decisions")
                    .transition(revealTransition(isPrimary: false))
            }
            if session.revealStep >= 4 {
                todoSection
                    .id("summary-todos")
                    .transition(revealTransition(isPrimary: false))
            }
            if session.revealStep >= 5, !session.summary.openQuestions.isEmpty {
                openQuestionSection
                    .id("summary-questions")
                    .transition(revealTransition(isPrimary: false))
            }
        }
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "list.bullet.indent", "议题纪要", color: Color.recapCeladon, count: session.summary.topics.count)
            VStack(alignment: .leading, spacing: Spacing.lg) {
                ForEach(Array(session.summary.topics.enumerated()), id: \.offset) { _, topic in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(topic.title)
                            .font(.recapRaw.weight(.semibold))
                            .foregroundStyle(Color.recapInk)
                        ForEach(topic.bullets, id: \.self) { bullet in
                            bulletRow(bullet, color: Color.recapCeladon, ink: Color.recapInk)
                        }
                    }
                }
            }
        }
    }

    private func agendaSection(_ brief: MeetingBrief) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "list.bullet.rectangle", "对照议程", color: Color.recapCeladon, count: brief.agenda.count)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(brief.agenda.sorted(by: { $0.order < $1.order })) { item in
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Text("\(item.order)")
                            .font(.recapTimestamp)
                            .foregroundStyle(Color.recapCeladon)
                            .frame(width: 18, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.recapRaw)
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
                                .foregroundStyle(item.resolution == "closed" ? Color.recapCeladon : Color.recapOchre)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.text)
                                    .font(.recapRaw)
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
            sectionTitle(systemImage: "sparkles", "关键决议", color: Color.recapCeladon)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(session.summary.decisions, id: \.self) { d in
                    bulletRow(d, color: Color.recapCeladon, ink: Color.recapInk)
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
        if researchRunner.isBusy {
            if let current = researchRunner.current,
               current.actionItemId == item.id || researchInProgress(for: item)?.id == current.id {
                showResearchProgress = true
                return
            }
            showResearchProgress = true
            return
        }
        do {
            try researchRunner.enqueue(actionItem: item, meeting: meeting)
            showResearchProgress = true
        } catch let error as AgentTaskRunnerError {
            if case .alreadyRunning = error {
                showResearchProgress = true
            } else {
                researchError = error.localizedDescription
            }
        } catch {
            researchError = error.localizedDescription
        }
    }

    private func openResearchProgress(taskId: UUID) {
        researchRunner.bind(modelContext: modelContext)
        if researchRunner.current?.id == taskId, researchRunner.isBusy {
            showResearchProgress = true
            return
        }
        if let task = meeting.agentTasks.first(where: { $0.id == taskId }),
           researchRunner.current?.id == task.id {
            showResearchProgress = true
            return
        }
        let objective = meeting.agentTasks.first(where: { $0.id == taskId })?.objective
        orphanResearchMessage = objective.map {
            "「\($0)」不在内存中，可能已中断。可从待办重新「让 AI 跟进」。"
        } ?? "该调研不在内存中，可能已中断。可从待办重新跟进。"
    }

    private func clearDraftTodosForRegen() {
        let drafts = meeting.actionItems.filter { $0.status == .draft }
        for item in drafts {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private var shareMarkdown: String {
        var lines: [String] = ["# \(meeting.title)", ""]
        let summary = session.summary
        if !summary.tldr.isEmpty {
            lines.append(summary.tldr)
            lines.append("")
        }
        if !summary.topics.isEmpty {
            lines.append("## 议题纪要")
            for topic in summary.topics {
                lines.append("### \(topic.title)")
                for b in topic.bullets { lines.append("- \(b)") }
                lines.append("")
            }
        }
        if !summary.decisions.isEmpty {
            lines.append("## 关键决议")
            for d in summary.decisions { lines.append("- \(d)") }
            lines.append("")
        }
        if !sortedItems.isEmpty {
            lines.append("## 待办事项")
            for item in sortedItems {
                let owner = item.owner.map { " — \($0)" } ?? ""
                lines.append("- [ ] \(item.task)\(owner)")
            }
            lines.append("")
        }
        if !summary.openQuestions.isEmpty {
            lines.append("## 未决问题")
            for q in summary.openQuestions { lines.append("- \(q)") }
        }
        return lines.joined(separator: "\n")
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
        guard audioPlayer.isReady else { return nil }
        let t = audioPlayer.currentTime
        return reviewTranscriptBlocks.last(where: { blockStartSeconds($0) <= t })?.id
    }

    private func blockStartSeconds(_ block: TranscriptBlock) -> Double {
        block.startSeconds ?? Self.parseTimestamp(block.timestamp)
    }

    private var openQuestionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle(systemImage: "questionmark.circle.fill", "未决问题", color: Color.recapOchre)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(session.summary.openQuestions, id: \.self) { q in
                    bulletRow(q, color: Color.recapOchre, ink: Color.recapTea)
                }
            }
        }
    }

    private func bulletRow(_ text: String, color: Color, ink: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Circle().fill(color).frame(width: 5, height: 5).padding(.top, 7)
            Text(text).font(.recapRaw).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionTitle(systemImage: String, _ text: String, color: Color, count: Int? = nil) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.recapInk)
            if let c = count {
                Text("\(c)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(Color.recapTea)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(light: 0xF1F3F5, dark: 0x22252A), in: Capsule())
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // 音频播放控制卡片：仅有本地录音时显示；进入即预载，避免 play 静默失效
            // （「转写」标题已由 sticky reviewTabBar 承担，正文不再重复 H1）
            if hasLocalAudio {
                PlaudAudioPlayerCard(
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
                        onSeek: hasLocalAudio
                            ? { openAudioPlayer(seekTo: blockStartSeconds(block), autoplay: true) }
                            : nil
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
                if showReviewBottom {
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

    /// LIVE 底部动作坞：拍照 · 手写(iPad) · 问AI —— 三个同级 glass 钮，各自 tap → 打开一个 overlay
    /// （相机取景 / 手写画布 / AI 对话窗），交互模式统一。主界面无画布 → PKToolPicker 不会遮挡此处。
    private var liveActionDock: some View {
        HStack(alignment: .top, spacing: 0) {
            cameraLiveBottomButton
            Spacer(minLength: Spacing.md)
            if UIDevice.current.userInterfaceIdiom == .pad {
                handwritingLiveBottomButton
                Spacer(minLength: Spacing.md)
            }
            askLiveBottomButton
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .contentShape(Rectangle())
    }

    /// 打开 AI 对话窗：底栏胶囊淡出、对话窗从底部 spring 滑起、compose 聚焦键盘只升一次。
    /// prefill 恒空 → AgentInvokeSheet 落到 focus 分支，键盘不中断。
    private func openAgent() {
        Haptics.impact(.soft)
        agentPrefill = ""
        // 先以空快照翻转 showAgent：sheet 用空 context 轻量构造，spring 首帧得以正常提交。
        agentTranscript = ""
        agentSegments = []
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
        withAnimation(.recapBottomExit) {
            showAgent = false
            agentDragOffset = 0
        }
        agentPrefill = ""
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
            RecapGlassAuxIcon(RecapSymbol.ask)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("问 Recap")
        .accessibilityHint(
            session.hasStartedRecording
                ? "开会走神时补课，不影响录音"
                : "可先问议程或资料，再开始录音"
        )
    }

    /// 底部动作坞·手写（仅 iPad）：打开全屏画布，锚定到打开瞬间的会议秒。
    private var handwritingLiveBottomButton: some View {
        Button {
            Haptics.impact(.soft)
            handwritingAnchor = Double(session.elapsed)
            showLiveHandwriting = true
        } label: {
            RecapGlassAuxIcon(RecapSymbol.handwrite)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("手写笔记")
        .accessibilityHint("打开全屏画布随手记，锚定到录音当前秒，不打断录音")
    }

    /// 底部动作坞·拍照：记录此刻，锚定到当前秒。
    private var cameraLiveBottomButton: some View {
        Button {
            Haptics.impact(.soft)
            momentCaptureAnchor = session.elapsed
            showMomentCapture = true
        } label: {
            RecapGlassAuxIcon(RecapSymbol.camera)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("记录此刻")
        .accessibilityHint("拍下白板或此刻，锚定到录音当前秒，不打断录音")
    }

    /// AI 对话窗 overlay：对话窗从底部平滑滑起、键盘不中断。
    ///
    /// 三层（自底向上）：① backdrop 暗化，盖住仍驻留的 reviewBottom；
    /// ② AgentInvokeSheet 表面（从底部 spring 滑入）；③ grabber 下拉命中区（不抢 ScrollView 滚动）。
    /// ZStack 常驻：backdrop 始终在视图树 → opacity 0↔0.5 由 .animation 驱动出渐变暗化（不再随首帧瞬切），
    /// sheet 的 .move(edge:.bottom) 在稳定容器内播放。空闲态 backdrop opacity 0 + allowsHitTesting(false)，几乎零成本。
    @ViewBuilder private var agentOverlay: some View {
        ZStack(alignment: .bottom) {
            // ① Backdrop：暗化并盖住 reviewBottom
            Color.recapInk
                .opacity(showAgent ? 0.5 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(showAgent)
                .onTapGesture { closeAgent() }

            // ② Agent 表面：从底部作为一条连续 AI 表面滑入
            if showAgent {
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
                    linkedMeetingTitle: meeting.brief?.sources.first(where: { $0.kind == .linkedMeeting })?.title,
                    onJumpToTranscript: { start in
                        jumpToTranscript(startSeconds: start)
                    },
                    onMinutesUpdated: { summary in
                        session.summary = summary
                    },
                    initialInput: agentPrefill,
                    autoSendInitial: true,
                    isPresented: $showAgent
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .offset(y: agentDragOffset)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            }

            // ③ Grabber 下拉命中区（顶部 30pt；grabber 视觉由 AgentInvokeSheet 顶部占位）
            if showAgent {
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .contentShape(Rectangle())
                    .gesture(agentDragGesture)
                    .accessibilityHidden(true)
            }
        }
        .animation(showAgent ? .recapSheet : .recapBottomExit, value: showAgent)
    }

    /// 会后底栏：全局虹彩悬浮 Ask Bar——对话=横切工具，对「当前正在看的内容」提问。
    /// placeholder 随 Tab 语义切换（转写/总结/此笔记），不割裂「边看边问」。
    private var reviewBottom: some View {
        PlaudAskBar(placeholder: askPlaceholder, onTap: openAgent)
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.sm)
            // 对话窗滑起时淡出底栏胶囊，避免与升起的对话窗重影
            .opacity(showAgent ? 0 : 1)
    }

    /// AskBar 文案随当前 Tab 切换：让"对话=对当前内容提问"的心智显式化。
    private var askPlaceholder: String {
        switch reviewTab {
        case .transcript: return "对这段转写提问"
        case .summary:    return "对这份总结提问"
        case .note:       return "对此笔记提问"
        case .handwriting: return "对手写笔记提问"
        }
    }

    /// 低频破坏动作：删除进「更多」，也可在首页列表左滑/长按删除。
    private var meetingMoreMenu: some View {
        Menu {
            // 逐字稿 LLM 润色（补标点 / 纠错别字 / 最小书面化），保段双行展示；不依赖端侧 ASR
            if session.phase == .review, !session.blocks.isEmpty {
                Button {
                    session.polishTranscript()
                    withAnimation(.recapSoft) { reviewTab = .transcript }
                } label: {
                    Label("优化原稿（补标点·纠错）", systemImage: "wand.and.stars")
                }
            }
            // 端侧高保真重转（仅 REVIEW + feature flag 开 + 有本地录音时显示）
            if session.phase == .review,
               ASRFeatureFlags.fluidRetranscribeEnabled,
               meeting.audioPath != nil {
                Menu {
                    Button {
                        session.retranscribeFromDisk(engineKind: .fluidSenseVoice)
                        withAnimation(.recapSoft) { reviewTab = .transcript }
                    } label: {
                        Label("SenseVoice · 中英混排", systemImage: "waveform")
                    }
                    Button {
                        session.retranscribeFromDisk(engineKind: .fluidParaformer)
                        withAnimation(.recapSoft) { reviewTab = .transcript }
                    } label: {
                        Label("Paraformer · 纯中文最准", systemImage: "waveform")
                    }
                } label: {
                    Label("端侧高保真重转", systemImage: "iphone.radiowaves.left.and.right")
                }
            }
            Button(role: .destructive) {
                showDeleteLiveConfirm = true
            } label: {
                Label("删除本场", systemImage: RecapSymbol.delete)
            }
        } label: {
            Image(systemName: RecapSymbol.more)
                .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                .contentShape(Circle())
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("更多")
        .accessibilityHint("删除本场等操作")
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

    private func persistTodos(_ items: [TodoListPayload.Item]) {
        for item in items {
            let due = item.due_text.flatMap { DueTextParser.parse($0) }
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
                modelId: LLMPresets.deepSeekPro,
                promptHash: "minutes-v3",
                version: (meeting.latestSummaryOutput?.version ?? 0) + 1,
                meeting: meeting
            ))
            try? modelContext.save()
        }
    }

    private func elapsedText(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// REVIEW 正文单层 Tab：扁平化「来源/笔记」二分为一排。
private enum ReviewTab: Hashable {
    case transcript  // 转写 + 录音 + 现场
    case summary     // 总结（默认选中 · 最高频路径）
    case note        // 笔记：模板产物（.note / 调研草稿，下拉切换）
    case handwriting // 手写笔记（Apple Pencil，会中记录 / 会后回看）
}

// MARK: - Process stage (整理态舞台)

/// 整理舞台：海獭 Mascot 悬浮 + 多重弥散极光 + Gemini 底部流光动效 + 逐字稿飞升 + 动态处理步骤。
/// 风格简洁、干净、高级（参考 Plaud AI 与 Google Gemini APP）。Reduce Motion 时静帧优雅呈现。
/// 会后任务 inline 进度：贴在转写 Tab 顶部，不随滚动、不污染总结/笔记 Tab。
/// 与 P0「成功静默」配合：进行中给一丝反馈；完成后此条消失，结果由说话人标签 / 双行原稿呈现。
private struct PostMeetingProgressRow: View {
    let isDiarizing: Bool
    let diarizeProgress: Double?  // 0..1
    let isPolishing: Bool
    @State private var pulse = false

    private var label: String {
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
                    .fill(Color.recapCeladon)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 0.35 : 1)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.recapTea)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.recapInk.opacity(0.06))
                    Capsule().fill(Color.recapCeladon.opacity(0.75))
                        .frame(width: geo.size.width * fillFactor)
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)
        .padding(.bottom, Spacing.md)
        .onAppear {
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
        Group {
            if reduceMotion {
                stageStack()
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { _ in
                    stageStack()
                }
            }
        }
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
        VStack(spacing: Spacing.xs) {
            // 步骤胶囊 Badge：仅 organizing/generating 显示（idle/done 隐藏）
            if !stage.badge.isEmpty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(hex: 0x6ECE9E))
                        .frame(width: 6, height: 6)
                    Text(stage.badge)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.recapTea)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Color.recapInk.opacity(0.04),
                    in: Capsule()
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Text(dynamicStatusTitle)
                .font(.system(size: 16, weight: .semibold, design: .default))
                .tracking(0.8)
                .foregroundStyle(Color.recapInk.opacity(0.92))
                .multilineTextAlignment(.center)
                .id(dynamicStatusTitle)
                .transition(.opacity.combined(with: .offset(y: 4)))

            if let subtitleText = dynamicStatusSubtitle {
                Text(subtitleText)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(Color.recapTea)
                    .multilineTextAlignment(.center)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .padding(.horizontal, Spacing.xxl)
    }

    // MARK: - Copy Helper (阶段驱动的动态文案)

    /// 非「整理中」（无 Key 的「已保存」等）沿用传入 title；否则由 stage 提供真实阶段文案。
    private var dynamicStatusTitle: String {
        if title != "整理中" && !title.isEmpty { return title }
        return stage.title
    }

    private var dynamicStatusSubtitle: String? {
        if let subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if MinutesPipelineSmoke.canRunMinutesPipeline {
            return "Recap AI 智能提炼中"
        }
        return nil
    }
}

/// 贴底 AI 问答入口（电光青蓝绿胶囊）——点击即平滑进入对话窗。
///
/// 与 AgentInvokeSheet 的 compose 栏同构（同一 `aiComposeBarStyle`），让「底栏发问 → 对话窗回答」
/// 读作一条连续的 AI 表面。色系电光青·蓝·翠，与 LIVE 推理绿光晕(GeminiFluidGlowView)的青色端同谱。
private struct PlaudAskBar: View {
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
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // 暗色待命发送钮（与 AgentInvokeSheet 空态同款）；进入对话窗后再聚焦输入。
                Image(systemName: RecapSymbol.send)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.recapTea)
                    .frame(width: 30, height: 30)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(height: 44)
        }
        .buttonStyle(RecapPressStyle())
        .aiComposeBarStyle(focused: false, reduceMotion: reduceMotion)
        .accessibilityLabel("问 Recap")
        .accessibilityHint("进入对话，对当前内容提问")
    }
}

/// Plaud AI 风格音频播放卡片
private struct PlaudAudioPlayerCard: View {
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
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.recapTea)

                Spacer(minLength: 0)
            }

            // Line 2: Waveform bar
            PlaudAudioWaveformView(
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
                            .font(.system(size: 13, weight: .semibold))
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

/// Plaud AI 极简音频波形视图
private struct PlaudAudioWaveformView: View {
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

/// Plaud AI 真实麦克风收音动态声波场
/// isCompact=true：有字幕时收缩为顶部常驻细带（~18pt），收音反馈不断；false：空场丰满大波形当主角。
/// 同一组件靠 isCompact 插值 frame/柱宽/文案显隐，避免 if/else 硬切。
/// 柱高 = 钟形包络 × (时间相位波动 · 音量增益) + 基底：时间相位保活（拾音弱/模拟器下也有呼吸），
/// audioPower 调制幅度（说话时显著放大）。与 LiveDots 同源，避免纯 power 驱动在信号弱时变成死水。
/// Transport Bar 状态点：录音中 = 朱砂呼吸圆，暂停 = 灰方块（无动画）。
private struct TransportStatusDot: View {
    let isPaused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        if isPaused {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.recapTea.opacity(0.5))
                .frame(width: 7, height: 7)
        } else {
            Circle()
                .fill(Color.recapCinnabar)
                .frame(width: 7, height: 7)
                .scaleEffect(reduceMotion ? 1 : (breathing ? 1.2 : 0.8))
                .opacity(reduceMotion ? 1 : (breathing ? 1.0 : 0.55))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: breathing
                )
                .onAppear { breathing = true }
        }
    }
}

private struct PlaudLiveWaveformVisualizer: View {
    let isPaused: Bool
    let audioPower: Float
    var isCompact: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: isCompact ? Spacing.xs : Spacing.md) {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: isCompact ? 2.5 : 3.5) {
                    ForEach(0..<36, id: \.self) { i in
                        let height = barHeight(for: i, time: t)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(
                                isPaused
                                    ? AnyShapeStyle(Color.recapTea.opacity(0.3))
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [
                                            Color.recapCinnabar,
                                            Color(hex: 0xFF6B5B)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ))
                            )
                            .frame(width: isCompact ? 2.5 : 3, height: height)
                    }
                }
            }
            .frame(height: isCompact ? 18 : 52)

            // 引导文案仅丰满态显示；紧凑态淡出（由容器层 .animation(value: blocks.isEmpty) 驱动）
            if !isCompact {
                Text(isPaused ? "录音已暂停 · 可恢复录音或点按「完成」生成纪要" : "正在倾听中 · 开始讲话字幕实时呈现")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.recapTea.opacity(0.85))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, isCompact ? Spacing.sm : Spacing.xl)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .recapSonicMorph, value: isCompact)
    }

    /// 单根柱高：钟形包络 × (时间波动 · 音量增益) + 基底。
    private func barHeight(for index: Int, time t: Double) -> CGFloat {
        let centerDist = abs(Double(index) - 17.5) / 17.5
        let bellFactor = cos(centerDist * .pi * 0.42)
        let maxAmp: CGFloat = isCompact ? 13 : 44
        let base: CGFloat = isCompact ? 3 : 4
        let cap: CGFloat = isCompact ? 16 : 48

        if isPaused { return base }                                  // 暂停：低平（下一帧生效，即时）
        if reduceMotion {                                            // 静态钟形，无时间动画
            return min(cap, max(base, bellFactor * maxAmp * 0.45 + base))
        }

        // 相位错开：每根柱独立呼吸，读起来像声场起伏而非整体齐跳
        let phase = t * 5.5 + Double(index) * 0.45
        let wave = 0.5 + 0.5 * sin(phase)                            // 0~1
        // 音量增益：非线性放大低位 power（人声常处 0.05~0.4），安静保底噪呼吸、说话显著放大
        let raw = max(0, min(1, Double(audioPower)))
        let power = pow(raw, 0.55)
        let gain = isCompact ? (0.4 + 0.6 * power) : (0.28 + 0.72 * power)
        let dynamicHeight = CGFloat(wave) * CGFloat(gain) * bellFactor * maxAmp + base
        return min(cap, max(base, dynamicHeight))
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
    var statusLine: String?      // 工具/状态行（"查阅本场转写…"）
    var error: String?           // 非 nil → 失败分支（重试/取消）
}

/// 笔记 Tab 生成中视图：AIDisclaimerBanner + 模板名标题 + 流式正文（`AskMarkdownText` isStreaming）。
/// 抽成独立 struct 作 diff 边界，避免高频 token 重绘整个 `MeetingNoteView`。
/// 与落定态 `noteInlineView` 同骨架（标题 = skill.name 落定后不变），配合外层 `.id("note-stream")`
/// 让 SwiftUI 合并子树：流式→落定 仅状态行淡出 + isStreaming 翻转，正文/@State 连续不闪。
private struct DraftingNoteView: View {
    let state: DraftingNoteState
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var statusText: String {
        state.statusLine ?? "正在用「\(state.skill.name)」生成…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            AIDisclaimerBanner()
            Text(state.skill.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.recapInk)

            if let error = state.error {
                failureCard(error)
            } else if state.partialText.isEmpty {
                // 首字未到：只显状态行（不显空正文区，避免占位跳动）
                statusRow
            } else {
                AskMarkdownText(source: state.partialText, isStreaming: true)
                statusRow
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            PulsingDot()
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.recapTea)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                Haptics.impact(.light)
                onCancel()
            } label: {
                Text("取消")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.recapCinnabar)
            }
            .buttonStyle(.plain)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在生成笔记：\(statusText)")
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("生成失败")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapOchre)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.recapTea)
            HStack(spacing: Spacing.lg) {
                Button {
                    Haptics.impact(.light)
                    onRetry()
                } label: {
                    Text("重试")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.recapCeladon)
                }
                .buttonStyle(.plain)
                Button {
                    Haptics.impact(.light)
                    onCancel()
                } label: {
                    Text("取消")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.recapTea)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.recapOchre.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("生成失败，\(message)，可重试或取消")
    }
}

/// 呼吸圆点（与 `PostMeetingProgressRow` 同源的呼吸节奏，克制的过程反馈）。
private struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.recapCeladon)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

