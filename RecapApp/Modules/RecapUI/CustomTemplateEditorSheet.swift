import SwiftUI
import RecapLLM

/// 自定义模板编辑器（新建 / 编辑）。复用 `AgentSkillDocument` 的 round-trip：
/// 表单 → 构造 `AgentSkill` → `encode` 成 SKILL.md → 交 `CustomTemplateStore.upsert`。
///
/// MVP 边界：本地存、allowedTools 固定为只读三件套、模型角色 quick / 3 步。
/// 无图标自定义文本（提供预设）；无多语言；无社区分享（P2）。
struct CustomTemplateEditorSheet: View {
    let store: CustomTemplateStore
    let editing: AgentSkill?

    @State private var name: String
    @State private var descriptionText: String
    @State private var scenario: TemplateScenario
    @State private var icon: String
    @State private var prompt: String

    @Environment(\.dismiss) private var dismiss

    private static let iconPresets = [
        "wand.and.stars", "doc.text", "star", "lightbulb",
        "flag", "tag", "book", "gearshape",
    ]

    init(store: CustomTemplateStore, editing: AgentSkill? = nil) {
        self.store = store
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _descriptionText = State(initialValue: editing?.description ?? "")
        _scenario = State(initialValue: editing?.scenario ?? .general)
        _icon = State(initialValue: editing?.icon ?? "wand.and.stars")
        _prompt = State(initialValue: editing?.systemPrompt ?? "")
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
                        .font(.system(size: 14))
                } header: {
                    Text("提示词")
                } footer: {
                    Text("告诉 AI 怎么处理这场会议。建议给出固定的输出章节骨架；只写转写里的事实，不确定写「待确认」，不要编造。")
                        .font(.system(size: 12))
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
                .font(.system(size: 13))
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
            allowedTools: AgentSkillDocument.defaultAllowedTools,
            modelRole: .quick,
            maxSteps: 3
        )
        store.upsert(AgentSkillDocument.encode(skill))
        Haptics.impact(.medium)
        dismiss()
    }
}
