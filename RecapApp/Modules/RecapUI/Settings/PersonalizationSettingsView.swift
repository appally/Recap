import SwiftUI
import RecapModels
import RecapASR

/// 个性化设置（极简风格：我的信息、输出偏好）
public struct PersonalizationSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // 用户身份（全局，自由文本）--驱动纪要称呼与待办归属（见 AgentSkillRunner.makeUserPrompt）
    @AppStorage("recap.user.about") private var identityAbout: String = ""
    // 全局输出偏好（自由文本）--驱动纪要风格与侧重；具体结构仍由模板决定
    @AppStorage("recap.output_pref") private var outputPref: String = ""

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                // Section 1: 我的信息
                identitySection

                // Section 2: 输出偏好
                outputPreferenceSection

                // Section 3: 常用词（plan 050）
                vocabularySection
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("个性化设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("我的信息")
                    .font(.recapEyebrow)
                    .tracking(Tracking.eyebrow)
                    .foregroundStyle(Color.recapTea)
                Text("这些信息将用于个性化纪要称呼与待办归属。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }

            MinimalInputBox(
                text: $identityAbout,
                placeholder: "介绍你自己：姓名、角色、团队，或任何希望在纪要中参照的身份信息。"
            )
        }
    }

    private var outputPreferenceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("输出偏好")
                    .font(.recapEyebrow)
                    .tracking(Tracking.eyebrow)
                    .foregroundStyle(Color.recapTea)
                Text("全局风格与侧重，适用于所有会议；具体结构仍由模板决定。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }

            MinimalInputBox(
                text: $outputPref,
                placeholder: "希望如何输出？如：简明直接、务必列出待办与截止日期、标注风险与待确认事项。"
            )
        }
    }

    // MARK: - 常用词（plan 050 Wave A）

    @State private var vocabDraft = ""
    @State private var vocabWords: [String] = UserVocabulary.words

    /// 常用词（人名/公司/术语）：注入本机转写热词与润色纠错提示，只在本机使用、不上传。
    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("常用词")
                    .font(.recapEyebrow)
                    .tracking(Tracking.eyebrow)
                    .foregroundStyle(Color.recapTea)
                Text("常被听错的人名、公司、术语。用于本机转写与润色纠错，不会上传。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea)
            }

            HStack(spacing: Spacing.md) {
                TextField("添加一个词（≤15 字）", text: $vocabDraft)
                    .textFieldStyle(.plain)
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapInk)
                    .onSubmit(addVocabWord)
                Button(action: addVocabWord) {
                    Image(systemName: RecapSymbol.add)
                        .font(.recapBody.weight(.medium))
                        .foregroundStyle(Color.recapInk)
                }
                .buttonStyle(RecapPressStyle())
                .disabled(vocabDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                Color(light: 0xF6F7F8, dark: 0x16191D),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )

            if !vocabWords.isEmpty {
                let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(vocabWords, id: \.self) { word in
                        HStack(spacing: 4) {
                            Text(word)
                                .font(.recapBodyS)
                                .foregroundStyle(Color.recapInk)
                                .lineLimit(1)
                            Button {
                                UserVocabulary.remove(word)
                                vocabWords = UserVocabulary.words
                            } label: {
                                Image(systemName: RecapSymbol.close)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Color.recapTea.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Color.recapInk.opacity(0.04),
                            in: Capsule()
                        )
                    }
                }
                if vocabWords.count >= UserVocabulary.maxWords {
                    Text("已达 \(UserVocabulary.maxWords) 词上限。")
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea.opacity(0.7))
                }
            }
        }
        .onAppear { vocabWords = UserVocabulary.words }
    }

    private func addVocabWord() {
        guard UserVocabulary.add(vocabDraft) else { return }
        vocabDraft = ""
        vocabWords = UserVocabulary.words
        Haptics.notify(.success)
    }
}

// MARK: - Minimal Input Box

private struct MinimalInputBox: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(light: 0xF6F7F8, dark: 0x16191D))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.recapTea.opacity(0.12), lineWidth: 0.5)
                )

            if text.isEmpty {
                Text(placeholder)
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapTea.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            TextField("", text: $text, axis: .vertical)
                .font(.recapBodyS)
                .foregroundStyle(Color.recapInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .lineLimit(3...5)
        }
        .frame(minHeight: 88)
    }
}
