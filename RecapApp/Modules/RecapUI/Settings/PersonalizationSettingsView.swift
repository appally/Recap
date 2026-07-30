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
    @State private var galleryRevision = 0

    public init() {}

    private var galleryCount: Int {
        _ = galleryRevision
        return VoiceprintGallery.shared.count
    }

    @ViewBuilder
    private var voiceprintSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("说话人声纹")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Text("在转写里点说话人名「这是我」可让 Recap 跨会议认出你。声纹仅本机、不上云。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.recapTea)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if VoiceprintConsent.granted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.recapCeladon)
                    Text("已同意 · 已存 \(galleryCount) 个说话人声纹")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.recapInk)
                    Spacer()
                }
                .padding(Spacing.lg)
                .background(Color.recapPaper,
                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.recapTea.opacity(0.08), lineWidth: 1))

                Button(role: .destructive) {
                    Haptics.impact(.medium)
                    VoiceprintGallery.shared.clearAll()
                    VoiceprintConsent.reset()
                    galleryRevision += 1
                } label: {
                    Label("删除全部声纹并撤回同意", systemImage: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.recapCinnabar)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(SettingsPressStyle())
            } else {
                Text("未开启。在会议转写里点某位说话人的名字选「这是我」时，会单独询问你是否同意。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.recapTea)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                // Section 1: 我的信息
                identitySection

                // Section 2: 输出偏好
                outputPreferenceSection

                // Section 3: 说话人声纹
                voiceprintSection
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Text("Recap 会用这些信息个性化纪要称呼与待办归属。")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.recapTea)
            }

            PlaudInputBox(
                text: $identityAbout,
                placeholder: "介绍你自己：姓名、角色、团队，或任何希望 Recap 在纪要中参照的身份信息。"
            )
        }
    }

    private var outputPreferenceSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("输出偏好")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.recapInk)
                Text("全局风格与侧重，适用于所有会议；具体结构仍由模板决定。")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.recapTea)
            }

            PlaudInputBox(
                text: $outputPref,
                placeholder: "希望 Recap 如何输出？如：简明直接、务必列出待办与截止日期、标注风险与待确认事项。"
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
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.recapTea.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            TextField("", text: $text, axis: .vertical)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.recapInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .lineLimit(3...5)
        }
        .frame(minHeight: 88)
    }
}
