import SwiftUI
import RecapModels
import RecapLLM

/// 技能面板：目录来自 SKILL.md catalog，执行走 AgentKernel。
public struct SkillsSheet: View {
    @Binding public var isPresented: Bool
    public let meetingTitle: String
    public let transcriptContext: String
    public var segments: [TranscriptSegment]
    public var speakers: [Speaker]
    public var briefSources: [BriefSource]
    public var meetingId: UUID
    public var actionItems: [ActionItem]
    public var minutesSummary: MeetingSummary?
    public var workspace: (any AgentWorkspaceQuerying)?

    @State private var runningSkill: String?
    @State private var statusLine: String?
    @State private var result: SkillResult?
    @State private var runTask: Task<Void, Never>?

    private let catalog = AgentSkillCatalog.bundledOrEmpty

    public struct SkillResult: Identifiable {
        public let id = UUID()
        public let title: String
        public let preview: String
    }

    public init(
        isPresented: Binding<Bool>,
        meetingTitle: String,
        transcriptContext: String,
        segments: [TranscriptSegment] = [],
        speakers: [Speaker] = [],
        briefSources: [BriefSource] = [],
        meetingId: UUID = UUID(),
        actionItems: [ActionItem] = [],
        minutesSummary: MeetingSummary? = nil,
        workspace: (any AgentWorkspaceQuerying)? = nil
    ) {
        self._isPresented = isPresented
        self.meetingTitle = meetingTitle
        self.transcriptContext = transcriptContext
        self.segments = segments
        self.speakers = speakers
        self.briefSources = briefSources
        self.meetingId = meetingId
        self.actionItems = actionItems
        self.minutesSummary = minutesSummary
        self.workspace = workspace
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                if runningSkill == nil, result == nil {
                    ForEach(catalog.groups) { group in
                        skillGroupCard(group)
                    }
                } else if let r = result {
                    resultCard(r)
                } else {
                    runningView
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, 60)
        }
        .background(Color.recapBg.ignoresSafeArea())
        .onDisappear { runTask?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Image(systemName: RecapSymbol.skills)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.recapCeladon)
            VStack(alignment: .leading, spacing: 1) {
                Text("技能")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Text(meetingTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(1)
            }
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.recapTea)
                    .frame(width: 32, height: 32)
                    .background(Color.recapTea.opacity(0.12), in: Circle())
            }
            .buttonStyle(RecapPressStyle())
        }
    }

    private func skillGroupCard(_ group: AgentSkillGroup) -> some View {
        let accent: Color = group.id == "extract" ? .recapCinnabar : .recapCeladon
        return VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: group.id == "extract" ? "list.bullet.rectangle" : "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                Spacer()
            }
            VStack(spacing: Spacing.sm) {
                ForEach(group.skills) { skill in
                    skillRow(skill, accent: accent)
                }
            }
        }
    }

    private func skillRow(_ skill: AgentSkill, accent: Color) -> some View {
        Button { run(skill) } label: {
            HStack(alignment: .top, spacing: Spacing.md) {
                ZStack {
                    Circle().fill(accent.opacity(0.14))
                    Image(systemName: skill.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.recapTea)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.recapTea.opacity(0.6))
                    .padding(.top, 10)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.md)
            .background(
                Color.recapPaper,
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
        }
        .buttonStyle(RecapPressStyle())
    }

    private var runningView: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            ProgressView()
            Text("正在用「\(runningSkill ?? "")」加工…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapInk)
            if let statusLine, !statusLine.isEmpty {
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
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private func resultCard(_ r: SkillResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.recapCeladon)
                Text(r.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Spacer()
                Button("重做") {
                    result = nil
                    statusLine = nil
                }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.recapCeladon)
            }
            Text(r.preview)
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(Color.recapInk)
                .padding(Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.recapPaper,
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                )
        }
    }

    private func run(_ skill: AgentSkill) {
        runTask?.cancel()
        runningSkill = skill.name
        statusLine = nil
        result = nil
        runTask = Task { @MainActor in
            await runWithKernel(skill)
        }
    }

    private func runWithKernel(_ skill: AgentSkill) async {
        let snapshots = actionItems.map {
            ActionItemSnapshot(
                id: $0.id,
                task: $0.task,
                owner: $0.owner,
                dueText: $0.dueText,
                statusRaw: $0.status.rawValue,
                meetingTitle: meetingTitle,
                isDispatched: $0.isReallyDispatched
            )
        }
        let ctx = AgentToolContext(
            meetingTitle: meetingTitle,
            phase: .review,
            segments: segments,
            speakers: speakers,
            briefSources: briefSources,
            fallbackTranscript: transcriptContext,
            webEnabled: false,
            currentMeetingId: meetingId,
            actionItems: snapshots,
            currentMinutes: minutesSummary,
            workspace: workspace
        )
        do {
            let text = try await AgentSkillRunner.run(skill: skill, context: ctx) { progress in
                Task { @MainActor in
                    if !progress.partialText.isEmpty {
                        result = SkillResult(
                            title: skill.name + " · 生成中",
                            preview: progress.partialText
                        )
                        runningSkill = nil
                    } else if let last = progress.toolLines.last {
                        statusLine = last
                    } else if let s = progress.status {
                        statusLine = s
                    }
                }
            }
            runningSkill = nil
            result = SkillResult(title: skill.name + " · 完成", preview: text)
        } catch is CancellationError {
            runningSkill = nil
        } catch {
            runningSkill = nil
            result = SkillResult(
                title: skill.name + " · 失败",
                preview: error.localizedDescription
            )
        }
    }
}
