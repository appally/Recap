import SwiftUI
import SwiftData
import UIKit
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
    @State private var showBrief = false
    @State private var briefInitialShelf: MeetingKitShelf = .incoming
    @State private var summaryTab = 0
    /// Segmented 选中胶囊在「摘要/逐字稿」间滑动的命名空间。
    @Namespace private var segNamespace
    @State private var pendingScrollStart: Double?
    @State private var showAudioPlayer = false
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
    /// 启动台入场：偶发场景可轻微 fade-up（Reduce Motion 关闭位移）。
    @State private var readyStageAppeared = false
    @StateObject private var audioPlayer = MeetingAudioPlayer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
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
        .sheet(isPresented: $showBrief, onDismiss: {
            briefInitialShelf = .incoming
        }) {
            BriefSheet(
                meeting: meeting,
                isPresented: $showBrief,
                initialShelf: briefInitialShelf,
                allowsRegenerate: session.phase == .review && !session.blocks.isEmpty,
                runningTaskId: researchRunner.isBusy ? researchRunner.current?.id : nil,
                onRoute: handleKitRoute
            )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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

    /// LIVE 启动台：进会未开麦。与「已暂停」决策台严格二分。
    private var isLiveReady: Bool {
        session.phase == .live
            && session.isLivePaused
            && !session.hasStartedRecording
            && !session.liveStartFailed
            && !isSettling
    }

    /// 顶栏标题：启动台 / 暂停可见；Settling/Process 留白；Review 再回正文。
    private var showsStageTitleInTopBar: Bool {
        if isSettling { return false }
        switch session.phase {
        case .live: return session.isLivePaused
        case .processing: return false
        case .review: return false // 标题在正文 H1
        }
    }

    private var hasLocalAudio: Bool {
        guard let path = meeting.audioPath else { return false }
        return MeetingAudioStore.fileExists(storedPath: path)
    }

    // MARK: Top bar

    /// 自绘顶栏。Ask 固定在底栏（智能体锚点）；顶栏只放导航与次要工具。
    /// LIVE：↓ · 资料 ·（已开录）更多；Review：← · 资料 · 回听 · 分享 · 更多。
    private var customTopBar: some View {
        let isLiveInteractive = session.phase == .live && !isSettling
        let useDownChevron = session.phase == .live && !isSettling
        return GlassEffectContainer(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Button {
                    dismissFromTopBar()
                } label: {
                    Image(systemName: useDownChevron ? RecapSymbol.dismissDown : RecapSymbol.back)
                        .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                        .contentShape(Circle())
                }
                .buttonStyle(RecapPressStyle())
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(topBarDismissAccessibilityLabel)
                .disabled(isSettling)

                Spacer(minLength: 0)

                if isLiveInteractive {
                    BriefToolbarButton(
                        hasContent: hasMaterialsContext,
                        accessibilityDetail: MeetingKitIndex.chipLabel(
                            for: meeting,
                            runningTaskId: researchRunner.isBusy ? researchRunner.current?.id : nil
                        )
                    ) {
                        briefInitialShelf = .incoming
                        showBrief = true
                    }

                    // 删除等低频破坏动作进「更多」；启动台 ↓ 已可清场，不必再挂
                    if session.hasStartedRecording {
                        meetingMoreMenu
                    }
                }

                // 工具仅 REVIEW 落定后出现；资料 / 回听 / 分享 同规
                if session.phase == .review {
                    BriefToolbarButton(
                        hasContent: hasMaterialsContext,
                        accessibilityDetail: MeetingKitIndex.chipLabel(
                            for: meeting,
                            runningTaskId: researchRunner.isBusy ? researchRunner.current?.id : nil
                        )
                    ) {
                        briefInitialShelf = .incoming
                        showBrief = true
                    }

                    if hasLocalAudio {
                        RecapToolbarIcon(
                            RecapSymbol.listen,
                            emphasized: showAudioPlayer || audioPlayer.isPlaying,
                            accessibilityLabel: showAudioPlayer ? "关闭回听" : "回听录音",
                            accessibilityHint: "播放本场会议的本地录音"
                        ) {
                            if showAudioPlayer {
                                closeAudioPlayer()
                            } else {
                                openAudioPlayer(autoplay: false)
                            }
                        }
                    }

                    ShareLink(item: shareMarkdown, subject: Text(meeting.title)) {
                        Image(systemName: RecapSymbol.share)
                            .font(.system(size: RecapToolbarIconMetrics.pointSize, weight: RecapToolbarIconMetrics.weight))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(Color.recapInk.opacity(RecapToolbarIconMetrics.inkOpacity))
                            .frame(width: RecapToolbarIconMetrics.side, height: RecapToolbarIconMetrics.side)
                            .contentShape(Circle())
                    }
                    .buttonStyle(RecapPressStyle())
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("分享")

                    meetingMoreMenu
                }
            }
            .overlay {
                if showsStageTitleInTopBar {
                    VStack(spacing: 1) {
                        Text(meeting.title)
                            .font(.system(size: 15, weight: .semibold, design: .default))
                            .tracking(0.1)
                            .foregroundStyle(Color.recapInk)
                            .lineLimit(1)
                        if let meta = liveTopMetaText {
                            Text(meta)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .tracking(0.2)
                                .foregroundStyle(Color.recapOchre)
                        }
                    }
                    .padding(.horizontal, 100)
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.xs)
        // 不在 GlassEffectContainer 上挂隐式 animation，避免 glassEffect 同帧多次更新
    }

    private var hasMaterialsContext: Bool {
        MeetingKitIndex.hasMaterials(
            for: meeting,
            runningTaskId: researchRunner.isBusy ? researchRunner.current?.id : nil
        )
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

    @ViewBuilder private var liveContent: some View {
        if isLiveReady {
            liveReadyStage
                .transition(.opacity)
        } else {
            liveRecordingOrPausedContent
        }
    }

    /// 启动台：静默舞台 + 一句邀请；决策（删/完成）不出现在这里。
    private var liveReadyStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Spacing.xxxl)

            VStack(spacing: Spacing.xxl) {
                LiveReadyMark()

                VStack(spacing: Spacing.sm) {
                    Text("开始后，话会落在这里")
                        .font(.system(size: 17, weight: .medium, design: .default))
                        .foregroundStyle(Color.recapInk.opacity(0.78))
                        .multilineTextAlignment(.center)

                    // 次路径：资料在右上；Ask 已锚定左下，此处不再抢主 CTA
                    Button {
                        Haptics.impact(.soft)
                        briefInitialShelf = .incoming
                        showBrief = true
                    } label: {
                        Text(hasMaterialsContext ? "已加资料" : "先加资料")
                            .font(.system(size: 13, weight: .medium, design: .default))
                            .foregroundStyle(Color.recapTea)
                    }
                    .buttonStyle(RecapPressStyle())
                    .accessibilityHint("打开本场资料")
                }
            }
            .padding(.horizontal, Spacing.xxxl)
            .opacity(readyStageAppeared ? 1 : 0)
            .offset(y: readyStageAppeared ? 0 : (reduceMotion ? 0 : 10))

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !readyStageAppeared else { return }
            if reduceMotion {
                readyStageAppeared = true
            } else {
                withAnimation(.easeOut(duration: 0.28)) {
                    readyStageAppeared = true
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("尚未开始录音")
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
                            Text(liveEmptyPrompt)
                                .font(.recapRaw)
                                .foregroundStyle(Color.recapTea)
                                .padding(.leading, Spacing.xl + 2 + Spacing.md)
                                .padding(.trailing, Spacing.xl)
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
            // 启动台走 liveReadyStage；此处仅暂停后空字幕的边角
            return "可继续，或点右侧完成"
        }
        return "开始讲话，字幕会出现在这里"
    }

    /// 启动台：只留标题、不写「准备就绪」；暂停后才给时长态。
    private var liveTopMetaText: String? {
        if session.isLivePaused {
            guard session.hasStartedRecording else { return nil }
            return "已暂停 · \(elapsedText(session.elapsed))"
        }
        return elapsedText(session.elapsed)
    }

    private var topBarDismissAccessibilityLabel: String {
        if isLiveReady { return "关闭" }
        if session.phase == .live && !isSettling { return "暂停并收起" }
        return "返回"
    }

    /// 异常 / 暂停 / 演示才出字；正常收音不写「正在收音」。
    private var liveStatusLabel: String {
        if session.isUsingMockAudio { return "演示字幕" }
        if session.isLivePaused {
            // 启动台无流末状态字；暂停后默认「已暂停」
            guard session.hasStartedRecording else { return "" }
            let msg = session.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? "已暂停" : msg
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

    private var liveFailureActions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
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
                    if session.phase == .review {
                        titleMeta
                    } else if session.revealStep >= 1 {
                        titleMetaReadonly
                    }
                    if !session.statusMessage.isEmpty, session.revealStep >= 1 {
                        Text(session.statusMessage)
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapOchre)
                    }
                    // Tab 等有内容后再出现，避免整理期像填表
                    if session.revealStep >= 1 {
                        segmented
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if summaryTab == 0 { summaryBody } else { transcriptBody }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.md)
                .padding(.bottom, 110)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: pendingScrollStart) { _, start in
                guard let start, summaryTab == 1 else { return }
                scrollTranscript(proxy: proxy, startSeconds: start)
            }
            .onChange(of: summaryTab) { _, tab in
                guard tab == 1, let start = pendingScrollStart else { return }
                scrollTranscript(proxy: proxy, startSeconds: start)
            }
            .onChange(of: session.isDiarizing) { was, now in
                // 分离结束且已写入 spk*：切到逐字稿，结果只在那里可见
                guard was, !now else { return }
                guard meeting.speakers.contains(where: { $0.id.hasPrefix("spk") }) else { return }
                withAnimation(.recapSoft) { summaryTab = 1 }
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

    private var segmented: some View {
        HStack(spacing: 2) {
            segButton("摘要", 0)
            segButton("逐字稿", 1)
        }
        .padding(3)
        .background(Color.recapPaper, in: Capsule())
    }

    private func segButton(_ t: String, _ idx: Int) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.recapSoft) { summaryTab = idx }
        } label: {
            Text(t)
                .font(.recapMeta.weight(.medium))
                .foregroundStyle(summaryTab == idx ? Color.recapInk : Color.recapTea)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if summaryTab == idx {
                        // 选中胶囊在两 Tab 间滑动（matchedGeometry），而非交叉淡入。
                        Color.recapBg
                            .matchedGeometryEffect(id: "segIndicator", in: segNamespace)
                            .clipShape(Capsule())
                    }
                }
        }
        .buttonStyle(.plain)
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
            if session.revealStep >= 4, kitDerivedCount > 0 {
                researchDraftSection
                    .id("summary-research-drafts")
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
            sectionTitle("☰", "议题纪要", color: Color.recapCeladon, count: session.summary.topics.count)
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
            sectionTitle("☰", "对照议程", color: Color.recapCeladon, count: brief.agenda.count)
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
            sectionTitle("↻", "上场遗留", color: Color.recapOchre, count: brief.openItems.count)
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
            sectionTitle("◆", "关键决议", color: Color.recapCeladon)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(session.summary.decisions, id: \.self) { d in
                    bulletRow(d, color: Color.recapCeladon, ink: Color.recapInk)
                }
            }
        }
    }

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("☐", "待办事项", color: Color.recapInk, count: sortedItems.count)
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

    private var kitDerivedCount: Int {
        MeetingKitIndex.derivedCount(
            in: MeetingKitIndex.build(
                from: meeting,
                runningTaskId: researchRunner.isBusy ? researchRunner.current?.id : nil
            )
        )
    }

    private var researchDraftSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("◇", "资料", color: Color.recapCeladon, count: kitDerivedCount)
            Button {
                briefInitialShelf = .derived
                showBrief = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("查看调研草稿与进行中的跟进")
                            .font(.recapTask)
                            .foregroundStyle(Color.recapInk)
                        Text("在资料中打开")
                            .font(.recapMeta)
                            .foregroundStyle(Color.recapTea)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: RecapSymbol.chevron)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.recapTea)
                }
                .padding(Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(Color.recapPaper)
                )
            }
            .buttonStyle(RecapPressStyle())
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

    private func handleKitRoute(_ route: MeetingKitRoute) {
        switch route {
        case .regenerateWithBrief:
            showBrief = false
            session.regenerateWithBrief(
                clearDraftTodos: clearDraftTodosForRegen,
                persistTodos: persistTodos,
                persistSummary: persistSummary
            )
        case .openResearchProgress(let taskId):
            showBrief = false
            openResearchProgress(taskId: taskId)
        case .openResearchDraft(let outputId):
            showBrief = false
            if let draft = meeting.outputs.first(where: { $0.id == outputId })?.researchDraftPayload {
                selectedResearchDraft = draft
                showResearchDraft = true
            }
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
        withAnimation(.recapSoft) { summaryTab = 1 }
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
            sectionTitle("◐", "未决问题", color: Color.recapOchre)
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

    private func sectionTitle(_ symbol: String, _ text: String, color: Color, count: Int? = nil) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(symbol).foregroundStyle(color)
            Text(text).font(.recapSection).foregroundStyle(color)
            if let c = count { Text("\(c)").font(.recapMeta).foregroundStyle(Color.recapTea) }
            Spacer()
        }
    }

    @ViewBuilder
    private var transcriptBody: some View {
        // 直接向父 LazyVStack 贡献行，避免嵌套 VStack 物化全表
        // 会议时刻（moments）与转写分段按 startSeconds 合并排序，时刻卡片在对应位置插队。
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

    /// LIVE 统一底栏：左 Ask（智能体锚点）· 中主控 · 右完成（仅暂停后）。
    /// 阶段切换只改中央/右侧，Ask 位置不变 → 强化「会议智能体」稳定认知。
    private var liveStageBottom: some View {
        GlassEffectContainer(spacing: Spacing.md) {
            HStack(alignment: .center, spacing: 0) {
                askLiveBottomButton
                    .frame(width: liveBottomSideSlot, height: liveBottomSideSlot)

                Spacer(minLength: Spacing.md)

                liveCenterControl

                Spacer(minLength: Spacing.md)

                liveRightSlot
                    .frame(width: liveBottomSideSlot, height: liveBottomSideSlot)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .contentShape(Rectangle())
    }

    /// 「问 Recap」统一动作：触感 + 清空 prefill + 弹出 AgentInvokeSheet。
    private func askRecap() {
        Haptics.impact(.soft)
        agentPrefill = ""
        showAgent = true
    }

    /// 左下：问 Recap —— LIVE 全程固定槽位（含启动台）。
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
        if session.isLivePaused {
            livePrimaryStartContinue(
                title: session.hasStartedRecording ? "继续" : "开始",
                accessibilityLabel: session.hasStartedRecording ? "继续录音" : "开始录音",
                accessibilityHint: session.hasStartedRecording ? "恢复收音" : "开始本场录音与转写"
            )
        } else {
            // 时长叠在暂停钮上方（不拉高整列），左右 Ask/占位仍与圆钮光学对齐
            Button {
                Haptics.impact(.light)
                session.pauseLive()
            } label: {
                Image(systemName: RecapSymbol.pause)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.recapInk.opacity(0.82))
                    .frame(width: 68, height: 68)
                    .contentShape(Circle())
            }
            .buttonStyle(RecapPressStyle())
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("暂停录音")
            .accessibilityHint("停止收音，可继续或完成整理")
            .overlay(alignment: .top) {
                Text(elapsedText(session.elapsed))
                    .font(.recapTimestamp)
                    .tracking(0.2)
                    .foregroundStyle(Color.recapTea.opacity(0.9))
                    .monospacedDigit()
                    .offset(y: -18)
                    .accessibilityLabel("已录制 \(elapsedText(session.elapsed))")
            }
        }
    }

    /// 开始 / 继续：同一视觉语言的居中主 CTA。
    private func livePrimaryStartContinue(
        title: String,
        accessibilityLabel: String,
        accessibilityHint: String
    ) -> some View {
        Button {
            // 开始（首次）给 medium 的分量；继续（恢复）退回 light，与暂停对称。
            Haptics.impact(session.hasStartedRecording ? .light : .medium)
            session.resumeLive()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: RecapSymbol.play)
                    .font(.system(size: 14, weight: .semibold))
                    .offset(x: 0.5)
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .default))
                    .tracking(1.0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            .padding(.vertical, 18)
            .contentShape(Capsule())
        }
        .buttonStyle(RecapPressStyle())
        // 朱砂染色玻璃：与同底栏的暂停钮/完成钮同属 Liquid Glass 族，
        // 仅以朱砂 tint（录音语义色）+ 胶囊形状承担「主操作」权重，
        // 不再是独一份的实心色块，避免打断 GlassEffectContainer 的融合。
        .glassEffect(.regular.tint(Color.recapCinnabar.opacity(0.60)), in: .capsule)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder private var liveRightSlot: some View {
        if session.isLivePaused && session.hasStartedRecording {
            Button {
                showEndLiveConfirm = true
            } label: {
                Image(systemName: RecapSymbol.check)
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.recapCeladon)
                    .frame(width: 52, height: 52)
                    .contentShape(Circle())
            }
            .buttonStyle(RecapPressStyle())
            .glassEffect(.regular.tint(Color.recapCeladon.opacity(0.22)), in: .circle)
            .accessibilityLabel("完成并整理纪要")
            .transition(.opacity)
        } else if session.isRecordingLive {
            // 录音中：记录此刻（拍照锚定到当前秒，不打断录音）
            cameraLiveBottomButton
                .transition(.opacity)
        } else {
            // 与左侧 Ask 等宽占位，保证中央光学居中
            Color.clear
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
        }
    }

    /// 右下：记录此刻 —— 录音中固定入口（暂停态让位给「完成」）。
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
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("记录此刻")
        .accessibilityHint("拍下白板或此刻，锚定到录音当前秒，不打断录音")
    }

    /// 会后底栏：右下浮钮，与 LIVE 左下同源同形（参考 Readio 首页右下角 AI 入口）。
    private var reviewBottom: some View {
        HStack {
            Spacer(minLength: 0)
            Button { askRecap() } label: {
                RecapAskEntryLabel()
            }
            .buttonStyle(RecapPressStyle())
            .accessibilityLabel("问 Recap")
            .accessibilityHint("提问、改纪要、技能，都从这里进")
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.lg)
    }

    /// 低频破坏动作：删除进「更多」，也可在首页列表左滑/长按删除。
    private var meetingMoreMenu: some View {
        Menu {
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
        .glassEffect(.regular.interactive(), in: .circle)
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
        if isLiveReady {
            // 未开录：收起即清场，不留空会议打扰首页
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

// MARK: - Process stage (整理态舞台)

/// 整理舞台：单环慢旋 + 轻波形 + 静核。Reduce Motion 时静帧，blur ≤20。
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
                TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: false)) { context in
                    stageStack(t: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let anim: Animation = reduceMotion
                ? .easeOut(duration: 0.2)
                : .easeOut(duration: 0.36)
            withAnimation(anim) { appeared = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
    }

    private func stageStack(t: Double) -> some View {
        ZStack {
            atmosphere
            if showGhost, !ghostBlocks.isEmpty { ghostLayer }
            signalCore(t: t)
        }
    }

    private var accessibilityLabelText: String {
        if let subtitle, !subtitle.isEmpty { return "\(title)，\(subtitle)" }
        return title
    }

    private var atmosphere: some View {
        Circle()
            .fill(Color.recapCeladon.opacity(0.07))
            .frame(width: 280, height: 280)
            .blur(radius: reduceMotion ? 8 : 18)
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var ghostLayer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ForEach(ghostBlocks) { block in
                SpeakerBlockView(block: block, isCurrent: false)
                    .padding(.horizontal, Spacing.xl)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? (reduceMotion ? 0.24 : 0.12) : 0)
        .blur(radius: reduceMotion ? 0 : 6)
        .mask(
            LinearGradient(
                colors: [.clear, .black.opacity(0.85), .black.opacity(0.85), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }

    private func signalCore(t: Double) -> some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .strokeBorder(Color.recapCeladon.opacity(0.14), lineWidth: 1)
                    .frame(width: 128, height: 128)

                Circle()
                    .strokeBorder(
                        Color.recapCeladon.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.1, dash: [2.5, 8])
                    )
                    .frame(width: 128, height: 128)
                    .rotationEffect(.radians(reduceMotion ? 0 : t * 0.16))

                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(
                        Color.recapCeladon.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .frame(width: 128, height: 128)
                    .rotationEffect(.radians(reduceMotion ? 0 : t * 0.16))

                waveformCluster(t: t)

                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.recapCeladon.opacity(0.9))
                    .frame(width: 1.5, height: appeared ? 40 : 14)
            }
            .frame(width: 140, height: 140)
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .medium, design: .default))
                    .tracking(title.count <= 4 ? 10 : 3)
                    .foregroundStyle(Color.recapInk.opacity(0.86))
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : (reduceMotion ? 0 : 6))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .default))
                        .foregroundStyle(Color.recapTea.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .opacity(appeared ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .accessibilityHidden(false)
    }

    private func waveformCluster(t: Double) -> some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                let phase = t * 1.4 + Double(i) * 0.55
                let wave = reduceMotion ? 0.5 : (0.4 + 0.6 * abs(sin(phase)))
                let envelope = 1.0 - abs(Double(i) - 2.0) / 3.2
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(Color.recapCeladon.opacity(0.4 + 0.4 * envelope))
                    .frame(width: 2.5, height: 10 + wave * 18 * envelope)
            }
        }
        .accessibilityHidden(true)
    }
}
