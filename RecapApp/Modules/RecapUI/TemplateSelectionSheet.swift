import SwiftUI
import SwiftData
import RecapModels
import RecapLLM

/// Plaud AI 风格「选择模板」Sheet：挑模板 → 跑 skill → 落库 `.note` → 回调新建笔记 id。
///
/// 接通后的语义：picker + 生成一体（进度在本 sheet 内展示）；不再把 skill 名拼成
/// prefill 跳聊天页。落库由 `SkillNoteWriter` 负责，本视图只做 UX + 编排。
public struct TemplateSelectionSheet: View {
    @Binding public var isPresented: Bool
    public let meetingTitle: String
    public let meeting: Meeting
    public let agentToolContext: AgentToolContext
    public var onGenerated: (UUID) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab: TemplateTab = .recommended
    @State private var selectedSkill: AgentSkill?
    @State private var isGenerating = false
    @State private var partialText: String?
    @State private var statusLine: String?
    @State private var errorMessage: String?
    @State private var genTask: Task<Void, Never>?

    public enum TemplateTab: String, CaseIterable, Identifiable {
        case mySpace = "我的空间"
        case recommended = "推荐"
        case explore = "探索"
        public var id: String { rawValue }
    }

    private let catalog = AgentSkillCatalog.bundledOrEmpty

    public init(
        isPresented: Binding<Bool>,
        meetingTitle: String,
        meeting: Meeting,
        agentToolContext: AgentToolContext,
        onGenerated: @escaping (UUID) -> Void
    ) {
        self._isPresented = isPresented
        self.meetingTitle = meetingTitle
        self.meeting = meeting
        self.agentToolContext = agentToolContext
        self.onGenerated = onGenerated
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if isGenerating {
                generatingView
            } else {
                segmentBar
                scrollView
                bottomBar
            }
        }
        .background(Color.recapBg.ignoresSafeArea())
        .onAppear {
            if selectedSkill == nil {
                selectedSkill = catalog.groups.first?.skills.first
            }
        }
        .onDisappear { genTask?.cancel() }
        .alert("生成失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header / segment

    private var header: some View {
        HStack {
            Button {
                genTask?.cancel()
                isPresented = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
            }
            .disabled(isGenerating)

            Spacer()

            Text(isGenerating ? "正在生成" : "选择模板")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.recapInk)

            Spacer()

            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    private var segmentBar: some View {
        HStack(spacing: 24) {
            ForEach(TemplateTab.allCases) { tab in
                Button {
                    withAnimation(.recapSoft) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: selectedTab == tab ? .bold : .regular))
                        .foregroundStyle(selectedTab == tab ? Color.recapInk : Color.recapTea)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Pick content

    @ViewBuilder
    private var scrollView: some View {
        switch selectedTab {
        case .recommended:
            catalogList(grouped: true)
        case .explore:
            catalogList(grouped: false)
        case .mySpace:
            mySpaceEmpty
        }
    }

    private func catalogList(grouped: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if grouped {
                    ForEach(catalog.groups) { group in
                        sectionTitle(group.title)
                        skillGrid(group.skills)
                    }
                } else {
                    sectionTitle("全部模板")
                    skillGrid(catalog.groups.flatMap(\.skills))
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, 100)
        }
    }

    private var mySpaceEmpty: some View {
        VStack(spacing: Spacing.sm) {
            Spacer()
            Image(systemName: "bookmark")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.recapTea.opacity(0.6))
            Text("还没有保存的模板")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.recapTea)
            Text("以后可以在这里管理你常用的模板")
                .font(.system(size: 12))
                .foregroundStyle(Color.recapTea.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func skillGrid(_ skills: [AgentSkill]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.md) {
            ForEach(skills) { skill in
                templateCard(skill)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.recapInk)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.recapTea)
        }
    }

    private func templateCard(_ skill: AgentSkill) -> some View {
        let isSelected = selectedSkill?.id == skill.id
        return Button {
            Haptics.selection()
            selectedSkill = skill
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Image(systemName: skill.icon.isEmpty ? "doc.text" : skill.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.recapCeladon)
                    Spacer()
                    Image(systemName: "arrow.up.right.and.arrow.down.left.rectangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.recapTea.opacity(0.6))
                }

                Text(skill.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.recapInk)
                    .lineLimit(1)

                Text(skill.description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 32, alignment: .topLeading)

                Spacer(minLength: 0)

                Text("📊 内置  •  Recap")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.recapTea.opacity(0.8))
            }
            .padding(Spacing.md)
            .frame(height: 150)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(light: 0xFFFFFF, dark: 0x16191D))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                isSelected ? Color.recapInk : Color.recapTea.opacity(0.12),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Generation

    private var generatingView: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            ProgressView()
            Text("正在用「\(selectedSkill?.name ?? "")」生成…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapInk)
            if let partialText, !partialText.isEmpty {
                Text(partialText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            } else if let statusLine, !statusLine.isEmpty {
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
                    .multilineTextAlignment(.center)
            } else {
                Text(MinutesPipelineSmoke.canRunMinutesPipeline ? "智能体生成中" : "未配置可用密钥")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
            }
            Spacer()
            Button("取消") {
                genTask?.cancel()
                isGenerating = false
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.recapCinnabar)
            .padding(.bottom, Spacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Button {
                guard let selectedSkill else { return }
                startGeneration(selectedSkill)
            } label: {
                Text("生成笔记")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(light: 0x737373, dark: 0x333333))
                    )
            }
            .disabled(selectedSkill == nil)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(Color.recapBg)
    }

    private func startGeneration(_ skill: AgentSkill) {
        guard MinutesPipelineSmoke.canRunMinutesPipeline else {
            errorMessage = "未配置可用的大模型密钥，请先在设置里配置。"
            return
        }
        Haptics.impact(.medium)
        isGenerating = true
        partialText = nil
        statusLine = nil
        let context = agentToolContext
        genTask = Task { @MainActor in
            do {
                let id = try await SkillNoteWriter.generate(
                    skill: skill,
                    context: context,
                    meeting: meeting,
                    modelContext: modelContext
                ) { progress in
                    Task { @MainActor in
                        if !progress.partialText.isEmpty {
                            partialText = progress.partialText
                        } else if let s = progress.status {
                            statusLine = s
                        } else if let last = progress.toolLines.last {
                            statusLine = last
                        }
                    }
                }
                isGenerating = false
                onGenerated(id)
                isPresented = false
            } catch is CancellationError {
                isGenerating = false
            } catch {
                isGenerating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
