import SwiftUI
import RecapModels
import RecapASR
import RecapLLM

/// 设置首页：账户 / 智能服务源头 / 隐私合规 / 关于。
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MembershipStore.self) private var membership

    /// 从子页返回时自增，迫使首页重读 UserDefaults / 账户状态。
    @State private var refreshToken = 0
    @State private var showDebug = false

    public init() {}

    private var account: RecapAccount {
        _ = refreshToken
        return RecapAccountStore.current
    }

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

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center, spacing: Spacing.xl) {
                    usageDashboardSection

                    VStack(alignment: .leading, spacing: Spacing.md) {
                        plaudNavigationList
#if DEBUG
                        debugSection
#endif
                    }
                    .padding(.top, Spacing.sm)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.xxxl)
            }
            .scrollIndicators(.hidden)
            .background(SettingsAmbientBackground())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.recapInk)
                }
            }
            .sheet(isPresented: $showDebug) {
                ScaffoldDebugView()
            }
            .onAppear {
                Haptics.prepare()
                refreshToken += 1
            }
        }
    }

    // MARK: - Plaud AI Style 4 Top-Level Entry List

    private var plaudNavigationList: some View {
        VStack(spacing: 0) {
            // 1. 个性化设置
            NavigationLink {
                PersonalizationSettingsView()
            } label: {
                SettingsNavRow(
                    icon: "slider.horizontal.3",
                    iconTint: .recapInk,
                    title: "个性化设置"
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            // 2. 偏好设置
            NavigationLink {
                PreferencesSettingsView()
                    .onDisappear { refreshToken += 1 }
            } label: {
                SettingsNavRow(
                    icon: "slider.horizontal.2.square",
                    iconTint: .recapInk,
                    title: "偏好设置"
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            // 3. 账号
            NavigationLink {
                AccountSettingsView()
                    .onDisappear { refreshToken += 1 }
            } label: {
                SettingsNavRow(
                    icon: "person",
                    iconTint: .recapInk,
                    title: "账号",
                    value: account.isSignedIn ? account.displayName : "未登录"
                )
            }
            .buttonStyle(SettingsPressStyle())

            SettingsDivider()

            // 4. 帮助与支持
            Link(destination: RecapLegal.supportURL) {
                SettingsNavRow(
                    icon: "questionmark.square",
                    iconTint: .recapInk,
                    title: "帮助与支持"
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

#if DEBUG
    private var debugSection: some View {
        SettingsSection(title: "开发") {
            Button { showDebug = true } label: {
                SettingsNavRow(
                    icon: "ant.fill",
                    iconTint: .recapCinnabar,
                    title: "冒烟测试",
                    showChevron: true
                )
            }
            .buttonStyle(SettingsPressStyle())
        }
    }
#endif

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: - Plaud AI Style Usage Dashboard & Activity Heatmap

    private var usageDashboardSection: some View {
        VStack(spacing: Spacing.lg) {
            // Top circular badge / ID
            VStack(spacing: Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(Color(light: 0xECEEEF, dark: 0x1E2228))
                        .frame(width: 84, height: 84)
                    Text("0")
                        .font(.system(size: 38, weight: .regular, design: .default))
                        .foregroundStyle(Color.recapInk)
                }

                Text("RECAP - 0420")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.recapTea)
                    .padding(.top, 2)
            }
            .padding(.top, Spacing.sm)

            // Core 3 Metrics
            HStack(spacing: 0) {
                metricColumn(label: "使用天数", value: "1", unit: "")
                Spacer()
                metricColumn(label: "录音总数", value: "6", unit: "")
                Spacer()
                metricColumn(label: "总使用时长", value: "0.8", unit: "小时")
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.xs)

            // GitHub style Activity Heatmap Grid
            ActivityHeatmapGrid()
                .padding(.top, Spacing.xs)
        }
        .padding(.vertical, Spacing.md)
    }

    private func metricColumn(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.recapTea)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .medium, design: .default))
                    .foregroundStyle(Color.recapInk)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.recapTea)
                }
            }
        }
        .frame(minWidth: 80)
    }
}

/// Plaud AI / GitHub 风格打卡热力图网格（7行 x 22列）
private struct ActivityHeatmapGrid: View {
    private let rowIndices = Array(0..<7)
    private let columnIndices = Array(0..<22)
    private let activeIndex = (row: 1, col: 21) // 当前活跃卡点

    var body: some View {
        VStack(spacing: 3) {
            ForEach(rowIndices, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(columnIndices, id: \.self) { col in
                        let isActive = (row == activeIndex.row && col == activeIndex.col)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(
                                isActive
                                ? Color(hex: 0x38C5F2) // Plaud 经典天蓝色高亮
                                : Color(light: 0xEAECEE, dark: 0x1F2329)
                            )
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.xs)
    }
}
