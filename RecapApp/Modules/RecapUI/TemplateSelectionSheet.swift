import SwiftUI
import SwiftData
import RecapModels
import RecapLLM

/// 极简风格「选择模板」Sheet：纯 picker——挑模板后回调 `onPickSkill`，
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
    // plan 060 Wave C：导入 / 导出 / 复制内置
    @State private var showSkillImporter = false
    @State private var importingDocs: [String] = []
    @State private var exportingSkill: AgentSkill?
    @State private var exportingURL: URL?

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
        // plan 060：导入 SKILL.md（多选）——外部文件是不可信输入，导入前展示能力清单（F12 同意时刻）。
        .fileImporter(isPresented: $showSkillImporter, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: true) { result in
            handleSkillImport(result)
        }
        .confirmationDialog(
            "导入 \(importingDocs.count) 个技能模板？",
            isPresented: Binding(get: { !importingDocs.isEmpty }, set: { if !$0 { importingDocs = [] } }),
            titleVisibility: .visible
        ) {
            Button("导入") {
                for raw in importingDocs { customStore.upsert(raw) }
                importingDocs = []
            }
            Button("取消", role: .cancel) { importingDocs = [] }
        } message: {
            Text(importConsentMessage)
        }
        .sheet(item: Binding(
            get: { exportingSkill.flatMap { skill in
                ExportedSkillFile(skill: skill, url: exportingURL)
            } },
            set: { if $0 == nil { exportingSkill = nil; exportingURL = nil } }
        )) { file in
            SkillShareSheet(items: [file.url])
                .presentationDetents([.medium])
        }
        .onAppear { customStore.rescan() }
    }

    /// 导入同意清单：名称 + 工具数 + 步数——写操作 codec 层硬禁，此处如实展示只读面。
    private var importConsentMessage: String {
        let lines = importingDocs.prefix(5).compactMap { raw -> String? in
            guard let s = try? AgentSkillDocument.parse(raw) else { return nil }
            return "「\(s.name)」— 工具 \(s.allowedTools.count) 个 · 步数上限 \(s.maxSteps)"
        }
        return (lines + ["导入后可在「我的模板」编辑；写操作（改纪要/建提醒）对所有模板硬禁。"])
            .joined(separator: "\n")
    }

    private func handleSkillImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        var docs: [String] = []
        for url in urls.prefix(10) {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let raw = try? String(contentsOf: url, encoding: .utf8),
                  (try? AgentSkillDocument.parse(raw)) != nil else { continue }
            docs.append(raw)
        }
        importingDocs = docs
    }

    /// 导出 = 写临时 .md（SKILL.md 原文）→ 系统分享面板。
    private func exportSkill(_ skill: AgentSkill) {
        guard let raw = customStore.documents.first(where: {
            (try? AgentSkillDocument.parse($0))?.id == skill.id
        }) ?? bundledDocument(for: skill) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(OpenWorkspace.skillFileName(for: skill.id))
        try? raw.write(to: url, atomically: true, encoding: .utf8)
        exportingSkill = skill
        exportingURL = url
    }

    private func bundledDocument(for skill: AgentSkill) -> String? {
        AgentBundledSkills.documents.first {
            (try? AgentSkillDocument.parse($0))?.id == skill.id
        }
    }

    /// 复制内置/收藏模板为我的模板（改 id/组名，进编辑器微调后保存）。
    private func duplicateAsCustom(_ skill: AgentSkill) {
        let copy = AgentSkill(
            id: "custom-\(UUID().uuidString.prefix(8))",
            name: skill.name + "（副本）",
            description: skill.description,
            icon: skill.icon,
            groupId: "custom",
            groupTitle: "自定义",
            scenario: skill.scenario,
            systemPrompt: skill.systemPrompt,
            allowedTools: skill.allowedTools,
            modelRole: skill.modelRole,
            maxSteps: skill.maxSteps,
            temperature: skill.temperature
        )
        editingCustom = copy
        showCustomEditor = true
    }

    /// 导出文件的 Identifiable 包装（sheet(item:) 要求）。
    private struct ExportedSkillFile: Identifiable {
        let skill: AgentSkill
        let url: URL?
        var id: String { skill.id }
    }

    /// 系统分享面板（UIActivityViewController 包装）。
    private struct SkillShareSheet: UIViewControllerRepresentable {
        let items: [URL?]

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items.compactMap { $0 }, applicationActivities: nil)
        }

        func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
    }

    // MARK: - Header / segment

    private var header: some View {
        // sheet 的关闭在 trailing（×），而非 leading 的返回箭头——chevron.left 是
        // push/pop 导航习语，与 sheet 的 dismiss（下滑 / 右上关闭）语义冲突。
        ZStack {
            Text("选择模板")
                .font(.recapTitleS)
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
        HStack(spacing: 8) {
            ForEach(TemplateTab.allCases) { tab in
                let isActive = selectedTab == tab
                Button {
                    Haptics.selection()
                    withAnimation(.recapSoft) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.recapBodyS.weight(isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? Color.recapInk : Color.recapTea.opacity(0.85))
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
                                    .matchedGeometryEffect(id: "segmentIndicator", in: segmentNS)
                            } else {
                                Capsule(style: .continuous)
                                    .fill(Color.clear)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xs)
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
                    .font(.recapMeta)
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
                    .font(.recapTitle)
                    .foregroundStyle(Color.recapInk)
                Spacer()
                Button {
                    editingCustom = nil
                    showCustomEditor = true
                } label: {
                    Label("新建", systemImage: "plus")
                        .font(.recapMeta.weight(.semibold))
                        .foregroundStyle(Color.recapInk)
                        .padding(.horizontal, Spacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RecapPressStyle())
                Button {
                    showSkillImporter = true
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .font(.recapMeta.weight(.semibold))
                        .foregroundStyle(Color.recapInk)
                        .padding(.horizontal, Spacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(RecapPressStyle())
            }
            Text("模板即文件：保存在「文件」App 的 Recap/skills 目录，可随时在电脑上编辑后回 App 生效。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.7))
                .lineSpacing(Leading.tight)
            if customStore.isEmpty {
                Text("还没有自定义模板——点「新建」，用你的提示词创建一个")
                    .font(.recapMeta)
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
                    .font(.recapTitle)
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
                        .font(.recapHeading)
                        .foregroundStyle(Color.recapInk)
                        .lineLimit(1)
                    Text(skill.description)
                        .font(.recapMeta)
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
        .contextMenu {
            Button { exportSkill(skill) } label: { Label("导出 .md", systemImage: "square.and.arrow.up") }
            Button { editingCustom = skill; showCustomEditor = true } label: { Label("编辑", systemImage: "pencil") }
            Button(role: .destructive) { skillToDelete = skill } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func scenarioHeader(_ group: AgentScenarioGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.recapInk)
            Text(group.title)
                .font(.recapTitle)
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

    private func skillColor(_ skill: AgentSkill) -> Color {
        switch skill.groupTitle {
        case "提取": return Color(light: 0x2563EB, dark: 0x60A5FA) // 皇家蓝
        case "写作": return Color(light: 0x7C3AED, dark: 0xA78BFA) // 优雅紫
        case "可视化": return Color(light: 0xDB2777, dark: 0xF472B6) // 活力粉
        case "纪要": return Color(light: 0x059669, dark: 0x34D399) // 翡翠绿
        default: return Color(light: 0xD97706, dark: 0xFBBF24) // 琥珀金
        }
    }

    private func templateCard(_ skill: AgentSkill) -> some View {
        let isSelected = selectedSkill?.id == skill.id
        let isFavorite = favorites.contains(skill.id)
        let color = skillColor(skill)
        return Button {
            Haptics.selection()
            withAnimation(.recapSoft) {
                selectedSkill = skill
            }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.xs) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(color.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: skill.icon.isEmpty ? "doc.text" : skill.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(color)
                    }
                    Spacer()
                    // 选中对勾：固定宽度槽位，淡入淡出，避免收藏星左右跳动。
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.recapInk)
                        .opacity(isSelected ? 1 : 0)
                        .frame(width: 20)
                    Button {
                        Haptics.selection()
                        withAnimation(.recapSoft) { favorites.toggle(skill.id) }
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundStyle(isFavorite ? Color.recapCinnabar : Color.recapTea.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RecapPressStyle())
                }

                Text(skill.name)
                    .font(.recapHeading)
                    .foregroundStyle(Color.recapInk)
                    .lineLimit(1)

                Text(skill.description)
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 32, alignment: .topLeading)

                Spacer(minLength: 0)

                Text(skill.groupTitle)
                    .font(.recapCaption.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(color.opacity(0.10))
                    )
            }
            .padding(Spacing.md)
            .frame(height: 156)
            .background(cardBackground(cornerRadius: 16, isSelected: isSelected, selectedLineWidth: 2))
        }
        .buttonStyle(RecapPressStyle())
        .contextMenu {
            Button { duplicateAsCustom(skill) } label: { Label("复制为我的模板", systemImage: "doc.on.doc") }
        }
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
                    .font(.recapTitleS)
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
