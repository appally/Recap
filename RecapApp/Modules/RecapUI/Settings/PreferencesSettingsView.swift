import SwiftUI
import RecapModels
import RecapASR
import RecapLLM

/// 偏好设置（整合大模型与转写引擎设置）
public struct PreferencesSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var refreshToken = 0

    private var serviceMode: AIServiceMode {
        _ = refreshToken
        return AIServiceMode.current
    }

    private var asrPreference: ASRPreference {
        _ = refreshToken
        return ASRPreference.current
    }

    private var llmTemplate: LLMProviderTemplate {
        _ = refreshToken
        return LLMSelection.selectedTemplate
    }

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                SettingsSection(
                    title: "智能服务引擎",
                    footnote: "大模型与语音转写均可自由选择：Recap 云端免配置，或导入自备 Key 与离线引擎。"
                ) {
                    NavigationLink {
                        LLMSettingsView()
                            .onDisappear { refreshToken += 1 }
                    } label: {
                        SettingsNavRow(
                            icon: "sparkles",
                            iconTint: .recapInk,
                            title: "大模型引擎",
                            value: llmValue
                        )
                    }
                    .buttonStyle(SettingsPressStyle())

                    SettingsDivider()

                    NavigationLink {
                        ASRSettingsView()
                            .onDisappear { refreshToken += 1 }
                    } label: {
                        SettingsNavRow(
                            icon: "waveform",
                            iconTint: .recapInk,
                            title: "语音转写引擎",
                            value: asrPreference.title
                        )
                    }
                    .buttonStyle(SettingsPressStyle())
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("偏好设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshToken += 1 }
    }

    private var llmValue: String {
        switch serviceMode {
        case .recapCloud: return "Recap 云端"
        case .freeTrial: return "Recap 免费"
        case .byok: return llmTemplate.displayName
        }
    }
}
