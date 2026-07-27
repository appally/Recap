import SwiftUI
import RecapModels

/// 个性化设置（Plaud AI 风格：内容侧重、自定义指令、AI 记忆）
public struct PersonalizationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("recap_content_focus") private var contentFocus: String = ""
    @AppStorage("recap_custom_instructions") private var customInstructions: String = ""
    @AppStorage("recap_use_memory") private var useMemory: Bool = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                // Section 1: 内容侧重
                contentFocusSection

                // Section 2: 自定义指令
                customInstructionsSection

                // Section 3: 记忆
                memorySection
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

    private var contentFocusSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("内容侧重")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.recapInk)

            PlaudInputBox(
                text: $contentFocus,
                placeholder: "Recap 输出时应重点关注哪些内容？"
            )

            // Preset Chip Pills
            HStack(spacing: Spacing.sm) {
                PlaudChipButton(title: "要点与结论") { appendText(&contentFocus, "要点与结论") }
                PlaudChipButton(title: "风险与待确认事项") { appendText(&contentFocus, "风险与待确认事项") }
                PlaudChipButton(title: "行动项与下一步") { appendText(&contentFocus, "行动项与下一步") }
            }
        }
    }

    private var customInstructionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("自定义指令")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.recapInk)

            PlaudInputBox(
                text: $customInstructions,
                placeholder: "Recap 应如何表达和说明内容？"
            )

            // Preset Chip Pills
            HStack(spacing: Spacing.sm) {
                PlaudChipButton(title: "简明直接") { appendText(&customInstructions, "简明直接") }
                PlaudChipButton(title: "正式、专业") { appendText(&customInstructions, "正式、专业") }
                PlaudChipButton(title: "结构清晰") { appendText(&customInstructions, "结构清晰") }
            }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("记忆")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.recapTea)

            SettingsDivider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $useMemory) {
                    Text("使用记忆")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color.recapInk)
                }
                .tint(Color.recapInk)

                Text("开启后，Recap 会记住并使用你的信息，提供个性化的回复。了解更多")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.recapTea)
                    .lineSpacing(3)
            }
            .padding(.vertical, 4)

            SettingsDivider()

            NavigationLink {
                MemoryManagementView()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("管理记忆")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Color.recapInk)
                        Spacer()
                        SettingsChevron()
                    }
                    Text("查看和管理 Recap 记住的内容")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.recapTea)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

    private func appendText(_ target: inout String, _ preset: String) {
        Haptics.impact(.light)
        if target.isEmpty {
            target = preset
        } else if !target.contains(preset) {
            target += "，\(preset)"
        }
    }
}

// MARK: - Plaud Input Box & Chip Components

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

private struct PlaudChipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.recapInk.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(light: 0xF6F7F8, dark: 0x1C2025))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.recapTea.opacity(0.15), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(RecapPressStyle())
    }
}

/// 记忆管理占位页
private struct MemoryManagementView: View {
    var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Color.recapTea)
            Text("暂无积累的偏好记忆")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.recapInk)
            Text("在使用 Recap 进行语音记录和 AI 纪要生成时，重要的习惯偏好将被自动记住。")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.recapTea)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsAmbientBackground())
        .navigationTitle("管理记忆")
        .navigationBarTitleDisplayMode(.inline)
    }
}
