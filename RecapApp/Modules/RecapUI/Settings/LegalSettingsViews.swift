import SwiftUI
import SwiftData
import RecapModels

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

/// 数据导出 / 清除（过审：用户对本地数据的控制）。
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
                        status = "导出将在后续版本提供（JSON / Markdown）"
                    } label: {
                        SettingsNavRow(
                            icon: "square.and.arrow.up",
                            iconTint: .recapInk,
                            title: "导出会议数据",
                            value: "即将推出"
                        )
                    }
                    .buttonStyle(SettingsPressStyle())

                    SettingsDivider()

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
            Text("录音、转写、纪要与待办将从本机删除，且无法恢复。")
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
                            value: "导出 / 清除"
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
