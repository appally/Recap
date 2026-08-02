import SwiftUI
import RecapModels
import RecapASR

/// 个性化设置（Plaud AI 风格：我的信息、输出偏好）
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

            PlaudInputBox(
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

            PlaudInputBox(
                text: $outputPref,
                placeholder: "希望如何输出？如：简明直接、务必列出待办与截止日期、标注风险与待确认事项。"
            )
        }
    }
}

// MARK: - Plaud Input Box

private struct PlaudInputBox: View {
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
