import SwiftUI
import SwiftData
import RecapModels
import RecapASR

/// 隐私政策 / 用户协议摘要（审核可离线阅读；同时提供外链）。
struct LegalDocumentView: View {
    enum Kind {
        case privacy, terms

        var title: String {
            switch self {
            case .privacy: return "隐私政策"
            case .terms: return "用户协议"
            }
        }

        var bodyText: String {
            switch self {
            case .privacy: return RecapLegal.privacySummary
            case .terms: return RecapLegal.termsSummary
            }
        }

        var url: URL {
            switch self {
            case .privacy: return RecapLegal.privacyURL
            case .terms: return RecapLegal.termsURL
            }
        }
    }

    let kind: Kind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text(kind.bodyText)
                    .font(.recapBodyS)
                    .foregroundStyle(Color.recapInk)
                    .lineSpacing(Leading.body)

                Link(destination: kind.url) {
                    SettingsNavRow(
                        icon: "safari",
                        iconTint: .recapInk,
                        title: "在浏览器中打开完整版",
                        showChevron: true
                    )
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 本地数据清除（过审：用户对本地数据的控制）。
/// 单场导出走会议详情的分享（PDF / Markdown / 长图）；批量导出待后续版本再上，不设占位入口。
struct DataPrivacySettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var meetings: [Meeting]

    @State private var showClearConfirm = false
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                summaryCard

                VStack(spacing: 0) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        SettingsNavRow(
                            icon: "trash",
                            iconTint: .recapCinnabar,
                            title: "清除全部会议数据",
                            showChevron: false
                        )
                    }
                    .buttonStyle(SettingsPressStyle())
                }

                Text("清除不会删除 Keychain 中的 API Key。如需一并清除，请到偏好设置中手动移除。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.6))
                    .lineSpacing(Leading.tight)

                if !status.isEmpty {
                    Text(status)
                        .font(.recapMeta)
                        .foregroundStyle(Color.recapTea)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("数据与隐私")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "清除全部会议？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清除 \(meetings.count) 条会议", role: .destructive, action: clearAllMeetings)
            Button("取消", role: .cancel) {}
        } message: {
            Text("录音、转写、纪要与待办将从本机删除，且无法恢复。已保存的声纹特征与「我」标记也将一并移除。")
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("本机数据")
                .font(.recapEyebrow)
                .tracking(Tracking.eyebrow)
                .foregroundStyle(Color.recapTea)
            Text("\(meetings.count) 场会议保存在此设备")
                .font(.recapTitleS)
                .foregroundStyle(Color.recapInk)
            Text("默认不上传会议内容。仅在你选择云端引擎或云端模型时，相关片段才会发往对应服务商。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
                .lineSpacing(Leading.tight)
        }
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearAllMeetings() {
        MeetingDeletion.deleteAll(meetings, in: modelContext)
        // 隐私政策承诺：清除会议数据一并移除声纹（生物识别信息）并撤回同意。
        VoiceprintGallery.shared.clearAll()
        VoiceprintConsent.reset()
        status = "已清除全部会议数据"
    }
}

