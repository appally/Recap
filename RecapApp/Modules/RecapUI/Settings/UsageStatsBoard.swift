import SwiftUI
import SwiftData
import RecapModels

/// 使用数据看板：核心指标三栏 + 近一年活动热力图（极简平面排版）。
/// 嵌入会员详情页，作为「计划与用量」的一部分。
struct UsageStatsBoard: View {
    let meetings: [Meeting]

    var body: some View {
        let stats = UsageStats(meetings: meetings)
        let duration = usageDurationPair(stats.totalSeconds)

        return VStack(alignment: .leading, spacing: Spacing.xxl) {
            // Core 3 Metrics (极简无边框平面三栏)
            HStack(spacing: 0) {
                metricColumn(label: "使用天数", value: "\(stats.activeDays)", unit: "天")

                Rectangle()
                    .fill(Color.recapTea.opacity(0.12))
                    .frame(width: 0.5, height: 36)

                metricColumn(label: "录音总数", value: "\(stats.recordingCount)", unit: "首")

                Rectangle()
                    .fill(Color.recapTea.opacity(0.12))
                    .frame(width: 0.5, height: 36)

                metricColumn(label: "总使用时长", value: duration.value, unit: duration.unit)
            }
            .padding(.vertical, Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(light: 0xF7F8F9, dark: 0x16181C))
            )

            // Heatmap Section (平面热力网格)
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("近一年活动热力")
                    .font(.recapEyebrow)
                    .tracking(Tracking.eyebrow)
                    .foregroundStyle(Color.recapTea)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ActivityHeatmapGrid(dailyCounts: stats.dailyCounts, showMonthLabels: true)
                        .padding(.vertical, Spacing.sm)
                }
                .padding(Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(light: 0xF7F8F9, dark: 0x16181C))
                )
            }
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
        VStack(spacing: 4) {
            Text(label)
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.recapTitle)
                    .foregroundStyle(Color.recapInk)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.recapCaption)
                        .foregroundStyle(Color.recapTea)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 近一年活动热力图（53 周 × 7 天）。横向滚动，初始定位到今天。
struct ActivityHeatmapGrid: View {
    let dailyCounts: [Date: Int]
    var showMonthLabels: Bool = true

    private let calendar = Calendar.current
    private let cellSize: CGFloat = 10
    private let spacing: CGFloat = 3
    private let weekCount = 53

    private var todayStart: Date { calendar.startOfDay(for: .now) }

    private var firstColumnDay: Date {
        let weekday = calendar.component(.weekday, from: todayStart)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        let thisWeekStart = calendar.date(byAdding: .day, value: -offset, to: todayStart)!
        return calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: thisWeekStart)!
    }

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
            .padding(.horizontal, 2)
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
                ? Color(light: 0xE5E8EC, dark: 0x22262D)
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
                    .font(.recapCaption)
                    .foregroundStyle(Color.recapTea)
                    .frame(width: cellSize, alignment: .leading)
            }
        }
    }

    private func monthLabel(forColumn col: Int) -> String? {
        let month = calendar.component(.month, from: day(col: col, row: 0))
        guard col > 0 else { return "\(month)" }
        let prev = calendar.component(.month, from: day(col: col - 1, row: 0))
        return month != prev ? "\(month)" : nil
    }
}
