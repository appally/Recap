import SwiftUI

// MARK: - 会话状态机（LIVE → PROCESS → REVIEW）

@MainActor
final class MeetingSession: ObservableObject {
    @Published var phase: MeetingPhase
    @Published var blocks: [TranscriptBlock] = []
    @Published var elapsed: Int = 1104   // 18:24
    @Published var revealStep: Int = 0
    @Published var todoCount: Int = 0

    private let initialPhase: MeetingPhase
    private var streamTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?

    init(initialPhase: MeetingPhase) {
        self.initialPhase = initialPhase
        self.phase = initialPhase
    }

    func onAppear() {
        switch initialPhase {
        case .live:
            startLive()
        case .review:
            blocks = TranscriptBlock.script.map { var c = $0; c.isFinal = true; return c }
            revealStep = 4
        case .processing:
            break
        }
    }

    // MARK: LIVE

    private func startLive() {
        startClock()
        startStream()
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.elapsed += 1
            }
        }
    }

    private func startStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            for (i, blk) in TranscriptBlock.script.enumerated() {
                if Task.isCancelled { return }
                self.finalizeAll()
                var partial = blk
                partial.isFinal = false
                withAnimation(.easeOut(duration: 0.22)) { self.blocks.append(partial) }
                if [4, 5].contains(i) { self.todoCount += 1 }
                try? await Task.sleep(for: .seconds(1.8))
                guard !self.blocks.isEmpty else { return }
                withAnimation(.recapLand) { self.blocks[self.blocks.count - 1].isFinal = true }
            }
        }
    }

    private func finalizeAll() {
        for i in blocks.indices { blocks[i].isFinal = true }
    }

    func endLive() {
        streamTask?.cancel()
        clockTask?.cancel()
        finalizeAll()
        withAnimation(.recapSheet) { phase = .processing }
        startReveal()
    }

    // MARK: PROCESS → REVIEW（分层揭示）

    private func startReveal() {
        revealTask?.cancel()
        revealTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1.2))
            self.setStep(1)              // TL;DR
            try? await Task.sleep(for: .seconds(1.6))
            self.setStep(2)              // 决议
            try? await Task.sleep(for: .seconds(1.6))
            self.setStep(3)              // 待办
            try? await Task.sleep(for: .seconds(1.4))
            self.setStep(4)              // 未决 → 进入会后
            withAnimation(.recapSheet) { self.phase = .review }
        }
    }

    private func setStep(_ s: Int) {
        withAnimation(.easeOut(duration: 0.24)) { revealStep = s }
    }

    func reset() {
        streamTask?.cancel(); clockTask?.cancel(); revealTask?.cancel()
    }
}

// MARK: - 纪要界面（一个屏 · 三态自适应 · 智能体贯穿）

struct MeetingNoteView: View {
    let meeting: Meeting
    @StateObject private var session: MeetingSession
    @Environment(\.presentationMode) private var presentationMode
    var onDismiss: () -> Void = {}
    @State private var showAgent = false
    @State private var showSkills = false   // 技能/模板面板
    @State private var summaryTab = 0      // 0 摘要 · 1 逐字稿
    @State private var items: [ActionItem]

    init(meeting: Meeting = Meeting.list[0], initialPhase: MeetingPhase, onDismiss: @escaping () -> Void = {}) {
        self.meeting = meeting
        self.onDismiss = onDismiss
        _session = StateObject(wrappedValue: MeetingSession(initialPhase: initialPhase))
        _items = State(initialValue: ActionItem.preview)
    }

    private var summary: MeetingSummary { .preview }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.recapBg.ignoresSafeArea()

            VStack(spacing: 0) {
                customTopBar
                content
            }

            bottomBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showAgent) {
            AgentInvokeSheet(phase: session.phase, isPresented: $showAgent)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear { session.onAppear() }
        .onDisappear { session.reset() }
    }

    // MARK: 自定义顶栏（彻底摆脱系统 toolbar 的 bordered 样式）

    private var customTopBar: some View {
        HStack(spacing: 0) {
            // 左侧：LIVE=最小化（↓）/ REVIEW=返回（←）
            Button { onDismiss() } label: {
                Image(systemName: session.phase == .live ? "chevron.down" : "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // 中间：会议名 + 录音状态
            VStack(spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .tracking(0.1)
                    .foregroundStyle(Color.recapInk)
                    .lineLimit(1)
                if session.phase == .live {
                    HStack(spacing: 5) {
                        Circle().fill(Color.recapCinnabar).frame(width: 5, height: 5)
                        Text("\(elapsedText(session.elapsed)) · \(meeting.attendeeCount) 人")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .tracking(0.2)
                            .foregroundStyle(Color.recapCinnabar)
                    }
                } else {
                    Text(meeting.dateText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .tracking(0.2)
                        .foregroundStyle(Color.recapTea)
                }
            }

            Spacer(minLength: 0)

            // 右侧：LIVE=暂停 / REVIEW=分享
            if session.phase == .live {
                Button {} label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    Button("分享", action: {})
                    Button("导出 Markdown", action: {})
                    Button("导出 PDF", action: {})
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.top, Spacing.xs)
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .live:                liveContent
        case .processing, .review: reviewContent
        }
    }

    // MARK: LIVE 会中态

    private var liveContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    AgentPresenceBar(todoCount: session.todoCount)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, Spacing.sm)
                        .padding(.bottom, Spacing.md)

                    ForEach(session.blocks) { block in
                        SpeakerBlockView(
                            block: block,
                            isCurrent: block.id == session.blocks.last?.id && !block.isFinal
                        )
                        .id(block.id)
                        .padding(.horizontal, Spacing.xl)
                    }

                    HStack(spacing: Spacing.sm) {
                        LiveDots()
                        Text("正在收音").font(.recapTimestamp).foregroundStyle(Color.recapCinnabar)
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.sm)
                    .padding(.bottom, Spacing.xxl)
                }
            }
            .scrollContentBackground(.hidden)
            .onChange(of: session.blocks.count) { _, _ in
                guard let last = session.blocks.last else { return }
                withAnimation(.easeOut) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: PROCESS / REVIEW 共用（分层揭示）

    private var reviewContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xxl) {
                titleMeta
                segmented
                if summaryTab == 0 { summaryBody } else { transcriptBody }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, 110)
        }
        .animation(.recapSoft, value: summaryTab)
        .scrollContentBackground(.hidden)
    }

    private var titleMeta: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(meeting.title).font(.recapH1).foregroundStyle(Color.recapInk)
            HStack(spacing: Spacing.sm) {
                Text("\(meeting.dateText.prefix(5)) · \(meeting.durationText)")
                    .font(.recapMeta).foregroundStyle(Color.recapTea)
                AvatarGroup(members: [("明", 0), ("华", 1), ("林", 2)])
                Text("中文").font(.recapTimestamp).foregroundStyle(Color.recapTea)
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
            withAnimation(.recapSoft) { summaryTab = idx }
        } label: {
            Text(t)
                .font(.recapMeta.weight(.medium))
                .foregroundStyle(summaryTab == idx ? Color.recapInk : Color.recapTea)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(summaryTab == idx ? Color.recapBg : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 摘要主体（分层揭示）

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: Spacing.xxl) {
            if session.revealStep == 0 {
                processingHero
            }
            if session.revealStep >= 1 {
                TldrCard(text: summary.tldr).transition(revealTransition)
            }
            if session.revealStep >= 2 { decisionSection.transition(revealTransition) }
            if session.revealStep >= 3 { todoSection.transition(revealTransition) }
            if session.revealStep >= 4 { openQuestionSection.transition(revealTransition) }
        }
    }

    private var revealTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        )
    }

    private var processingHero: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 48)).foregroundStyle(Color.recapCeladon)
            Text("正在整理…").font(.recapH1).foregroundStyle(Color.recapInk)
            Text("本机处理，数据不上传")
                .font(.recapMeta).foregroundStyle(Color.recapTea)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private var decisionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("◆", "关键决议", color: Color.recapCeladon)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(summary.decisions, id: \.self) { d in
                    bulletRow(d, color: Color.recapCeladon, ink: Color.recapInk)
                }
            }
        }
    }

    private var todoSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("☐", "待办事项", color: Color.recapInk, count: items.count)
            ForEach($items) { $item in
                ActionItemCard(item: $item)
            }
        }
    }

    private var openQuestionSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionTitle("◐", "未决问题", color: Color.recapOchre)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(summary.openQuestions, id: \.self) { q in
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

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(TranscriptBlock.script) { block in
                SpeakerBlockView(block: block, isCurrent: false)
            }
        }
    }

    // MARK: 底部条（随态切换）

    @ViewBuilder private var bottomBar: some View {
        switch session.phase {
        case .live:       liveBottom
        case .processing: EmptyView()
        case .review:     reviewBottom
        }
    }

    private var liveBottom: some View {
        // iOS 26 真液态玻璃：GlassEffectContainer 把两个浮钮融合成一块玻璃
        GlassEffectContainer(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                // 问 Recap（轻量 glass · 青瓷色 sparkles）
                Button { showAgent = true } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.recapCeladon)
                        Text("问 Recap")
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .tracking(0.1)
                            .foregroundStyle(Color.recapInk)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .capsule)

                // 结束录音（朱砂填充 · 主操作）
                Button { session.endLive() } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("结束")
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .tracking(0.2)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .background(Color.recapCinnabar, in: .capsule)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .background(.bar)
    }

    private var reviewBottom: some View {
        // iOS 26 真液态玻璃：技能是核心操作（青瓷填充），问 Recap 是次操作（glass）
        GlassEffectContainer(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                // 问 Recap（对话智能体 · glass）
                Button { showAgent = true } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.recapCeladon)
                        Text("问 Recap")
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .tracking(0.1)
                            .foregroundStyle(Color.recapInk)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular, in: .capsule)

                // 技能/模板（核心操作 · 青瓷填充）
                Button { showSkills = true } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 14, weight: .semibold))
                        Text("技能")
                            .font(.system(size: 14, weight: .semibold, design: .default))
                            .tracking(0.1)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .background(Color.recapCeladon, in: .capsule)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .background(.bar)
        .sheet(isPresented: $showSkills) {
            SkillsSheet(isPresented: $showSkills, meetingTitle: meeting.title)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: 顶栏（随态切换，已隐藏系统 back button）

    private func elapsedText(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}
