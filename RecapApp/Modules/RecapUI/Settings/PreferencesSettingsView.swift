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

                // plan 049：零摩擦入口引导（控制中心/Action Button 配置在系统设置里，
                // App 内只做指路；自动化提示按用户要求移除）。
                SettingsSection(
                    title: "快捷开始录音",
                    footnote: "「开始录音」已加入快捷指令 App。"
                ) {
                    VStack(spacing: Spacing.sm) {
                        QuickStartRow(
                            glyph: .controlCenter,
                            title: "控制中心 · 锁屏",
                            hint: "添加「开始录音」控件",
                            path: "控制中心 › 编辑 › 开始录音"
                        )
                        QuickStartRow(
                            glyph: .actionButton,
                            title: "Action Button",
                            hint: "一按即录",
                            path: "设置 › Action Button › 快捷指令"
                        )
                    }
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

/// 快捷入口指路条：左侧入口图形（控制中心用 SF Symbol，Action Button 画硬件按钮造型），
/// 右侧名称 + 一句话用途 + mono 路径注脚——纸面文档风「指路卡」。
private struct QuickStartRow: View {
    enum Glyph {
        case controlCenter
        case actionButton
    }

    let glyph: Glyph
    let title: String
    /// 一句话说明这个入口「能干什么」（如「一按即录」）。
    let hint: String
    /// 系统内配置路径，mono 注脚呈现（› 分隔）。
    let path: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            glyphView
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.sm) {
                    Text(title)
                        .font(.recapBodyS.weight(.medium))
                        .foregroundStyle(Color.recapInk)
                    Text(hint)
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea.opacity(0.85))
                }
                Text(path)
                    .font(.recapMono)
                    .foregroundStyle(Color.recapTea.opacity(0.7))
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(
            Color.recapPaper,
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.recapTea.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var glyphView: some View {
        // 底衬统一：浅青底圆角方，与设置域图标徽章同族。
        Group {
            switch glyph {
            case .controlCenter:
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.recapInk)
            case .actionButton:
                // iPhone 侧边 Action Button 造型：竖侧框条 + 顶部胶囊钮，一眼即识。
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.recapTea.opacity(0.4), lineWidth: 1)
                    .frame(width: 10, height: 22)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(Color.recapInk)
                            .frame(width: 4, height: 8)
                            .offset(y: 3)
                    }
            }
        }
        .frame(width: 34, height: 34)
        .background(
            Color.recapTea.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}