/// 关于 Recap。
struct AboutRecapView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xxl) {
                VStack(spacing: Spacing.md) {
                    Text("纪要")
                        .font(.recapHero)
                        .tracking(Tracking.hero)
                        .foregroundStyle(Color.recapInk)
                    Text("把会议变成可行动的纪要")
                        .font(.recapBodyS)
                        .foregroundStyle(Color.recapTea)
                    Text(versionLabel)
                        .font(.recapMono)
                        .foregroundStyle(Color.recapTea.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Spacing.xxl)

                VStack(spacing: 0) {
                    Link(destination: RecapLegal.supportURL) {
                        SettingsNavRow(
                            icon: "questionmark.circle",
                            iconTint: .recapInk,
                            title: "帮助与支持"
                        )
                    }
                    SettingsDivider()
                    Link(destination: URL(string: "mailto:\(RecapLegal.supportEmail)")!) {
                        SettingsNavRow(
                            icon: "envelope",
                            iconTint: .recapInk,
                            title: "联系我们",
                            value: RecapLegal.supportEmail
                        )
                    }
                    SettingsDivider()
                    NavigationLink {
                        LegalDocumentView(kind: .privacy)
                    } label: {
                        SettingsNavRow(
                            icon: "hand.raised",
                            iconTint: .recapInk,
                            title: "隐私政策"
                        )
                    }
                    SettingsDivider()
                    NavigationLink {
                        DataPrivacySettingsView()
                    } label: {
                        SettingsNavRow(
                            icon: "lock.shield",
                            iconTint: .recapInk,
                            title: "数据与隐私",
                            value: "清除"
                        )
                    }
                    SettingsDivider()
                    NavigationLink {
                        LegalDocumentView(kind: .terms)
                    } label: {
                        SettingsNavRow(
                            icon: "doc.text",
                            iconTint: .recapInk,
                            title: "用户协议"
                        )
                    }
                    SettingsDivider()
                    NavigationLink {
                        OpenSourceAcknowledgementsView()
                    } label: {
                        SettingsNavRow(
                            icon: "checkmark.seal",
                            iconTint: .recapInk,
                            title: "开源许可致谢"
                        )
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "版本 \(short)（\(build)）"
    }
}

/// 开源许可致谢（随包分发的第三方组件与模型权重来源）。
/// License 类型均按本地 SPM checkout 的 LICENSE 文件核实（2026-08-15）。
struct OpenSourceAcknowledgementsView: View {
    /// (名称, 许可, 用途)
    private static let libraries: [(name: String, license: String, role: String)] = [
        ("mermaid.js", "MIT", "Markdown 图表渲染（流程图 / 时序图）"),
        ("FluidAudio", "Apache-2.0", "端侧语音转写与说话人分离"),
        ("argmax SpeakerKit (argmax-oss-swift)", "MIT", "端侧说话人声纹嵌入"),
        ("OpenAI Swift SDK (MacPaw)", "MIT", "大模型 API 客户端"),
        ("swift-argument-parser", "Apache-2.0", "命令行参数解析（依赖传递）"),
        ("swift-http-types", "Apache-2.0", "HTTP 类型（依赖传递）"),
        ("swift-openapi-runtime", "Apache-2.0", "OpenAPI 运行时（依赖传递）"),
    ]

    /// 模型权重：代码许可与权重发布条款分开，如实注明来源与条款位置。
    private static let modelWeights: [(name: String, source: String, terms: String)] = [
        ("SenseVoice 语音识别模型", "FunAudioLLM（Hugging Face / hf-mirror 分发）", "权重遵循其发布页条款"),
        ("pyannote 说话人分离模型", "pyannote-audio（Hugging Face / hf-mirror 分发）", "代码 MIT；权重遵循 HF 发布页条款"),
        ("WeSpeaker 声纹模型", "WeSpeaker（Hugging Face / hf-mirror 分发）", "代码 Apache-2.0；权重遵循 HF 发布页条款"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("开源组件")
                        .font(.recapEyebrow)
                        .tracking(Tracking.eyebrow)
                        .foregroundStyle(Color.recapTea)
                    VStack(spacing: 0) {
                        ForEach(Array(Self.libraries.enumerated()), id: \.offset) { index, item in
                            if index > 0 { SettingsDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.name)
                                        .font(.recapBodyS.weight(.medium))
                                        .foregroundStyle(Color.recapInk)
                                    Spacer()
                                    Text(item.license)
                                        .font(.recapMono)
                                        .foregroundStyle(Color.recapTea.opacity(0.85))
                                }
                                Text(item.role)
                                    .font(.recapMeta)
                                    .foregroundStyle(Color.recapTea.opacity(0.7))
                            }
                            .padding(.vertical, Spacing.sm)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("内置模型权重")
                        .font(.recapEyebrow)
                        .tracking(Tracking.eyebrow)
                        .foregroundStyle(Color.recapTea)
                    VStack(spacing: 0) {
                        ForEach(Array(Self.modelWeights.enumerated()), id: \.offset) { index, item in
                            if index > 0 { SettingsDivider() }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.recapBodyS.weight(.medium))
                                    .foregroundStyle(Color.recapInk)
                                Text(item.source)
                                    .font(.recapMeta)
                                    .foregroundStyle(Color.recapTea.opacity(0.7))
                                Text(item.terms)
                                    .font(.recapMeta)
                                    .foregroundStyle(Color.recapTea.opacity(0.7))
                            }
                            .padding(.vertical, Spacing.sm)
                        }
                    }
                }

                Text("以上各项目的完整许可文本以其官方仓库 LICENSE 文件为准。感谢这些开源项目使「纪要」成为可能。")
                    .font(.recapMeta)
                    .foregroundStyle(Color.recapTea.opacity(0.6))
                    .lineSpacing(Leading.tight)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xxxl)
        }
        .scrollIndicators(.hidden)
        .background(SettingsAmbientBackground())
        .navigationTitle("开源许可致谢")
        .navigationBarTitleDisplayMode(.inline)
    }
}
