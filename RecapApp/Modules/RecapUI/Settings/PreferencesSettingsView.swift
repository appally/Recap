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
                    footnote: "大模型与语音转写均可自由选择：官方云端免配置，或导入自备 Key 与离线引擎。"
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

                // plan 049：零摩擦入口引导（纯文案——快捷指令自动化与 Action Button
                // 的配置在系统设置里，App 内只做指路）。
                SettingsSection(
                    title: "快捷开始录音",
                    footnote: "「开始录音」已加入快捷指令 App，可配置到系统的各个快捷入口："
                ) {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Label("控制中心或锁屏：添加「开始录音」控件", systemImage: "slider.horizontal.3")
                        Label("Action Button：设置 → Action Button → 快捷指令", systemImage: "circle.button.2")
                        Label("自动化：快捷指令 App → 自动化（如「到公司时开始录音」）", systemImage: "clock.arrow.circlepath")
                    }
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapTea)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        case .recapCloud: return "官方云端"
        case .freeTrial: return "免费档"
        case .byok: return llmTemplate.displayName
        }
    }
}
