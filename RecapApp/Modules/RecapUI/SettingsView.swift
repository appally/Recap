import SwiftUI
import RecapModels
import RecapASR
import RecapLLM
import SwiftData

/// 设置首页：账户 / 智能服务源头 / 隐私合规 / 关于。
public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MembershipStore.self) private var membership

    /// 会议数据（看板 + 热力图的数据源）。sheet 内自动共享根 container。
    @Query private var meetings: [Meeting]

    /// 从子页返回时自增，迫使首页重读 UserDefaults / 账户状态。
    @State private var refreshToken = 0
    @State private var showDebug = false
    @State private var showAccount = false
    @State private var showMembership = false
    @State private var profileStatus = ""

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
                    profileHeader

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
            .navigationDestination(isPresented: $showAccount) {
                AccountSettingsView()
                    .onDisappear { refreshToken += 1 }
            }
            .navigationDestination(isPresented: $showMembership) {
                MembershipSettingsView()
            }
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
            Button {
                showAccount = true
            } label: {
                SettingsNavRow(
                    icon: "person",
                    iconTint: .recapInk,
                    title: "账号"
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

    // MARK: - 居中英雄头像 + 使用看板

    /// 顶部：极简居中英雄头像 + 使用看板（统计 + 无噪电光青热力图）。
    private var profileHeader: some View {
        VStack(spacing: Spacing.xl) {
            identityHero
            usageDashboardSection
            SettingsInlineNotice(message: $profileStatus)
        }
    }

    /// 居中大型英雄头像（与附图 21:50 风格一致）
    private var identityHero: some View {
        Button {
            showAccount = true
        } label: {
            VStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(Color(light: 0xECEEEF, dark: 0x22262B))
                        .frame(width: 96, height: 96)

                    if account.isSignedIn {
                        Text(account.initials.isEmpty ? "0" : account.initials)
                            .font(.system(size: 38, weight: .regular, design: .default))
                            .foregroundStyle(Color.recapInk)
                    } else {
                        Text("0")
                            .font(.system(size: 38, weight: .regular, design: .default))
                            .foregroundStyle(Color.recapInk)
                    }
                }

                Text(account.isSignedIn ? (account.displayName.isEmpty ? "0420" : account.displayName) : "0420")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.recapInk)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .accessibilityLabel("账号")
    }

    // MARK: - Usage Dashboard & Activity Heatmap

    private var usageDashboardSection: some View {
        let stats = UsageStats(meetings: meetings)
        let duration = usageDurationPair(stats.totalSeconds)

        return VStack(spacing: Spacing.xl) {
            // Core 3 Metrics
            HStack(spacing: 0) {
                metricColumn(label: "使用天数", value: "\(stats.activeDays)", unit: "")
                Spacer()
                metricColumn(label: "录音总数", value: "\(stats.recordingCount)", unit: "")
                Spacer()
                metricColumn(label: "总使用时长", value: duration.value, unit: duration.unit)
            }
            .padding(.horizontal, Spacing.lg)

            // 近一年活动热力图（极简无顶标尺、电光青点缀）
            ActivityHeatmapGrid(dailyCounts: stats.dailyCounts, showMonthLabels: false)
                .padding(.top, Spacing.xs)
        }
    }

    /// 总时长格式化：<1 小时显示分钟，否则保留 1 位小数小时。
    private func usageDurationPair(_ seconds: Double) -> (value: String, unit: String) {
        let hours = seconds / 3600
        if hours >= 1 {
            return (String(format: "%.1f", hours), "小时")
        } else {
            let minutes = max(1, Int((seconds / 60).rounded()))
            return ("\(minutes)", "分钟")
        }
    }

    private func metricColumn(label: String, value: String, unit: String) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.recapTea)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 28, weight: .regular, design: .default))
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

/// 近一年活动热力图（53 周 × 7 天）。横向滚动，初始定位到今天。
private struct ActivityHeatmapGrid: View {
    let dailyCounts: [Date: Int]
    var showMonthLabels: Bool = false

    private let calendar = Calendar.current
    private let cellSize: CGFloat = 10
    private let spacing: CGFloat = 3
    private let weekCount = 53

    private var todayStart: Date { calendar.startOfDay(for: .now) }

    /// 最左列的起始日：本周首日往回推 (weekCount-1) 周。
    private var firstColumnDay: Date {
        let weekday = calendar.component(.weekday, from: todayStart)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let thisWeekStart = calendar.date(byAdding: .day, value: -offset, to: todayStart)!
        return calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: thisWeekStart)!
    }

    /// 第 col 列第 row 行对应的自然日（00:00，与 dailyCounts 的 key 对齐）。
    private func day(col: Int, row: Int) -> Date {
        calendar.date(byAdding: .day, value: col * 7 + row, to: firstColumnDay)!
    }

    var body: some View {
        let columns = Array(0..<weekCount)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: spacing) {
                if showMonthLabels {
                    monthLabelsRow(columns: columns)
                }
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(columns, id: \.self) { col in
                        columnView(col)
                    }
                }
            }
            .padding(.horizontal, Spacing.xs)
        }
        .defaultScrollAnchor(.trailing)
    }

    private func columnView(_ col: Int) -> some View {
        VStack(spacing: spacing) {
            ForEach(0..<7, id: \.self) { row in
                cellView(col: col, row: row)
            }
        }
    }

    private func cellView(col: Int, row: Int) -> some View {
        let date = day(col: col, row: row)
        let count = dailyCounts[date] ?? 0
        let level = UsageStats.level(forDailyCount: count)
        let isToday = calendar.isDateInToday(date)
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(
                level == 0
                ? Color(light: 0xEEF0F2, dark: 0x1F2329)
                : Color.heatmapLevel(level)
            )
            .frame(width: cellSize, height: cellSize)
            .overlay(
                isToday && count > 0
                ? RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.recapAICyan, lineWidth: 1)
                : nil
            )
    }

    private func monthLabelsRow(columns: [Int]) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(columns, id: \.self) { col in
                Text(monthLabel(forColumn: col) ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.recapTea)
                    .frame(width: cellSize, alignment: .leading)
            }
        }
    }

    /// 月份切换的首列返回月份数字，其余 nil。
    private func monthLabel(forColumn col: Int) -> String? {
        let month = calendar.component(.month, from: day(col: col, row: 0))
        guard col > 0 else { return "\(month)" }
        let prev = calendar.component(.month, from: day(col: col - 1, row: 0))
        return month != prev ? "\(month)" : nil
    }
}
