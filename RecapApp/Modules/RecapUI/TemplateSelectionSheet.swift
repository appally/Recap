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
    @Namespace private var segmentNS
    @State private var skillToDelete: AgentSkill?

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
        .confirmationDialog(
            "删除「\(skillToDelete?.name ?? "")」？",
            isPresented: Binding(get: { skillToDelete != nil }, set: { if !$0 { skillToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let s = skillToDelete { customStore.delete(id: s.id) }
                skillToDelete = nil
            }
            Button("取消", role: .cancel) { skillToDelete = nil }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    // MARK: - Header / segment

    private var header: some View {
        // sheet 的关闭在 trailing（×），而非 leading 的返回箭头——chevron.left 是
        // push/pop 导航习语，与 sheet 的 dismiss（下滑 / 右上关闭）语义冲突。
        ZStack {
            Text("选择模板")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.recapInk)
            HStack {
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.recapTea)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RecapPressStyle())
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    private var segmentBar: some View {
        HStack(spacing: 24) {
            ForEach(TemplateTab.allCases) { tab in
                Button {
                    Haptics.selection()
                    withAnimation(.recapSoft) { selectedTab = tab }
                } label: {
                    VStack(spacing: 4) {
                        Text(tab.rawValue)
                            .font(.system(size: 15, weight: selectedTab == tab ? .bold : .regular))
                            .foregroundStyle(selectedTab == tab ? Color.recapInk : Color.recapTea)
                        // 滑动下划线：固定占位保高，选中项带 matchedGeometry 的墨色胶囊
                        // 随 selectedTab 平滑滑动，给眼睛一个移动锚点（空间一致性）。
                        ZStack {
                            Capsule().fill(.clear).frame(width: 18, height: 2.5)
                            if selectedTab == tab {
                                Capsule().fill(Color.recapInk).frame(width: 18, height: 2.5)
                                    .matchedGeometryEffect(id: "segmentIndicator", in: segmentNS)
                            }
                        }
                    }
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
        // 用 selectedTab 作 id 强制换 identity，配合 .transition 在 withAnimation 下做
        // 内容淡入淡出——避免 switch 不同 view 的硬切跳变。
        Group {
            switch selectedTab {
            case .recommended:
                recommendedList
            case .explore:
                exploreList
            case .mySpace:
                mySpaceList
            }
        }
        .id(selectedTab)
        .transition(.opacity)
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
            .padding(.bottom, Spacing.xl)
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
            .padding(.bottom, Spacing.xl)
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
            .padding(.bottom, Spacing.xl)
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
                        .padding(.horizontal, Spacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RecapPressStyle())
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
        return Button {
            Haptics.selection()
            withAnimation(.recapSoft) {
                selectedSkill = skill
            }
        } label: {
            HStack(spacing: Spacing.md) {
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
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RecapPressStyle())
                Button {
                    Haptics.impact(.medium)
                    skillToDelete = skill
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.recapCinnabar)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RecapPressStyle())
            }
            .padding(Spacing.md)
            .background(cardBackground(cornerRadius: 14, isSelected: isSelected))
        }
        .buttonStyle(RecapPressStyle())
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

    /// 卡片/行底：纸底 + 选中墨色微填充 + 边框。选中态靠「填充淡入 + 对勾 + 边框加深」
    /// 三件叠加，而非仅 1px 边框差异——高代价生成前的提交依据必须一眼可辨。
    private func cardBackground(cornerRadius: CGFloat, isSelected: Bool, selectedLineWidth: CGFloat = 1.5) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.recapPaper)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.recapInk)
                    .opacity(isSelected ? 0.04 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        isSelected ? Color.recapInk : Color.recapTea.opacity(0.12),
                        lineWidth: isSelected ? selectedLineWidth : 0.5
                    )
            )
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
        return Button {
            Haptics.selection()
            withAnimation(.recapSoft) {
                selectedSkill = skill
            }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: skill.icon.isEmpty ? "doc.text" : skill.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                    Spacer()
                    // 选中对勾：固定宽度槽位，淡入淡出，避免收藏星左右跳动。
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 18)
                    Button {
                        Haptics.selection()
                        withAnimation(.recapSoft) { favorites.toggle(skill.id) }
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(isFavorite ? Color.recapCinnabar : Color.recapTea.opacity(0.5))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RecapPressStyle())
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
            .background(cardBackground(cornerRadius: 16, isSelected: isSelected, selectedLineWidth: 2))
        }
        .buttonStyle(RecapPressStyle())
    }

    // MARK: - Generate

    /// 生成钮文案带上所选模板名——显式绑定「选择↔提交」，消除预选带来的
    /// 「这是 AI 替我选的，还是我点的」模糊。
    private var generateTitle: String {
        if let name = selectedSkill?.name, !name.isEmpty {
            return "生成 · \(name)"
        }
        return "生成"
    }

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
                Text(generateTitle)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.recapBg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.recapInk)
                    )
            }
            .buttonStyle(RecapPressStyle())
            .disabled(selectedSkill == nil)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
        .background(Color.recapBg)
    }
}
