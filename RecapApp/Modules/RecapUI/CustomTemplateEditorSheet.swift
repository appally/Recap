import SwiftUI
import RecapLLM

/// 自定义模板编辑器（新建 / 编辑）。复用 `AgentSkillDocument` 的 round-trip：
/// 表单 → 构造 `AgentSkill` → `encode` 成 SKILL.md → 交 `CustomTemplateStore.upsert`。
///
/// plan 060 Wave C 解锁：模型角色（quick/pro）、步数 1–6、工具白名单多选
/// （仅只读检索池；写操作三件在 codec 层硬禁）。落盘 = `Documents/Recap/skills/<id>.md`。
struct CustomTemplateEditorSheet: View {
    let store: CustomTemplateStore
    let editing: AgentSkill?

    @State private var name: String
    @State private var descriptionText: String
    @State private var scenario: TemplateScenario
    @State private var icon: String
    @State private var prompt: String
    @State private var modelRole: AgentModelRole
    @State private var maxSteps: Int
    @State private var selectedTools: Set<String>
    @State private var showAdvanced = false

    @Environment(\.dismiss) private var dismiss

    private static let iconPresets = [
        "wand.and.stars", "doc.text", "star", "lightbulb",
        "flag", "tag", "book", "gearshape",
    ]

    /// 可选工具池（只读检索；`forbiddenTools` 写操作不在此层，codec 硬禁）。
    private static let toolPool: [(id: String, label: String)] = [
        ("search_transcript", "检索本场转写"),
        ("search_brief", "检索会前底稿"),
        ("list_action_items", "列出本场待办"),
        ("search_meetings", "跨会议检索"),
        ("get_meeting_transcript", "读取他场转写"),
        ("get_meeting_minutes", "读取他场纪要"),
        ("read_url", "读取网页"),
    ]

    init(store: CustomTemplateStore, editing: AgentSkill? = nil) {
        self.store = store
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _descriptionText = State(initialValue: editing?.description ?? "")
        _scenario = State(initialValue: editing?.scenario ?? .general)
        _icon = State(initialValue: editing?.icon ?? "wand.and.stars")
        _prompt = State(initialValue: editing?.systemPrompt ?? "")
        _modelRole = State(initialValue: editing?.modelRole ?? .quick)
        _maxSteps = State(initialValue: editing?.maxSteps ?? 3)
        _selectedTools = State(
            initialValue: editing?.allowedTools ?? AgentSkillDocument.defaultAllowedTools)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称（如：需求评审要点）", text: $name)
                    TextField("一句话说明", text: $descriptionText, axis: .vertical)
                        .lineLimit(1...3)
                    Picker("场景", selection: $scenario) {
                        ForEach(TemplateScenario.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    iconPicker
                } header: {
                    Text("基础")
                }

                Section {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 220)
                        .font(.recapBodyS)
                } header: {
                    Text("提示词")
                } footer: {
                    Text("告诉 AI 怎么处理这场会议。建议给出固定的输出章节骨架；只写转写里的事实，不确定写「待确认」，不要编造。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                }

                Section {
                    Toggle("高级设置", isOn: $showAdvanced.animation(.recapSoft))
                    if showAdvanced {
                        Picker("模型角色", selection: $modelRole) {
                            Text("快速（日常/便宜）").tag(AgentModelRole.quick)
                            Text("深入（纪要/调研）").tag(AgentModelRole.deep)
                        }
                        Stepper("步数上限：\(maxSteps)", value: $maxSteps, in: 1...6)
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text("允许工具（默认只读三件）")
                                .font(.recapMeta)
                                .foregroundStyle(Color.recapTea)
                            ForEach(Self.toolPool, id: \.id) { tool in
                                Toggle(tool.label, isOn: Binding(
                                    get: { selectedTools.contains(tool.id) },
                                    set: { on in
                                        if on { selectedTools.insert(tool.id) }
                                        else { selectedTools.remove(tool.id) }
                                    }
                                ))
                                .font(.recapBodyS)
                            }
                        }
                    }
                } header: {
                    Text("执行")
                } footer: {
                    Text("写操作（改纪要/建提醒/嵌套技能）对所有模板硬禁；跨会议与网页工具按需开启。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                }
            }
            .navigationTitle(editing == nil ? "新建模板" : "编辑模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Subviews

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("图标")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.iconPresets, id: \.self) { sym in
                        Button {
                            Haptics.selection()
                            icon = sym
                        } label: {
                            Image(systemName: sym)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(icon == sym ? Color.white : Color.recapInk)
                                .frame(width: 40, height: 40)
                                .background(
                                    Circle()
                                        .fill(icon == sym ? Color.recapInk : Color.recapTea.opacity(0.12))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    // MARK: - Save

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedTools.isEmpty
    }

    private func save() {
        let id = editing?.id ?? "custom-\(UUID().uuidString.prefix(8))"
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let skill = AgentSkill(
            id: String(id),
            name: trimmedName,
            description: trimmedDesc,
            icon: icon,
            groupId: "custom",
            groupTitle: "自定义",
            scenario: scenario,
            systemPrompt: trimmedPrompt,
            allowedTools: selectedTools.union(AgentSkillDocument.defaultAllowedTools),
            modelRole: modelRole,
            maxSteps: maxSteps
        )
        store.upsert(AgentSkillDocument.encode(skill))
        Haptics.impact(.medium)
        dismiss()
    }
}
