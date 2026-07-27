import SwiftUI
import SwiftData
import UIKit
import AVFoundation
import RecapModels
import RecapLLM
import RecapASR
import RecapPersistence

/// 纪要界面（一个屏 · 三态自适应 · @Model 直驱）。
public struct MeetingNoteView: View {
    @Bindable var meeting: Meeting
    @StateObject private var session: MeetingSession
    @Environment(\.modelContext) private var modelContext
    var onDismiss: () -> Void

    @State private var showAgent = false
    @State private var agentPrefill = ""
    @State private var showMinutesVersions = false
    @State private var agentDetent: PresentationDetent = .large
    /// REVIEW 正文两 Tab：原稿（转写+录音+现场）/ 笔记（模板产物·默认）。
    @State private var reviewTab: ReviewTab = .notes
    /// 笔记 Tab 当前选中的笔记（switcher 驱动 inline 渲染）。
    @State private var selectedNote: NoteTarget = .summary
    /// Segmented 选中胶囊在「摘要/逐字稿」间滑动的命名空间。
    @Namespace private var segNamespace
    @State private var pendingScrollStart: Double?
    @State private var showAudioPlayer = false
    @State private var showTemplateSelection = false
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
                if showAudioPlayer {
                    MeetingAudioPlayerBar(player: audioPlayer) {
                        closeAudioPlayer()
                    }
                }
                bottomBar
            }
            .animation(.recapSheet, value: showAudioPlayer)
            .animation(settlingAnimation, value: isSettling)
            .animation(.recapPhaseBar, value: session.isLivePaused)
            .animation(.recapPhaseBar, value: session.hasStartedRecording)
            .animation(showReviewBottom ? .recapSheet : .recapBottomExit, value: showReviewBottom)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showAgent) {
            AgentInvokeSheet(
                meeting: meeting,
                phase: session.phase,
                transcriptContext: transcriptContext,
                segments: askSegments,
                speakers: meeting.speakers,
                meetingTitle: meeting.title,
                actionItems: meeting.actionItems,
                minutesSummary: meeting.latestSummary,
                briefSummary: meeting.briefPromptSummary,
                briefSources: meeting.brief?.sources ?? [],
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
                isPresented: $showAgent
            )
            .presentationDetents([.medium, .large], selection: $agentDetent)
            .presentationDragIndicator(.visible)
            .presentationBackground(Color.recapBg)
            .onAppear { agentDetent = .large }
            .onDisappear { agentPrefill = "" }
        }
        .sheet(isPresented: $showTemplateSelection) {
            TemplateSelectionSheet(
                isPresented: $showTemplateSelection,
                meetingTitle: meeting.title,
                meeting: meeting,
                agentToolContext: makeAgentToolContext(),
                onGenerated: { id in
                    withAnimation(.recapSoft) { selectedNote = .note(id) }
                    reviewTab = .notes
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

    /// 自绘顶栏。LIVE 阶段：左侧保留最小化收起按钮 (chevron.down)，居中挂载声波时间胶囊 (LiveSonicCapsule)。
    private var customTopBar: some View {
        let isLiveInteractive = session.phase == .live && !isSettling
        return HStack(spacing: Spacing.sm) {
            // 左侧控制按钮：LIVE 阶段为最小化收起 (chevron.down)，REVIEW 阶段为返回 (chevron.left)
            Button {
                dismissFromTopBar()
            } label: {
                Image(systemName: session.phase == .live ? RecapSymbol.dismissDown : RecapSymbol.back)
                    .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                    .contentShape(Circle())
            }
            .buttonStyle(RecapPressStyle())
            .accessibilityLabel(topBarDismissAccessibilityLabel)
            .disabled(isSettling)

            Spacer(minLength: 0)

            if isLiveInteractive {
                if session.hasStartedRecording {
                    meetingMoreMenu
                }
            }

            if session.phase == .review {
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
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .overlay {
            if isLiveInteractive {
                LiveSonicCapsule(
                    isPaused: session.isLivePaused,
                    elapsedTimeText: elapsedText(session.elapsed)
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .onTapGesture {
                    dismissFromTopBar()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(capsuleAccessibilityLabel)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { dismissFromTopBar() }
            } else if session.phase == .review {
                HStack(spacing: 24) {
                    segHeaderButton("来源", .source)
                    segHeaderButton("笔记", .notes)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isSettling {
            settlingStage
        } else {
            switch session.phase {
            case .live: liveContent
            case .processing, .review: reviewContent
            }
        }
    }

    /// 幕② Settling：字幕沉底残影 + 墨线舞台（与 Process Hero 共用）。
    private var settlingStage: some View {
        ProcessStageCanvas(
            title: processHeroTitle,
            subtitle: processHeroSubtitle,
            ghostBlocks: Array(session.blocks.suffix(5)),
            reduceMotion: reduceMotion,
            showGhost: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    // MARK: LIVE

    private var liveContent: some View {
        // 会前启动台已移除：进会即开麦，录音舞台本身承担「准备中 → 收音」过渡
        liveRecordingOrPausedContent
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

                        if session.blocks.isEmpty && !session.liveStartFailed {
                            PlaudLiveWaveformVisualizer(
                                isPaused: session.isLivePaused,
                                audioPower: session.liveAudioPower
                            )
                            .padding(.horizontal, Spacing.xl)
                            .padding(.bottom, Spacing.md)

                            // #8：空场文字引导（首跑无字幕 / 暂停空场），接回原 dead-code liveEmptyPrompt 文案
                            Text(liveEmptyPrompt)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.recapTea.opacity(0.9))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.bottom, Spacing.lg)
                        }

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
        guard let last = session.blocks.last else { return }
        suppressLiveFollowUpdate = true
        if reduceMotion {
            proxy.scrollTo(last.id, anchor: .bottom)
        } else {
            withAnimation(.recapLiveFollow) {
                proxy.scrollTo(last.id, anchor: .bottom)
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

    /// 流末：空场才挂波形；有字幕时波形跟当前行。异常/暂停才出短句。
    private var liveStreamFooter: some View {
        Group {
            if session.blocks.isEmpty || !liveStatusLabel.isEmpty {
                HStack(alignment: .center, spacing: 8) {
                    if session.blocks.isEmpty && liveShowsListeningIndicator {
                        LiveDots()
                    }
                    if !liveStatusLabel.isEmpty {
                        Text(liveStatusLabel)
                            .font(.system(size: 12, weight: .medium, design: .default))
                            .tracking(0.3)
                            .foregroundStyle(liveStatusColor)
                    }
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

    /// #M6：声波时间胶囊的 VoiceOver 标签（含状态与时长），点按 = 暂停并收起。
    private var capsuleAccessibilityLabel: String {
        let time = elapsedText(session.elapsed)
        return session.isLivePaused ? "已暂停，已录制 \(time)" : "录音中，已录制 \(time)"
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
                    if reviewTab == .source { transcriptBody } else { notesBody }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.md)
                .padding(.bottom, 130)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: pendingScrollStart) { _, start in
                guard let start, reviewTab == .source else { return }
                scrollTranscript(proxy: proxy, startSeconds: start)
            }
            .onChange(of: reviewTab) { _, tab in
                guard tab == .source, let start = pendingScrollStart else { return }
                scrollTranscript(proxy: proxy, startSeconds: start)
            }
            .onChange(of: session.isDiarizing) { was, now in
                // 分离结束且已写入 spk*：切到逐字稿，结果只在那里可见
                guard was, !now else { return }
                guard meeting.speakers.contains(where: { $0.id.hasPrefix("spk") }) else { return }
                withAnimation(.recapSoft) { reviewTab = .source }
            }
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

    private func segHeaderButton(_ title: String, _ tab: ReviewTab) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.recapSoft) { reviewTab = tab }
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: reviewTab == tab ? .semibold : .regular))
                    .foregroundStyle(reviewTab == tab ? Color.recapInk : Color.recapTea)

                Rectangle()
                    .fill(reviewTab == tab ? Color.recapInk : Color.clear)
                    .frame(width: 24, height: 2.5)
                    .cornerRadius(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            segButton("来源", .source)
            segButton("笔记", .notes)
        }
        .padding(3)
        .background(Color.recapPaper, in: Capsule())
    }

    private func segButton(_ t: String, _ tab: ReviewTab) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.recapSoft) { reviewTab = tab }
        } label: {
            Text(t)
                .font(.recapMeta.weight(.medium))
                .foregroundStyle(reviewTab == tab ? Color.recapInk : Color.recapTea)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if reviewTab == tab {
                        // 选中胶囊在两 Tab 间滑动（matchedGeometry），而非交叉淡入。
                        Color.recapBg
                            .matchedGeometryEffect(id: "segIndicator", in: segNamespace)
                            .clipShape(Capsule())
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Notes tab（笔记层）

    /// 笔记 Tab：模板切换器 + 当前笔记（整理态极简全空，避免无关干扰）。
    private var notesBody: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if session.revealStep >= 1 || session.phase == .review {
                noteSwitcherBar
            }
            currentNoteView
        }
    }

    @ViewBuilder
    private var currentNoteView: some View {
        switch selectedNote {
        case .note(let id):
            noteInlineView(id)
        case .summary, .researchDraft, .researchTask:
            summaryNoteView
        }
    }

    /// 总结笔记：整理态时隐藏 H1 标题、TAB 与 AI 声明，保持纯净高级舞台；完成降落后再展开纪要头部。
    private var summaryNoteView: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            if session.revealStep >= 1 || session.phase == .review {
                Text("内容由 AI 生成，仅供参考")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.recapTea.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)

                // Plaud AI 风格 H1 页面大标题（大字号粗体）
                Text(meeting.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.recapInk)
                    .lineSpacing(4)
                    .padding(.top, Spacing.xs)
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
                    MindmapOutlineView(source: payload.body)
                } else {
                    AskMarkdownText(source: payload.body, isStreaming: false)
                }
            }
        } else {
            // 笔记被删除等异常情况，回退总结
            summaryNoteView
        }
    }

    /// switcher 当前标题。
    private var currentNoteTitle: String {
        switch selectedNote {
        case .summary, .researchDraft, .researchTask:
            return "总结"
        case .note(let id):
            return meeting.outputs.first(where: { $0.id == id })?.notePayload?.title ?? "笔记"
        }
    }

    /// Plaud 风格模板切块：`标记` | `当前笔记 ∨` | `+`
    private var noteSwitcherBar: some View {
        HStack(spacing: Spacing.sm) {
            Text("标记")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.recapTea)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(light: 0xF6F7F8, dark: 0x16191D), in: Capsule())

            Menu {
                ForEach(allNoteItems) { item in
                    Button {
                        openNote(item.target)
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentNoteTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.recapInk)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(light: 0xF6F7F8, dark: 0x16191D), in: Capsule())
            }

            Button {
                Haptics.impact(.light)
                showTemplateSelection = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(light: 0xF6F7F8, dark: 0x16191D), in: Capsule())
            }

            Spacer(minLength: 0)

            ShareLink(item: currentNoteMarkdown, subject: Text(meeting.title)) {
                Image(systemName: RecapSymbol.share)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.recapInk)
            }
            .buttonStyle(RecapPressStyle())
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
            withAnimation(.recapSoft) { selectedNote = .summary }
        case .note(let id):
            Haptics.selection()
            withAnimation(.recapSoft) { selectedNote = .note(id) }
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
            showGhost: true
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
        withAnimation(.recapSoft) { reviewTab = .source }
        if hasLocalAudio {
            openAudioPlayer(seekTo: startSeconds, autoplay: true)
        }
    }

    private func openAudioPlayer(seekTo: Double? = nil, autoplay: Bool = false) {
        guard let path = meeting.audioPath,
              MeetingAudioStore.fileExists(storedPath: path) else { return }
        withAnimation(.recapSheet) { showAudioPlayer = true }
        audioPlayer.load(storedPath: path)
        if let seekTo {
            audioPlayer.seek(to: seekTo)
        }
        if autoplay {
            audioPlayer.play()
        }
    }

    private func closeAudioPlayer() {
        audioPlayer.pause()
        withAnimation(.recapSheet) { showAudioPlayer = false }
    }

    private var listeningBlockId: String? {
        guard showAudioPlayer, audioPlayer.isReady else { return nil }
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
            // H1 页面大标题：转写（带墨色下划线）
            VStack(alignment: .leading, spacing: 4) {
                Text("转写")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.recapInk)
                Rectangle()
                    .fill(Color.recapInk)
                    .frame(width: 24, height: 2.5)
                    .cornerRadius(1)
            }
            .padding(.top, Spacing.xs)

            // 音频播放控制卡片
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
                },
                onCrop: {
                    Haptics.impact(.light)
                }
            )

            Divider()
                .background(Color.recapTea.opacity(0.12))

            // 转写区标头
            Text("转写")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.recapInk)
                .padding(.top, Spacing.xs)

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

    /// 底栏侧槽宽度：左右等宽，保证中央主控光学居中。
    private var liveBottomSideSlot: CGFloat { 56 }

    @ViewBuilder private var bottomBar: some View {
        if isSettling {
            // 占位保持布局稳定；仅淡出，无位移（高频底栏路径保持克制）
            liveStageBottom
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            switch session.phase {
            case .live:
                liveStageBottom
                    .transition(.opacity)
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

    /// LIVE 统一底栏：左 辅助功能（记录此刻/完成）· 中 主控 · 右 问 Recap（AI 锚点）。
    /// 无论 LIVE（录音中/暂停）还是 REVIEW（会后），Ask Recap 均统一固定在右下角，符合单手人体工学与一致的 UI/UX 心理模型。
    private var liveStageBottom: some View {
        HStack(alignment: .center, spacing: 0) {
            liveLeftSlot
                .frame(width: liveBottomSideSlot, height: liveBottomSideSlot)

            Spacer(minLength: Spacing.md)

            liveCenterControl

            Spacer(minLength: Spacing.md)

            askLiveBottomButton
                .frame(width: liveBottomSideSlot, height: liveBottomSideSlot)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .contentShape(Rectangle())
    }

    /// 「问 Recap」统一动作：触觉 + 清空 prefill + 弹出 AgentInvokeSheet。
    private func askRecap() {
        Haptics.impact(.soft)
        agentPrefill = ""
        showAgent = true
    }

    /// 右下：问 Recap —— 全站统一固定槽位（含启动台）。
    private var askLiveBottomButton: some View {
        Button { askRecap() } label: {
            RecapAskEntryLabel()
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("问 Recap")
        .accessibilityHint(
            session.hasStartedRecording
                ? "开会走神时补课，不影响录音"
                : "可先问议程或资料，再开始录音"
        )
    }

    @ViewBuilder private var liveCenterControl: some View {
        Button {
            Haptics.impact(.light)
            if session.isLivePaused {
                session.resumeLive()
            } else {
                session.pauseLive()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        session.isLivePaused
                            ? Color.recapOchre.opacity(0.15)
                            : Color.recapCinnabar.opacity(0.15)
                    )
                    .frame(width: 72, height: 72)

                Circle()
                    .fill(
                        session.isLivePaused
                            ? Color.recapOchre
                            : Color.recapCinnabar
                    )
                    .frame(width: 56, height: 56)

                Image(systemName: session.isLivePaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel(session.isLivePaused ? "继续录音" : "暂停录音")
        .accessibilityHint(session.isLivePaused ? "恢复收音" : "停止收音，可继续或完成整理")
        .overlay(alignment: .top) {
            HStack(spacing: 6) {
                if session.isLivePaused {
                    Text("已暂停")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.recapOchre)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.recapOchre.opacity(0.12), in: Capsule())
                }
                Text(elapsedText(session.elapsed))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(session.isLivePaused ? Color.recapTea : Color.recapInk)
                    .monospacedDigit()
            }
            .offset(y: -24)
            .accessibilityLabel("已录制 \(elapsedText(session.elapsed))")
        }
    }

    @ViewBuilder private var liveLeftSlot: some View {
        if session.isLivePaused && session.hasStartedRecording {
            liveFinishButton
                .transition(.scale.combined(with: .opacity))
        } else if !session.liveStartFailed {
            // 失败态不挂相机（无录音可锚定）；失败操作在正文 liveFailureActions
            cameraLiveBottomButton
                .transition(.scale.combined(with: .opacity))
        }
    }

    /// 暂停态左侧 Hero CTA：完成并整理纪要（翡翠青瓷圆形按键）。
    private var liveFinishButton: some View {
        Button {
            Haptics.impact(.medium)
            showEndLiveConfirm = true
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                Text("完成")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(width: 52, height: 52)
            .background(
                LinearGradient(
                    colors: [
                        Color(hex: 0x248A4D),
                        Color(hex: 0x1B6F3E)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .shadow(color: Color(hex: 0x248A4D).opacity(0.3), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("完成并整理纪要")
        .accessibilityHint("结束本场录音，由 AI 自动生成结构化会议纪要")
    }

    /// 左下：记录此刻 —— 辅助功能固定入口（暂停态让位给「完成」）。
    private var cameraLiveBottomButton: some View {
        Button {
            Haptics.impact(.soft)
            momentCaptureAnchor = session.elapsed
            showMomentCapture = true
        } label: {
            Image(systemName: RecapSymbol.camera)
                .font(.system(size: 19, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.recapInk.opacity(0.72))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(RecapPressStyle())
        .accessibilityLabel("记录此刻")
        .accessibilityHint("拍下白板或此刻，锚定到录音当前秒，不打断录音")
    }

    /// 会后底栏：笔记页直刷虹彩悬浮 Ask Bar，转写页保持纯净无浮钮
    private var reviewBottom: some View {
        Group {
            if reviewTab == .notes {
                PlaudAskBar(
                    placeholder: "对此笔记提问",
                    onSubmit: { prompt in
                        agentPrefill = prompt
                        showAgent = true
                    }
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.sm)
            }
        }
    }

    /// 低频破坏动作：删除进「更多」，也可在首页列表左滑/长按删除。
    private var meetingMoreMenu: some View {
        Menu {
            // 逐字稿 LLM 润色（补标点 / 纠错别字 / 最小书面化），保段双行展示；不依赖端侧 ASR
            if session.phase == .review, !session.blocks.isEmpty {
                Button {
                    session.polishTranscript()
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
                    } label: {
                        Label("SenseVoice · 中英混排", systemImage: "waveform")
                    }
                    Button {
                        session.retranscribeFromDisk(engineKind: .fluidParaformer)
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
        session.pauseOrTeardownForDisappear()
        MeetingDeletion.delete(meeting, in: modelContext)
        onDismiss()
    }

    private func persistTodos(_ items: [TodoListPayload.Item]) {
        for item in items {
            let due = item.due.flatMap { ISO8601DateFormatter().date(from: $0) }
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
                priority: item.priority.flatMap(Priority.init(rawValue:)),
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

/// REVIEW 正文两 Tab。
private enum ReviewTab: Hashable {
    case source  // 原稿：转写 + 录音 + 现场
    case notes   // 笔记：模板产物（默认）
}

// MARK: - Process stage (整理态舞台)

/// 整理舞台：海獭 Mascot 悬浮 + 多重弥散极光 + Gemini 底部流光动效 + 逐字稿飞升 + 动态处理步骤。
/// 风格简洁、干净、高级（参考 Plaud AI 与 Google Gemini APP）。Reduce Motion 时静帧优雅呈现。
private struct ProcessStageCanvas: View {
    let title: String
    let subtitle: String?
    let ghostBlocks: [TranscriptBlock]
    let reduceMotion: Bool
    var showGhost: Bool = true

    @State private var appeared = false

    var body: some View {
        Group {
            if reduceMotion {
                stageStack(t: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    stageStack(t: context.date.timeIntervalSinceReferenceDate)
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

    private func stageStack(t: Double) -> some View {
        ZStack(alignment: .bottom) {
            // 全宽 Google Gemini 风格底部流光池背景
            GeminiFluidGlowView(reduceMotion: reduceMotion)
                .opacity(appeared ? 1 : 0)

            ZStack {
                atmosphere(t: t)
                if showGhost, !ghostBlocks.isEmpty {
                    TranscriptStreamFlowView(ghostBlocks: ghostBlocks, reduceMotion: reduceMotion)
                        .padding(.top, Spacing.lg)
                }
                signalCore(t: t)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var accessibilityLabelText: String {
        if let subtitle, !subtitle.isEmpty { return "\(title)，\(subtitle)" }
        return title
    }

    // MARK: - Atmosphere (弥散极光与光晕)

    private func atmosphere(t: Double) -> some View {
        let pulse = reduceMotion ? 1.0 : (1.0 + 0.06 * sin(t * 1.5))
        return ZStack {
            // 底层：柔和的双色弥散极光
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.recapCeladon.opacity(0.14),
                            Color.recapOchre.opacity(0.06),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 20,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .scaleEffect(pulse * (appeared ? 1 : 0.85))
                .blur(radius: reduceMotion ? 12 : 24)
                .opacity(appeared ? 1 : 0)

            // 次层：极其淡微的内侧脉动光晕
            Circle()
                .fill(Color.recapPaper.opacity(0.4))
                .frame(width: 180, height: 180)
                .blur(radius: 16)
                .scaleEffect(appeared ? 1 : 0.9)
                .opacity(appeared ? 0.8 : 0)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Core (海獭 Mascot + 流光轨 + 动态文案)

    private func signalCore(t: Double) -> some View {
        let floatY = reduceMotion ? 0 : sin(t * 2.2) * 4.0
        let breathScale = reduceMotion ? 1.0 : (1.0 + 0.02 * sin(t * 1.8))
        let rot1 = reduceMotion ? 0 : t * 0.35
        let rot2 = reduceMotion ? 0 : -t * 0.25

        return VStack(spacing: Spacing.xl) {
            // 核心动画区：海獭 Mascot + 双流光轨
            ZStack {
                // 外层流光轨 (Outer Orbit)
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.recapInk.opacity(0.12),
                                Color.recapInk.opacity(0.02),
                                Color.recapCeladon.opacity(0.18),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
                    .frame(width: 136, height: 136)
                    .rotationEffect(.radians(rot2))

                // 内层流光弧 (Inner Arc)
                Circle()
                    .trim(from: 0.05, to: 0.38)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.recapInk.opacity(0.45),
                                Color.recapInk.opacity(0.08)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                    )
                    .frame(width: 110, height: 110)
                    .rotationEffect(.radians(rot1))

                // 轨道小光点粒子
                if !reduceMotion {
                    Circle()
                        .fill(Color.recapInk.opacity(0.6))
                        .frame(width: 4, height: 4)
                        .offset(x: 55)
                        .rotationEffect(.radians(rot1 + .pi * 0.38))

                    Circle()
                        .fill(Color.recapCeladon.opacity(0.5))
                        .frame(width: 3, height: 3)
                        .offset(x: -68)
                        .rotationEffect(.radians(rot2))
                }

                // 中心海獭 Mascot 徽记 (Capy Avatar Container)
                ZStack {
                    Circle()
                        .fill(Color.recapPaper)
                        .shadow(color: Color.recapShadow, radius: 14, x: 0, y: 6)

                    Circle()
                        .strokeBorder(Color.recapInk.opacity(0.06), lineWidth: 1)

                    RecapAIAvatarImage(size: 54)
                        .clipShape(Circle())
                }
                .frame(width: 76, height: 76)
                .offset(y: floatY)
                .scaleEffect(breathScale)
            }
            .frame(width: 144, height: 144)
            .scaleEffect(appeared ? 1 : 0.90)
            .opacity(appeared ? 1 : 0)

            // 动态 Processing 步骤文案区
            VStack(spacing: Spacing.xs) {
                // 步骤指示胶囊 Badge
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.recapCeladon)
                        .frame(width: 6, height: 6)
                    Text(stepBadgeText(t: t))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.recapTea)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Color.recapInk.opacity(0.04),
                    in: Capsule()
                )

                Text(dynamicStatusTitle(t: t))
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .tracking(0.8)
                    .foregroundStyle(Color.recapInk.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .id(dynamicStatusTitle(t: t))
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
        }
        .padding(.horizontal, Spacing.xxl)
    }

    // MARK: - Dynamic Step & Copy Helper (动态步骤文案)

    private func stepBadgeText(t: Double) -> String {
        guard MinutesPipelineSmoke.canRunMinutesPipeline else {
            return "本地完成"
        }
        let cycle = Int(t) % 9
        switch cycle {
        case 0..<3:
            return "STEP 1 / 3"
        case 3..<6:
            return "STEP 2 / 3"
        default:
            return "STEP 3 / 3"
        }
    }

    private func dynamicStatusTitle(t: Double) -> String {
        guard MinutesPipelineSmoke.canRunMinutesPipeline else {
            return title
        }
        if title != "整理中" && !title.isEmpty {
            return title
        }
        let cycle = Int(t) % 9
        switch cycle {
        case 0..<3:
            return "正在梳理语音对话原稿…"
        case 3..<6:
            return "正在提炼核心议题与关键决议…"
        default:
            return "正在生成行动待办与结构化纪要…"
        }
    }

    private var dynamicStatusSubtitle: String? {
        if let subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if MinutesPipelineSmoke.canRunMinutesPipeline {
            return "Gemini AI 智能推理中"
        }
        return nil
    }
}

/// Plaud AI 标志性贴底 AI 问答输入框（彩虹微渐变边框 + Beta 微标）
private struct PlaudAskBar: View {
    @State private var text: String = ""
    let placeholder: String
    let onSubmit: (String) -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(light: 0xFFFFFF, dark: 0x16191D))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(hex: 0x38BDF8), // 天蓝
                                    Color(hex: 0x818CF8), // 靛蓝
                                    Color(hex: 0x4ADE80), // 翠绿
                                    Color(hex: 0xF472B6)  // 粉紫
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )

            HStack(spacing: Spacing.sm) {
                TextField(placeholder, text: $text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.recapInk)
                    .submitLabel(.send)
                    .onSubmit {
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            onSubmit(trimmed)
                            text = ""
                        }
                    }

                Button {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    onSubmit(trimmed)
                    if !trimmed.isEmpty { text = "" }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Floating Beta Badge
            Text("Beta")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.recapTea)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(light: 0xF1F3F5, dark: 0x22252A))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.recapTea.opacity(0.2), lineWidth: 0.5)
                        )
                )
                .offset(x: 14, y: -22)
        }
        .frame(height: 44)
    }
}

/// Plaud AI 风格音频播放卡片
private struct PlaudAudioPlayerCard: View {
    @ObservedObject var player: MeetingAudioPlayer
    var onSeek15Back: () -> Void
    var onSeek15Forward: () -> Void
    var onSpeedToggle: () -> Void
    var onCrop: () -> Void

    private func formatTime(_ s: TimeInterval) -> String {
        let total = max(0, Int(s))
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hrs, mins, secs)
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            // Line 1: Time & Crop
            HStack {
                Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.recapTea)

                Spacer()

                Button {
                    onCrop()
                } label: {
                    Image(systemName: "crop")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.recapTea)
                }
            }

            // Line 2: Waveform bar
            PlaudAudioWaveformView(
                progress: player.duration > 0 ? player.currentTime / player.duration : 0
            )
            .frame(height: 36)

            // Line 3: 5 Control Buttons
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
                        Text("1x")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.recapInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(light: 0xF1F3F5, dark: 0x22252A), in: Capsule())
                }
                .frame(maxWidth: .infinity)

                // 5. Crop / Selection
                Button {
                    onCrop()
                } label: {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color.recapInk)
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
private struct PlaudLiveWaveformVisualizer: View {
    let isPaused: Bool
    let audioPower: Float

    var body: some View {
        VStack(spacing: Spacing.md) {
            HStack(alignment: .center, spacing: 3.5) {
                ForEach(0..<36, id: \.self) { i in
                    let height = barHeight(for: i)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(
                            isPaused
                                ? AnyShapeStyle(Color.recapTea.opacity(0.25))
                                : AnyShapeStyle(LinearGradient(
                                    colors: [
                                        Color.recapCinnabar,
                                        Color(hex: 0xE25347)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))
                        )
                        .frame(width: 3, height: height)
                        .animation(.smooth(duration: 0.12), value: height)
                }
            }
            .frame(height: 52)

            Text(isPaused ? "录音已暂停 · 点击下方「完成」生成纪要" : "正在倾听中 · 开始讲话字幕实时呈现")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.recapTea)
        }
        .padding(.vertical, Spacing.xl)
        .frame(maxWidth: .infinity)
    }

    private func barHeight(for index: Int) -> CGFloat {
        if isPaused { return 4 }
        let centerDist = abs(Double(index) - 17.5) / 17.5
        let bellFactor = cos(centerDist * .pi * 0.42)
        let powerVal = CGFloat(max(0.05, audioPower))
        let dynamicHeight = (powerVal * bellFactor * 44.0) + 4.0
        return min(48.0, max(4.0, dynamicHeight))
    }
}

