import SwiftUI
import SwiftData
import RecapModels
import RecapLLM

/// Plaud AI 风格「选择模板」Sheet：纯 picker——挑模板后回调 `onPickSkill`，
/// 由父视图（`MeetingNoteView`）负责在笔记 Tab 内联流式生成与落库。
///
/// 三档 Tab 职责：
/// - 推荐：按本场会议信号（标题/时长/说话人/Moments）排序的精选（`TemplateRecommender`）；
/// - 探索：按场景域（`scenarioGroups`）分组的全目录；
/// - 我的空间：收藏的模板（`TemplateFavoritesStore`，本地偏好）。
public struct TemplateSelectionSheet: View {
    @Binding public var isPresented: Bool
    public let meetingTitle: String
    public let meeting: Meeting
    public var onPickSkill: (AgentSkill) -> Void

    @State private var selectedTab: TemplateTab = .recommended
    @State private var selectedSkill: AgentSkill?
    @State private var errorMessage: String?
    @StateObject private var favorites = TemplateFavoritesStore()
    @StateObject private var customStore = CustomTemplateStore()
    @State private var showCustomEditor = false
    @State private var editingCustom: AgentSkill?

    public enum TemplateTab: String, CaseIterable, Identifiable {
        case recommended = "推荐"
        case explore = "探索"
        case mySpace = "我的空间"
        public var id: String { rawValue }
    }

    /// 内置 + 用户自定义合并（自定义无法覆盖内置 id）。
    private var catalog: AgentSkillCatalog {
        AgentSkillCatalog.merging(customDocuments: customStore.documents)
    }

    public init(
        isPresented: Binding<Bool>,
        meetingTitle: String,
        meeting: Meeting,
        onPickSkill: @escaping (AgentSkill) -> Void
    ) {
        self._isPresented = isPresented
        self.meetingTitle = meetingTitle
        self.meeting = meeting
        self.onPickSkill = onPickSkill
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            segmentBar
            scrollView
            bottomBar
        }
        .background(Color.recapBg.ignoresSafeArea())
        .onAppear {
            if selectedSkill == nil {
                selectedSkill = recommendedSkills.first ?? catalog.skills.first
            }
        }
        .alert("无法生成", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showCustomEditor) {
            CustomTemplateEditorSheet(store: customStore, editing: editingCustom)
        }
    }

    // MARK: - Header / segment

    private var header: some View {
        HStack {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
            }

            Spacer()

            Text("选择模板")
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
            recommendedList
        case .explore:
            exploreList
        case .mySpace:
            mySpaceList
        }
    }

    private var recommendedSkills: [AgentSkill] {
        TemplateRecommender.recommend(
            title: meeting.title,
            durationSeconds: meeting.durationSeconds,
            speakerCount: meeting.speakers.count,
            hasMoments: !meeting.moments.isEmpty,
            hasBrief: meeting.brief != nil,
            catalog: catalog
        )
    }

    private var recommendedList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("根据本场会议推荐")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.recapTea)
                skillGrid(recommendedSkills)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, 100)
        }
    }

    private var exploreList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                ForEach(catalog.scenarioGroups) { group in
                    scenarioHeader(group)
                    skillGrid(group.skills)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, 100)
        }
    }

    private var mySpaceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                myTemplatesSection
                favoritesSection
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, 100)
        }
    }

    @ViewBuilder
    private var myTemplatesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("我的模板")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.recapInk)
                Spacer()
                Button {
                    editingCustom = nil
                    showCustomEditor = true
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                }
                .buttonStyle(.plain)
            }
            if customStore.isEmpty {
                Text("还没有自定义模板——点「新建」，用你的提示词创建一个")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.sm)
            } else {
                VStack(spacing: Spacing.sm) {
                    ForEach(customStore.skills) { skill in
                        customRow(skill)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let favs = favorites.favorited(in: catalog)
        if !favs.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("收藏的模板")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.recapInk)
                skillGrid(favs)
            }
        }
    }

    private func customRow(_ skill: AgentSkill) -> some View {
        let isSelected = selectedSkill?.id == skill.id
        return HStack(spacing: Spacing.md) {
            Image(systemName: skill.icon.isEmpty ? "doc.text" : skill.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.recapInk)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                    .lineLimit(1)
                Text(skill.description)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                editingCustom = skill
                showCustomEditor = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.recapTea)
            }
            .buttonStyle(.plain)
            Button {
                Haptics.impact(.medium)
                customStore.delete(id: skill.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.recapCinnabar)
            }
            .buttonStyle(.plain)
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(light: 0xFFFFFF, dark: 0x16191D))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isSelected ? Color.recapInk : Color.recapTea.opacity(0.12),
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.selection()
            selectedSkill = skill
        }
    }

    private func scenarioHeader(_ group: AgentScenarioGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapInk)
            Text(group.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.recapInk)
        }
    }

    private func skillGrid(_ skills: [AgentSkill]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.md) {
            ForEach(skills) { skill in
                templateCard(skill)
            }
        }
    }

    private func templateCard(_ skill: AgentSkill) -> some View {
        let isSelected = selectedSkill?.id == skill.id
        let isFavorite = favorites.contains(skill.id)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Image(systemName: skill.icon.isEmpty ? "doc.text" : skill.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Spacer()
                Button {
                    Haptics.selection()
                    favorites.toggle(skill.id)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundStyle(isFavorite ? Color.recapCinnabar : Color.recapTea.opacity(0.5))
                }
                .buttonStyle(.plain)
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

            Text(skill.groupTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.recapTea)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.recapTea.opacity(0.12))
                )
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
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.selection()
            selectedSkill = skill
        }
    }

    // MARK: - Generate

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Button {
                guard let selectedSkill else { return }
                guard MinutesPipelineSmoke.canRunMinutesPipeline else {
                    errorMessage = "未配置可用的大模型密钥，请先在设置里配置。"
                    return
                }
                Haptics.impact(.medium)
                onPickSkill(selectedSkill)
                isPresented = false
            } label: {
                Text("生成")
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
}
